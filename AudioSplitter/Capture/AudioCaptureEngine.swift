//
//  AudioCaptureEngine.swift
//  AudioSplitter
//
//  Bertanggung jawab menangkap audio sistem/aplikasi menjadi PCM buffer.
//  Dua strategi:
//    1. CoreAudioProcessTap  -> macOS 14.4+, native, tidak perlu driver tambahan.
//    2. BlackHoleCapture     -> fallback untuk macOS lama, butuh instalasi
//                               virtual driver BlackHole oleh user.
//
//  TODO (lihat task list Fase 1):
//   - Implementasikan AudioHardwareCreateProcessTap (lihat WWDC24 "Capture
//     system audio in your app") untuk strategi utama.
//   - Implementasikan device discovery untuk BlackHole sebagai fallback.
//   - Pastikan format buffer (Float32, sample rate, channel count) konsisten
//     sebelum diteruskan ke CrossoverFilter.
//

import AVFoundation
import CoreAudio

/// Kontrak umum untuk sumber audio, supaya strategi capture bisa ditukar
/// tanpa mengubah kode di layer DSP / Output.
protocol AudioSource: AnyObject {
    /// Dipanggil setiap kali ada buffer baru dari sistem.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? { get set }

    func start() throws
    func stop()
}

enum AudioCaptureError: Error {
    case permissionDenied
    case processTapUnavailable
    case deviceNotFound
    case engineStartFailed(String)
}

/// Strategi utama: Core Audio Process Tap (macOS 14.4+).
/// Menangkap audio dari proses tertentu atau seluruh sistem tanpa
/// perlu instalasi virtual driver.
final class CoreAudioProcessTapSource: AudioSource {

    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown

    func start() throws {
        // TODO:
        // 1. Buat CATapDescription (system-wide atau per-process).
        // 2. AudioHardwareCreateProcessTap(description, &tapID)
        // 3. Bungkus tap ke Aggregate Device via AudioHardwareCreateAggregateDevice
        //    supaya bisa dibaca lewat IOProc seperti device biasa.
        // 4. Register IOProc untuk menerima buffer, convert ke AVAudioPCMBuffer,
        //    lalu panggil onBuffer?(buffer, time).
        throw AudioCaptureError.processTapUnavailable
    }

    func stop() {
        // TODO: AudioHardwareDestroyProcessTap(tapID) + cleanup aggregate device.
    }
}

/// Strategi fallback: capture dari virtual driver BlackHole.
/// User harus install BlackHole (https://github.com/ExistentialAudio/BlackHole)
/// dan set BlackHole sebagai bagian dari Multi-Output Device di Audio MIDI Setup,
/// atau aplikasi ini membuat Aggregate Device secara programatik.
final class BlackHoleCaptureSource: AudioSource {

    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    private let engine = AVAudioEngine()

    func start() throws {
        // TODO:
        // 1. Cari AudioDeviceID untuk device bernama "BlackHole 2ch" via
        //    AudioObjectGetPropertyData(kAudioHardwarePropertyDevices, ...).
        // 2. Set device tsb sebagai default input untuk engine.inputNode
        //    (lewat kAudioOutputUnitProperty_CurrentDevice pada AudioUnit).
        // 3. installTap(onBus: 0) pada inputNode untuk menerima buffer.
        guard deviceExists(named: "BlackHole 2ch") else {
            throw AudioCaptureError.deviceNotFound
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            self?.onBuffer?(buffer, time)
        }

        do {
            try engine.start()
        } catch {
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func deviceExists(named name: String) -> Bool {
        // TODO: query kAudioHardwarePropertyDevices dan cocokkan nama device.
        return true // placeholder
    }
}

/// Factory yang memilih strategi capture terbaik sesuai OS version yang tersedia.
enum AudioCaptureFactory {
    static func makeSource() -> AudioSource {
        if #available(macOS 14.4, *) {
            return CoreAudioProcessTapSource()
        } else {
            return BlackHoleCaptureSource()
        }
    }
}
