# Architecture Specification: Sahara

## 1. System Pipeline

```
SENDER NODE
------------
Microphone (16kHz/16-bit mono PCM)
   -> Silero VAD (30ms frames, 600ms silence = utterance boundary)
      -> Offline STT (language-specific ONNX model)
         -> [optional] Distress-Intent Classifier (see ADDITIONAL_FEATURES.md)
         -> [optional] GPS Stamp Attach
         -> Binary Frame Encoder (see NETWORK_PROTOCOL.md)
            -> P2P Transport (Bluetooth RFCOMM / Wi-Fi Direct)

RECEIVER NODE
-------------
P2P Transport
   -> Binary Frame Decoder
      -> [if isEmergency] Alert Priority Router
      -> [optional] Translation Layer (source lang -> receiver's preferred lang)
      -> Offline TTS (receiver's active language model)
         -> Audio Output (STREAM_MUSIC normal / STREAM_ALARM emergency)
```

Same app instance runs both roles simultaneously — a phone is always listening for inbound packets while able to transmit, mirroring real half-duplex PTT radio behavior when "on," and behaving like an ordinary phone when the transceiver mode is toggled off.

## 2. Core Subsystems

### 2.1 Audio Ingestion & VAD
- Input: linear 16-bit PCM, mono, 16 kHz.
- Buffered into 30 ms frames (480 samples) fed to Silero VAD.
- Utterance boundary: continuous silence > 600 ms triggers STT decode on the buffered chunk. This threshold is configurable — test it against real speech patterns under stress/panic, which tend to have longer pauses than calm speech; a fixed 600ms tuned on calm test recordings may cut off distressed speakers mid-sentence.

### 2.2 Neural Inference Engine
- Runtime: `sherpa-onnx` (C++ core) via platform bindings, `arm64-v8a` and `armeabi-v7a` targets.
- **Single-Language Resident Policy:** only one language's STT+TTS weights are memory-mapped at a time.

```
[Language Selected in UI]
   -> Compare to currently resident language
      -> Match: no-op, retain in memory
      -> Mismatch:
         1. Release native pointers / destroy sherpa-onnx instance for old language
         2. mmap new language's INT8 ONNX + tokenizer files
         3. Warm up with a silent dummy inference (avoids first-utterance latency spike)
```

### 2.3 Audio Playback & Emergency Override
- Normal voice note: `STREAM_MUSIC`, respects system volume.
- Emergency packet (`priority == EMERGENCY`):
  1. Request `AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE`.
  2. Route PCM to `STREAM_ALARM`.
  3. Force volume to max, ignore ringer/DND mode (this requires the `MODIFY_AUDIO_SETTINGS` permission and, on some OEM skins, exemption handling — test on real devices, not just the emulator, since alarm-stream override behavior varies by manufacturer).

### 2.4 Language Mismatch Handling
Not addressed in earlier drafts. When Phone A transmits Kannada text but Phone B only has Hindi TTS resident:
- **Option A (minimum viable):** Phone B displays the raw transcribed text on screen instead of speaking it, with a "load Kannada model" prompt.
- **Option B (differentiator, see ADDITIONAL_FEATURES.md §Translation):** route through an on-device translation model before TTS.
Pick one explicitly — don't leave this undefined, it's a guaranteed judge question.

## 3. State Machine (PTT Mode)

```
IDLE (listening for inbound only)
  --press PTT--> RECORDING
RECORDING
  --release or VAD silence--> PROCESSING (STT running)
PROCESSING
  --transcription ready--> TRANSMITTING
TRANSMITTING
  --ack or timeout--> IDLE
```

Toggle "Transceiver Mode" off → app behaves as a normal phone (this should be a real UI state, not just marketing copy — implement it as literally disabling the P2P service and mic-VAD loop).

## 4. Failure Modes & Mitigation

| Failure | Mitigation |
|---|---|
| Out-of-memory on low-end device | Pre-allocated buffer pools; fall back to a smaller/lower-quality TTS voice rather than crashing |
| Corrupted frame over RF | CRC-16 validation at frame level; drop and request retransmit (see NETWORK_PROTOCOL.md) |
| Peer disconnects mid-session | Auto-reconnect with exponential backoff on RFCOMM; queue outbound messages (see ADDITIONAL_FEATURES.md §Store-and-Forward) |
| STT confidence very low (noise, dialect, accent) | Fall back to sending a short, aggressively compressed raw-audio clip instead of silently failing (see ADDITIONAL_FEATURES.md §Adaptive Fallback) |
| Receiver has no model for sender's language | Explicit handling required — see §2.4 above |

## 5. What Changed From the Original Draft
- Removed the fictional "0.5-byte field" bit-packing — see the corrected byte-aligned layout in NETWORK_PROTOCOL.md.
- Reconciled contradictory latency claims into one target table (README §5).
- Added explicit language-mismatch handling, which the original architecture never addressed.
- Hooks for distress detection, GPS stamping, translation, and store-and-forward are now first-class pipeline stages (each individually optional/toggleable), not bolted on separately.
