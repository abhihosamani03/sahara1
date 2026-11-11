# Additional Features — Differentiators Beyond the Baseline Problem Statement

The baseline (offline STT -> text transfer -> offline TTS, two-phone PTT loop) is the core of the project. These features are optional, individually toggleable additions that extend the same architecture toward real-world disaster-response needs. Build them in the priority order below, only after the baseline is stable (see SETUP_AND_BUILD.md §5).

## Priority 1 — Highest value per hour of build time

### 1. Distress-Intent Auto-Detection
Run a lightweight keyword/intent classifier on the STT text output (not the audio) to detect distress language ("help", "trapped", "injured", "fire", equivalents per language) and auto-set the packet's Priority flag to Emergency — instead of requiring the sender to manually mark it. Directly strengthens the accuracy story since it's additional on-device inference, and it's a genuine safety feature that's field-relevant.
- Implementation: a small classifier head on top of STT output text, or even a curated keyword-match list per language as a first pass if time is short.

### 2. GPS Location Stamping
Attach device GPS coordinates (works fully offline, no data connection needed) to transmitted messages using the extended payload format (see NETWORK_PROTOCOL.md §4). Turns "help needed" into "help needed, here" — the single highest-value addition for an actual disaster-response use case.

### 3. Store-and-Forward Queueing
If the target peer is out of range, queue the message locally (with its Sequence ID) and auto-deliver on reconnect, rather than failing silently. Uses Packet Type `0x4` (relay) from NETWORK_PROTOCOL.md. Cheap to build on top of the existing frame format, high practical value given disaster-zone connectivity is inherently intermittent.

## Priority 2 — Strong differentiator, more build effort

### 4. Cross-Language Relay (Translation) — implemented with ML Kit
Text already sits mid-pipeline, so the translation stage runs between decode and TTS: Person A speaking Kannada is *spoken aloud* in English on Person B's phone. The packet's own language field is the detected input language, so the receiver compares it against its listen language and only translates when they differ.

**Engine:** Google ML Kit on-device translation (`OnDeviceTranslator`). Chosen over AI4Bharat IndicTrans2 because IndicTrans2 distilled is 200 MB+ per direction, which would have undone the APK-size work, while ML Kit adds no model bytes to the APK at all.

**Offline behaviour:** ML Kit runs fully on-device; only the per-language models come from Google, once each (~30 MB). After that translation works with no network whatsoever, which is what makes it usable in a disaster zone.

**Never blocks reception:** `ensureModels()` returns `false` immediately while a model downloads in the background rather than awaiting it. A 30 MB download must not stall an incoming SOS for minutes. The message that arrives mid-download is shown and spoken in its original language, and the *next* one is translated. Progress is surfaced in Settings.

**Honest coverage limit:** ML Kit ships models for 9 of the 23 languages — Hindi, Bengali, Gujarati, Kannada, Marathi, Tamil, Telugu, Urdu and English. Malayalam, Odia, Punjabi, Assamese, Nepali and every north-eastern language have no model; those pairs show the original text with a note naming the missing side. The Settings screen lists exactly which languages are unsupported.

- The `HasSourceLang` extended payload flag (NETWORK_PROTOCOL.md §4) remains available for relay scenarios; the packet's header language is the primary source-language signal.

### 5. Mesh / Multi-Hop Relay
Beyond direct two-phone pairing, allow a message to hop through intermediate phones running the app to reach someone outside direct radio range (Wi-Fi Direct group owner election, or BT bridging). Reflects real disaster-mesh precedent (goTenna, Bridgefy-style approaches). Use the Sequence ID for hop-dedup (a relay node drops packets it's already forwarded, per NETWORK_PROTOCOL.md §5).

## Priority 3 — Nice to have, lower marginal value

### 6. Adaptive Fallback to Compressed Raw Audio
If STT confidence is very low (heavy accent, dialect gap, high noise), fall back to sending a short, heavily compressed raw-audio clip (Opus or Codec2 at low bitrate) rather than silently failing or sending garbled text. Signals you understood your own architecture's failure modes rather than assuming STT always succeeds.

### 7. Transcription Confidence Display + Manual Correction
Show the sender the transcribed text with a confidence indicator before it transmits, allowing quick correction of misrecognized words — especially proper nouns and place names, which STT models handle worst. Cheap UI addition, meaningfully improves real-world reliability.

### 8. Group / Broadcast Mode
One-to-many PTT instead of strictly 1:1, closer to how real disaster-response radio channels work (a command post broadcasting to a full team rather than pairing individually).

### 8a. SOS Emergency Broadcast (implemented)
A red SOS button that fans an emergency alert (Packet Type `0x2`, see NETWORK_PROTOCOL.md §Packet Type) to every device in radio range — not one peer, all of them. Receiving devices treat it as "raise the alarm": a full-screen red overlay, a spoken message via TTS, and a native alert that is engineered to be un-missable:

- **App closed on the receiver** — a foreground standby service (`SosService.kt`) keeps the Flutter engine (and the BLE / Wi-Fi Direct mesh) alive after the app is swiped off the recents list, so the packet is still received. The alarm is raised by the native layer, which works with no Activity attached.
- **Silent mode / Do Not Disturb** — the alarm tone plays on `STREAM_ALARM` (what silent and DND modes do not silence), the SOS notification channel is created with `setBypassDnd(true)`, and with Notification Policy Access granted the receiver's DND is lifted entirely for the alert and restored after.
- **Screen off / locked** — the full-screen notification intent wakes the display and shows over the lock screen.
- **Delivery guarantee** — when no device is in range, the SOS is queued by the store-and-forward layer and re-sent automatically on reconnect.

The sender gets a 3-second confirm countdown (auto-cancel) so a pocket trigger cannot fire an irreversible village-wide alert, plus an optional note that is shown and spoken on every receiver. A readiness strip (Standby / DND / Battery chips) shows exactly what could block reception on this device and deep-links to the fix.

### 9. Battery/Thermal-Aware Model Scheduling
Throttle or unload models based on battery level and thermal state, not just RAM. Field phones will be resource-starved in ways a lab-tested phone isn't — this is a footprint-metric point worth documenting even in a minimal implementation.

### 10. Lightweight Payload Encryption
AES on the small text payload — negligible performance cost given payload sizes are tens of bytes, but signals security-mindedness appropriate for a government-facing distress system.

### 11. Settings & Persistence (implemented)
A Settings screen backed by `shared_preferences` (`AppSettings`), loaded before the first frame so the UI never renders a default value and then corrects itself:

- **Username** — up to **8 characters**, transmitted in every packet (NETWORK_PROTOCOL.md §4) so receivers know who is speaking. The limit is enforced in the setting *and* again in the encoder, because a name that silently will not transmit is worse than one that is visibly clipped.
- **Speech rate** — 0.5×–1.5×, applied to both the neural VITS and the platform synthesizer.
- **Hardware SOS trigger** — see §15.
- **Medical & distress telemetry** — blood group, pre-existing conditions, emergency contact, appended to every outgoing SOS so responders get them in the same packet instead of having to ask.
- **Local rescue log & cache cleanup** — one action clears cached audio clips, the packet log and the undelivered queue. Downloaded AI models are deliberately preserved: re-downloading a 150 MB speech model in a disaster zone is the exact scenario this app exists to avoid. Separate, explicitly-confirmed actions delete translation models or speech models.

### 12. Dual Operation Mode — PTT vs Hands-Free (implemented)
The evaluation asks for walkie-talkie behaviour that becomes phone-like when the button is turned off. Both modes are implemented:

- **Walkie-Talkie (PTT)** — hold to talk, release to send; a quick tap latches recording until the next tap so a short utterance is never lost.
- **Phone (hands-free)** — the mic stays open. Silero VAD is reconfigured to a **3.0 s** trailing-silence window (vs 0.45 s for PTT), and when that silence is reached the sentence is finalised, encoded and streamed with no button press at all.

Two details that matter for hands-free to actually work:

1. **Feedback prevention.** The receiving phone's own spoken translation would otherwise be recognised as speech and bounced back to the peer. Capture is muted for exactly as long as inbound audio is playing.
2. **Half-duplex is not applied in hands-free.** Suppressing inbound playback while the mic is open (the correct PTT rule) would make the phone mode one-way, since the mic is *always* open. The loop is broken by the targeted mute above instead.

### 13. Device Role Selector — STT / TTS / Transceiver (implemented)
The evaluation asks for two phones, one in TTS mode and one in STT mode, to verify the loop. `AppRole` gates features so nothing silently does nothing:

| Role | Microphone | Playback | Centre control |
|---|---|---|---|
| **Transceiver** | on | on | PTT / hands-free panel |
| **STT (sender)** | on | off — logged, never spoken | PTT / hands-free panel |
| **TTS (receiver)** | off | on | explicit "receiver only" state |

The role is switchable from both the Settings screen and the always-visible mode bar on the main screen. Sender-side latency benchmarks (`STT ms`, `ASR ms`, `RTF`) are recorded on every message; **RTF is decode-time ÷ audio-duration**, which is the meaningful ASR metric — button-to-text time includes however long the speaker held the button and would always read ≈1.0.

### 14. Offline Map for SOS Telemetry (implemented)
An incoming distress packet already carries `lat`/`lon` (NETWORK_PROTOCOL.md §4). Tapping any log entry with a fix — or *View position on map* on the alarm overlay — plots it on `OfflineMapView`, which needs no internet and no Google Maps key:

- Web-Mercator slippy map with drag pan, pinch zoom, +/− buttons and recentre.
- Tiles read from `<app documents>/offline_tiles/<z>/<x>/<y>.png`, with an optional `assets/offline_tiles/...` fallback.
- That is the universal XYZ layout every MBTiles archive uses, so an `.mbtiles` file can be exported straight into it. With `sqlite3` installed:

  ```bash
  # Dump every tile in world.mbtiles into the XYZ folder layout.
  sqlite3 world.mbtiles \
    "SELECT zoom_level, tile_column, tile_row, writefile(zoom_level || '/' || tile_column || '/' || ( (1 << zoom_level) - 1 - tile_row ) || '.png', tile_data) FROM tiles;"
  ```

  (Tiles in MBTiles are stored TMS-style — row flipped — which is why the dump inverts `tile_row`.)

- **With no tiles installed it still works**: a Mercator graticule is drawn, pan and zoom keep working, and the marker lands in the correct position, so the operator can see where the call came from on a bare device. Missing individual tiles render as empty rather than as an error box.

The map maths is a pure, unit-tested projection (`MercatorProjection`) rather than a plugin, so it adds zero APK size.

### 15. Hardware Silent SOS Trigger (implemented)
A Settings switch arms a **deliberate volume-key hold** (two key-repeat events, ≈700 ms) as an SOS trigger. This is the "I cannot look at my phone" path, so it deliberately skips the on-screen 3-second confirmation sheet. The key event is never consumed — the volume rocker still works normally.

- **Limitation, stated plainly:** Android only delivers key events to a focused window, and exposes no API for capturing volume keys globally. The trigger therefore works while Sahara is running (foreground or behind the standby service) but cannot fire from a process with no window. This is a platform constraint, not an oversight.
- **Timer change:** a keyword-triggered emergency alert overlay now auto-clears after **5 s** (it is an attention grabber, not a mode; the message remains in the packet log). An explicit SOS still runs for 20 s, because the person who pressed it needs help.

### 16. Username on the wire (implemented)
See §11. The name is a **structured payload field** (`HasSenderName` + a length-prefixed UTF-8 string), not a `"[Name]: message"` text prefix. Reasons: the text stays clean for translation (a prefixed name would be fed to the NMT model and come back mangled), the receiver can render it as a separate chip and speak only the message, and it costs **1 length byte + the name** only when a name is actually set — zero bytes otherwise.

## What NOT to over-invest in
Given the quality weights (Accuracy 40%, Latency 20%, Efficiency 20%), a flashy feature list does not substitute for hitting your core STT WER and end-to-end latency targets. If you're choosing between polishing feature #6-10 versus tightening your baseline numbers, tighten the baseline — see EVALUATION_MAPPING.md for how the criteria actually weigh these choices.
