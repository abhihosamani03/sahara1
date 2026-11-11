package com.example.voice

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Every native channel Sahara uses, registered in one place.
 *
 * Registration happens when the engine is created rather than in the Activity,
 * because these channels must stay usable after the Activity is gone — that is
 * the whole point of emergency standby. Method call handlers live on the
 * engine's binary messenger, so they survive Activity destruction as long as
 * they were registered once.
 */
object SaharaChannels {

    private const val AUDIO_CHANNEL = "itantra/audio_override"
    private const val SOS_CHANNEL = "itantra/sos_service"
    private const val DEVICE_CHANNEL = "itantra/device"

    /** Strong references so nothing registered here is garbage collected. */
    private val retained = mutableListOf<Any>()

    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null

    /**
     * The SOS channel, retained so native code can call back into Dart.
     *
     * The volume-key hold is detected in the Activity, but the *decision* to
     * send an SOS lives in Dart (it owns the radio and the preference), so the
     * Activity needs a way to reach the channel without holding a reference to
     * the engine — which is exactly what this is for.
     */
    private var sosChannel: MethodChannel? = null

    /** Whether the hardware shortcut may fire. Mirrored from the Dart setting. */
    @Volatile
    var silentSosEnabled: Boolean = false
        private set

    /**
     * Deliver a hardware-triggered SOS to Dart.
     *
     * Returns false when the shortcut is disabled or the engine is not up, so
     * the caller can leave the key event alone.
     */
    fun notifySilentSos(): Boolean {
        val channel = sosChannel ?: return false
        if (!silentSosEnabled) return false
        return try {
            channel.invokeMethod("onSilentSos", null)
            true
        } catch (e: Exception) {
            false
        }
    }

    fun register(engine: FlutterEngine, context: Context) {
        val messenger = engine.dartExecutor.binaryMessenger
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        EmergencyAlerts.ensureChannels(context)

        // Wi-Fi Direct radio (also kept referenced — it owns live sockets).
        retained += WifiDirectPlugin(context, messenger)
        // Long-range BLE (LE Coded PHY) and Wi-Fi Aware (NAN) radios.
        retained += CodedPhyPlugin(context, messenger)
        retained += WifiAwarePlugin(context, messenger)
        // Real-time Codec2 voice (native codec + 8 kHz audio path).
        retained += Codec2VoicePlugin(context, messenger)

        registerAudioOverride(messenger, context)
        registerSosService(messenger, context)
        registerDevice(messenger, context)
    }

    // ── Battery + thermal ────────────────────────────────────────────

    /**
     * Real battery percentage, charging state and thermal status.
     *
     * The Dart side uses these to throttle scanning / TTS and to attach a
     * battery figure to an SOS, so a responder can triage a phone that is
     * about to die. Values come from the platform, never guessed.
     */
    private fun registerDevice(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, DEVICE_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "status") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
                // -1 means the property is unavailable (rare, some emulators).
                val level = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
                if (level < 0) {
                    result.error("NO_BATTERY", "Battery capacity unavailable", null)
                    return@setMethodCallHandler
                }
                val charging = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    bm?.isCharging == true
                } else {
                    false
                }
                val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                val thermal = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    pm?.currentThermalStatus ?: 0
                } else {
                    0
                }
                result.success(
                    mapOf(
                        "level" to level,
                        "charging" to charging,
                        "thermal" to thermalName(thermal),
                    ),
                )
            } catch (e: Exception) {
                result.error("ERR", e.message, null)
            }
        }
    }

    /** Map PowerManager.THERMAL_STATUS_* to the Dart enum names. */
    private fun thermalName(status: Int): String = when (status) {
        0 -> "none"   // THERMAL_STATUS_NONE
        1 -> "light"  // THERMAL_STATUS_LIGHT
        2 -> "moderate"
        3 -> "severe"
        4 -> "critical"
        5 -> "emergency"
        6 -> "shutdown"
        else -> "unknown"
    }

    // ── Audio override ───────────────────────────────────────────────

    private fun registerAudioOverride(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setMaxVolume" -> {
                    try {
                        val am = audioManager
                        if (am == null) {
                            result.error("NO_AM", "AudioManager unavailable", null)
                            return@setMethodCallHandler
                        }
                        requestAudioFocus(am)
                        // Media stream carries the spoken message; the alarm
                        // stream is what silent / DND modes do not silence.
                        for (stream in intArrayOf(
                            AudioManager.STREAM_MUSIC,
                            AudioManager.STREAM_ALARM,
                        )) {
                            am.setStreamVolume(
                                stream,
                                am.getStreamMaxVolume(stream),
                                0,
                            )
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERR", e.message, null)
                    }
                }

                "restoreAudio" -> {
                    try {
                        abandonAudioFocus()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERR", e.message, null)
                    }
                }

                "extractAsset" -> extractAsset(call, result, context)

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Copy a bundled asset out of the APK to a real file path.
     *
     * sherpa-onnx can only load models from the filesystem, and the larger
     * ONNX assets may exceed the AssetManager's uncompress limit, so the APK
     * zip is read directly as a second attempt.
     */
    private fun extractAsset(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val assetPath = call.argument<String>("assetPath")
        val destPath = call.argument<String>("destPath")
        if (assetPath == null || destPath == null) {
            result.error("ARG_ERR", "Missing path arguments", null)
            return
        }

        val main = Handler(Looper.getMainLooper())
        Thread {
            try {
                val destFile = File(destPath)
                val tempFile = File("$destPath.tmp")
                destFile.parentFile?.mkdirs()

                var copied = false
                val flutterAssetPath =
                    if (assetPath.startsWith("flutter_assets/")) assetPath
                    else "flutter_assets/$assetPath"

                // Attempt 1: AssetManager.
                try {
                    context.assets.open(flutterAssetPath).use { input ->
                        java.io.FileOutputStream(tempFile).use { output ->
                            val buffer = ByteArray(65536)
                            var read: Int
                            while (input.read(buffer).also { read = it } != -1) {
                                output.write(buffer, 0, read)
                            }
                            output.flush()
                        }
                    }
                    if (tempFile.length() > 0) copied = true
                } catch (_: Exception) {
                    // Unreadable through AssetManager — try the zip below.
                }

                // Attempt 2: read straight from the APK zip.
                if (!copied) {
                    val apkPath = context.applicationInfo.sourceDir
                    java.util.zip.ZipFile(apkPath).use { zip ->
                        val entry = zip.getEntry("assets/$flutterAssetPath")
                            ?: zip.getEntry(flutterAssetPath)
                            ?: zip.entries().asSequence()
                                .firstOrNull { it.name.endsWith(assetPath) }

                        if (entry != null) {
                            zip.getInputStream(entry).use { input ->
                                java.io.FileOutputStream(tempFile).use { output ->
                                    val buffer = ByteArray(65536)
                                    var read: Int
                                    while (input.read(buffer).also { read = it } != -1) {
                                        output.write(buffer, 0, read)
                                    }
                                    output.flush()
                                }
                            }
                            if (tempFile.length() > 0) copied = true
                        }
                    }
                }

                if (copied && tempFile.length() > 0) {
                    if (destFile.exists()) destFile.delete()
                    tempFile.renameTo(destFile)
                    main.post { result.success(true) }
                } else {
                    tempFile.delete()
                    main.post {
                        result.error("COPY_ERR", "Could not extract asset: $assetPath", null)
                    }
                }
            } catch (e: Exception) {
                main.post { result.error("COPY_ERR", e.message, null) }
            }
        }.apply { isDaemon = true }.start()
    }

    private fun requestAudioFocus(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attrs)
                .setWillPauseWhenDucked(false)
                .build()
            focusRequest = request
            am.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                null,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            )
        }
    }

    private fun abandonAudioFocus() {
        val am = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(null)
        }
        focusRequest = null
    }

    // ── SOS standby + emergency alerting ─────────────────────────────

    private fun registerSosService(messenger: BinaryMessenger, context: Context) {
        val channel = MethodChannel(messenger, SOS_CHANNEL)
        sosChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Enable/disable the volume-key shortcut. Driven by the
                // Settings switch, so there is one source of truth for it.
                "setSilentSosEnabled" -> {
                    silentSosEnabled = call.argument<Boolean>("enabled") ?: false
                    result.success(true)
                }

                "startStandby" -> {
                    if (!SosService.canRunConnectedDeviceService(context)) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    result.success(SosService.start(context))
                }

                "stopStandby" -> {
                    SosService.stop(context)
                    result.success(true)
                }

                "isStandbyRunning" -> result.success(SosService.isRunning())

                "raiseAlarm" -> {
                    val text = call.argument<String>("text")
                    val from = call.argument<String>("from")
                    EmergencyAlerts.raise(context, text, from)
                    result.success(true)
                }

                "clearAlarm" -> {
                    EmergencyAlerts.clear(context)
                    result.success(true)
                }

                "isAlarming" -> result.success(EmergencyAlerts.isAlarming)

                "hasDndAccess" -> result.success(EmergencyAlerts.hasDndAccess(context))

                "openDndSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        open(
                            context,
                            Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS),
                        )
                    }
                    result.success(true)
                }

                "openNotificationSettings" -> {
                    val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(
                            Settings.EXTRA_APP_PACKAGE,
                            context.packageName,
                        )
                    open(context, intent)
                    result.success(true)
                }

                "isIgnoringBatteryOptimizations" -> result.success(
                    isIgnoringBatteryOptimizations(context),
                )

                "openBatterySettings" -> {
                    val direct = Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    ).setData(Uri.parse("package:${context.packageName}"))
                    if (!open(context, direct)) {
                        open(
                            context,
                            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
                        )
                    }
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            pm?.isIgnoringBatteryOptimizations(context.packageName) == true
        } catch (_: Exception) {
            false
        }
    }

    /** Launch a settings intent for the user. Returns false if unavailable. */
    private fun open(context: Context, intent: Intent): Boolean {
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
