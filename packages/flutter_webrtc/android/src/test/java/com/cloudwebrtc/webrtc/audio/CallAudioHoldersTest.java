package com.cloudwebrtc.webrtc.audio;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.util.ArrayList;
import java.util.List;

import org.junit.Test;

public class CallAudioHoldersTest {

    /** Manual clock: tasks run only when the test advances time. */
    static final class FakeScheduler implements CallAudioHolders.Scheduler {
        long now;
        final List<Object[]> pending = new ArrayList<>();
        Runnable lastScheduled;

        @Override
        public void schedule(Runnable task, long delayMs) {
            for (Object[] p : pending) {
                if (p[0] == task) fail("the idle check was scheduled twice");
            }
            pending.add(new Object[] {task, now + delayMs});
            lastScheduled = task;
        }

        @Override
        public void cancel(Runnable task) {
            pending.removeIf(p -> p[0] == task);
        }

        void advance(long ms) {
            now += ms;
            List<Object[]> due = new ArrayList<>();
            for (Object[] p : pending) {
                if ((long) p[1] <= now) due.add(p);
            }
            pending.removeAll(due);
            for (Object[] p : due) ((Runnable) p[0]).run();
        }
    }

    private static final long GRACE = 4000;

    private final FakeScheduler clock = new FakeScheduler();
    private int deactivations;
    private final CallAudioHolders holders =
            new CallAudioHolders(clock, GRACE, () -> deactivations++);

    @Test
    public void dmCallEndsCallAudioWhileDataChannelLanesStayOpen() {
        holders.hold(CallAudioHolders.mic("mic1"));
        holders.hold(CallAudioHolders.peerConnection("call-pc"));
        // A data-channel lane never held; closing or keeping it changes nothing.
        assertFalse(holders.release(CallAudioHolders.peerConnection("file-lane-pc")));
        assertFalse(holders.release(CallAudioHolders.mic("mic1")));
        assertTrue(holders.release(CallAudioHolders.peerConnection("call-pc")));
        clock.advance(GRACE);
        assertEquals(1, deactivations);
    }

    @Test
    public void voiceRoomKeepsCallAudioUntilItsLastHolderGoes() {
        holders.hold(CallAudioHolders.app("voice-channel"));
        holders.hold(CallAudioHolders.mic("mic1"));
        holders.hold(CallAudioHolders.peerConnection("leg1"));
        assertFalse(holders.release(CallAudioHolders.peerConnection("leg1")));
        assertFalse(holders.release(CallAudioHolders.mic("mic1")));
        clock.advance(GRACE * 10);
        assertEquals(0, deactivations);
        assertTrue(holders.release(CallAudioHolders.app("voice-channel")));
    }

    @Test
    public void mediaRebuildLongerThanTheGraceKeepsCallAudioWhileTheCallHolds() {
        holders.hold(CallAudioHolders.app("dm-call"));
        holders.hold(CallAudioHolders.mic("old-mic"));
        holders.hold(CallAudioHolders.peerConnection("old-pc"));
        // The peer asks for a media restart: every track and connection goes.
        holders.release(CallAudioHolders.mic("old-mic"));
        holders.release(CallAudioHolders.peerConnection("old-pc"));
        clock.advance(GRACE * 5);
        assertEquals(0, deactivations);
        holders.hold(CallAudioHolders.mic("new-mic"));
        assertFalse(holders.isIdle());
    }

    @Test
    public void aHoldInsideTheGraceCancelsTheDeactivate() {
        holders.hold(CallAudioHolders.mic("room-mic"));
        assertTrue(holders.release(CallAudioHolders.mic("room-mic")));
        clock.advance(GRACE - 1);
        holders.hold(CallAudioHolders.mic("call-mic"));
        clock.advance(GRACE * 2);
        assertEquals(0, deactivations);
        assertTrue(holders.release(CallAudioHolders.mic("call-mic")));
        clock.advance(GRACE - 1);
        assertEquals("the grace restarts at the last release", 0, deactivations);
        clock.advance(1);
        assertEquals(1, deactivations);
    }

    @Test
    public void aHoldAndReleaseInsideTheGraceRestartsIt() {
        holders.hold(CallAudioHolders.mic("a"));
        holders.release(CallAudioHolders.mic("a"));
        clock.advance(1000);
        holders.hold(CallAudioHolders.mic("b"));
        holders.release(CallAudioHolders.mic("b"));
        clock.advance(GRACE - 1000);
        assertEquals("the first idle spell's check must be gone", 0, deactivations);
        clock.advance(1000);
        assertEquals(1, deactivations);
    }

    @Test
    public void releaseAfterGraceDeactivatesOnce() {
        holders.hold(CallAudioHolders.mic("a"));
        holders.release(CallAudioHolders.mic("a"));
        clock.advance(GRACE);
        clock.advance(GRACE * 3);
        assertEquals(1, deactivations);
        // A repeated release of a gone holder schedules nothing.
        assertFalse(holders.release(CallAudioHolders.mic("a")));
        clock.advance(GRACE * 3);
        assertEquals(1, deactivations);
    }

    @Test
    public void aCheckAlreadyRunningWhenAHoldLandsNeverDeactivates() {
        holders.hold(CallAudioHolders.mic("a"));
        holders.release(CallAudioHolders.mic("a"));
        Runnable check = clock.lastScheduled;
        // The hold lands on the signaling thread just as the main thread runs it.
        holders.hold(CallAudioHolders.peerConnection("pc"));
        check.run();
        assertEquals(0, deactivations);
    }

    @Test
    public void aRepeatedOrUnknownReleaseNeverEndsCallAudio() {
        holders.hold(CallAudioHolders.mic("a"));
        holders.hold(CallAudioHolders.mic("b"));
        assertFalse(holders.release(CallAudioHolders.mic("a")));
        assertFalse(holders.release(CallAudioHolders.mic("a")));
        assertFalse(holders.release(CallAudioHolders.peerConnection("b")));
        assertFalse(holders.release(CallAudioHolders.app("b")));
        assertFalse(holders.isIdle());
        assertTrue(holders.release(CallAudioHolders.mic("b")));
        assertFalse(holders.release(CallAudioHolders.mic("b")));
    }

    @Test
    public void clearCancelsAPendingDeactivate() {
        holders.hold(CallAudioHolders.mic("a"));
        holders.release(CallAudioHolders.mic("a"));
        holders.clear();
        clock.advance(GRACE * 2);
        assertEquals(0, deactivations);
    }
}
