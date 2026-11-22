package com.cloudwebrtc.webrtc.audio;

import java.util.HashSet;
import java.util.Set;

/**
 * Hollow fork: what still needs call audio (AudioSwitch activation and the
 * microphone foreground service): each live microphone track and each peer
 * connection that received an audio track. A data-channel or video-only
 * connection never holds, so call audio ends with the last call, not with the
 * last peer connection of any kind. Thread-safe: holds arrive on the WebRTC
 * signaling thread, releases on the platform thread.
 */
public final class CallAudioHolders {
    private final Set<String> holders = new HashSet<>();

    public static String mic(String trackId) {
        return "mic:" + trackId;
    }

    public static String peerConnection(String peerConnectionId) {
        return "pc:" + peerConnectionId;
    }

    public synchronized void hold(String holder) {
        holders.add(holder);
    }

    /** True only when this release let go of the last holder. */
    public synchronized boolean release(String holder) {
        return holders.remove(holder) && holders.isEmpty();
    }

    public synchronized boolean isIdle() {
        return holders.isEmpty();
    }

    public synchronized int size() {
        return holders.size();
    }

    public synchronized void clear() {
        holders.clear();
    }
}
