//
//  AudioSplitterTests.swift
//  AudioSplitterTests
//

import XCTest
import AVFoundation
@testable import AudioSplitter

final class AudioSplitterTests: XCTestCase {

    /// Menguji performa pemisahan frekuensi 3-Way CrossoverFilter.
    func testCrossoverFilter3WaySplit() {
        let lowCutoffHz = 120.0
        let highCutoffHz = 2000.0
        let sampleRate = 48000.0
        let crossover = CrossoverFilter(lowCutoffHz: lowCutoffHz, highCutoffHz: highCutoffHz, sampleRate: sampleRate, channelCount: 2)

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

        // Sinyal impulse
        if let channels = inputBuffer.floatChannelData {
            channels[0][0] = 1.0
            channels[1][0] = 1.0
            for i in 1..<Int(frameCount) {
                channels[0][i] = 0.0
                channels[1][i] = 0.0
            }
        }

        // Jalankan pemisahan crossover 3-way
        guard let result = crossover.split(inputBuffer) else {
            XCTFail("Crossover split mengembalikan nil")
            return
        }

        XCTAssertEqual(result.bass.frameLength, frameCount)
        XCTAssertEqual(result.mid.frameLength, frameCount)
        XCTAssertEqual(result.treble.frameLength, frameCount)
        XCTAssertEqual(result.bass.format.sampleRate, sampleRate)
        XCTAssertEqual(result.mid.format.channelCount, 2)
        XCTAssertEqual(result.treble.format.channelCount, 2)

        // Verifikasi semua band memiliki kontribusi energi sinyal
        if let bassData = result.bass.floatChannelData,
           let midData = result.mid.floatChannelData,
           let trebleData = result.treble.floatChannelData {
            var bassSum: Float = 0
            var midSum: Float = 0
            var trebleSum: Float = 0
            for i in 0..<Int(frameCount) {
                bassSum += abs(bassData[0][i])
                midSum += abs(midData[0][i])
                trebleSum += abs(trebleData[0][i])
            }
            XCTAssertGreaterThan(bassSum, 0.0, "Sinyal Bass tidak boleh kosong")
            XCTAssertGreaterThan(midSum, 0.0, "Sinyal Mid tidak boleh kosong")
            XCTAssertGreaterThan(trebleSum, 0.0, "Sinyal Treble tidak boleh kosong")
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
            tag: .bassMid,
            volume: 0.8,
            delaySeconds: 0.15,
            bassEQ: 1.5,
            midEQ: 0.5,
            trebleEQ: 1.0
        )

        XCTAssertEqual(control.id, 12345)
        XCTAssertEqual(control.name, "Test Bluetooth Speaker")
        XCTAssertEqual(control.tag, .bassMid)
        XCTAssertEqual(control.volume, 0.8)
        XCTAssertEqual(control.delaySeconds, 0.15)
        XCTAssertEqual(control.bassEQ, 1.5)
        XCTAssertEqual(control.midEQ, 0.5)
        XCTAssertEqual(control.trebleEQ, 1.0)
    }

    /// Menguji fallback DeviceRoutingManager di lingkungan tanpa hardware Core Audio fisik.
    @MainActor
    func testDeviceRoutingManagerFallbacks() {
        let routing = DeviceRoutingManager()
        XCTAssertFalse(routing.availableDevices.isEmpty)

        let builtIn = routing.builtInSpeakerDevice()
        XCTAssertNotNil(builtIn)
    }

    /// Menguji 6 kategori tag yang baru.
    func testOutputTagCases() {
        let cases = OutputTag.allCases
        XCTAssertEqual(cases.count, 6)
        XCTAssertTrue(cases.contains(.bass))
        XCTAssertTrue(cases.contains(.bassMid))
        XCTAssertTrue(cases.contains(.bassTreble))
        XCTAssertTrue(cases.contains(.mid))
        XCTAssertTrue(cases.contains(.midTreble))
        XCTAssertTrue(cases.contains(.treble))
    }
}
