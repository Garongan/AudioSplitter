//
//  AudioRouterViewModel.swift
//  AudioSplitter
//
//  Menghubungkan AudioCaptureEngine -> CrossoverFilter -> MultiOutputManager.
//  Menjadi source of truth untuk UI (ContentView).
//

import AVFoundation
import Combine
import SwiftUI

public enum OutputTag: String, CaseIterable, Identifiable {
    case bass = "Bass"
    case bassMid = "Bass Mid"
    case bassTreble = "Bass Treble"
    case mid = "Mid"
    case midTreble = "Mid Treble"
    case treble = "Treble"

    public var id: String { self.rawValue }
}

public struct DeviceControlState: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let name: String
    public var tag: OutputTag
    public var volume: Double
    public var delaySeconds: Double
    public var bassEQ: Double
    public var midEQ: Double
    public var trebleEQ: Double

    public init(
        id: AudioDeviceID,
        name: String,
        tag: OutputTag = .bassMid,
        volume: Double = 1.0,
        delaySeconds: Double = 0.0,
        bassEQ: Double = 1.0,
        midEQ: Double = 1.0,
        trebleEQ: Double = 1.0
    ) {
        self.id = id
        self.name = name
        self.tag = tag
        self.volume = volume
        self.delaySeconds = delaySeconds
        self.bassEQ = bassEQ
        self.midEQ = midEQ
        self.trebleEQ = trebleEQ
    }
}

@MainActor
public final class AudioRouterViewModel: ObservableObject {

    @Published public var isRunning: Bool = false
    @Published public var lowCutoffHz: Double = 120.0 {
        didSet { crossover.setLowCutoff(lowCutoffHz) }
    }
    @Published public var highCutoffHz: Double = 2000.0 {
        didSet { crossover.setHighCutoff(highCutoffHz) }
    }
    @Published public var errorMessage: String?
    @Published public var deviceControls: [DeviceControlState] = []

    public let deviceRouting = DeviceRoutingManager()

    private var captureSource: AudioSource?
    private let crossover = CrossoverFilter(lowCutoffHz: 120.0, highCutoffHz: 2000.0, sampleRate: 48000.0, channelCount: 2)
    private let outputManager = MultiOutputManager()
    private var cancellables = Set<AnyCancellable>()

    public init() {
        // Observasi perubahan device dari routing manager
        deviceRouting.$availableDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncDeviceControls()
            }
            .store(in: &cancellables)

        syncDeviceControls()
    }

    public func syncDeviceControls() {
        let currentDevices = deviceRouting.availableDevices
        var updatedControls: [DeviceControlState] = []

        for device in currentDevices {
            if let existing = deviceControls.first(where: { $0.id == device.id }) {
                updatedControls.append(existing)
            } else {
                let defaultTag: OutputTag
                let nameLower = device.name.lowercased()
                if nameLower.contains("built-in") || nameLower.contains("terintegrasi") {
                    defaultTag = .midTreble
                } else if nameLower.contains("subwoofer") || nameLower.contains("bass") {
                    defaultTag = .bass
                } else {
                    defaultTag = .bassMid
                }
                updatedControls.append(DeviceControlState(
                    id: device.id,
                    name: device.name,
                    tag: defaultTag,
                    volume: 1.0,
                    delaySeconds: 0.0,
                    bassEQ: 1.0,
                    midEQ: 1.0,
                    trebleEQ: 1.0
                ))
            }
        }

        self.deviceControls = updatedControls

        // Update device aktif di MultiOutputManager
        let activeIDs = updatedControls.map { $0.id }
        do {
            try outputManager.updateActiveDevices(activeIDs)
        } catch {
            print("Warning: Gagal menyinkronkan active devices: \(error)")
        }
    }

    public func start() {
        do {
            // Pastikan active devices sinkron
            syncDeviceControls()

            // Konfigurasi and nyalakan output engines
            try outputManager.start()

            // Inisialisasi capture source (Process Tap default)
            let source = AudioCaptureFactory.makeSource()
            source.onBuffer = { [weak self] buffer, time in
                guard let self else { return }
                guard let (bass, mid, treble) = self.crossover.split(buffer) else { return }

                // Distribusikan buffer ke masing-masing device berdasarkan tag & konfigurasinya
                for control in self.deviceControls {
                    let targetBuffer: AVAudioPCMBuffer
                    switch control.tag {
                    case .bass:
                        targetBuffer = bass
                    case .bassMid:
                        targetBuffer = self.combine(bass, mid)
                    case .bassTreble:
                        targetBuffer = self.combine(bass, treble)
                    case .mid:
                        targetBuffer = mid
                    case .midTreble:
                        targetBuffer = self.combine(mid, treble)
                    case .treble:
                        targetBuffer = treble
                    }

                    // Update Volume & EQ secara real-time
                    self.outputManager.updateDeviceVolume(deviceID: control.id, volume: control.volume)

                    let bassDb = (control.bassEQ - 1.0) * 12.0
                    let midDb = (control.midEQ - 1.0) * 12.0
                    let trebleDb = (control.trebleEQ - 1.0) * 12.0
                    self.outputManager.updateDeviceEQ(deviceID: control.id, bassGainDb: bassDb, midGainDb: midDb, trebleGainDb: trebleDb)

                    // Jadwalkan dengan parameter delay compensation
                    self.outputManager.scheduleBuffer(targetBuffer, onDevice: control.id, anchorTime: time, delaySeconds: control.delaySeconds)
                }
            }

            try source.start()
            self.captureSource = source

            isRunning = true
            errorMessage = nil
        } catch {
            errorMessage = "Gagal memulai: \(error.localizedDescription)"
        }
    }

    public func stop() {
        captureSource?.stop()
        captureSource = nil
        outputManager.stop()
        isRunning = false
    }

    /// Menggabungkan dua buffer PCM dengan menjumlahkan data sinyalnya
    private func combine(_ first: AVAudioPCMBuffer, _ second: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let firstData = first.floatChannelData,
              let secondData = second.floatChannelData,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: first.frameCapacity) else {
            return first
        }

        outBuffer.frameLength = first.frameLength
        let channels = Int(first.format.channelCount)
        let frames = Int(first.frameLength)

        guard let outData = outBuffer.floatChannelData else { return first }

        for ch in 0..<channels {
            for f in 0..<frames {
                outData[ch][f] = firstData[ch][f] + secondData[ch][f]
            }
        }
        return outBuffer
    }
}
