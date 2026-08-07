//
//  AudioSplitterApp.swift
//  AudioSplitter
//
//  Entry point aplikasi. Berjalan sebagai menu bar app (MenuBarExtra).
//  Ganti ke WindowGroup biasa jika ingin regular app dengan jendela utama.
//

import SwiftUI

@main
struct AudioSplitterApp: App {

    @StateObject private var router = AudioRouterViewModel()

    var body: some Scene {
        MenuBarExtra("Audio Splitter", systemImage: "waveform.and.arrow.up.arrow.down") {
            ContentView()
                .environmentObject(router)
                .frame(width: 340)
        }
        .menuBarExtraStyle(.window)
    }
}
