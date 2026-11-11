package com.example.voice

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat

/**
 * Emergency alerting for Sahara SOS signals.
 *
 * This object is application-scoped on purpose. It must keep working when no
 * Activity is attached — i.e. when the app has been swiped off the recents
 * list but the process is still alive under [SosService] — because the whole
 * point of an SOS is that it reaches a phone whose owner is not looking at it.
 *
 * How the alert gets through the things that normally silence a phone:
 *
 *  * **Silent / vibrate mode.** Silent mode sets the *ringer* stream to zero.
 *    The alert is played on `STREAM_ALARM`, which silent and vibrate mode do
 *    not touch (this is the same reason an alarm clock still rings on silent).
 *    The alarm stream volume is also forced to maximum first.
 *  * **Do Not Disturb.** Alarm-usage audio is exempt from DND by default, and
 *    the notification channel is created with `setBypassDnd(true)`. If the user
 *    has granted Notification Policy Access, DND is additionally lifted
 *    entirely for the duration of the alert (and restored afterwards) so the
 *    spoken message — which uses the media stream — is audible too.
 *  * **Screen off / locked.** The notification carries a full-screen intent, so
 *    the system shows it over the lock screen and wakes the display.
 *
 * What no app can do: run after the user has *force-stopped* it from Android
 * settings, or on an OEM that kills background services regardless of battery
 * settings. The app surfaces both of those cases instead of pretending.
 */
object EmergencyAlerts {

    const val STANDBY_CHANNEL = "itantra_standby"
    const val SOS_CHANNEL = "itantra_sos"

    const val NOTIFICATION_STANDBY = 8001
    const val NOTIFICATION_SOS = 8002

    /** How long the audible alarm and DND lift last. */
    private const val ALARM_MS = 20_000L

    /** How long the alert notification stays before it self-dismisses. */
    private const val NOTIFICATION_TIMEOUT_MS = 60_000L

    private val handler = Handler(Looper.getMainLooper())

    private var player: MediaPlayer? = null
    private var tone: android.media.ToneGenerator? = null
    private var ringtone: Ringtone? = null
    /** Held so the repeating SOS vibration pattern can actually be cancelled. */
    private var activeVibrator: Vibrator? = null
    private var previousInterruptionFilter: Int? = null
    private var restoreRunnable: Runnable? = null
    private var alarming = false
    private var lastAlertText: String? = null

    /** Whether an SOS alert is currently sounding. */
    val isAlarming: Boolean get() = alarming

    // ── Notification channels ────────────────────────────────────────

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return

        if (nm.getNotificationChannel(STANDBY_CHANNEL) == null) {
            val standby = NotificationChannel(
                STANDBY_CHANNEL,
                "Emergency standby",
                NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description =
                    "Keeps Sahara listening for SOS signals while the app is closed"
                setShowBadge(false)
            }
            nm.createNotificationChannel(standby)
        }

        if (nm.getNotificationChannel(SOS_CHANNEL) == null) {
            val sos = NotificationChannel(
                SOS_CHANNEL,
                "SOS alerts",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Emergency SOS alerts from nearby Sahara devices"
                // Ask the system to let this channel through Do Not Disturb.
                // The user confirms this in the channel's settings.
                setBypassDnd(true)
                enableVibration(true)
                enableLights(true)
                // Deliberately no channel sound: the alert tone is played on
                // STREAM_ALARM by this object so it can loop and be stopped.
                setSound(
                    null,
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
            }
            nm.createNotificationChannel(sos)
        }
    }

    // ── Raise / clear ───────────────────────────────────────────────

    /**
     * Sound the alarm and post the full-screen SOS notification.
     *
     * [text] is the message the sender transmitted (may be empty).
     */
    fun raise(context: Context, text: String?, fromDeviceLabel: String? = null) {
        ensureChannels(context)
        lastAlertText = text
        alarming = true

        forceMaxVolume(context)
        bypassDnd(context)
        startTone(context)
        startVibration(context)
        postSosNotification(context, text, fromDeviceLabel)

        // Extend the alert if a second SOS arrives while one is sounding.
        restoreRunnable?.let { handler.removeCallbacks(it) }
        val runnable = Runnable {
            stopAudio()
            restoreDnd(context)
        }
        restoreRunnable = runnable
        handler.postDelayed(runnable, ALARM_MS)
    }

    /** Stop the alarm immediately (user dismissed it, or the app did). */
    fun clear(context: Context) {
        stopAudio()
        restoreDnd(context)
        restoreRunnable?.let { handler.removeCallbacks(it) }
        restoreRunnable = null
        alarming = false
        lastAlertText = null
        try {
            context.getSystemService(NotificationManager::class.java)
                ?.cancel(NOTIFICATION_SOS)
        } catch (_: Exception) {
            // Nothing to cancel.
        }
    }

    fun lastText(): String? = lastAlertText

    // ── Audio ────────────────────────────────────────────────────────

    private fun forceMaxVolume(context: Context) {
        try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                ?: return
            // Alarm stream: what silent / vibrate / DND mode do not silence.
            am.setStreamVolume(
                AudioManager.STREAM_ALARM,
                am.getStreamMaxVolume(AudioManager.STREAM_ALARM),
                0,
            )
            // Media stream: carries the spoken message from the TTS engine.
            am.setStreamVolume(
                AudioManager.STREAM_MUSIC,
                am.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                0,
            )
        } catch (_: SecurityException) {
            // Volume left as-is; the alert still sounds.
        }
    }

    private fun startTone(context: Context) {
        stopAudio()
        val uri = defaultAlarmUri()
        if (uri != null) {
            try {
                player = MediaPlayer().apply {
                    setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(
                                AudioAttributes.CONTENT_TYPE_SONIFICATION,
                            )
                            .build(),
                    )
                    setDataSource(context, uri)
                    isLooping = true
                    prepare()
                    start()
                }
                return
            } catch (_: Exception) {
                stopAudio()
            }
            // MediaPlayer refused the asset — try the ringtone player.
            try {
                ringtone = RingtoneManager.getRingtone(context, uri)?.apply {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        isLooping = true
                    }
                    play()
                }
                if (ringtone != null) return
            } catch (_: Exception) {
                stopAudio()
            }
        }

        // Last resort: the built-in tone generator, on the alarm stream.
        try {
            tone = android.media.ToneGenerator(AudioManager.STREAM_ALARM, 100)
            tone?.startTone(android.media.ToneGenerator.TONE_CDMA_EMERGENCY_RINGBACK)
        } catch (_: Exception) {
            tone = null
        }
    }

    private fun stopAudio() {
        try {
            player?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (_: Exception) {
            // Already released.
        }
        player = null

        try {
            ringtone?.stop()
        } catch (_: Exception) {
            // Ignore.
        }
        ringtone = null

        try {
            tone?.stopTone()
            tone?.release()
        } catch (_: Exception) {
            // Ignore.
        }
        tone = null

        stopVibration()
    }

    private fun defaultAlarmUri(): Uri? =
        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)

    // ── Vibration ────────────────────────────────────────────────────

    private fun vibrator(context: Context): Vibrator? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = context.getSystemService(VibratorManager::class.java)
            manager?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    } catch (_: Exception) {
        null
    }

    private fun startVibration(context: Context) {
        val v = vibrator(context) ?: return
        activeVibrator = v
        // SOS in Morse: three short, three long, three short.
        val pattern = longArrayOf(
            0,
            250, 150, 250, 150, 250, 400,
            700, 200, 700, 200, 700, 400,
            250, 150, 250, 150, 250,
        )
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(
                    VibrationEffect.createWaveform(pattern, 0),
                )
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(pattern, 0)
            }
        } catch (_: Exception) {
            // Vibration unavailable.
        }
    }

    private fun stopVibration() {
        // The pattern repeats indefinitely, so it must be cancelled explicitly
        // or the phone vibrates forever.
        try {
            activeVibrator?.cancel()
        } catch (_: Exception) {
            // Ignore.
        }
        activeVibrator = null
    }

    // ── Do Not Disturb ───────────────────────────────────────────────

    fun hasDndAccess(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            context.getSystemService(NotificationManager::class.java)
                ?.isNotificationPolicyAccessGranted == true
        } catch (_: Exception) {
            false
        }
    }

    private fun bypassDnd(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            val nm = context.getSystemService(NotificationManager::class.java)
                ?: return
            if (!nm.isNotificationPolicyAccessGranted) return
            if (previousInterruptionFilter == null) {
                previousInterruptionFilter = nm.currentInterruptionFilter
            }
            nm.setInterruptionFilter(
                NotificationManager.INTERRUPTION_FILTER_ALL,
            )
        } catch (_: SecurityException) {
            // Access revoked between the check and the call.
        } catch (_: Exception) {
            // Ignore — the alarm stream still sounds.
        }
    }

    private fun restoreDnd(context: Context) {
        val previous = previousInterruptionFilter ?: return
        previousInterruptionFilter = null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            val nm = context.getSystemService(NotificationManager::class.java)
                ?: return
            if (nm.isNotificationPolicyAccessGranted) {
                nm.setInterruptionFilter(previous)
            }
        } catch (_: Exception) {
            // Leaving DND on is better than crashing.
        }
    }

    // ── Notification ─────────────────────────────────────────────────

    private fun postSosNotification(
        context: Context,
        text: String?,
        fromDeviceLabel: String?,
    ) {
        ensureChannels(context)

        val open = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(MainActivity.EXTRA_SOS_ALERT, true)
        }
        val openFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            PendingIntent.FLAG_IMMUTABLE
        val openIntent = PendingIntent.getActivity(context, 1001, open, openFlags)

        val stop = Intent(context, SosStopReceiver::class.java).apply {
            action = SosStopReceiver.ACTION_STOP_SOS
        }
        val stopIntent = PendingIntent.getBroadcast(
            context,
            1002,
            stop,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val body = buildString {
            append(fromDeviceLabel?.takeIf { it.isNotBlank() } ?: "Nearby device")
            if (!text.isNullOrBlank()) {
                append(": ")
                append(text)
            } else {
                append(" sent an emergency SOS")
            }
        }

        val notification = NotificationCompat.Builder(context, SOS_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle("SOS RECEIVED")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setTimeoutAfter(NOTIFICATION_TIMEOUT_MS)
            .setContentIntent(openIntent)
            // Wakes the screen and shows over the lock screen even when the
            // app has no Activity attached.
            .setFullScreenIntent(openIntent, true)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "STOP ALARM",
                stopIntent,
            )
            .build()

        try {
            context.getSystemService(NotificationManager::class.java)
                ?.notify(NOTIFICATION_SOS, notification)
        } catch (_: SecurityException) {
            // Notifications disabled for the app; audio already plays.
        }
    }
}

/** Stops a sounding SOS alarm from the notification's STOP action. */
class SosStopReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_STOP_SOS = "com.example.voice.STOP_SOS"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null) return
        if (intent?.action != ACTION_STOP_SOS) return
        EmergencyAlerts.clear(context)
    }
}
