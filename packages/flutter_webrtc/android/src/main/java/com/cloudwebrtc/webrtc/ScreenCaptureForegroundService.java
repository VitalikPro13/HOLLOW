package com.cloudwebrtc.webrtc;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

/**
 * Hollow fork: foreground service for MediaProjection screen capture.
 *
 * Android 10+ (API 29) throws a SecurityException from
 * {@code MediaProjectionManager.getMediaProjection()} unless the app is
 * running a foreground service of type {@code mediaProjection}, and Android 14
 * (API 34) enforces the declared service type hard. The projection is created
 * inside {@link OrientationAwareScreenCapturer#startCapture}, so this service
 * must be STARTED (startForeground executed) before that runs — callers pass a
 * continuation to {@link #start} which fires once the service is live.
 *
 * The service itself does no work; it only holds the foreground state (and the
 * user-visible "sharing your screen" notification) for the capture's lifetime.
 * Stopped from {@link GetUserMediaImpl#removeVideoCapturer} when the screen
 * capturer is torn down.
 */
public class ScreenCaptureForegroundService extends Service {
    private static final String TAG = FlutterWebRTCPlugin.TAG;
    private static final String CHANNEL_ID = "flutter_webrtc_screen_share";
    private static final int NOTIFICATION_ID = 0x53534843; // 'SSHC'

    private static Runnable pendingOnStarted;
    private static volatile boolean running;

    /** Start the service and invoke {@code onStarted} (on the main thread) once
     *  startForeground has executed. If already running, fires immediately. */
    public static void start(Context context, Runnable onStarted) {
        if (running) {
            if (onStarted != null) onStarted.run();
            return;
        }
        pendingOnStarted = onStarted;
        Intent intent = new Intent(context, ScreenCaptureForegroundService.class);
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
        } catch (Exception e) {
            // Most likely a background-start restriction; capture will then fail
            // with a SecurityException, surfaced to Dart as a getDisplayMedia
            // error. Run the continuation so the flow errors instead of hanging.
            Log.e(TAG, "ScreenCaptureForegroundService start failed", e);
            pendingOnStarted = null;
            if (onStarted != null) onStarted.run();
        }
    }

    public static void stop(Context context) {
        pendingOnStarted = null;
        if (!running) return;
        context.stopService(new Intent(context, ScreenCaptureForegroundService.class));
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        createNotificationChannel();
        Notification notification = buildNotification();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
        running = true;
        final Runnable onStarted = pendingOnStarted;
        pendingOnStarted = null;
        if (onStarted != null) {
            new Handler(Looper.getMainLooper()).post(onStarted);
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
                CHANNEL_ID, "Screen sharing", NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Shown while your screen is being shared");
        channel.setShowBadge(false);
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager != null) manager.createNotificationChannel(channel);
    }

    private Notification buildNotification() {
        // The app's launcher icon keeps the plugin free of bundled resources.
        int icon = getApplicationInfo().icon;
        if (icon == 0) icon = android.R.drawable.presence_video_online;
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        return builder
                .setSmallIcon(icon)
                .setContentTitle("Sharing your screen")
                .setContentText("Your screen is visible to call participants.")
                .setOngoing(true)
                .build();
    }
}
