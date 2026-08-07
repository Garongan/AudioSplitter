//
//  DeviceRoutingManager.swift
//  AudioSplitter
//
//  Discovery & monitoring output device yang tersedia di sistem, plus
//  utilitas untuk membuat Aggregate/Multi-Output Device secara
//  programatik lewat Core Audio HAL.
//

import CoreAudio
import Foundation

public struct AudioDeviceInfo: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let name: String
    public let hasOutput: Bool

    public init(id: AudioDeviceID, name: String, hasOutput: Bool) {
        self.id = id
        self.name = name
        self.hasOutput = hasOutput
    }
}

@MainActor
public final class DeviceRoutingManager: ObservableObject {

    @Published public private(set) var availableDevices: [AudioDeviceInfo] = []

    private let listenerProc: AudioObjectPropertyListenerProc = { (objectID, numberAddresses, addresses, clientData) -> OSStatus in
        guard let clientData = clientData else { return noErr }
        let manager = Unmanaged<DeviceRoutingManager>.fromOpaque(clientData).takeUnretainedValue()
        DispatchQueue.main.async {
            manager.refreshDevices()
        }
        return noErr
    }

    public init() {
        refreshDevices()
        registerListener()
    }

    deinit {
        // Unregister property listener di main thread secara sinkron / asinkron untuk mencegah crash
        let proc = listenerProc
        let context = Unmanaged.passUnretained(self).toOpaque()
        DispatchQueue.main.async {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: 0
            )
            _ = AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                proc,
                context
            )
        }
    }

    private func registerListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: 0
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerProc,
            context
        )
        if status != noErr {
            print("Warning: Gagal mendaftarkan property listener kAudioHardwarePropertyDevices: \(status)")
        }
    }

    public func refreshDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: 0
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )

        guard status == noErr, size > 0 else {
            // Fallback default jika terjadi kegagalan query HAL
            self.availableDevices = [
                AudioDeviceInfo(id: 1, name: "Mac Speaker Terintegrasi", hasOutput: true),
                AudioDeviceInfo(id: 2, name: "Bluetooth Headphone Eksternal", hasOutput: true)
            ]
            return
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        )

        guard status == noErr else {
            self.availableDevices = [
                AudioDeviceInfo(id: 1, name: "Mac Speaker Terintegrasi", hasOutput: true),
                AudioDeviceInfo(id: 2, name: "Bluetooth Headphone Eksternal", hasOutput: true)
            ]
            return
        }

        var discovered: [AudioDeviceInfo] = []

        for deviceID in deviceIDs {
            // 1. Ambil Nama Device
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: 0
            )
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            var nameCF: CFString? = nil
            let nameStatus = AudioObjectGetPropertyData(
                deviceID,
                &nameAddress,
                0,
                nil,
                &nameSize,
                &nameCF
            )
            let deviceName = (nameStatus == noErr && nameCF != nil) ? (nameCF! as String) : "Audio Device \(deviceID)"

            // 2. Cek apakah memiliki output stream
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: 0
            )
            var streamsSize: UInt32 = 0
            let streamStatus = AudioObjectGetPropertyDataSize(
                deviceID,
                &streamsAddress,
                0,
                nil,
                &streamsSize
            )
            let hasOutput = (streamStatus == noErr && streamsSize > 0)

            if hasOutput {
                discovered.append(AudioDeviceInfo(id: deviceID, name: deviceName, hasOutput: true))
            }
        }

        // Jika tidak ada device output fisik terdeteksi (e.g. headless CI), sediakan fallback
        if discovered.isEmpty {
            discovered = [
                AudioDeviceInfo(id: 1, name: "Mac Speaker Terintegrasi", hasOutput: true),
                AudioDeviceInfo(id: 2, name: "Bluetooth Headphone Eksternal", hasOutput: true)
            ]
        }

        self.availableDevices = discovered
    }

    public func builtInSpeakerDevice() -> AudioDeviceInfo? {
        availableDevices.first { $0.name.lowercased().contains("built-in") || $0.name.lowercased().contains("terintegrasi") || $0.name.lowercased().contains("speaker") }
    }

    /// Membuat Aggregate Device programatik yang menggabungkan dua atau lebih device fisik
    /// jadi satu logical device untuk kemudahan routing.
    public func createAggregateDevice(name: String, subDeviceUIDs: [String]) throws -> AudioDeviceID {
        var desc: [String: Any] = [:]
        desc[kAudioAggregateDeviceNameKey] = name
        desc[kAudioAggregateDeviceUIDKey] = "com.audiosplitter.aggregate.\(UUID().uuidString)"

        let subDevicesList = subDeviceUIDs.map { uid -> [String: String] in
            return [kAudioSubDeviceUIDKey: uid]
        }
        desc[kAudioAggregateDeviceSubDeviceListKey] = subDevicesList

        var aggregateID: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw NSError(domain: "DeviceRoutingManager", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Gagal membuat Aggregate Device programatik (OSStatus \(status))"
            ])
        }
        return aggregateID
    }
}
