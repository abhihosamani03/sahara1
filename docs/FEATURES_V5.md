# Sahara 0.6.0 — long-range BLE, Wi-Fi Aware and real-time Codec2 voice

0.5.0 shipped the mesh/UI layer and left three native items out. This build
implements all three as real radios rather than settings switches.

Honest status: `flutter analyze` is clean, the 150 Dart tests pass, the Kotlin
and the native Codec2 library compile for `arm64-v8a`, and the codec was
verified by an encode/decode round trip on the host. **No Android device was
attached while this was built**, so the radio and audio behaviour below is
compile-verified, not field-tested.

## 1. Bluetooth LE Coded PHY (long range)

The `bluetooth_low_energy` plugin exposes no PHY control, so Coded PHY is a
**third radio**, not a replacement:

* `CodedPhyPlugin.kt` advertises through the extended advertising API with
  `PHY_LE_CODED`, scans with a Coded-only filter, and runs its own GATT client
  that calls `setPreferredPhy(..., PHY_LE_CODED, ...)`.
* The client connects to the peer's existing Sahara GATT server (published by
  the plugin), so the two implementations interoperate on one service.
* Frames reuse the Dart chunk envelope (`0xB5` magic, fragment id, index,
  count), so a frame is split and reassembled identically whichever radio
  carried it.
* `lib/net/coded_phy.dart` probes support and reports the real outcome: if the
  controller refuses the Coded PHY the status says so (`isCoded == false`)
  instead of claiming the range benefit.

Coded PHY trades throughput for sensitivity (~4× the range of 1M at the same
power), so it carries text frames and breadcrumbs; bulk transfers stay on Wi-Fi.

## 2. Wi-Fi Aware (NAN)

`WifiAwarePlugin.kt` attaches a NAN cluster and is **symmetric**: every node
publishes *and* subscribes to the `sahara-mesh` service, so any two phones find
each other without roles.

* Discovery carries an 8-byte random `instanceId` in `serviceSpecificInfo`.
  When two nodes see each other, only the lexicographically smaller ID opens
  the data path — this prevents two duplicate links per pair.
* The data path is an IPv6 link via `WifiAwareNetworkSpecifier` with a
  passphrase, then ordinary length-prefixed TCP frames, mirroring the Wi-Fi
  Direct transport.
* Requires API 29+; older devices report `unsupported` and keep BLE only.
* Relay mode is supported: frames arriving on NAN are re-broadcast like any
  other link.

Because NAN and Wi-Fi Direct both drive the Wi-Fi radio, `MeshTransport` starts
NAN first and only falls back to Wi-Fi Direct when NAN is genuinely unavailable.

## 3. Real-time Codec2 voice

Codec2 1.2.0 (LGPL 2.1, `android/app/src/main/cpp/codec2/`) is vendored and
built as `libsahara_codec2.so`. Its codebooks are generated **once on the host**
and checked in, so the Android build never needs a host toolchain or a nested
`ExternalProject` build.

* Mode **3200 bps**: 8 kHz mono, 20 ms frames, 160 samples → 8 bytes.
* `Codec2VoicePlugin.kt` captures with `AudioRecord` and plays with a streaming
  `AudioTrack`, both on dedicated threads.
* Three codec frames are batched per outbound packet (~17 packets/s instead of
  50), which is what makes the stream viable on a shared BLE link.
* Wire format is packet type `0xE`: `{"d":"<base64 of whole codec frames>"}`.
  No receipt is sent for these frames — ACKing 17 packets/s would crowd the
  same radio the audio needs.
* Push-to-talk is the control: with **Live voice (Codec2)** enabled in Settings,
  a PTT press streams audio instead of running offline speech recognition, and
  release ends the stream. This path works with no speech model downloaded and
  in noise where recognition fails.
* Playback is half duplex: received bursts are dropped while this phone is
  transmitting or speaking, and the speaker closes 2 s after the last burst.

Limits: 3200 bps is intelligible speech, not music; a lost packet costs 60 ms of
audio and is not retransmitted; the format is not interoperable with a phone
running 0.5.0 or older (unknown packet type 0xE is ignored).

## Deliberately unchanged

* BLE 1M and Wi-Fi Direct still work as before and remain the fallbacks.
* No API keys, no cloud services, no telemetry: all three radios are on-device.
* `release/`, `release-v2/` and `release-v3/` are untouched.
