//
//  ContentView.swift
//  AudioSplitter
//
//  Panel kontrol utama: Grid kartu output device dengan equalizer individual,
//  volume, output tag, dan delay compensation.
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject var router: AudioRouterViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Header & Start/Stop Toggle
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio Splitter")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("macOS 3-Way Frequency Router")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { router.isRunning },
                        set: { newValue in
                            newValue ? router.start() : router.stop()
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                if let error = router.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                }

                // Crossover Control Panel (3-Way: Low & High Cutoffs)
                VStack(alignment: .leading, spacing: 10) {
                    Text("3-Way Crossover Cutoffs")
                        .font(.headline)

                    // Low Cutoff Slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Low Cutoff (Bass/Mid):")
                                .font(.caption)
                            Spacer()
                            Text("\(Int(router.lowCutoffHz)) Hz")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        Slider(value: $router.lowCutoffHz, in: 40...500, step: 1)
                            .accentColor(.blue)
                    }

                    // High Cutoff Slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("High Cutoff (Mid/Treble):")
                                .font(.caption)
                            Spacer()
                            Text("\(Int(router.highCutoffHz)) Hz")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        Slider(value: $router.highCutoffHz, in: 1000...8000, step: 50)
                            .accentColor(.orange)
                    }
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )

                Divider()

                // Connected Devices Cards
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Output Speaker Sources")
                            .font(.headline)
                        Spacer()
                        Button(action: {
                            router.deviceRouting.refreshDevices()
                        }) {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }

                    if router.deviceControls.isEmpty {
                        Text("No output devices detected.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 20)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(0..<router.deviceControls.count, id: \.self) { index in
                                DeviceCardView(control: $router.deviceControls[index])
                            }
                        }
                    }
                }

                Divider()

                HStack {
                    Spacer()
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q", modifiers: .command)
                }
            }
            .padding()
        }
        .frame(minHeight: 550)
    }
}

struct DeviceCardView: View {
    @Binding var control: DeviceControlState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: isBluetoothDevice(control.name) ? "apps.iphone" : "speaker.wave.2.fill")
                    .foregroundColor(.accentColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(control.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Device ID: \(control.id)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Output Tag
            HStack {
                Text("Role Tag:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $control.tag) {
                    ForEach(OutputTag.allCases) { tag in
                        Text(tag.rawValue).tag(tag)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            // Volume and Delay
            VStack(spacing: 8) {
                // Volume slider
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Volume")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(control.volume * 100))%")
                            .font(.caption2)
                    }
                    HStack {
                        Image(systemName: "speaker.wave.1")
                            .font(.caption)
                        Slider(value: $control.volume, in: 0...1)
                        Image(systemName: "speaker.wave.3")
                            .font(.caption)
                    }
                }

                // Delay compensation slider
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Delay Compensation")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.2fs", control.delaySeconds))
                            .font(.caption2)
                    }
                    HStack {
                        Image(systemName: "timer")
                            .font(.caption)
                        Slider(value: $control.delaySeconds, in: 0...1, step: 0.01)
                    }
                }
            }

            // Equalizer Section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Device Equalizer")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Flat") {
                        control.bassEQ = 1.0
                        control.midEQ = 1.0
                        control.trebleEQ = 1.0
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }

                HStack(spacing: 12) {
                    // Bass EQ
                    VStack {
                        Slider(value: $control.bassEQ, in: 0...2)
                            .controlSize(.small)
                        Text("Bass: \(Int((control.bassEQ - 1.0) * 12.0)) dB")
                            .font(.system(size: 8))
                    }
                    // Mid EQ
                    VStack {
                        Slider(value: $control.midEQ, in: 0...2)
                            .controlSize(.small)
                        Text("Mid: \(Int((control.midEQ - 1.0) * 12.0)) dB")
                            .font(.system(size: 8))
                    }
                    // Treble EQ
                    VStack {
                        Slider(value: $control.trebleEQ, in: 0...2)
                            .controlSize(.small)
                        Text("Treble: \(Int((control.trebleEQ - 1.0) * 12.0)) dB")
                            .font(.system(size: 8))
                    }
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func isBluetoothDevice(_ name: String) -> Bool {
        let nameLower = name.lowercased()
        return nameLower.contains("bluetooth") || nameLower.contains("headphone") || nameLower.contains("airpods")
    }
}

#Preview {
    ContentView()
        .environmentObject(AudioRouterViewModel())
}
