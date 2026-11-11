# Testing & Validation Plan

The original draft's only validation procedure was a single manual two-phone happy-path script. That's necessary but not sufficient — here's the fuller plan.

## 1. Unit Level
- STT: feed known audio clips with known transcripts, measure WER per language against a held-out labeled set (not the training set).
- TTS: measure RTF and run an internal MOS (mean opinion score) panel — a handful of native speakers per language rating naturalness 1-5 is enough for validation.
- Protocol: unit-test the binary frame encode/decode round-trip, including CRC failure injection (deliberately corrupt a byte and confirm it's dropped, not crashed on).

## 2. Integration Level
- Full pipeline, one language, one phone, no networking: speak -> STT -> TTS -> hear it back (loopback test) to isolate ML pipeline bugs from networking bugs.
- Two-phone loop, one language: the core validation from SETUP_AND_BUILD.md §7.
- Language-switch test: switch active language mid-session, confirm old model unloads and new one loads without leaking memory (watch this across 5-10 rapid switches, not just once).

## 3. Adverse Conditions (Do Not Skip — This Is What Separates a Real System From a Demo Toy)
- Background noise: wind, crowd noise, another person talking nearby — disaster conditions are not quiet rooms.
- Low battery / thermal throttled device — confirm the app degrades gracefully (e.g., battery/thermal-aware scheduling, ADDITIONAL_FEATURES.md #9) rather than crashing.
- Deliberate Bluetooth disconnect mid-transmission — confirm reconnect logic and/or store-and-forward queueing behaves as documented (NETWORK_PROTOCOL.md §5, ADDITIONAL_FEATURES.md #3).
- Language mismatch: Phone A sends a language Phone B has no model loaded for — confirm the documented fallback (ARCHITECTURE.md §2.4) actually triggers, not just "should trigger."
- Low-end device test: run on the lowest-spec phone you can access, not just whoever has the newest phone — performance is evaluated against "low and mid-range" hardware.

## 4. Metrics to Log for Every Test Run
- STT RTF, TTS RTF, total speech-to-speech latency
- Peak RAM during the session
- WER against ground truth (where you have a known transcript)
- Any crash logs or ANRs (Application Not Responding)

## 5. What Goes Into Documentation
Report actual measured numbers from real device testing, with the device model and Android version stated, not projected or estimated numbers. If your measured latency is worse than the target table in README.md, report the real number and explain what you'd optimize next — honest partial results build more trust than suspiciously perfect unverified ones.
