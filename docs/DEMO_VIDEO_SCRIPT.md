# Sahara — 4-Minute SIH Evaluation Video Script

Word-for-word spoken script, timed to exactly 4:00. Total spoken budget ≈ 575
words (~145 wpm) — read it at a normal, unhurried pace and it lands on time.

Replace the two `<...>` placeholders with your team name and PS ID before
recording.

---

## Before you record — do this first

The STT models are **downloaded on first use**, not bundled in the APK. If you
put the phones in airplane mode before a model is on disk, voice mode degrades to
the `🎙️ [Voice note]` fallback and the centrepiece of the demo dies.

1. Install the **same** APK build on **both** phones (`app-arm64-v8a-release.apk`).
   Mixed builds are wire-incompatible and will look like a total failure.
2. On each phone, while still online: open Sahara, pick the language you will
   demo (Hindi recommended), and let the model download finish (~189 MB).
   Do this for **both** sender and receiver.
3. Confirm the pipeline strip has lit up green at least once with both phones in
   normal mode before you start rolling.
4. Now: airplane mode **ON** on both, Wi-Fi **ON**, Bluetooth **ON**,
   Location **ON**. Airplane mode kills the SIM; the mesh radios still work.
5. Do Not Disturb **ON** on both phones — incoming calls mid-take are the
   single most common way a demo video gets ruined.
6. Lock exposure/white balance on the camera, shoot landscape, and record the
   phone screens with a second camera or a screen recorder. Judges need to read
   the text on screen.

Have ready: two phones, a tripod, a printed copy of this script, and the mic
level tested.

---

## 0:00 – 0:20 — Intro

*On screen: title card with Sahara / सहारा, team name, PS ID. Then cut to you,
then to the two phones side by side.*

> "Hello, we are Team `<TEAM NAME>`.
> Our problem statement is `<PS ID>` — communication during disasters when
> cellular networks fail.
> Our solution is **Sahara** — an offline, multilingual voice transceiver that
> runs entirely on the phone. No internet, no server, no SIM. Let me show you it
> working right now."

---

## 0:20 – 0:50 — The problem

*On screen: overlay "96 KB vs 40 bytes".*

> "When a disaster hits, the first thing that dies is the network. Towers
> overload, fibre gets cut, power goes out. And the links that actually survive —
> Bluetooth, Wi-Fi Direct — are far too slow to carry voice.
>
> Three seconds of raw audio is about ninety-six kilobytes. That does not go
> over a weak ad-hoc link. So we asked a different question. What if we never
> send audio at all?"

---

## 0:50 – 1:20 — The solution

*On screen: the core loop diagram —
speech → VAD → on-device STT → iBFS-v1 encode → radio → decode → on-device TTS.*

> "Sahara converts speech to text **on the device**, sends only that text, and
> re-synthesises the voice at the other end using on-device text-to-speech.
>
> The same three-second message becomes roughly **forty to eighty bytes**. That
> is a **99.9 percent reduction** in bandwidth — the difference between a link
> that fails and a link that works.
>
> The packet format is our own binary protocol, **iBFS-v1**: a 14-byte header,
> CRC-16 error checking on every frame, and it carries the language, a sequence
> number, GPS coordinates, and emergency priority in those bytes."

---

## 1:20 – 2:30 — Live demo A: offline push-to-talk

*Action: hold both phones up to camera. Show airplane mode enabled on both.
Point at the Wi-Fi and Bluetooth icons. Batteries/clock visible.*

> "Both phones are in airplane mode. No SIM, no internet, no router, no hotspot,
> no pairing. Nothing is configured. They found each other over Bluetooth and
> Wi-Fi Direct on their own.
>
> I am in Hindi. I hold the button and speak."

*Action: hold PTT on phone A. Speak clearly and slowly into the mic:*

> "यहाँ सब ठीक है। राहत शिविर गाँव के स्कूल में खुल गया है।"

*Hold phone A's screen to camera while still speaking — live transcript appears.
Then release. Wait for phone B.*

> "Watch my screen. The words appear **as I speak** — that is on-device
> recognition, not a pre-recorded clip.
>
> On release, the text is encoded into that binary frame and pushed over the
> radio. And on the second phone —"

*Action: phone B speaks the message out loud in Hindi. Let the audio play on
camera. Point at phone B's pipeline strip showing STT → Encode → TX → Decode → TTS
timings in milliseconds.*

> "It just **spoke the message out loud**, in Hindi, with no network. The
> pipeline strip at the bottom shows the real timing of each stage — recognition,
> encoding, transfer, decoding, and synthesis — measured per packet on the
> device. The whole speech-to-speech loop is running in seconds, on a phone."

---

## 2:30 – 2:55 — Live demo B: hands-free phone mode

*Action: switch phone B from push-to-talk to the always-listening phone mode.
Then hold PTT on phone A and speak a short sentence without touching phone B.*

> "Push-to-talk is not always practical. In phone mode, the receiver is
> continuously listening. I transmit from the other phone — and the message is
> spoken back here automatically, hands free."

*Action: speak a short line into phone A, e.g.*
*"पानी का स्तर बढ़ रहा है, लोगों को ऊपर ले जाओ।"*

---

## 2:55 – 3:20 — Live demo C: SOS override

*Action: press the SOS button on phone A. Phone B must fire the full-screen red
alarm at maximum volume.*

> "And the most important case. If someone is trapped, a normal notification is
> not enough.
>
> This is the SOS. On the receiving phone it takes over the whole screen,
> forces volume to maximum, ignores Do Not Disturb, and **cannot be dismissed** —
> it clears itself only after the emergency window. The alert also requires no
> reading: it is spoken out loud at full volume.
>
> The app additionally watches the transcript itself. Speaking any distress word
> in any supported language — 'मदद', 'help', 'बचाओ' — automatically escalates
> that message to emergency priority."

---

## 3:20 – 3:45 — Engineering depth

*On screen: overlay of the four quality criteria — Accuracy 40%, Efficiency 20%,
Latency 20%, Robustness.*

> "How we meet the evaluation criteria. **Accuracy**: we use AI4Bharat's
> IndicConformer models, quantised to INT8, per language, with the correct
> tokenizer mapped for each script. **Efficiency**: only the active language is
> resident in memory, and the models are INT8-quantised.
> **Latency**: voice-activity detection trims silence before recognition, models
> are pre-warmed on language switch, and the binary frame is byte-minimal — a
> 14-byte overhead.
> **Robustness**: every frame is CRC-16 validated and corrupted frames are
> dropped rather than played as garbage, and messages sent with no peer in range
> are queued and delivered automatically when the link returns.
>
> The whole stack is offline and open source — our code is MIT, models are
> CC BY 4.0 from AI4Bharat, with sherpa-onnx and Silero VAD. No proprietary SDKs
> on the recognition or synthesis path. Twenty-two scheduled Indian languages
> plus English."

---

## 3:45 – 4:00 — Closing

*Action: back to wide shot, two phones side by side, message still on screen.*

> "Sahara turns any two Android phones into a working emergency radio — no
> infrastructure, no cost, no connectivity. It works in the first hour of a
> disaster, which is when it matters most.
>
> Thank you."

---

## On-screen text overlays (add in editing)

| Time | Overlay |
|---|---|
| 0:00 | Sahara / सहारा — Indian Multilingual Neural Transceiver |
| 0:20 | 3 seconds of raw audio = 96 KB · Sahara = ~40–80 bytes |
| 0:50 | On-device STT → iBFS-v1 binary → BLE / Wi-Fi Direct → On-device TTS |
| 1:20 | ✈️ Airplane mode on both devices · No SIM · No internet · No router |
| 1:25 | Live transcription — captured on camera, not pre-recorded |
| 2:05 | Payload: 14 bytes overhead + CRC-16 · ~99.9% smaller than raw audio |
| 2:55 | Emergency: full-screen · max volume · ignores DND · non-dismissible |
| 3:20 | Accuracy 40% · Efficiency 20% · Latency 20% · Robustness |
| 3:45 | 22 scheduled Indian languages + English · 100% offline · MIT / CC BY 4.0 |

---

## If something breaks during the take

- **No peer appearing**: both phones must be on the same build, Bluetooth and
  Wi-Fi ON, Location ON, and Sahara open in the foreground on both. Wait
  ~10–15 seconds; discovery rotates and retries.
- **Receiver shows a voice-note fallback instead of speech**: the STT model is
  not on that phone. Go back online briefly, download it, then switch airplane
  mode back on and re-take.
- **Take the demo in one continuous shot.** A single unbroken take where the
  transcript and the spoken playback are visible on camera is far more
  convincing than any cut. If a stage fails, cut at a natural break and restart
  the segment — never fake a result on camera.

Record 2–3 full takes, pick the cleanest one, and keep the video under 4:00 —
portals commonly hard-cut anything longer.
