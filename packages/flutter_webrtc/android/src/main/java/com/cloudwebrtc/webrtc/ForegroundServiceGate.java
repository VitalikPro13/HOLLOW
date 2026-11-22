package com.cloudwebrtc.webrtc;

/**
 * Hollow fork: which start and stop requests for a foreground service must
 * reach the system. A stop clears "running" at once, never only in onDestroy:
 * a start landing between stopService and onDestroy was skipped as "already
 * running", and the service then died under a live call.
 */
final class ForegroundServiceGate {
    private boolean running;

    synchronized boolean shouldStart() {
        return !running;
    }

    synchronized void started() {
        running = true;
    }

    /** True when the stop must reach the system. */
    synchronized boolean stopRequested() {
        if (!running) return false;
        running = false;
        return true;
    }

    synchronized void destroyed() {
        running = false;
    }
}
