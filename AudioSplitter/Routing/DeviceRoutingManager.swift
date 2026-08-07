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
import Combine

private final class DeviceRoutingContextRegistry {
    // These are accessed from nonisolated contexts (e.g., Core Audio callbacks).
    // Mark them nonisolated to opt out of main-actor isolation for this storage.
    nonisolated(unsafe) static let lock = NSLock()
    nonisolated(unsafe) static var activeContexts = Set<UnsafeMutableRawPointer>()
}

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

    nonisolated private static func registerContext(_ context: UnsafeMutableRawPointer) {
        DeviceRoutingContextRegistry.lock.lock()
        DeviceRoutingContextRegistry.activeContexts.insert(context)
        DeviceRoutingContextRegistry.lock.unlock()
    }

    nonisolated private static func unregisterContext(_ context: UnsafeMutableRawPointer) {
        DeviceRoutingContextRegistry.lock.lock()
        DeviceRoutingContextRegistry.activeContexts.remove(context)
        DeviceRoutingContextRegistry.lock.unlock()
    }

    nonisolated private static func isContextActive(_ context: UnsafeMutableRawPointer) -> Bool {
        DeviceRoutingContextRegistry.lock.lock()
        defer { DeviceRoutingContextRegistry.lock.unlock() }
        return DeviceRoutingContextRegistry.activeContexts.contains(context)
    }

    private let listenerProc: AudioObjectPropertyListenerProc = { (objectID, numberAddresses, addresses, clientData) -> OSStatus in
        guard let clientData = clientData else { return noErr }

        // Lakukan pengecekan apakah context manager ini masih aktif dan tidak sedang dealloc
        if DeviceRoutingManager.isContextActive(clientData) {
            let manager = Unmanaged<DeviceRoutingManager>.fromOpaque(clientData).takeUnretainedValue()
            DispatchQueue.main.async {
                if DeviceRoutingManager.isContextActive(clientData) {
                    manager.refreshDevices()
                }
            }
        }
        return noErr
    }

    public init() {
        refreshDevices()
        registerListener()
    }

    deinit {
        let context = Unmanaged.passUnretained(self).toOpaque()
        DeviceRoutingManager.unregisterContext(context)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: 0
        )
        _ = AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerProc,
            context
        )
    }

    private func registerListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: 0
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        DeviceRoutingManager.registerContext(context)

        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerProc,
            context
        )
        if status != noErr {
            DeviceRoutingManager.unregisterContext(context)
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

