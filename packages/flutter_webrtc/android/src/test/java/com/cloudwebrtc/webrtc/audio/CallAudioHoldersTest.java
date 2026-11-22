package com.cloudwebrtc.webrtc.audio;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class CallAudioHoldersTest {

    @Test
    public void dmCallEndsCallAudioWhileDataChannelLanesStayOpen() {
        CallAudioHolders holders = new CallAudioHolders();
        holders.hold(CallAudioHolders.mic("mic1"));
        holders.hold(CallAudioHolders.peerConnection("call-pc"));
        // A data-channel lane never held; closing or keeping it changes nothing.
        assertFalse(holders.release(CallAudioHolders.peerConnection("file-lane-pc")));
        assertFalse(holders.release(CallAudioHolders.mic("mic1")));
        assertTrue(holders.release(CallAudioHolders.peerConnection("call-pc")));
        assertTrue(holders.isIdle());
    }

    @Test
    public void voiceRoomKeepsCallAudioUntilTheMicGoes() {
        CallAudioHolders holders = new CallAudioHolders();
        holders.hold(CallAudioHolders.mic("mic1"));
        holders.hold(CallAudioHolders.peerConnection("leg1"));
        holders.hold(CallAudioHolders.peerConnection("leg2"));
        assertFalse(holders.release(CallAudioHolders.peerConnection("leg1")));
        assertFalse(holders.release(CallAudioHolders.peerConnection("leg2")));
        // Alone (or muted) in the room: the kept mic track still holds.
        assertFalse(holders.isIdle());
        assertTrue(holders.release(CallAudioHolders.mic("mic1")));
    }

    @Test
    public void aHoldInsideTheGraceKeepsCallAudio() {
        CallAudioHolders holders = new CallAudioHolders();
        holders.hold(CallAudioHolders.mic("room-mic"));
        assertTrue(holders.release(CallAudioHolders.mic("room-mic")));
        // The DM call's mic arrives before the delayed release runs.
        holders.hold(CallAudioHolders.mic("call-mic"));
        assertFalse(holders.isIdle());
    }

    @Test
    public void aRepeatedOrUnknownReleaseNeverEndsCallAudio() {
        CallAudioHolders holders = new CallAudioHolders();
        holders.hold(CallAudioHolders.mic("a"));
        holders.hold(CallAudioHolders.mic("b"));
        assertFalse(holders.release(CallAudioHolders.mic("a")));
        assertFalse(holders.release(CallAudioHolders.mic("a")));
        assertFalse(holders.release(CallAudioHolders.peerConnection("b")));
        assertFalse(holders.isIdle());
        assertTrue(holders.release(CallAudioHolders.mic("b")));
        assertFalse(holders.release(CallAudioHolders.mic("b")));
    }
}
