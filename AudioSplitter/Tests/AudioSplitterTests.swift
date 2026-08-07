//
//  AudioSplitterTests.swift
//  AudioSplitterTests
//

import XCTest
import AVFoundation
@testable import AudioSplitter

final class AudioSplitterTests: XCTestCase {

    /// Menguji performa pemisahan frekuensi CrossoverFilter (Linkwitz-Riley).
    func testCrossoverFilterSplit() {
        let cutoffHz = 120.0
        let sampleRate = 48000.0
        let crossover = CrossoverFilter(cutoffHz: cutoffHz, sampleRate: sampleRate, channelCount: 2)

        // Buat format PCM audio buffer stereo 48kHz
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            XCTFail("Gagal membuat AVAudioFormat")
            return
        }

        let frameCount: AVAudioFrameCount = 512
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("Gagal membuat AVAudioPCMBuffer")
            return
        }
        inputBuffer.frameLength = frameCount

        // Isi buffer dengan sinyal impulse (1.0 di sample pertama)
        if let channels = inputBuffer.floatChannelData {
            channels[0][0] = 1.0
            channels[1][0] = 1.0
            for i in 1..<Int(frameCount) {
                channels[0][i] = 0.0
                channels[1][i] = 0.0
            }
        }

        // Jalankan pemisahan crossover
        guard let result = crossover.split(inputBuffer) else {
            XCTFail("Crossover split mengembalikan nil")
            return
        }

        XCTAssertEqual(result.bass.frameLength, frameCount)
        XCTAssertEqual(result.midTreble.frameLength, frameCount)
        XCTAssertEqual(result.bass.format.sampleRate, sampleRate)
        XCTAssertEqual(result.midTreble.format.channelCount, 2)

        // Verifikasi filter memisahkan energi impulse (bass vs treble)
        if let bassData = result.bass.floatChannelData,
           let midData = result.midTreble.floatChannelData {
            // Sinyal bass dan treble tidak boleh kosong (all zeros) setelah impulse melewati biquad
            var bassSum: Float = 0
            var midSum: Float = 0
            for i in 0..<Int(frameCount) {
                bassSum += abs(bassData[0][i])
                midSum += abs(midData[0][i])
            }
            XCTAssertGreaterThan(bassSum, 0.0)
            XCTAssertGreaterThan(midSum, 0.0)
        }
    }

    /// Menguji interpolasi koefisien dinamis / update cutoff pada Linkwitz-Riley Filter.
    func testFilterCutoffUpdate() {
        let filter = LinkwitzRileyFilter(cutoffHz: 120.0, sampleRate: 48000.0, type: .lowPass, channelCount: 2)

        // Verifikasi updateCutoff berjalan mulus tanpa crash
        XCTAssertNoThrow(filter.updateCutoff(hz: 200.0, sampleRate: 48000.0, type: .lowPass))
        XCTAssertNoThrow(filter.updateCutoff(hz: 80.0, sampleRate: 48000.0, type: .lowPass))
    }

    /// Menguji inisialisasi status control masing-masing device (Volume, Delay, EQ).
    func testDeviceControlStateInitialization() {
        let control = DeviceControlState(
            id: 12345,
            name: "Test Bluetooth Speaker",
            tag: .bassOnly,
            volume: 0.8,
            delaySeconds: 0.15,
            bassEQ: 1.5,
            midEQ: 0.5,
            trebleEQ: 1.0
        )

        XCTAssertEqual(control.id, 12345)
        XCTAssertEqual(control.name, "Test Bluetooth Speaker")
        XCTAssertEqual(control.tag, .bassOnly)
        XCTAssertEqual(control.volume, 0.8)
        XCTAssertEqual(control.delaySeconds, 0.15)
        XCTAssertEqual(control.bassEQ, 1.5)
        XCTAssertEqual(control.midEQ, 0.5)
        XCTAssertEqual(control.trebleEQ, 1.0)
    }

    /// Menguji fallback DeviceRoutingManager di lingkungan tanpa hardware Core Audio fisik (e.g. CI / Sandbox).
    @MainActor
    func testDeviceRoutingManagerFallbacks() {
        let routing = DeviceRoutingManager()

        // Dalam sandbox, ketersediaan hardware device bisa kosong, verifikasi fallback bekerja
        XCTAssertFalse(routing.availableDevices.isEmpty, "Device list harus diisi dengan fallback jika sistem kosong")

        let builtIn = routing.builtInSpeakerDevice()
        XCTAssertNotNil(builtIn, "Harus bisa mendeteksi / menyediakan built-in speaker")
    }

    /// Menguji kategori tag dan raw id.
    func testOutputTagCases() {
        XCTAssertEqual(OutputTag.bassOnly.rawValue, "Only Bass")
        XCTAssertEqual(OutputTag.midTreble.rawValue, "Mid & Treble")
        XCTAssertEqual(OutputTag.fullRange.rawValue, "Combine All (Full Range)")
    }
}
