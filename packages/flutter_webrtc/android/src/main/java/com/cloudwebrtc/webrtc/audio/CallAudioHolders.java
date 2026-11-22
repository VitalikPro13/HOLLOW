package com.cloudwebrtc.webrtc.audio;

import java.util.HashSet;
import java.util.Set;

/**
 * Hollow fork: what still needs call audio (AudioSwitch activation and the
 * microphone foreground service): each live microphone track, each peer
 * connection that received an audio track, and each key the app holds for a
 * call or voice room from its start to its end. A data-channel or video-only
 * connection never holds, so call audio ends with the last call, not with the
 * last peer connection of any kind. Thread-safe: holds arrive on the WebRTC
 * signaling thread too.
 */
public final class CallAudioHolders {

    /** Delayed work on one thread; on Android the main-looper Handler. */
    public interface Scheduler {
        void schedule(Runnable task, long delayMs);

        void cancel(Runnable task);
    }

    private final Set<String> holders = new HashSet<>();
    private final Scheduler scheduler;
    private final long graceMs;
    private final Runnable onIdle;
    private final Runnable idleCheck = this::runIdleCheck;

    /** [onIdle] runs [graceMs] after the last release, unless a hold came meanwhile. */
    public CallAudioHolders(Scheduler scheduler, long graceMs, Runnable onIdle) {
        this.scheduler = scheduler;
        this.graceMs = graceMs;
        this.onIdle = onIdle;
    }

    public static String mic(String trackId) {
        return "mic:" + trackId;
    }

    public static String peerConnection(String peerConnectionId) {
        return "pc:" + peerConnectionId;
    }

    public static String app(String key) {
        return "app:" + key;
    }

    public void hold(String holder) {
        synchronized (this) {
            holders.add(holder);
        }
        scheduler.cancel(idleCheck);
    }

    /** True only when this release let go of the last holder. */
    public boolean release(String holder) {
        boolean idle;
        synchronized (this) {
            idle = holders.remove(holder) && holders.isEmpty();
        }
        // Never pending here: the hold that ended the last idle spell cancelled it.
        if (idle) scheduler.schedule(idleCheck, graceMs);
        return idle;
    }

    // A hold can land after the scheduler already started this check.
    private void runIdleCheck() {
        if (isIdle()) onIdle.run();
    }

    public synchronized boolean isIdle() {
        return holders.isEmpty();
    }

    public void clear() {
        synchronized (this) {
            holders.clear();
        }
        scheduler.cancel(idleCheck);
    }
}
