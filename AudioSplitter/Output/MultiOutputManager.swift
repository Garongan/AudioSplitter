//
//  MultiOutputManager.swift
//  AudioSplitter
//
//  Mengelola banyak AVAudioEngine terpisah (satu engine per device output fisik).
//  Mendukung query format native masing-masing device secara dinamis lewat Core Audio HAL,
//  EQ independen per device, serta per-device delay compensation untuk sinkronisasi audio.
//

import AVFoundation
import CoreAudio

public enum AudioOutputError: Error {
    case deviceUnavailable(deviceID: AudioDeviceID)
    case formatNegotiationFailed(reason: String)
    case engineStartFailed(underlying: Error)
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

    public func configure(preferredMaxChannels: Int? = nil) throws {
        // Format Sumber default dari Crossover: 48kHz, Stereo
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2)!

        // 1. Tetapkan physical output device pada output unit terlebih dahulu
        try assignDevice(deviceID, to: engine)

        // 2. Programmatic Query Format Native dari Perangkat Output Fisik
        let (nativeRate, nativeChannels) = getDeviceNativeInfo(deviceID)

        // 3. Tentukan channels dengan format standard float
        // Gunakan preferredMaxChannels jika diberikan, jika tidak, batasi sesuai channel native atau default ke 2.
        let targetChannels: UInt32
        if let maxChannels = preferredMaxChannels {
            targetChannels = UInt32(min(Int(nativeChannels), maxChannels))
        } else {
            // Default behavior: batasi maksimal 2 channel untuk output standard
            targetChannels = min(nativeChannels, 2)
        }

        let targetRate = nativeRate > 0.0 ? nativeRate : 48000.0
        let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: targetRate,
            channels: AVAudioChannelCount(targetChannels > 0 ? targetChannels : 2)
        ) ?? sourceFormat

        // 4. Hubungkan player -> EQ menggunakan source format (48kHz)
        engine.connect(playerNode, to: eqNode, format: sourceFormat)

        // 5. Hubungkan EQ -> Mixer menggunakan source format (48kHz).
        //    Menghindari format mismatch pada effect node.
        engine.connect(eqNode, to: engine.mainMixerNode, format: sourceFormat)

        // 6. Hubungkan Mixer -> Output menggunakan format nil secara eksplisit.
        //    Untuk menghindari kAudioUnitErr_FormatNotSupported (-10868), koneksi ke output unit
        //    harus membiarkan AVAudioEngine bernegosiasi secara otomatis dengan format native device fisik.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

        // Konfigurasi awal 3-band parametric EQ (Bass, Mid, Treble)
        setupEQ()
    }

    private func assignDevice(_ deviceID: AudioDeviceID, to engine: AVAudioEngine) throws {
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw AudioOutputError.deviceUnavailable(deviceID: deviceID)
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
            throw AudioOutputError.deviceUnavailable(deviceID: deviceID)
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
            throw AudioOutputError.engineStartFailed(underlying: error)
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

    /// Query nominal sample rate and channel count directly from Core Audio HAL.
    private func getDeviceNativeInfo(_ deviceID: AudioDeviceID) -> (sampleRate: Double, channelCount: UInt32) {
        var sampleRate: Double = 48000.0
        var channelCount: UInt32 = 2

        // 1. Query Nominal Sample Rate
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        var rateSize = UInt32(MemoryLayout<Double>.size)
        let rateStatus = AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &rateSize, &sampleRate)

        // 2. Query Channel Count via Stream Configuration
        var configAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        var configSize: UInt32 = 0
        let configStatusSize = AudioObjectGetPropertyDataSize(deviceID, &configAddress, 0, nil, &configSize)
        if configStatusSize == noErr && configSize > 0 {
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { pointer.deallocate() }
            let configStatusData = AudioObjectGetPropertyData(deviceID, &configAddress, 0, nil, &configSize, pointer)
            if configStatusData == noErr {
                let bufferList = pointer.assumingMemoryBound(to: AudioBufferList.self)
                let audioBufferListPointer = UnsafeMutableAudioBufferListPointer(bufferList)
                var totalChannels: UInt32 = 0
                for buffer in audioBufferListPointer {
                    totalChannels += buffer.mNumberChannels
                }
                if totalChannels > 0 {
                    channelCount = totalChannels
                }
            }
        } else {
            // Fallback to Stream Format if Stream Configuration is not available
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: 0
            )
            var streamDesc = AudioStreamBasicDescription()
            var streamSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let streamStatus = AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamSize, &streamDesc)
            if streamStatus == noErr {
                if streamDesc.mChannelsPerFrame > 0 {
                    channelCount = streamDesc.mChannelsPerFrame
                }
                if rateStatus != noErr && streamDesc.mSampleRate > 0.0 {
                    sampleRate = streamDesc.mSampleRate
                }
            }
        }

        return (sampleRate, channelCount)
    }
}

public final class MultiOutputManager {

    private var deviceStates: [AudioDeviceID: DeviceOutputState] = [:]
    private var isRunning = false

    public init() {}

    /// Mengonfigurasi engine baru untuk list device id yang aktif saat ini dengan preferred max channel count.
    public func updateActiveDevices(_ deviceIDs: [AudioDeviceID], preferredChannels: [AudioDeviceID: Int] = [:]) throws {
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
                try state.configure(preferredMaxChannels: preferredChannels[id])
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
