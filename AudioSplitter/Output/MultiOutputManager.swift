//
//  MultiOutputManager.swift
//  AudioSplitter
//
//  Mengelola banyak AVAudioEngine terpisah (satu engine per device output fisik).
//  Mendukung query format native masing-masing device, EQ independen per device,
//  serta per-device delay compensation untuk sinkronisasi audio yang presisi.
//

import AVFoundation
import CoreAudio

public enum OutputRoutingError: Error {
    case deviceAssignmentFailed(String)
    case engineStartFailed(String)
}

public final class DeviceOutputState {
    public let engine = AVAudioEngine()
    public let playerNode = AVAudioPlayerNode()
    public let eqNode = AVAudioUnitEQ(numberOfBands: 3)
    public let deviceID: AudioDeviceID

    private var isEngineRunning = false

    public init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
        engine.attach(playerNode)
        engine.attach(eqNode)
    }

    public func configure() throws {
        let format = getDeviceNativeFormat(deviceID)

        // Hubungkan player -> EQ -> Mixer -> Output
        engine.connect(playerNode, to: eqNode, format: format)
        engine.connect(eqNode, to: engine.mainMixerNode, format: format)

        // Tetapkan physical output device pada output unit
        try assignDevice(deviceID, to: engine)

        // Konfigurasi awal 3-band parametric EQ (Bass, Mid, Treble)
        setupEQ()
    }

    private func assignDevice(_ deviceID: AudioDeviceID, to engine: AVAudioEngine) throws {
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw OutputRoutingError.deviceAssignmentFailed("No AudioUnit on output node")
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw OutputRoutingError.deviceAssignmentFailed("Gagal menetapkan kAudioOutputUnitProperty_CurrentDevice (OSStatus \(status))")
        }
    }

    private func setupEQ() {
        // Band 0: Bass (Low Shelf)
        eqNode.bands[0].filterType = .lowShelf
        eqNode.bands[0].frequency = 150.0 // Hz
        eqNode.bands[0].gain = 0.0 // Flat (dB)
        eqNode.bands[0].bypass = false

        // Band 1: Mid (Parametric / Peaking)
        eqNode.bands[1].filterType = .parametric
        eqNode.bands[1].frequency = 1000.0 // Hz
        eqNode.bands[1].bandwidth = 1.5 // Octaves
        eqNode.bands[1].gain = 0.0 // Flat (dB)
        eqNode.bands[1].bypass = false

        // Band 2: Treble (High Shelf)
        eqNode.bands[2].filterType = .highShelf
        eqNode.bands[2].frequency = 4000.0 // Hz
        eqNode.bands[2].gain = 0.0 // Flat (dB)
        eqNode.bands[2].bypass = false
    }

    public func updateEQ(bassGainDb: Double, midGainDb: Double, trebleGainDb: Double) {
        eqNode.bands[0].gain = Float(bassGainDb)
        eqNode.bands[1].gain = Float(midGainDb)
        eqNode.bands[2].gain = Float(trebleGainDb)
    }

    public func updateVolume(_ volume: Double) {
        playerNode.volume = Float(volume)
    }

    public func start() throws {
        guard !isEngineRunning else { return }
        do {
            try engine.start()
            playerNode.play()
            isEngineRunning = true
        } catch {
            throw OutputRoutingError.engineStartFailed(error.localizedDescription)
        }
    }

    public func stop() {
        playerNode.stop()
        engine.stop()
        isEngineRunning = false
    }

    public func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        playerNode.scheduleBuffer(buffer, at: time, options: .interrupts)
    }

    private func getDeviceNativeFormat(_ deviceID: AudioDeviceID) -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: 0
        )
        var sampleRate: Double = 48000.0
        var size = UInt32(MemoryLayout<Double>.size)
        var status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        if status != noErr {
            sampleRate = 48000.0
        }

        var channelAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: 0
        )
        var channelSize: UInt32 = 0
        status = AudioObjectGetPropertyDataSize(deviceID, &channelAddress, 0, nil, &channelSize)
        var channels = 2
        if status == noErr, channelSize > 0 {
            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(channelSize))
            defer { bufferList.deallocate() }
            status = AudioObjectGetPropertyData(deviceID, &channelAddress, 0, nil, &channelSize, bufferList)
            if status == noErr {
                var totalChannels = 0
                let count = Int(bufferList.pointee.mNumberBuffers)
                let buffers = UnsafeMutableBufferPointer(start: &bufferList.pointee.mBuffers, count: count)
                for i in 0..<count {
                    totalChannels += Int(buffers[i].mNumberChannels)
                }
                if totalChannels > 0 {
                    channels = totalChannels
                }
            }
        }

        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) ?? AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2)!
    }
}

public final class MultiOutputManager {

    private var deviceStates: [AudioDeviceID: DeviceOutputState] = [:]
    private var isRunning = false

    public init() {}

    /// Mengonfigurasi engine baru untuk list device id yang aktif saat ini.
    public func updateActiveDevices(_ deviceIDs: [AudioDeviceID]) throws {
        // Hentikan dan hapus device yang tidak lagi aktif
        for (id, state) in deviceStates {
            if !deviceIDs.contains(id) {
                state.stop()
                deviceStates.removeValue(forKey: id)
            }
        }

        // Tambah dan inisialisasi device baru
        for id in deviceIDs {
            if deviceStates[id] == nil {
                let state = DeviceOutputState(deviceID: id)
                try state.configure()
                if isRunning {
                    try state.start()
                }
                deviceStates[id] = state
            }
        }
    }

    public func updateDeviceEQ(deviceID: AudioDeviceID, bassGainDb: Double, midGainDb: Double, trebleGainDb: Double) {
        deviceStates[deviceID]?.updateEQ(bassGainDb: bassGainDb, midGainDb: midGainDb, trebleGainDb: trebleGainDb)
    }

    public func updateDeviceVolume(deviceID: AudioDeviceID, volume: Double) {
        deviceStates[deviceID]?.updateVolume(volume)
    }

    public func start() throws {
        guard !isRunning else { return }
        for state in deviceStates.values {
            try state.start()
        }
        isRunning = true
    }

    public func stop() {
        for state in deviceStates.values {
            state.stop()
        }
        isRunning = false
    }

    /// Menjadwalkan buffer ke device tertentu dengan parameter delay compensation.
    public func scheduleBuffer(_ buffer: AVAudioPCMBuffer, onDevice deviceID: AudioDeviceID, anchorTime: AVAudioTime?, delaySeconds: Double) {
        guard let state = deviceStates[deviceID] else { return }

        if delaySeconds <= 0.0 || anchorTime == nil {
            state.scheduleBuffer(buffer, at: anchorTime)
        } else if let anchor = anchorTime {
            // Hitung future time berdasarkan delay offset
            let sampleRate = buffer.format.sampleRate
            let delaySamples = AVAudioFramePosition(delaySeconds * sampleRate)
            let futureSampleTime = anchor.sampleTime + delaySamples

            let futureTime = AVAudioTime(sampleTime: futureSampleTime, atRate: sampleRate)
            state.scheduleBuffer(buffer, at: futureTime)
        }
    }
}
