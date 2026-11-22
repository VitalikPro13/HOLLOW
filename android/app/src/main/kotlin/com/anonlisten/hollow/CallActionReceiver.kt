package com.anonlisten.hollow

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

// The call notification's buttons (#154). Not exported; reached only through the explicit,
// immutable PendingIntents built here.
class CallActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_HANG_UP = "com.anonlisten.hollow.call.HANG_UP"
        const val ACTION_MUTE = "com.anonlisten.hollow.call.MUTE"

        fun pendingIntent(context: Context, action: String): PendingIntent {
            val intent = Intent(context, CallActionReceiver::class.java).setAction(action)
            return PendingIntent.getBroadcast(
                context, action.hashCode(), intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_HANG_UP -> OsCallBridge.onUserHangUp()
            ACTION_MUTE -> OsCallBridge.onUserToggleMute()
        }
    }
}
