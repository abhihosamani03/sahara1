# Model Licensing & Open-Source Compliance

The problem statement's "Open-Source Only" restriction is a hard disqualification risk, not a soft preference. This doc must be filled in with the actual license of every model/library you ship, verified at the source (Hugging Face model card, GitHub repo LICENSE file) — not assumed.

## Why This Matters
A team that builds a technically excellent app but ships a model with an unclear or non-commercial-only license, or wraps a closed-source SDK (e.g., relying on Google's on-device STT/TTS under the hood via certain Play Services APIs) can be disqualified on a technicality regardless of demo quality. Verify before you integrate, not after.

## Compliance Checklist (fill in per model actually used)

| Component | Source | License | Verified? | Notes |
|---|---|---|---|---|
| VAD | Silero VAD | MIT | [ ] | Confirm current license at source repo |
| STT (per language) | AI4Bharat IndicConformer / IndicWhisper | Check per-checkpoint — AI4Bharat models are generally released under permissive research licenses but **verify per specific checkpoint**, some fine-tunes carry different terms | [ ] | Do not assume all AI4Bharat releases share one blanket license |
| TTS (per language) | AI4Bharat Indic-TTS (VITS) | Same — verify per checkpoint | [ ] | |
| Inference runtime | sherpa-onnx | Apache 2.0 | [ ] | |
| Inference runtime (alt) | whisper.cpp | MIT | [ ] | |
| ONNX Runtime | Microsoft ONNX Runtime | MIT | [ ] | |
| Translation (if used) | AI4Bharat IndicTrans2 | Verify per checkpoint | [ ] | |

## Rules
1. **No proprietary voice-activation SDKs.** This explicitly rules out relying on closed-source components of Google Play Services for STT/TTS, per the problem statement's own restriction — even if it would be faster to integrate.
2. **Attribute everything** in your final documentation/README — model authors, license names, and links to source. This is expected practice for open-source model reuse and demonstrates compliance directly.
3. **Keep a copy of each license file** alongside the model weights in your repo (`assets/models/<lang>/LICENSE`) so provenance travels with the artifact, not just with a README link that can go stale.
4. If a model's license is ambiguous or research-only in a way that conflicts with your project's usage, **do not use it** — pick an alternative with a clear permissive license (MIT/Apache 2.0/BSD) instead of arguing interpretation.

## Action Item
Before your first internal demo, someone on the team should own this file and have every row filled in with a verified license and source link — not "TODO." Treat it as part of the deliverable, not paperwork.
