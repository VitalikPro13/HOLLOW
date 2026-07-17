package com.cloudwebrtc.webrtc;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

/**
 * Hollow fork: foreground service of type {@code microphone} held for the
 * duration of any call.
 *
 * Android 11+ silently feeds SILENCE to a backgrounded app's mic AudioRecord
 * (a few seconds of grace, then nothing) unless the app runs a foreground
 * service whose type includes {@code microphone} that was started while the
 * app was in the foreground. Without this service the mic dies whenever the
 * user backgrounds Hollow mid-call — most visibly during screen shares, where
 * being in another app is the whole point. The existing
 * {@link ScreenCaptureForegroundService} ({@code mediaProjection} type) does
 * NOT cover mic capture.
 *
 * Started from {@link com.cloudwebrtc.webrtc.audio.AudioSwitchManager#start()}
 * (fires on mic acquisition for every DM call / voice channel) and stopped
 * from its {@code stop()} (call teardown / plugin detach). The service does no
 * work; it only holds the foreground state and the "Ongoing call"
 * notification, which taps back into the app.
 */
public class CallForegroundService extends Service {
    private static final String TAG = FlutterWebRTCPlugin.TAG;
    private static final String CHANNEL_ID = "flutter_webrtc_ongoing_call";
    private static final int NOTIFICATION_ID = 0x43414C4C; // 'CALL'

    private static volatile boolean running;

    public static void start(Context context) {
        if (running) return;
        Intent intent = new Intent(context, CallForegroundService.class);
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
        } catch (Exception e) {
            // Background-start restriction (API 34+) or similar. Degrade
            // gracefully: the call works, the mic just won't survive
            // backgrounding — same as before this service existed.
            Log.e(TAG, "CallForegroundService start failed", e);
        }
    }

    public static void stop(Context context) {
        if (!running) return;
        context.stopService(new Intent(context, CallForegroundService.class));
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        createNotificationChannel();
        Notification notification = buildNotification();
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(NOTIFICATION_ID, notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
            } else {
                startForeground(NOTIFICATION_ID, notification);
            }
            running = true;
        } catch (Exception e) {
            // MissingForegroundServiceTypeException / start-not-allowed edge
            // cases: never take the call down over the keep-alive.
            Log.e(TAG, "CallForegroundService startForeground failed", e);
            stopSelf();
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        running = false;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID, "Ongoing call", NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Shown while you are in a call");
        channel.setShowBadge(false);
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager != null) manager.createNotificationChannel(channel);
    }

    private Notification buildNotification() {
        // The app's launcher icon keeps the plugin free of bundled resources.
        int icon = getApplicationInfo().icon;
        if (icon == 0) icon = android.R.drawable.presence_audio_online;
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        builder.setSmallIcon(icon)
                .setContentTitle("Ongoing call")
                .setContentText("Tap to return to the call.")
                .setOngoing(true);
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launch != null) {
            builder.setContentIntent(PendingIntent.getActivity(
                    this, 0, launch,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        }
        return builder.build();
    }
}
