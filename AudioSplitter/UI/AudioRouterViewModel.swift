//
//  AudioRouterViewModel.swift
//  AudioSplitter
//
//  Menghubungkan AudioCaptureEngine -> CrossoverFilter -> DualOutputManager.
//  Menjadi source of truth untuk UI (ContentView).
//

import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AudioRouterViewModel: ObservableObject {

    @Published var isRunning: Bool = false
    @Published var cutoffHz: Double = 120.0 {
        didSet { crossover.setCutoff(cutoffHz) }
    }
    @Published var bassGain: Double = 1.0
    @Published var midTrebleGain: Double = 1.0
    @Published var errorMessage: String?

    let deviceRouting = DeviceRoutingManager()

    private var captureSource: AudioSource?
    private let crossover = CrossoverFilter(cutoffHz: 120.0, sampleRate: 48000.0, channelCount: 2)
    private let outputManager = DualOutputManager()

    func start() {
        do {
            guard let builtIn = deviceRouting.builtInSpeakerDevice() else {
                errorMessage = "Built-in speaker tidak ditemukan."
                return
            }
            // TODO: ganti dengan device yang dipilih user dari UI, bukan device pertama.
            guard let external = deviceRouting.availableDevices.first(where: { $0.id != builtIn.id }) else {
                errorMessage = "Tidak ada external device yang terdeteksi."
                return
            }

            try outputManager.configureDevices(bassDeviceID: external.id, midTrebleDeviceID: builtIn.id)
            try outputManager.start()

            let source = AudioCaptureFactory.makeSource()
            source.onBuffer = { [weak self] buffer, time in
                guard let self else { return }
                guard let (bass, mid) = self.crossover.split(buffer) else { return }
                self.outputManager.scheduleBass(bass, at: nil)
                self.outputManager.scheduleMidTreble(mid, at: nil)
            }
            try source.start()
            self.captureSource = source

            isRunning = true
            errorMessage = nil
        } catch {
            errorMessage = "Gagal memulai: \(error.localizedDescription)"
        }
    }

    func stop() {
        captureSource?.stop()
        captureSource = nil
        outputManager.stop()
        isRunning = false
    }
}
