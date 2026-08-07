//
//  CrossoverFilter.swift
//  AudioSplitter
//
//  Memisahkan sinyal audio menjadi tiga band (3-way crossover):
//    - Low band (bass/subwoofer)
//    - Mid band (midrange)
//    - High band (treble)
//
//  Menggunakan dua cascaded Linkwitz-Riley crossover (24 dB/oktaf = 2x Butterworth 2nd order)
//  agar respon penjumlahan flat dan fase tetap sejajar.
//

import Accelerate
import AVFoundation

/// Satu biquad section (2nd order IIR filter) dengan status targeting persisten untuk real-time threads.
private struct BiquadSection {
    var coefficients: [Float] // [b0, b1, b2, a1, a2] format vDSP_biquad (Float)
    var setup: vDSP_biquad_Setup?
    var delay: [Float] // state / delay line, 4 x channelCount

    init(coefficients: [Float], channelCount: Int) {
        self.coefficients = coefficients
        self.setup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress, 1)
        }
        self.delay = [Float](repeating: 0, count: 4 * channelCount)
    }
}

public enum FilterType {
    case lowPass
    case highPass
}

/// Menghitung koefisien Butterworth 2nd-order.
private func butterworth2ndOrderCoefficients(
    cutoffHz: Double,
    sampleRate: Double,
    type: FilterType
) -> [Float] {
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

    let c0 = Float(b0 / a0)
    let c1 = Float(b1 / a0)
    let c2 = Float(b2 / a0)
    let c3 = Float(a1 / a0)
    let c4 = Float(a2 / a0)
    return [c0, c1, c2, c3, c4]
}

/// Filter Linkwitz-Riley 4th-order (2x cascaded Butterworth 2nd-order).
public final class LinkwitzRileyFilter {

    private var stage1: BiquadSection
    private var stage2: BiquadSection
    private let channelCount: Int

    public init(cutoffHz: Double, sampleRate: Double, type: FilterType, channelCount: Int) {
        self.channelCount = channelCount
        let coeffs = butterworth2ndOrderCoefficients(
            cutoffHz: cutoffHz, sampleRate: sampleRate, type: type
        )
        self.stage1 = BiquadSection(coefficients: coeffs, channelCount: channelCount)
        self.stage2 = BiquadSection(coefficients: coeffs, channelCount: channelCount)
    }

    /// Update cutoff frequency by rebuilding setups. Do not call on the realtime thread.
    public func updateCutoff(hz: Double, sampleRate: Double, type: FilterType) {
        let coeffs = butterworth2ndOrderCoefficients(cutoffHz: hz, sampleRate: sampleRate, type: type)
        // Destroy old setups
        if let s = stage1.setup { vDSP_biquad_DestroySetup(s) }
        if let s = stage2.setup { vDSP_biquad_DestroySetup(s) }
        // Reset delay lines when filter changes to avoid artifacts due to topology change
        stage1.delay = [Float](repeating: 0, count: stage1.delay.count)
        stage2.delay = [Float](repeating: 0, count: stage2.delay.count)
        // Assign new coefficients and setups
        stage1.coefficients = coeffs
        stage2.coefficients = coeffs
        stage1.setup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress, 1)
        }
        stage2.setup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress, 1)
        }
    }

    /// Process buffer in-place (mono channel float array) using Float vDSP APIs.
    public func process(_ input: inout [Float]) {
        guard let setup1 = stage1.setup, let setup2 = stage2.setup else { return }
        var temp = [Float](repeating: 0, count: input.count)

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

/// Modul utama crossover 3-way: menerima satu buffer input, menghasilkan
/// tiga buffer output (bass, mid, treble).
public final class CrossoverFilter {

    private var lowPass1: LinkwitzRileyFilter
    private var highPass1: LinkwitzRileyFilter
    private var lowPass2: LinkwitzRileyFilter
    private var highPass2: LinkwitzRileyFilter

    private let sampleRate: Double
    private var targetLowCutoffHz: Double
    private var targetHighCutoffHz: Double

    public private(set) var lowCutoffHz: Double
    public private(set) var highCutoffHz: Double

    public init(
        lowCutoffHz: Double = 120.0,
        highCutoffHz: Double = 2000.0,
        sampleRate: Double = 48000.0,
        channelCount: Int = 2
    ) {
        self.lowCutoffHz = lowCutoffHz
        self.targetLowCutoffHz = lowCutoffHz
        self.highCutoffHz = highCutoffHz
        self.targetHighCutoffHz = highCutoffHz
        self.sampleRate = sampleRate

        // Crossover pertama (Low/Mid split)
        self.lowPass1 = LinkwitzRileyFilter(cutoffHz: lowCutoffHz, sampleRate: sampleRate, type: .lowPass, channelCount: channelCount)
        self.highPass1 = LinkwitzRileyFilter(cutoffHz: lowCutoffHz, sampleRate: sampleRate, type: .highPass, channelCount: channelCount)

        // Crossover kedua (Mid/Treble split)
        self.lowPass2 = LinkwitzRileyFilter(cutoffHz: highCutoffHz, sampleRate: sampleRate, type: .lowPass, channelCount: channelCount)
        self.highPass2 = LinkwitzRileyFilter(cutoffHz: highCutoffHz, sampleRate: sampleRate, type: .highPass, channelCount: channelCount)
    }

    public func setLowCutoff(_ hz: Double) {
        targetLowCutoffHz = hz
    }

    public func setHighCutoff(_ hz: Double) {
        targetHighCutoffHz = hz
    }

    /// Split satu buffer PCM menjadi 3 band: (bass, mid, treble).
    public func split(_ buffer: AVAudioPCMBuffer) -> (bass: AVAudioPCMBuffer, mid: AVAudioPCMBuffer, treble: AVAudioPCMBuffer)? {
        // Lakukan parameter smoothing secara bertahap pada level blok frekuensi
        if abs(lowCutoffHz - targetLowCutoffHz) > 0.1 {
            lowCutoffHz += (targetLowCutoffHz - lowCutoffHz) * 0.15
            lowPass1.updateCutoff(hz: lowCutoffHz, sampleRate: sampleRate, type: .lowPass)
            highPass1.updateCutoff(hz: lowCutoffHz, sampleRate: sampleRate, type: .highPass)
        }
        if abs(highCutoffHz - targetHighCutoffHz) > 0.1 {
            highCutoffHz += (targetHighCutoffHz - highCutoffHz) * 0.15
            lowPass2.updateCutoff(hz: highCutoffHz, sampleRate: sampleRate, type: .lowPass)
            highPass2.updateCutoff(hz: highCutoffHz, sampleRate: sampleRate, type: .highPass)
        }

        guard let bassBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity),
              let midBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity),
              let trebleBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity),
              let channelData = buffer.floatChannelData else {
            return nil
        }

        bassBuffer.frameLength = buffer.frameLength
        midBuffer.frameLength = buffer.frameLength
        trebleBuffer.frameLength = buffer.frameLength

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        for ch in 0..<channelCount {
            var samples = [Float](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                samples[i] = channelData[ch][i]
            }

            // 1. Crossover pertama: Pisahkan Bass
            var bassSamples = samples
            var highBandSamples = samples

            lowPass1.process(&bassSamples)
            highPass1.process(&highBandSamples)

            // 2. Crossover kedua: Pisahkan highBandSamples menjadi Mid dan Treble
            var midSamples = highBandSamples
            var trebleSamples = highBandSamples

            lowPass2.process(&midSamples)
            highPass2.process(&trebleSamples)

            // Tulis kembali ke float channel buffers
            guard let bassData = bassBuffer.floatChannelData,
                  let midData = midBuffer.floatChannelData,
                  let trebleData = trebleBuffer.floatChannelData else { continue }

            for i in 0..<frameCount {
                bassData[ch][i] = bassSamples[i]
                midData[ch][i] = midSamples[i]
                trebleData[ch][i] = trebleSamples[i]
            }
        }

        return (bassBuffer, midBuffer, trebleBuffer)
    }
}

