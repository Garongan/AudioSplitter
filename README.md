# Audio Splitter — macOS Starter Pack

Starter project untuk aplikasi macOS yang memisahkan audio berdasarkan
frekuensi (bass/subwoofer vs mid/treble) dan mengirim tiap band ke output
device yang berbeda secara real-time.

> ⚠️ Ini adalah **skeleton/kerangka kode**, bukan aplikasi jadi. Banyak
> fungsi berisi `TODO` yang perlu diimplementasikan (terutama bagian
> Core Audio yang butuh testing langsung di Xcode/macOS nyata). Lihat
> dokumen `docs/development-guide.md` untuk breakdown task lengkap.

## Struktur Folder

```
AudioSplitter/
├── project.yml                          # XcodeGen spec (generate .xcodeproj)
├── README.md                            # File ini
├── docs/
│   └── development-guide.md             # Arsitektur & task breakdown lengkap
└── AudioSplitter/
    ├── AudioSplitterApp.swift           # Entry point (menu bar app)
    ├── Capture/
    │   └── AudioCaptureEngine.swift     # Strategi capture: Process Tap & BlackHole
    ├── DSP/
    │   └── CrossoverFilter.swift        # Linkwitz-Riley crossover filter
    ├── Output/
    │   └── DualOutputManager.swift      # Dua AVAudioEngine -> dua device
    ├── Routing/
    │   └── DeviceRoutingManager.swift   # Discovery & Aggregate Device
    ├── UI/
    │   ├── AudioRouterViewModel.swift   # Penghubung capture -> DSP -> output
    │   └── ContentView.swift            # Panel kontrol SwiftUI
    └── Resources/
        ├── Info.plist                  # Usage description untuk permission
        └── AudioSplitter.entitlements  # Sandbox & audio-input entitlement
```

## Cara Membuka di Xcode

### Opsi A — Pakai XcodeGen (disarankan)

```bash
brew install xcodegen
cd AudioSplitter
xcodegen generate
open AudioSplitter.xcodeproj
```

### Opsi B — Manual

1. Buka Xcode → New Project → macOS App (SwiftUI, Swift).
2. Beri nama `AudioSplitter`.
3. Hapus file default yang di-generate Xcode, lalu drag folder
   `AudioSplitter/AudioSplitter` (Capture, DSP, Output, Routing, UI,
   Resources) ke dalam project navigator, centang "Copy items if needed".
4. Set `Info.plist` dan entitlements di Target → Signing & Capabilities
   sesuai file di folder `Resources`.
5. Tambahkan framework: `AVFoundation`, `CoreAudio`, `Accelerate`
   (Target → General → Frameworks and Libraries).

## Langkah Selanjutnya (Prioritas)

Ikuti urutan di `docs/development-guide.md`, tapi ringkasnya:

1. **Isi `CoreAudioProcessTapSource`** di `AudioCaptureEngine.swift` —
   ini bagian paling teknis, pelajari WWDC24 session "Capture system
   audio in your app" (macOS 14.4+). Kalau perlu dukung macOS lebih
   lama, siapkan BlackHole sebagai fallback.
2. **Isi `assignDevice(_:to:)`** di `DualOutputManager.swift` — set
   `kAudioOutputUnitProperty_CurrentDevice` pada AudioUnit tiap engine.
3. **Isi `refreshDevices()`** di `DeviceRoutingManager.swift` — query
   `kAudioHardwarePropertyDevices` untuk dapat daftar device asli
   (saat ini masih placeholder dummy data).
4. Setelah tiga hal di atas jalan, test end-to-end: audio dari sistem
   ke aplikasi kamu → split by frequency → keluar ke dua device.

## Catatan Penting

- **Testing harus di Mac fisik** — Process Tap & device routing tidak
  bisa disimulasikan di luar macOS asli.
- **Target distribusi menentukan arsitektur**: kalau mau App Store,
  hindari bundling BlackHole (driver pihak ketiga sering bermasalah
  saat review) dan fokus ke Process Tap API murni + sandboxed entitlements.
- **Linkwitz-Riley filter** di `CrossoverFilter.swift` sudah diimplementasikan
  penuh (bukan TODO) — tapi belum divalidasi dengan sine sweep/FFT test,
  disarankan buat unit test sebelum dipakai production.
- Ganti `com.yourcompany` di `project.yml` dan bundle identifier dengan
  identifier Apple Developer account kamu sendiri.

## Lisensi Referensi

Kalau pakai BlackHole sebagai fallback, dia berlisensi GPL-3.0 — cek
kompatibilitas lisensi dengan rencana distribusi aplikasi kamu:
https://github.com/ExistentialAudio/BlackHole
