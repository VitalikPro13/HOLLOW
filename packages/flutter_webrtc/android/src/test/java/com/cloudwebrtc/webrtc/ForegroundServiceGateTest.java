package com.cloudwebrtc.webrtc;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class ForegroundServiceGateTest {

    @Test
    public void stopThenImmediateStartStartsTheServiceAgain() {
        ForegroundServiceGate gate = new ForegroundServiceGate();
        assertTrue(gate.shouldStart());
        gate.started();
        assertTrue(gate.stopRequested());
        // A hold lands before the stopped service's onDestroy.
        assertTrue(gate.shouldStart());
        gate.destroyed();
        gate.started();
        assertFalse(gate.shouldStart());
        assertTrue(gate.stopRequested());
    }

    @Test
    public void aStartWhileRunningAndAStopWhileStoppedAreSkipped() {
        ForegroundServiceGate gate = new ForegroundServiceGate();
        assertFalse(gate.stopRequested());
        gate.started();
        assertFalse(gate.shouldStart());
        gate.destroyed();
        assertTrue(gate.shouldStart());
        assertFalse(gate.stopRequested());
    }
}
