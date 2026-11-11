package com.example.voice

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Emergency standby service.
 *
 * Sahara's whole point is that an SOS reaches the other phones nearby. That
 * cannot happen if the receiving app has been swiped off the recents list and
 * Android then reclaims the process. This service holds the process at
 * foreground priority with a minimal ongoing notification, so the Flutter
 * engine — and with it the BLE / Wi-Fi Direct mesh — keeps running with no
 * Activity attached.
 *
 * It is declared with `stopWithTask="false"` so removing the task does not
 * tear it down, and it uses the `connectedDevice` foreground service type
 * because that is exactly what it does: keep a link to nearby devices alive.
 *
 * Honest limits: Android will not run this after the user force-stops the app
 * from system settings, and some OEMs kill background services regardless of
 * battery settings. The app reports both cases rather than hiding them.
 */
class SosService : Service() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        EmergencyAlerts.ensureChannels(this)
        try {
            startForeground(NOTIFICATION_STANDBY, buildNotification())
            running = true
            // Boot/standby may be the only entry point: bring the Dart isolate
            // (and with it the mesh) up without an Activity.
            SaharaEngine.ensure(applicationContext)
        } catch (_: Exception) {
            // Foreground service start refused (missing Bluetooth/Wi-Fi
            // runtime permission on Android 14+, or an OEM restriction).
            // Standby is unavailable but the app keeps working in foreground.
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        // Restart if the system reclaims us while standby is wanted.
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): android.app.Notification {
        val open = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = android.app.PendingIntent.getActivity(
            this,
            2001,
            open,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, EmergencyAlerts.STANDBY_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("Sahara emergency standby")
            .setContentText("Listening for SOS signals from nearby devices")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(pending)
            .build()
    }

    companion object {
        private const val NOTIFICATION_STANDBY = 8003

        @Volatile
        private var running = false

        fun isRunning(): Boolean = running

        /** Start standby. Returns `true` when the service was asked to start. */
        fun start(context: Context): Boolean {
            return try {
                val intent = Intent(context, SosService::class.java)
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (e: Exception) {
                // Background start restrictions or an OEM block.
                false
            }
        }

        fun stop(context: Context) {
            running = false
            try {
                context.stopService(Intent(context, SosService::class.java))
            } catch (_: Exception) {
                // Already stopped.
            }
        }

        /**
         * Whether a `connectedDevice` foreground service is allowed right now.
         * Android 14+ requires the Bluetooth or Wi-Fi runtime permissions that
         * this service type depends on.
         */
        fun canRunConnectedDeviceService(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                return true
            }
            val pm = context.packageManager
            val permissions = listOf(
                android.Manifest.permission.BLUETOOTH_CONNECT,
                android.Manifest.permission.BLUETOOTH_SCAN,
                android.Manifest.permission.CHANGE_WIFI_STATE,
            )
            return permissions.any {
                pm.checkPermission(it, context.packageName) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
            }
        }
    }
}
