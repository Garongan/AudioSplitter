//
//  ContentView.swift
//  AudioSplitter
//
//  Panel kontrol utama: toggle on/off, pilih device, atur cutoff & gain.
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject var router: AudioRouterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack {
                Text("Audio Splitter")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { router.isRunning },
                    set: { newValue in
                        newValue ? router.start() : router.stop()
                    }
                ))
                .labelsHidden()
            }

            if let error = router.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Crossover Cutoff: \(Int(router.cutoffHz)) Hz")
                    .font(.subheadline)
                Slider(value: $router.cutoffHz, in: 40...300, step: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Bass Gain")
                    .font(.subheadline)
                Slider(value: $router.bassGain, in: 0...2)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Mid/Treble Gain")
                    .font(.subheadline)
                Slider(value: $router.midTrebleGain, in: 0...2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Devices Terdeteksi")
                    .font(.subheadline)
                ForEach(router.deviceRouting.availableDevices) { device in
                    Text("• \(device.name)")
                        .font(.caption)
                }
                Button("Refresh Devices") {
                    router.deviceRouting.refreshDevices()
                }
                .font(.caption)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(AudioRouterViewModel())
}
