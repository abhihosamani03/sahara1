# Evaluation Mapping — Features vs. Quality Criteria

Features mapped against quality criteria to guide build priorities.

| Criterion | Weight | What Directly Moves This Number |
|---|---|---|
| **Efficiency** (model size, RAM/flash, idle CPU) | 20% | Single-language resident policy (ARCHITECTURE.md §2.2), INT8 quantization (ML_PIPELINE.md §3), battery/thermal-aware scheduling (ADDITIONAL_FEATURES.md #9) |
| **Accuracy** (WER for STT, naturalness/flow for TTS) | 40% | Correct per-language tokenizer/phoneme mapping (ML_PIPELINE.md §6), quantization WER-delta validation, distress-intent detection as *additional* correctly-functioning inference (ADDITIONAL_FEATURES.md #1), confidence display + correction (#7) |
| **Latency** (STT delay, TTS delay, RTF, speech-to-speech delta) | 20% | VAD tuning (ARCHITECTURE.md §2.1), model warm-up on language switch, byte-minimal binary framing (NETWORK_PROTOCOL.md), native stack choice if control over audio focus/BT stack matters more than dev speed (SETUP_AND_BUILD.md §1) |
| **Robustness / Deployability** (implicit — "robust, deployable system architecture" in the problem statement's Expected Solution) | Not separately weighted but referenced in the PS text | Language-mismatch handling (ARCHITECTURE.md §2.4), store-and-forward (ADDITIONAL_FEATURES.md #3), adaptive fallback (#6), CRC validation and reconnect logic (NETWORK_PROTOCOL.md §5) |

## Feature-to-Weight Priority (why the build order in ADDITIONAL_FEATURES.md is what it is)

Since Accuracy (40%) and Latency+Efficiency (40% combined) make up 80% of the score, and feature count isn't separately rewarded, the highest-leverage use of remaining time after the baseline works is:

1. Tightening WER and RTF numbers on your actual target languages, with real benchmark data (not estimates).
2. Distress-detection + GPS stamping — cheap to build, and their value is immediately visible during a live demo ("phone said 'help' and location appeared automatically").
3. Only then: translation, mesh, or the remaining lower-priority features — these are genuine differentiators but cost more build time per quality-point than #1-2.

## What to Show in a Live Demo

- Two phones, airplane mode, visibly no internet — the offline claim has to be *demonstrated*, not asserted.
- Real transcription appearing on screen as the person speaks (not a pre-recorded clip).
- A deliberate distress phrase to trigger the auto-emergency-priority path, at max volume, non-interruptible.
- If time allows: a deliberate network drop mid-message to show store-and-forward or reconnect logic working, since "what happens when it fails" is a stronger demo moment than only showing the happy path.
