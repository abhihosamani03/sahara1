package com.example.voice

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Sahara's single Activity.
 *
 * The Activity attaches to a **cached** Flutter engine and refuses to destroy
 * it with the host. That is what makes "SOS reaches a phone whose app is
 * closed" work: when the user swipes Sahara off the recents list, the Activity
 * dies but the Dart isolate keeps running, so the BLE / Wi-Fi Direct mesh stays
 * up. [SosService] holds the process at foreground priority so Android does not
 * reclaim it in the meantime.
 *
 * All native channels are registered on the engine in
 * [SaharaChannels.register], before the Dart entrypoint starts, so they are
 * also available when no Activity is attached.
 */
class MainActivity : FlutterActivity() {

    companion object {
        /** Intent extra set when an SOS full-screen notification opens us. */
        const val EXTRA_SOS_ALERT = "itantra_sos_alert"

    }

    /**
     * Provide (creating once) the cached engine.
     *
     * Registration order matters: plugins and native channels are wired up
     * *before* the Dart entrypoint runs, so Dart can never observe a missing
     * platform channel.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        SaharaEngine.ensure(context)

    /**
     * Keep the engine alive across Activity destruction. This is the whole
     * mechanism behind receiving SOS signals while the app appears closed.
     */
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        EmergencyAlerts.ensureChannels(applicationContext)

        // When an SOS full-screen notification launches us, make sure the alarm
        // UI is visible over the lock screen and the display wakes up.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
    }

    /** Whether this launch was triggered by an SOS alert. */
    fun launchedFromSos(): Boolean =
        intent?.getBooleanExtra(EXTRA_SOS_ALERT, false) == true

    // ── Hardware (silent) SOS shortcut ──────────────────────────────

    /** Key code of the volume key currently held, or 0 when none is. */
    private var heldVolumeKey = 0

    /** Whether this press has already fired, so a long hold fires once. */
    private var volumeHoldFired = false

    /**
     * Number of key-repeat events a volume key must produce before the hold
     * counts as deliberate (~700 ms). A brush past the volume rocker never gets
     * here, which is what keeps this from becoming a pocket trigger.
     */
    private val volumeHoldRepeats = 2

    /**
     * Detect a deliberate volume-key hold and fire an SOS.
     *
     * The key event is never consumed — `super` still sees it, so the volume
     * rocker behaves exactly as before. This is the "I cannot look at my
     * screen" path, so it is intentionally *not* gated behind the 3-second
     * confirmation sheet the on-screen button uses.
     *
     * Limitation: key events only reach a focused window, so this works while
     * the app is in the foreground or running behind the standby service; it
     * cannot fire from a process with no window (Android gives no API for
     * capturing volume keys globally).
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (SaharaChannels.silentSosEnabled &&
            (event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN ||
                event.keyCode == KeyEvent.KEYCODE_VOLUME_UP)
        ) {
            when (event.action) {
                KeyEvent.ACTION_DOWN -> {
                    if (heldVolumeKey != event.keyCode) {
                        heldVolumeKey = event.keyCode
                        volumeHoldFired = false
                    }
                    if (!volumeHoldFired && event.repeatCount >= volumeHoldRepeats) {
                        volumeHoldFired = true
                        SaharaChannels.notifySilentSos()
                    }
                }

                KeyEvent.ACTION_UP -> {
                    heldVolumeKey = 0
                    volumeHoldFired = false
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }
}
