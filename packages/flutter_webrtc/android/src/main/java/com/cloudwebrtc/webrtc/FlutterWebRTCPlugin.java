package com.cloudwebrtc.webrtc;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.os.Bundle;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.lifecycle.DefaultLifecycleObserver;
import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.LifecycleOwner;

import com.cloudwebrtc.webrtc.audio.AudioProcessingController;
import com.cloudwebrtc.webrtc.audio.AudioSwitchManager;
import com.cloudwebrtc.webrtc.utils.AnyThreadSink;
import com.cloudwebrtc.webrtc.utils.ConstraintsMap;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

import org.webrtc.ExternalAudioProcessingFactory;
import org.webrtc.MediaStreamTrack;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.embedding.engine.plugins.lifecycle.HiddenLifecycleReference;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;

/**
 * FlutterWebRTCPlugin
 */
public class FlutterWebRTCPlugin implements FlutterPlugin, ActivityAware, EventChannel.StreamHandler {

    static public final String TAG = "FlutterWebRTCPlugin";
    private static Application application;

    private MethodChannel methodChannel;
    private MethodCallHandlerImpl methodCallHandler;
    private LifeCycleObserver observer;
    private Lifecycle lifecycle;
    private EventChannel eventChannel;

    // Hollow fork (#154, N5): each engine keeps its OWN sink. A static one was overwritten by
    // every engine that listened (the FCM background engine too) and nulled by any engine's
    // cancel, so a later call's route picker stopped hearing hotplugs.
    private EventChannel.EventSink eventSink;

    // Every engine attached right now; the shared audio manager reports device changes to all.
    private static final List<FlutterWebRTCPlugin> liveEngines = new CopyOnWriteArrayList<>();

    public FlutterWebRTCPlugin() {
        sharedSingleton = this;
    }

    public static FlutterWebRTCPlugin sharedSingleton;

    public AudioProcessingController getAudioProcessingController() {
        return methodCallHandler.audioProcessingController;
    }

    public MediaStreamTrack getTrackForId(String trackId, String peerConnectionId) {
        return methodCallHandler.getTrackForId(trackId, peerConnectionId);
    }

    public LocalTrack getLocalTrack(String trackId) {
        return methodCallHandler.getLocalTrack(trackId);
    }

    public MediaStreamTrack getRemoteTrack(String trackId) {
        return methodCallHandler.getRemoteTrack(trackId);
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        startListening(binding.getApplicationContext(), binding.getBinaryMessenger(),
                binding.getTextureRegistry());
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        stopListening();
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        methodCallHandler.setActivity(binding.getActivity());
        this.observer = new LifeCycleObserver();
        this.lifecycle = ((HiddenLifecycleReference) binding.getLifecycle()).getLifecycle();
        this.lifecycle.addObserver(this.observer);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        methodCallHandler.setActivity(null);
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        methodCallHandler.setActivity(binding.getActivity());
    }

    @Override
    public void onDetachedFromActivity() {
        methodCallHandler.setActivity(null);
        if (this.observer != null) {
            this.lifecycle.removeObserver(this.observer);
            if (application!=null) {
                application.unregisterActivityLifecycleCallbacks(this.observer);
            }
        }
        this.lifecycle = null;
    }

    private void startListening(final Context context, BinaryMessenger messenger,
                                TextureRegistry textureRegistry) {
        // Hollow fork (#154, N5): ONE audio manager per process, made by the first engine and never
        // replaced: a second engine (an FCM wake) replacing it mid-call orphaned the live call's
        // audioswitch and its device listener.
        if (AudioSwitchManager.instance == null) {
            AudioSwitchManager.instance = new AudioSwitchManager(context);
            AudioSwitchManager.instance.audioDeviceChangeListener = (devices, currentDevice) -> {
                Log.w(TAG, "audioFocusChangeListener " + devices+ " " + currentDevice);
                for (FlutterWebRTCPlugin engine : liveEngines) {
                    ConstraintsMap params = new ConstraintsMap();
                    params.putString("event", "onDeviceChange");
                    engine.sendEvent(params.toMap());
                }
                return null;
            };
        }
        liveEngines.add(this);
        methodCallHandler = new MethodCallHandlerImpl(context, messenger, textureRegistry);
        methodChannel = new MethodChannel(messenger, "FlutterWebRTC.Method");
        methodChannel.setMethodCallHandler(methodCallHandler);
        eventChannel = new EventChannel( messenger,"FlutterWebRTC.Event");
        eventChannel.setStreamHandler(this);
    }

    private void stopListening() {
        liveEngines.remove(this);
        methodCallHandler.dispose();
        methodCallHandler = null;
        methodChannel.setMethodCallHandler(null);
        eventChannel.setStreamHandler(null);
        eventSink = null;
        // Hollow fork (#154, N5): the leaving engine gave back only its own call-audio holds
        // (dispose); the shared audio stops at once only with the last engine. A secondary
        // engine's detach stopping it mid-call deactivated audioswitch under the live call.
        if (AudioSwitchManager.instance != null && liveEngines.isEmpty()) {
            Log.d(TAG, "Stopping the audio manager...");
            AudioSwitchManager.instance.stop();
        }
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        eventSink = new AnyThreadSink(events);
    }
    @Override
    public void onCancel(Object arguments) {
        eventSink = null;
    }

    public void sendEvent(Object event) {
        if(eventSink != null) {
            eventSink.success(event);
        }
    }

    private class LifeCycleObserver implements Application.ActivityLifecycleCallbacks, DefaultLifecycleObserver {

        @Override
        public void onActivityCreated(Activity activity, Bundle savedInstanceState) {

        }

        @Override
        public void onActivityStarted(Activity activity) {

        }

        @Override
        public void onActivityResumed(Activity activity) {
            if (null != methodCallHandler) {
                methodCallHandler.reStartCamera();
            }
        }

        @Override
        public void onResume(LifecycleOwner owner) {
            if (null != methodCallHandler) {
                methodCallHandler.reStartCamera();
            }
        }

        @Override
        public void onActivityPaused(Activity activity) {

        }

        @Override
        public void onActivityStopped(Activity activity) {

        }

        @Override
        public void onActivitySaveInstanceState(Activity activity, Bundle outState) {

        }

        @Override
        public void onActivityDestroyed(Activity activity) {

        }
    }
}
