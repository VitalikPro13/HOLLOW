package com.cloudwebrtc.webrtc;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

import org.junit.Test;

/**
 * Hollow fork (#154): every place call audio starts or ends holds or releases
 * it. These call sites need a live WebRTC factory, so the wiring is read from
 * the sources (the gradle test runs in the module directory).
 */
public class CallAudioWiringTest {

    private static final String DIR = "src/main/java/com/cloudwebrtc/webrtc/";

    private static String source(String file) throws IOException {
        return new String(Files.readAllBytes(Paths.get(DIR + file)), StandardCharsets.UTF_8);
    }

    /** The block that opens at the first '{' after [signature], braces balanced. */
    private static String body(String file, String signature) throws IOException {
        String s = source(file);
        int at = s.indexOf(signature);
        if (at < 0) fail(file + " lost " + signature);
        int open = s.indexOf('{', at);
        int depth = 0;
        for (int i = open; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '{') depth++;
            if (c == '}' && --depth == 0) return s.substring(open, i + 1);
        }
        fail("unbalanced " + signature);
        return "";
    }

    private static void has(String file, String signature, String needle) throws IOException {
        assertTrue(signature + " must call " + needle, body(file, signature).contains(needle));
    }

    @Test
    public void everyMicTrackAndAudioConnectionHoldsCallAudio() throws IOException {
        has("GetUserMediaImpl.java", "private ConstraintsMap getUserAudio(",
                "AudioSwitchManager.instance.hold(CallAudioHolders.mic(track.id()))");
        has("PeerConnectionObserver.java", "public void onAddTrack(",
                "AudioSwitchManager.instance.hold(CallAudioHolders.peerConnection(id))");
        has("MethodCallHandlerImpl.java", "case \"holdCallAudioKey\":",
                "AudioSwitchManager.instance.hold(CallAudioHolders.app(key))");
    }

    @Test
    public void everyEndOfAMicTrackOrConnectionReleasesIt() throws IOException {
        String f = "MethodCallHandlerImpl.java";
        has(f, "public void peerConnectionClose(final String id)",
                "release(CallAudioHolders.peerConnection(id))");
        has(f, "public void peerConnectionDispose(final String id)",
                "release(CallAudioHolders.peerConnection(id))");
        has(f, "public void trackDispose(final String trackId)",
                "release(CallAudioHolders.mic(trackId))");
        has(f, "public void mediaStreamTrackRelease(", "release(CallAudioHolders.mic(_trackId))");
        has(f, "public void streamDispose(final MediaStream stream)",
                "release(CallAudioHolders.mic(trackId))");
        has(f, "case \"releaseCallAudioKey\":", "release(CallAudioHolders.app(key))");
        // The old rule ended call audio with the last connection of any kind.
        assertFalse(body(f, "public void peerConnectionDispose(final String id)").contains(".stop()"));
    }

    @Test
    public void anEngineGivesBackOnlyItsOwnHolds() throws IOException {
        String f = "MethodCallHandlerImpl.java";
        has(f, "void dispose()", "releaseCallAudio();");
        has(f, "void dispose()", "releaseAppCallAudioKeys();");
        has(f, "void releaseCallAudio()", "release(CallAudioHolders.mic(trackId))");
        has(f, "void releaseCallAudio()", "release(CallAudioHolders.peerConnection(id))");
        has(f, "private void releaseAppCallAudioKeys()", "release(CallAudioHolders.app(key))");
        String p = "FlutterWebRTCPlugin.java";
        has(p, "private void startListening(", "if (AudioSwitchManager.instance == null)");
        has(p, "private void stopListening()", "liveEngines.isEmpty()");
    }

    @Test
    public void everyHoldRetriesTheForegroundService() throws IOException {
        String start = body("audio/AudioSwitchManager.java", "public void start()");
        assertTrue(start.contains("CallForegroundService.start(context)"));
        int guard = start.indexOf("if (!isActive) {");
        String activateOnly = start.substring(guard, start.indexOf('}', guard) + 1);
        assertFalse("a hold while active must still ask for the service",
                activateOnly.contains("CallForegroundService.start"));
    }
}
