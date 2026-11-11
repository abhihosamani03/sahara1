# 📻 Sahara: Offline Multilingual Neural Transceiver

![Android](https://img.shields.io/badge/Platform-Android_7.0+-3DDC84?style=for-the-badge&logo=android&logoColor=white)
![Offline](https://img.shields.io/badge/Connectivity-100%25_Offline-FF4B4B?style=for-the-badge)
![AI](https://img.shields.io/badge/Edge_AI-ONNX_Runtime-005CED?style=for-the-badge)
![Mesh](https://img.shields.io/badge/Network-Wi--Fi_Direct_%7C_BLE-0078D4?style=for-the-badge)

**Sahara** is a decentralized, 100% offline Android communication hub designed for disaster relief and zero-connectivity zones. It transforms standard budget smartphones into a self-healing walkie-talkie mesh network powered entirely by Edge AI. 

By compressing transcribed speech into compact text frames (a typical spoken sentence is a few dozen bytes), Sahara provides voice-to-voice communication across 9 Indian languages with offline models out of a 23-language registry, even when cellular towers, internet, and power grids completely collapse.

---

## 🚀 Core Innovations

*   **Ultra-Compressed Micro-Payloads (IBFS-v1):** Converts heavy voice audio into a compact text frame (14 bytes of header + CRC; a typical sentence is a few dozen bytes of UTF-8). This requires a small fraction of the bandwidth of streaming audio, ensuring delivery over severely degraded radio links.
*   **On-Device Edge AI Pipeline:** Runs STT and TTS models natively with INT8-quantized, hot-swappable models. Memory use depends on the loaded language pair; measured figures and limits are in `docs/APP_FEATURES.md`.
*   **Keyword SOS Triage:** Runs per-language distress-keyword detection on the STT text (e.g., "Help", "Rescue", with Indic equivalents) and raises an emergency-priority packet carrying offline GPS coordinates — no screen interaction required.
*   **Tactical OS Audio Override:** Incoming emergency SOS frames bypass Android's "Do Not Disturb" and silent profiles, seizing hardware audio focus to blast alerts at 100% volume.
*   **Delay-Tolerant Store & Forward:** Acts as an asynchronous data mule. If a user is completely isolated, the app caches SOS beacons and blasts them the exact microsecond another mesh node enters radio range.
*   **Multilingual Inclusivity:** Breaks the literacy and language barrier. A user speaks naturally in their regional language, the payload is transmitted, and the receiving device synthesizes the text back into natural, spoken audio.

---

## 🆕 v0.3.0 — Coordination & Early Warning

*   **Mesh v2 routing:** every frame carries a 9-byte envelope with TTL (5), hop count and origin/destination IDs, so flooding stops instead of circling the mesh.
*   **Offline incident board:** SOS calls, needs (water / food / medical / shelter / rescue), safe/missing check-ins and warnings are aggregated on the phone, with totals, assignment (team + ETA) and resolve — no server.
*   **Structured reports:** check-in, triage, early-warning and assignment packet types (0x5–0x8) with GPS, severity and battery level.
*   **SOS beacon:** repeats every 45 s (90 s on low battery) up to 12 times with a fresh fix, and stops when a delivery receipt arrives.
*   **Early warning delivery:** an alert spoken and alarmed on every receiver, with no internet at either end.
*   **Real battery + thermal readings** through a native Android channel.

Details and limits: [`docs/FEATURES_V2.md`](docs/FEATURES_V2.md).

---

## 🆕 v0.6.0 — Long-range BLE, Wi-Fi Aware and live Codec2 voice

*   **LE Coded PHY:** a third radio with extended Coded advertising, a Coded-only scan and a native GATT client that requests the long-range PHY — roughly 4× the range of BLE 1M for text and breadcrumbs.
*   **Wi-Fi Aware (NAN):** symmetric publish + subscribe discovery, a tie-break so a pair only builds one data path, and a passphrase-protected IPv6 link with the same framing as Wi-Fi Direct.
*   **Real-time Codec2 voice:** 3200 bps speech at 8 kHz (20 ms / 8-byte frames) through a vendored Codec2 1.2.0 native library, streamed on PTT as packet type `0xE`. Works with no speech model and in noise where recognition fails.

Details and limits: [`docs/FEATURES_V5.md`](docs/FEATURES_V5.md).

## 🆕 v0.5.0 — Routed mesh, field clock and incident map

*   **Mesh v3 routing:** frames carry a learned next hop and an eight-node path trace; relays outside the route stop forwarding, and targeted messages report how they travelled.
*   **Mesh time sync:** median-filtered clock samples align log ordering and trail timestamps without internet.
*   **Priority preemption:** emergency traffic opens a four-second window; ledger, breadcrumb and clock gossip wait instead of competing.
*   **Relay-only mode:** a spare phone can act as a pure repeater (BLE only, no mic/speaker, low-power scanning).
*   **Start on boot:** optional standby/mesh restart after a reboot.
*   **Incident map:** all positioned incidents and breadcrumb trails on the offline tile map.
*   **MBTiles region packs:** one-tap import of a district `.mbtiles` archive.
*   **Responder breadcrumbs:** GPS trail shared over the mesh and drawn on the map.

Details are in [`docs/FEATURES_V4.md`](docs/FEATURES_V4.md). The three native items it deferred (BLE Coded PHY, Wi-Fi Aware, Codec2) ship in 0.6.0.

## 📦 Builds

| Build | Folder | Notes |
|---|---|---|
| 0.2.0 | `release/` | Phase-1 transceiver (ACK/retry, translation, map, queue). Left untouched. |
| 0.3.0 | `release-v2/` | Adds coordination, mesh v2, beacon, battery channel. arm64 APK + SHA-256. |
| 0.4.0 | `release-v3/` | iTantra 0.4.0 field coordination (kept unchanged). |
| 0.5.0 | `release-sahara/` | Sahara with mesh v3 routing, time sync, relay mode, incident map, MBTiles import and breadcrumbs. |
| 0.6.0 | `release-sahara/` | Adds LE Coded PHY, Wi-Fi Aware and real-time Codec2 voice. |

## 🛠️ Technology Stack

*   **Application Core:** Flutter & Kotlin (Native Android Services)
*   **Edge Machine Learning:** ONNX Runtime C++ Bindings, Sherpa-ONNX
*   **Acoustic Models:** AI4Bharat IndicConformer (STT), VITS (TTS)
*   **Voice Activity Detection:** Silero VAD (TinyML)
*   **Networking:** Android Wi-Fi Direct (P2P), Wi-Fi Aware (NAN), Bluetooth Low Energy (GATT/Advertising, LE Coded PHY)
*   **Voice Codec:** Codec2 3200 bps (native, LGPL 2.1), beside the offline STT/TTS pipeline

---

## ⚙️ The Neural Transceiver Pipeline

1.  **Audio Capture:** Minimal-CPU Silero VAD detects natural speech pauses (0.45s) for hands-free operation.
2.  **Speech-to-Text (STT):** Local INT8 Indic models transcribe the audio to text.
3.  **Compression:** The text, sender name, and offline GPS are packed into one iBFS frame — 14 bytes of header and CRC, then the UTF-8 text (a typical sentence stays in the low tens of bytes).
4.  **Ad-Hoc Mesh Transport:** Each node re-broadcasts the frame once over Wi-Fi Direct and BLE, so it crosses idle survivor smartphones acting as repeaters.
5.  **Text-to-Speech (TTS):** The receiving device decodes the packet and synthesizes it into natural spoken audio for the receiver.

---

## 📱 Hardware Compatibility
Designed strictly for inclusivity and disaster-resilience in developing regions:
*   **OS:** Android 7.0 (API 24) and above.
*   **Memory:** Runs smoothly on low-to-mid-range devices with 2GB+ RAM.
*   **Cloud Dependency:** `0%` (No APIs, no cloud servers, no cellular towers required).

---

## 👥 Contributors & Team
Developed by **Team Sahara** for the Smart India Hackathon. 
*An open-source initiative to build a resilient, voice-driven communication grid when all infrastructure collapses.*
