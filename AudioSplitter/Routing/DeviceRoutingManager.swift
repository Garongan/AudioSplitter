//
//  DeviceRoutingManager.swift
//  AudioSplitter
//
//  Discovery & monitoring output device yang tersedia di sistem, plus
//  utilitas untuk (opsional) membuat Aggregate/Multi-Output Device secara
//  programatik lewat Core Audio HAL.
//
//  TODO (lihat task list Fase 4):
//   - Implementasi query kAudioHardwarePropertyDevices untuk list semua device.
//   - Filter device yang punya output channel > 0 (buang input-only device).
//   - Tambahkan listener kAudioHardwarePropertyDevices untuk deteksi hot-plug.
//   - (Opsional) AudioHardwareCreateAggregateDevice untuk bikin Multi-Output
//     Device otomatis tanpa user buka Audio MIDI Setup manual.
//

import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let hasOutput: Bool
}

final class DeviceRoutingManager: ObservableObject {

    @Published private(set) var availableDevices: [AudioDeviceInfo] = []

    init() {
        refreshDevices()
        // TODO: register AudioObjectAddPropertyListenerBlock untuk
        // kAudioHardwarePropertyDevices supaya availableDevices auto-update
        // saat device hot-plug/unplug.
    }

    func refreshDevices() {
        // TODO: implementasi nyata:
        // 1. AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, ...) untuk devices
        // 2. AudioObjectGetPropertyData untuk ambil array AudioDeviceID
        // 3. Untuk tiap device, ambil kAudioObjectPropertyName (nama) dan
        //    kAudioDevicePropertyStreams scope output (cek apakah punya output channel)
        //
        // Placeholder sementara:
        availableDevices = [
            AudioDeviceInfo(id: 0, name: "Built-in Speaker (placeholder)", hasOutput: true),
            AudioDeviceInfo(id: 1, name: "External Device (placeholder)", hasOutput: true),
        ]
    }

    func builtInSpeakerDevice() -> AudioDeviceInfo? {
        availableDevices.first { $0.name.lowercased().contains("built-in") }
    }

    /// (Opsional, Fase 4) Buat Aggregate Device programatik yang menggabungkan
    /// dua device fisik jadi satu logical device untuk kemudahan routing.
    func createAggregateDevice(name: String, subDeviceUIDs: [String]) throws -> AudioDeviceID {
        // TODO: implementasi AudioHardwareCreateAggregateDevice dengan
        // dictionary description berisi kAudioAggregateDeviceUIDKey,
        // kAudioAggregateDeviceNameKey, kAudioAggregateDeviceSubDeviceListKey, dst.
        throw NSError(domain: "DeviceRoutingManager", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "createAggregateDevice belum diimplementasikan"
        ])
    }
}
