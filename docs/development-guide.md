# Instruksi Pengembangan: macOS Frequency-Based Audio Router

Aplikasi yang memisahkan sinyal audio berdasarkan frekuensi (bass/subwoofer vs mid/treble) dan mengarahkan masing-masing ke output device yang berbeda secara real-time.

---

## 1. Ringkasan Arsitektur

```
┌─────────────────┐
│  System Audio /  │
│  App Audio       │
└────────┬─────────┘
         │ (Core Audio Tap / BlackHole capture)
         ▼
┌─────────────────────────┐
│  Audio Capture Engine    │  ← AVAudioEngine input node
└────────┬─────────────────┘
         │ PCM Buffer (Float32)
         ▼
┌─────────────────────────┐
│  Crossover DSP Module     │
│  - Linkwitz-Riley LPF     │  → Bass signal (< cutoff Hz)
│  - Linkwitz-Riley HPF     │  → Mid/Treble signal (> cutoff Hz)
└────────┬──────────┬──────┘
         │           │
         ▼           ▼
┌────────────────┐ ┌────────────────┐
│ Output Engine A │ │ Output Engine B │
│ → External Dev  │ │ → Built-in Spk  │
└────────────────┘ └────────────────┘
         ▲
         │ dikendalikan oleh
┌─────────────────────────┐
│  Device Routing Manager   │
│  (Core Audio HAL / MIDI  │
│   Setup Aggregate Device) │
└─────────────────────────┘
         ▲
┌─────────────────────────┐
│  SwiftUI Control Panel    │
│  - Pilih device            │
│  - Atur cutoff frequency   │
│  - Atur gain per band       │
└─────────────────────────┘
```

### Komponen Inti

| Komponen | Teknologi | Fungsi |
|---|---|---|
| Audio Capture | Core Audio Tap API (macOS 14.4+) atau BlackHole | Menangkap audio sistem/aplikasi |
| DSP Crossover | Accelerate/vDSP atau AVAudioUnitEQ | Memisahkan frekuensi bass vs mid/treble |
| Dual Output | 2x AVAudioEngine / AudioUnit | Kirim sinyal ke 2 device berbeda |
| Device Routing | Core Audio HAL (Aggregate Device) | Kelola daftar & pemetaan channel device |
| UI | SwiftUI + AppKit (menu bar app) | Kontrol pengguna |
| Permission | TCC / Privacy entitlement | Izin capture audio sistem |

---

## 2. Keputusan Teknis Kunci (Ambil di Awal)

1. **Metode capture audio**: Core Audio Process Tap (native, macOS 14.4+, tidak butuh install driver) vs BlackHole (kompatibel versi lama, tapi butuh instalasi driver pihak ketiga). → Rekomendasi: pakai Process Tap sebagai jalur utama, BlackHole sebagai fallback.
2. **Target distribusi**: App Store (butuh sandboxing ketat, virtual driver pihak ketiga bermasalah) vs direct distribution/notarized DMG (lebih fleksibel). → Ini menentukan apakah Anda perlu bikin HAL plugin sendiri.
3. **Minimum macOS version**: Jika mendukung < 14.4, Process Tap API tidak tersedia, wajib pakai driver virtual.
4. **Crossover cutoff default**: umumnya 80–150 Hz untuk speaker built-in Mac (drivernya kecil, tidak sanggup reproduksi sub-bass), tapi buat ini adjustable oleh user.

---

## 3. Task Breakdown

### Fase 0 — Riset & Setup Proyek
- [ ] Tentukan target macOS minimum version (pengaruh besar ke pilihan capture API)
- [ ] Tentukan jalur distribusi (App Store vs notarized DMG di luar App Store)
- [ ] Setup project Xcode (SwiftUI + AppKit menu bar app / regular app)
- [ ] Riset & baca dokumentasi `AudioHardwareCreateProcessTap` (macOS 14.4+) atau BlackHole SDK
- [ ] Setup entitlements: `com.apple.security.device.audio-input`, audio capture permission

### Fase 1 — Audio Capture
- [ ] Implementasi capture via Core Audio Process Tap untuk system-wide audio
- [ ] (Fallback) Implementasi deteksi & instalasi BlackHole sebagai virtual driver jika Process Tap tidak tersedia
- [ ] Buat abstraction layer `AudioSource` supaya capture method bisa di-switch tanpa ubah kode DSP
- [ ] Test: pastikan buffer PCM (Float32, sample rate, channel count) diterima dengan benar dan tanpa dropout
- [ ] Handle permission request flow (system audio recording permission dialog)

### Fase 2 — DSP Crossover Filter
- [ ] Implementasi Linkwitz-Riley Low-Pass Filter (24 dB/oktaf, cascaded 2nd order Butterworth)
- [ ] Implementasi Linkwitz-Riley High-Pass Filter (komplemen dari LPF)
- [ ] Validasi fase: pastikan sum LPF+HPF = flat response (karakteristik utama Linkwitz-Riley)
- [ ] Implementasi menggunakan `vDSP_biquad` (Accelerate framework) untuk performa real-time
- [ ] Buat parameter cutoff frequency dinamis (adjustable saat runtime tanpa klik/pop)
- [ ] Tambahkan smoothing/crossfade saat user ubah cutoff untuk hindari artifact audio
- [ ] Unit test DSP dengan sine sweep, verifikasi cutoff response pakai FFT analysis

### Fase 3 — Dual Output Routing
- [ ] Setup `AVAudioEngine` A untuk output ke built-in speaker (mid/treble)
- [ ] Setup `AVAudioEngine` B untuk output ke external device (bass)
- [ ] Assign device spesifik ke tiap engine via `kAudioOutputUnitProperty_CurrentDevice`
- [ ] Implementasi device discovery (list semua available output devices via Core Audio)
- [ ] Handle device hot-plug/unplug (external device dicabut saat runtime → fallback graceful)
- [ ] Sinkronisasi timing antara dua engine (minimalkan latency mismatch)
- [ ] Test end-to-end: audio benar-benar terpisah sesuai frekuensi di device yang tepat

### Fase 4 — Device Management (Core Audio HAL)
- [ ] Evaluasi apakah perlu bikin Aggregate Device programatik (`AudioHardwareCreateAggregateDevice`)
- [ ] (Opsional) Buat automasi setup Multi-Output Device agar user tidak perlu buka Audio MIDI Setup manual
- [ ] Simpan preferensi device pairing (bass device + speaker device) per user

### Fase 5 — UI/UX
- [ ] Desain menu bar app (status icon + quick toggle on/off)
- [ ] Panel setting: pilih external device, slider cutoff frequency, gain per band (bass gain, mid/treble gain)
- [ ] Visual feedback: level meter per band (opsional, pakai Core Audio metering)
- [ ] Preset system (misal: "Movie", "Music", "Gaming" dengan cutoff berbeda)
- [ ] Onboarding flow untuk permission audio capture

### Fase 6 — Performance & Reliability
- [ ] Profiling latency end-to-end (target < 20ms capture→output)
- [ ] Stress test: audio panjang (streaming video/musik berjam-jam), cek memory leak & buffer underrun
- [ ] Handle sample rate mismatch antar device (built-in vs external mungkin beda sample rate)
- [ ] Graceful degradation: kalau salah satu output device gagal, fallback ke single output

### Fase 7 — Packaging & Distribusi
- [ ] Code signing & notarization
- [ ] Jika pakai BlackHole: bundling installer driver atau instruksi instalasi manual
- [ ] Jika App Store: review sandboxing constraints, sesuaikan API yang dipakai
- [ ] Dokumentasi user (cara pairing device, troubleshooting)

---

## 4. Risiko & Hal yang Perlu Diwaspadai

- **Latency mismatch antar dua output engine** — kalau tidak disinkronkan, bass akan terasa "telat" dari mid/treble, imaging jadi aneh.
- **Sample rate berbeda antar device** — built-in speaker biasanya 44.1/48kHz, sebagian external device beda. Perlu resampling di jalur yang sesuai.
- **Permission system audio capture** — sejak macOS Sonoma, capture system-wide audio makin diperketat; user akan diminta approval eksplisit.
- **App Store review** — virtual audio driver pihak ketiga (BlackHole) sering jadi masalah approval; kalau target App Store, prioritaskan Process Tap API murni.
- **Device hot-plug handling** — user cabut headphone/speaker external saat aplikasi jalan harus di-handle tanpa crash.

---

## 5. Referensi Teknis untuk Dipelajari

- Core Audio Process Tap API (WWDC 2024 session tentang "Capture system audio in your app")
- `AVAudioEngine` & `AVAudioUnitEQ` documentation
- Accelerate framework — `vDSP_biquad` untuk filter digital
- Core Audio HAL — Aggregate & Multi-Output Device programmatic creation
- Linkwitz-Riley crossover filter theory (untuk memastikan implementasi filter benar secara akustik)

---

Mau saya lanjutkan dengan membuat skeleton kode Swift untuk salah satu fase (misal capture engine atau crossover filter) sebagai starting point?
