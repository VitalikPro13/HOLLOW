package com.anonlisten.hollow

import android.Manifest
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * THE call foreground service (#154): it lives exactly from the OS call session's `begin` to its
 * `end`, Telecom or not, so the mic keeps working in the background through a media
 * rebuild or an empty room. Its notification is the session's CallStyle.
 *
 * The `microphone` type is what keeps a backgrounded mic (spike D4: `phoneCall` alone is
 * silenced), and Android refuses it from the background, so it is taken at `begin` when
 * RECORD_AUDIO is granted and otherwise added on the next return to the foreground (N7).
 */
class HollowCallService : Service() {
    companion object {
        private const val TAG = "HollowOsCall"

        private var current: HollowCallService? = null

        /** The session's look; null = no session, so a start still in flight stops at once. */
        private var look: CallLook? = null
        private var lastLook = CallLook("Hollow", muted = false, connectedAt = null)

        /** The types the last startForeground got (0 = not foreground), for the debug status. */
        @Volatile var grantedTypes = 0
            private set

        /** A start was accepted and its onStartCommand has not run yet. */
        private var pending = false

        /**
         * Main thread. A service already up (a ring-out the answer turned into a call) is only
         * re-posted: a second start from the background could be refused.
         */
        fun start(context: Context, initial: CallLook) {
            val running = look != null && (current != null || pending)
            look = initial
            lastLook = initial
            if (running) {
                current?.post(initial)
                return
            }
            val app = context.applicationContext
            try {
                ContextCompat.startForegroundService(app, Intent(app, HollowCallService::class.java))
                pending = true
            } catch (e: Exception) {
                pending = false
                // Refused (started from the background): the call goes on as it did before.
                Log.w(TAG, "call service start refused: $e")
            }
        }

        /** Main thread. Re-posts the notification with [next]. */
        fun update(next: CallLook) {
            if (look == null) return
            look = next
            lastLook = next
            current?.post(next)
        }

        /** Main thread, in the foreground: adds the microphone type once RECORD_AUDIO is granted. */
        fun addMicIfGranted() {
            val service = current ?: return
            if (look == null || !micAllowed(service)) return
            if (grantedTypes and micType() != 0) return
            service.goForeground()
        }

        /** Main thread. */
        fun stop() {
            look = null
            current?.finish()
        }

        private fun micAllowed(context: Context): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED

        private fun micType(): Int =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        current = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A start that lands on an instance a stop is still taking down reuses it.
        current = this
        pending = false
        // startForeground comes first even when the session already ended: a service started for
        // the foreground that stops before it crashes the app.
        goForeground()
        if (look == null) finish()
        return START_NOT_STICKY
    }

    // phoneCall first (+ microphone when allowed); a refusal retries with the microphone alone; a
    // second refusal leaves the call running as it did before this service existed.
    private fun goForeground() {
        val notification = CallNotification.build(this, look ?: lastLook)
        val wanted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or (if (micAllowed(this)) micType() else 0)
        } else {
            0
        }
        val attempts = listOf(wanted, wanted and ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL.inv())
            .distinct()
            .filter { it != 0 || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q }
        for (types in attempts) {
            try {
                ServiceCompat.startForeground(this, CallNotification.NOTIFICATION_ID, notification, types)
                grantedTypes = if (types == 0) -1 else types
                Log.i(TAG, "call service foreground types=$types")
                return
            } catch (e: Exception) {
                Log.w(TAG, "startForeground types=$types refused: $e")
            }
        }
        finish()
    }

    private fun post(next: CallLook) {
        if (grantedTypes == 0) return
        try {
            getSystemService(NotificationManager::class.java)
                ?.notify(CallNotification.NOTIFICATION_ID, CallNotification.build(this, next))
        } catch (e: Exception) {
            Log.w(TAG, "call notification update failed: $e")
        }
    }

    private fun finish() {
        if (current === this) {
            current = null
            grantedTypes = 0
        }
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // Swiped away from Recents: the engine and its call die with the task, so the OS call goes too
    // (no ghost call on the status bar, a headset or a car).
    override fun onTaskRemoved(rootIntent: Intent?) {
        OsCallBridge.endAll("task removed")
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (current === this) {
            current = null
            grantedTypes = 0
        }
        super.onDestroy()
    }
}
