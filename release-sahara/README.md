# Sahara 0.6.0 — arm64 release APK (separate app)

Adds the three native radios that 0.5.0 deferred, on top of the field-network
layer:

- LE Coded PHY: long-range BLE as a third radio, with a native GATT client that
  requests the Coded PHY (~4× the range of 1M for text and breadcrumbs)
- Wi-Fi Aware (NAN): symmetric publish/subscribe discovery, a tie-break so a
  pair only builds one data path, and a passphrase-protected IPv6 link
- Real-time Codec2 voice: 3200 bps at 8 kHz through a native Codec2 1.2.0
  library, streamed on push-to-talk as packet type `0xE`

Plus everything from 0.5.0: mesh v3 next-hop routing with a path trace,
median-filtered time sync, emergency priority preemption, relay-only mode,
optional start-on-boot, the incident map overlay, MBTiles region import and the
responder breadcrumb trail.

Verified for this build: `flutter analyze` clean, 150 tests pass, Kotlin and the
native Codec2 library compile for `arm64-v8a`, and the codec round-trips audio
(encode → decode) on the host. No Android device was attached, so radio and
audio behaviour is compile-verified rather than field-tested.

| | |
|---|---|
| File | `Sahara-0.6.0-arm64-v8a.apk` |
| Size | 64,631,576 bytes (61.6 MB) |
| SHA-256 | `938899b1cc2a1aa859c25dfff4cc638b3886d1a52b905ac5ba600bfd99a5e822` |
| Version | 0.6.0 (versionCode 10000; arm64 split) |
| Package | `com.example.voice.sahara` |
| Launcher name | Sahara |
| ABI | arm64-v8a |
| minSdk / targetSdk | 24 / 36 |
| Signing | Android debug certificate, APK Signature Scheme V2 |

Install with:

```bash
adb install -r release-sahara/Sahara-0.6.0-arm64-v8a.apk
```

Interoperability: the radios and text mesh are compatible with a 0.5.0 phone,
but live Codec2 voice is not — an older build ignores packet type `0xE`. Wi-Fi
Aware needs Android 10 (API 29) or newer; on older phones the app reports it as
unsupported and keeps BLE and Wi-Fi Direct.
