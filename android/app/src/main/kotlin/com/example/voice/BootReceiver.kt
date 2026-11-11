package com.example.voice

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Starts emergency standby after a reboot.
 *
 * Only runs when the user explicitly enabled "Start on boot" in Settings. The
 * preference is written by Flutter's shared_preferences plugin, which prefixes
 * keys with `flutter.`, so the key read here must match that prefix exactly.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED &&
            intent?.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        )
        val startOnBoot = prefs.getBoolean("flutter.set.startOnBoot", false)
        if (!startOnBoot) return

        // The service creates the cached engine itself, so the mesh starts with
        // no Activity and keeps listening for SOS frames after a power cut.
        try {
            SaharaEngine.ensure(context.applicationContext)
            SosService.start(context.applicationContext)
        } catch (e: Exception) {
            Log.w("Sahara", "Boot standby could not start", e)
        }
    }
}
