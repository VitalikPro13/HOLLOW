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
    public void anAppHoldNeverActivatesCallAudio() throws IOException {
        String hold = body("audio/AudioSwitchManager.java", "public void hold(");
        assertTrue(hold.contains("if (CallAudioHolders.activates(holder))"));
        assertTrue(hold.contains("CallForegroundService.start(context)"));
    }

    @Test
    public void anIdleReleaseStopsTheServiceEvenWhenCallAudioNeverActivated() throws IOException {
        // A placed call that rang out held only its app key: the service started,
        // AudioSwitch never activated, and the service must still end.
        String f = "audio/AudioSwitchManager.java";
        String release = body(f, "private void releaseIfIdle()");
        assertTrue(release.contains("deactivateLive();"));
        assertTrue(release.contains("CallForegroundService.stop(context)"));
        assertFalse(body(f, "private void deactivateLive()").contains("CallForegroundService.stop"));
    }

    // #154 review MED-1: call mode follows real audio; app keys keep only the service.
    @Test
    public void theEndOfRealAudioEndsCallModeButKeepsTheService() throws IOException {
        String f = "audio/AudioSwitchManager.java";
        assertTrue(source(f).contains("this::releaseIfIdle,\n            this::endCallModeOnly)"));
        String only = body(f, "private void endCallModeOnly()");
        assertTrue(only.contains("deactivateLive();"));
        assertFalse(only.contains("CallForegroundService.stop"));
    }

    // #154 review MED-1: a room's live AudioSwitch steps down when Telecom takes the call.
    @Test
    public void telecomTakingTheAudioStepsDownALiveAudioSwitch() throws IOException {
        String f = "audio/AudioSwitchManager.java";
        has(f, "public static void takeAudioForTelecom(", "stepDownForTelecom");
        String down = body(f, "private void stepDownForTelecom()");
        assertTrue(down.contains("deactivateLive();"));
        assertTrue(down.contains("wantsActive = true;"));
    }

    // #154 review MED-3: a fallback starts call audio only for real audio, and start/stop never
    // wipe the handler (that deleted the holders' idle check and left call mode on).
    @Test
    public void aFallbackStartsOnlyForRealAudioAndNothingWipesTheIdleCheck() throws IOException {
        String f = "audio/AudioSwitchManager.java";
        has(f, "private void afterTelecom(", "if (callAudioHolders.hasActivating()) start();");
        assertFalse(body(f, "public void start()").contains("removeCallbacksAndMessages"));
        assertFalse(body(f, "public void stop()").contains("removeCallbacksAndMessages"));
    }

    @Test
    public void everyHoldRetriesTheForegroundService() throws IOException {
        String start = body("audio/AudioSwitchManager.java", "private void startNow()");
        assertTrue(start.contains("CallForegroundService.start(context)"));
        int guard = start.indexOf("if (!isActive) {");
        String activateOnly = start.substring(guard, start.indexOf('}', guard) + 1);
        assertFalse("a hold while active must still ask for the service",
                activateOnly.contains("CallForegroundService.start"));
    }
}
