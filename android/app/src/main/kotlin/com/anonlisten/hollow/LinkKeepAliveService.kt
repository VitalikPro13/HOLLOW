package com.anonlisten.hollow

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.IBinder
import androidx.annotation.RequiresApi

// Held while this phone presents a link code (lib/src/core/services/link_keep_alive.dart):
// Android cuts a backgrounded app's network within seconds unless a foreground service
// runs, and the person is typing the code on the other device meanwhile. A short
// service needs no extra permission or store declaration; past its few minutes the
// link waits for the app to come back.
class LinkKeepAliveService : Service() {
    companion object {
        private const val CHANNEL_ID = "hollow_link"
        private const val NOTIFICATION_ID = 7341

        // Every start bumps it, so a delayed stop never ends a newer hold.
        private var generation = 0
        private var startedAt = 0L

        fun start(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
            generation++
            startedAt = SystemClock.elapsedRealtime()
            try {
                context.applicationContext.startForegroundService(Intent(context.applicationContext, LinkKeepAliveService::class.java))
            } catch (e: Exception) {
                // Refused (started from the background): the link still completes when the app returns.
            }
        }

        // A stop that reaches the service before its startForeground crashes the app, so a
        // stop right after a start waits a moment.
        fun stop(context: Context) {
            val mine = generation
            val wait = (startedAt + 2000L - SystemClock.elapsedRealtime()).coerceAtLeast(0L)
            Handler(Looper.getMainLooper()).postDelayed({
                if (generation == mine) {
                    context.applicationContext.stopService(Intent(context.applicationContext, LinkKeepAliveService::class.java))
                }
            }, wait)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) goForeground() else stopSelf()
        return START_NOT_STICKY
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun goForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Device linking", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_hollow)
            .setContentTitle("Linking a device")
            .setContentText("Hollow stays connected while you enter the code on your other device.")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        try {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE)
        } catch (e: Exception) {
            stopSelf()
        }
    }

    // A short service still running at its time limit crashes the app.
    override fun onTimeout(startId: Int) {
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }
}
