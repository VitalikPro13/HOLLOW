package com.anonlisten.hollow

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.graphics.drawable.IconCompat

/**
 * What the call notification shows; [title] is already the privacy-ruled name Dart sent (1.6).
 * [ringing] = a call we placed, not answered yet: hang-up only, nothing to mute.
 */
data class CallLook(val title: String, val muted: Boolean, val connectedAt: Long?, val ringing: Boolean = false)

/** The CallStyle notification of the OS call session (#154), posted by [HollowCallService]. */
object CallNotification {
    // DEFAULT importance, silent: LOW may hide the status-bar call chip (spike D5). A channel's
    // importance cannot change once created, so a new importance needs a new id.
    const val CHANNEL_ID = "hollow_ongoing_call"
    const val NOTIFICATION_ID = 0x484F4C43 // 'HOLC'

    fun build(context: Context, look: CallLook): Notification {
        ensureChannel(context)
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
            PendingIntent.getActivity(
                context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val hangUp = CallActionReceiver.pendingIntent(context, CallActionReceiver.ACTION_HANG_UP)
        val person = Person.Builder()
            .setName(look.title.ifBlank { "Hollow" })
            .setImportant(false)
            .build()
        val mute = NotificationCompat.Action.Builder(
            IconCompat.createWithResource(context, android.R.drawable.ic_btn_speak_now),
            if (look.muted) "Unmute" else "Mute",
            CallActionReceiver.pendingIntent(context, CallActionReceiver.ACTION_MUTE),
        ).build()
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_hollow)
            .setStyle(NotificationCompat.CallStyle.forOngoingCall(person, hangUp))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        if (!look.ringing) builder.addAction(mute)
        open?.let { builder.setContentIntent(it) }
        look.connectedAt?.let { builder.setWhen(it).setShowWhen(true).setUsesChronometer(true) }
        return builder.build()
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Calls", NotificationManager.IMPORTANCE_DEFAULT).apply {
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            })
    }
}
