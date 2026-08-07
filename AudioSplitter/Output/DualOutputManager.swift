//
//  DualOutputManager.swift
//  AudioSplitter
//
//  Mengelola dua AVAudioEngine terpisah:
//    - engineBass       -> di-assign ke external device (subwoofer/speaker bass)
//    - engineMidTreble  -> di-assign ke built-in speaker Mac
//
//  TODO (lihat task list Fase 3):
//   - Implementasi assignment device via kAudioOutputUnitProperty_CurrentDevice
//     pada AVAudioOutputNode/AudioUnit yang mendasarinya.
//   - Tambahkan handling hot-plug: kalau external device dicabut, hentikan
//     engineBass dengan graceful, jangan crash.
//   - Sinkronisasi buffer scheduling supaya kedua engine mainkan sample yang
//     berkorespondensi pada waktu yang sama (pakai AVAudioTime yang sama).
//

import AVFoundation
import CoreAudio

enum OutputRoutingError: Error {
    case deviceAssignmentFailed(String)
    case engineStartFailed(String)
}

final class DualOutputManager {

    private let engineBass = AVAudioEngine()
    private let engineMidTreble = AVAudioEngine()

    private let bassPlayerNode = AVAudioPlayerNode()
    private let midTreblePlayerNode = AVAudioPlayerNode()

    private(set) var bassDeviceID: AudioDeviceID?
    private(set) var midTrebleDeviceID: AudioDeviceID?

    init() {
        engineBass.attach(bassPlayerNode)
        engineMidTreble.attach(midTreblePlayerNode)
    }

    /// Tetapkan device output untuk masing-masing jalur.
    /// `bassDeviceID` biasanya external device (subwoofer/soundbar).
    /// `midTrebleDeviceID` biasanya built-in speaker Mac.
    func configureDevices(bassDeviceID: AudioDeviceID, midTrebleDeviceID: AudioDeviceID) throws {
        self.bassDeviceID = bassDeviceID
        self.midTrebleDeviceID = midTrebleDeviceID

        try assignDevice(bassDeviceID, to: engineBass)
        try assignDevice(midTrebleDeviceID, to: engineMidTreble)
    }

    private func assignDevice(_ deviceID: AudioDeviceID, to engine: AVAudioEngine) throws {
        // TODO: ambil AudioUnit dari engine.outputNode.audioUnit, lalu set
        // property kAudioOutputUnitProperty_CurrentDevice dengan deviceID.
        //
        // guard let audioUnit = engine.outputNode.audioUnit else {
        //     throw OutputRoutingError.deviceAssignmentFailed("No AudioUnit on output node")
        // }
        // var mutableDeviceID = deviceID
        // let status = AudioUnitSetProperty(
        //     audioUnit,
        //     kAudioOutputUnitProperty_CurrentDevice,
        //     kAudioUnitScope_Global,
        //     0,
        //     &mutableDeviceID,
        //     UInt32(MemoryLayout<AudioDeviceID>.size)
        // )
        // guard status == noErr else {
        //     throw OutputRoutingError.deviceAssignmentFailed("OSStatus \(status)")
        // }
    }

    func start() throws {
        do {
            let bassFormat = engineBass.outputNode.inputFormat(forBus: 0)
            let midFormat = engineMidTreble.outputNode.inputFormat(forBus: 0)
            engineBass.connect(bassPlayerNode, to: engineBass.mainMixerNode, format: bassFormat)
            engineMidTreble.connect(midTreblePlayerNode, to: engineMidTreble.mainMixerNode, format: midFormat)

            try engineBass.start()
            try engineMidTreble.start()

            bassPlayerNode.play()
            midTreblePlayerNode.play()
        } catch {
            throw OutputRoutingError.engineStartFailed(error.localizedDescription)
        }
    }

    func stop() {
        bassPlayerNode.stop()
        midTreblePlayerNode.stop()
        engineBass.stop()
        engineMidTreble.stop()
    }

    /// Jadwalkan buffer bass ke jalur external device.
    func scheduleBass(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        bassPlayerNode.scheduleBuffer(buffer, at: time, options: .interrupts)
    }

    /// Jadwalkan buffer mid/treble ke jalur built-in speaker.
    func scheduleMidTreble(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        midTreblePlayerNode.scheduleBuffer(buffer, at: time, options: .interrupts)
    }
}
