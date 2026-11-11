# ── Sahara ProGuard Rules ──────────────────────────────────────────

# Keep sherpa-onnx JNI bindings (C++ FFI classes must not be renamed).
-keep class com.k2fsa.sherpa.onnx.** { *; }

# Keep Flutter embedding and plugin classes.
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# Keep flutter_tts platform channel handler.
-keep class com.eyedeadevelopment.fluttertts.** { *; }

# Keep bluetooth_low_energy plugin.
-keep class dev.zeekr.bluetooth_low_energy_android.** { *; }

# JNI entry points are resolved by exact class + method name at runtime, so the
# Codec2 bridge and the native radio plugins must not be renamed.
-keep class com.example.voice.Codec2Bridge { *; }
-keepclasseswithmembernames class com.example.voice.** { native <methods>; }

# Ignore missing Play Core split install classes (used by Flutter engine
# for deferred components but not actually needed for APK builds).
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# Don't warn about missing annotations.
-dontwarn javax.annotation.**
-dontwarn org.jetbrains.annotations.**
