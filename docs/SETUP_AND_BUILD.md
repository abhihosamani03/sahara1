# Setup & Build Guide: Sahara

## 1. Stack Decision

Two viable paths exist — pick one and state why, don't leave it ambiguous:

| | Native (Kotlin + NDK/JNI) | Flutter + sherpa-onnx Dart bindings |
|---|---|---|
| Dev speed | Slower | Faster |
| Control over BT/Wi-Fi Direct + audio focus | Direct, fine-grained | Wrapped, less control over edge cases (e.g. OEM-specific audio focus quirks) |
| Best when | Team has strong Android/Kotlin + some C++ experience, and P2P/latency tuning is your priority | Team is short on native Android experience and needs a working demo fast |

**Recommendation:** if unsure, default to native Kotlin — the latency and audio-focus behavior that quality metrics weight 40% (accuracy) and 20% (latency) on are exactly the things Flutter's abstraction layer makes harder to control precisely.

## 2. Prerequisites
- OS: Linux / macOS / Windows+WSL2
- Android Studio: Hedgehog (2023.1.1)+
- Android NDK: 25.2.9519653+
- Java JDK 17
- If Flutter path: Flutter SDK 3.22.x (stable channel)

## 3. Environment Setup

```bash
git clone <your-repo-url>
cd Sahara

# Download and quantize models — start with 2 languages, not all 10
python scripts/fetch_models.py --lang hi,kn --quantize int8
```

If Flutter path, declare assets in `pubspec.yaml`:
```yaml
flutter:
  assets:
    - assets/models/vad/
    - assets/models/stt/
    - assets/models/tts/
```

## 4. Required Android Permissions

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES"
        android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
        android:usesPermissionFlags="neverForLocation" />
</manifest>
```

Note: `ACCESS_FINE_LOCATION` is required by Android for Wi-Fi/BT scanning APIs even though you're not using it for location *display* unless you build the optional GPS-stamping feature — this is a common question since "why does a privacy-focused app need location permission" is a fair concern.

## 5. Build Order (Why Sequence Matters)

Building UI before the offline AI pipeline is proven means any change to model I/O shape, tokenizer, or latency characteristics forces a UI rewrite. Build in this order:

1. **Offline ML pipeline standalone** — verify STT and TTS work correctly for one language in isolation (a command-line test harness is fine, no UI needed yet).
2. **P2P networking layer standalone** — verify two phones can exchange a hardcoded text string over Bluetooth RFCOMM, no ML involved yet.
3. **Wire the two together** for one language.
4. **Push-to-talk UI** on top of a working pipeline.
5. **Scale to remaining languages.**
6. **Add differentiator features** (see ADDITIONAL_FEATURES.md) only after step 5 is stable and benchmarked.

## 6. Running

```bash
flutter run --profile     # never benchmark ML inference in debug mode — debug adds
                           # significant overhead to sherpa-onnx/C++ runtime calls
                           # and will make your latency numbers look worse than reality
```

Build release APK:
```bash
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

## 7. Validation: The Two-Phone Offline Loop

1. Sideload the release APK on Phone A and Phone B.
2. **Turn off cellular data AND Wi-Fi internet** on both — this is the actual test, not optional.
3. On Phone A: pair/discover Phone B via Bluetooth or Wi-Fi Direct within the app.
4. On Phone A: select a language, hold PTT, speak a test sentence.
5. Confirm:
   - Phone A transcribes locally (visible on-screen).
   - Packet transmits (log the actual measured time, don't estimate).
   - Phone B's TTS plays the message audibly, fully offline.
6. **Log real numbers** — STT time, transfer time, TTS time, total — from actual device logs, not estimates. These are the numbers you document, not the target table in README.md (that's a target, not a claim).

## 8. Testing Beyond the Happy Path

See `docs/TESTING.md` for the full plan, but at minimum before demo day:
- Test with real background noise (wind, crowd noise — disaster conditions aren't quiet rooms).
- Test with the phone at low battery / thermal throttled.
- Test a language mismatch scenario deliberately (see ARCHITECTURE.md §2.4).
- Test what happens when Bluetooth disconnects mid-transmission.
