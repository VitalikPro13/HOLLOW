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
    private final Runnable onAudioIdle;
    private final Runnable idleCheck = this::runIdleCheck;
    private final Runnable audioIdleCheck = this::runAudioIdleCheck;

    /** [onIdle] runs [graceMs] after the last release, unless a hold came meanwhile. */
    public CallAudioHolders(Scheduler scheduler, long graceMs, Runnable onIdle) {
        this(scheduler, graceMs, onIdle, () -> {});
    }

    /**
     * Also [onAudioIdle]: [graceMs] after the last ACTIVATING holder went while app keys still
     * hold, unless real audio came back meanwhile. Call mode ends there; the service stays.
     */
    public CallAudioHolders(Scheduler scheduler, long graceMs, Runnable onIdle, Runnable onAudioIdle) {
        this.scheduler = scheduler;
        this.graceMs = graceMs;
        this.onIdle = onIdle;
        this.onAudioIdle = onAudioIdle;
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

    /**
     * Whether a hold by [holder] activates call audio: a mic track or a connection carrying
     * audio does; an app hold (Dart's call or room key) only keeps it from ending.
     */
    public static boolean activates(String holder) {
        return !holder.startsWith("app:");
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
        boolean audioIdle;
        synchronized (this) {
            boolean removed = holders.remove(holder);
            idle = removed && holders.isEmpty();
            audioIdle = removed && !idle && activates(holder) && !hasActivatingLocked();
        }
        // Never pending here: the hold that ended the last idle spell cancelled it.
        if (idle) {
            scheduler.cancel(audioIdleCheck);
            scheduler.schedule(idleCheck, graceMs);
        } else if (audioIdle) {
            scheduler.cancel(audioIdleCheck);
            scheduler.schedule(audioIdleCheck, graceMs);
        }
        return idle;
    }

    // A hold can land after the scheduler already started this check.
    private void runIdleCheck() {
        if (isIdle()) onIdle.run();
    }

    // Real audio back by now keeps call mode: a hold never cancels this check, this test does.
    private void runAudioIdleCheck() {
        if (!isIdle() && !hasActivating()) onAudioIdle.run();
    }

    public synchronized boolean isIdle() {
        return holders.isEmpty();
    }

    /** Whether a mic track or an audio connection still holds (what call mode follows). */
    public synchronized boolean hasActivating() {
        return hasActivatingLocked();
    }

    private boolean hasActivatingLocked() {
        for (String h : holders) {
            if (activates(h)) return true;
        }
        return false;
    }

    public void clear() {
        synchronized (this) {
            holders.clear();
        }
        scheduler.cancel(idleCheck);
        scheduler.cancel(audioIdleCheck);
    }
}
