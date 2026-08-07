//
//  CrossoverFilter.swift
//  AudioSplitter
//
//  Memisahkan sinyal audio menjadi dua band:
//    - Low band  (bass/subwoofer)  -> dikirim ke external device
//    - High band (mid/treble)      -> dikirim ke built-in speaker
//
//  Menggunakan Linkwitz-Riley crossover (24 dB/oktaf = cascaded 2x Butterworth
//  2nd order) supaya saat kedua band dijumlahkan kembali, responsnya flat
//  (tanpa dip/peak di titik cutoff) dan tidak ada masalah fase.
//
//  TODO (lihat task list Fase 2):
//   - Validasi koefisien biquad dengan sine sweep + FFT.
//   - Tambahkan smoothing saat cutoff frequency berubah runtime (hindari klik).
//   - Pertimbangkan pindah ke vDSP_biquadm untuk multi-channel (stereo) sekaligus.
//

import Accelerate
import AVFoundation

/// Satu biquad section (2nd order IIR filter).
private struct BiquadSection {
    var coefficients: [Double] // [b0, b1, b2, a1, a2] format vDSP_biquad
    var setup: vDSP_biquad_Setup?
    var delay: [Double] // state / delay line, 4 x channelCount

    init(coefficients: [Double], channelCount: Int) {
        self.coefficients = coefficients
        self.setup = vDSP_biquad_CreateSetup(coefficients, 1)
        self.delay = [Double](repeating: 0, count: 4 * channelCount)
    }
}

enum FilterType {
    case lowPass
    case highPass
}

/// Menghitung koefisien Butterworth 2nd-order (dasar dari Linkwitz-Riley).
/// Linkwitz-Riley didapat dengan meng-cascade DUA Butterworth 2nd-order
/// dengan cutoff yang sama.
private func butterworth2ndOrderCoefficients(
    cutoffHz: Double,
    sampleRate: Double,
    type: FilterType
) -> [Double] {
    let omega = 2.0 * .pi * cutoffHz / sampleRate
    let sinOmega = sin(omega)
    let cosOmega = cos(omega)
    let q = 1.0 / sqrt(2.0) // Butterworth Q
    let alpha = sinOmega / (2.0 * q)

    var b0 = 0.0, b1 = 0.0, b2 = 0.0
    let a0: Double
    var a1 = 0.0, a2 = 0.0

    switch type {
    case .lowPass:
        b0 = (1 - cosOmega) / 2
        b1 = 1 - cosOmega
        b2 = (1 - cosOmega) / 2
    case .highPass:
        b0 = (1 + cosOmega) / 2
        b1 = -(1 + cosOmega)
        b2 = (1 + cosOmega) / 2
    }
    a0 = 1 + alpha
    a1 = -2 * cosOmega
    a2 = 1 - alpha

    // Normalisasi & format sesuai yang diminta vDSP_biquad: [b0,b1,b2,a1,a2]
    return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
}

/// Filter Linkwitz-Riley 4th-order (24 dB/oktaf) = 2x cascaded Butterworth 2nd-order.
final class LinkwitzRileyFilter {

    private var stage1: BiquadSection
    private var stage2: BiquadSection
    private let channelCount: Int

    init(cutoffHz: Double, sampleRate: Double, type: FilterType, channelCount: Int) {
        self.channelCount = channelCount
        let coeffs = butterworth2ndOrderCoefficients(
            cutoffHz: cutoffHz, sampleRate: sampleRate, type: type
        )
        self.stage1 = BiquadSection(coefficients: coeffs, channelCount: channelCount)
        self.stage2 = BiquadSection(coefficients: coeffs, channelCount: channelCount)
    }

    /// Update cutoff frequency saat runtime.
    /// TODO: tambahkan crossfade/smoothing di sini agar tidak klik saat user
    /// menggeser slider cutoff.
    func updateCutoff(hz: Double, sampleRate: Double, type: FilterType) {
        let coeffs = butterworth2ndOrderCoefficients(cutoffHz: hz, sampleRate: sampleRate, type: type)
        stage1.coefficients = coeffs
        stage2.coefficients = coeffs
        if let setup = stage1.setup { vDSP_biquad_SetTargetsDouble(setup, coeffs, 0, 0, 0, 0, 1) }
        if let setup = stage2.setup { vDSP_biquad_SetTargetsDouble(setup, coeffs, 0, 0, 0, 0, 1) }
    }

    /// Proses buffer in-place (mono channel double array).
    func process(_ input: inout [Double]) {
        guard let setup1 = stage1.setup, let setup2 = stage2.setup else { return }
        var temp = [Double](repeating: 0, count: input.count)

        input.withUnsafeMutableBufferPointer { inPtr in
            temp.withUnsafeMutableBufferPointer { tempPtr in
                vDSP_biquad(setup1, &stage1.delay, inPtr.baseAddress!, 1, tempPtr.baseAddress!, 1, vDSP_Length(input.count))
            }
        }
        temp.withUnsafeMutableBufferPointer { tempPtr in
            input.withUnsafeMutableBufferPointer { outPtr in
                vDSP_biquad(setup2, &stage2.delay, tempPtr.baseAddress!, 1, outPtr.baseAddress!, 1, vDSP_Length(input.count))
            }
        }
    }

    deinit {
        if let s = stage1.setup { vDSP_biquad_DestroySetup(s) }
        if let s = stage2.setup { vDSP_biquad_DestroySetup(s) }
    }
}

/// Modul utama crossover: menerima satu buffer input, menghasilkan
/// dua buffer output (bass, mid/treble).
final class CrossoverFilter {

    private var lowPass: LinkwitzRileyFilter
    private var highPass: LinkwitzRileyFilter
    private let sampleRate: Double
    private(set) var cutoffHz: Double

    init(cutoffHz: Double = 120.0, sampleRate: Double = 48000.0, channelCount: Int = 2) {
        self.cutoffHz = cutoffHz
        self.sampleRate = sampleRate
        self.lowPass = LinkwitzRileyFilter(cutoffHz: cutoffHz, sampleRate: sampleRate, type: .lowPass, channelCount: channelCount)
        self.highPass = LinkwitzRileyFilter(cutoffHz: cutoffHz, sampleRate: sampleRate, type: .highPass, channelCount: channelCount)
    }

    func setCutoff(_ hz: Double) {
        cutoffHz = hz
        lowPass.updateCutoff(hz: hz, sampleRate: sampleRate, type: .lowPass)
        highPass.updateCutoff(hz: hz, sampleRate: sampleRate, type: .highPass)
    }

    /// Split satu buffer PCM menjadi (bassBuffer, midTrebleBuffer).
    /// TODO: implementasi ekstraksi channel dari AVAudioPCMBuffer ke [Double],
    /// proses per channel, lalu tulis kembali ke dua AVAudioPCMBuffer baru.
    func split(_ buffer: AVAudioPCMBuffer) -> (bass: AVAudioPCMBuffer, midTreble: AVAudioPCMBuffer)? {
        guard let bassBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity),
              let midBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity),
              let channelData = buffer.floatChannelData else {
            return nil
        }

        bassBuffer.frameLength = buffer.frameLength
        midBuffer.frameLength = buffer.frameLength

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        for ch in 0..<channelCount {
            var samples = [Double](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                samples[i] = Double(channelData[ch][i])
            }

            var bassSamples = samples
            var midSamples = samples
            lowPass.process(&bassSamples)
            highPass.process(&midSamples)

            guard let bassData = bassBuffer.floatChannelData,
                  let midData = midBuffer.floatChannelData else { continue }
            for i in 0..<frameCount {
                bassData[ch][i] = Float(bassSamples[i])
                midData[ch][i] = Float(midSamples[i])
            }
        }

        return (bassBuffer, midBuffer)
    }
}
