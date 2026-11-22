package com.anonlisten.hollow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OsCallRulesTest {
    private fun MuteMirror.telecomSaid(muted: Boolean) =
        fromTelecom(muted, settling = false) == MuteMirror.Telecom.TELL

    // ---- the fallback trigger (D5) ----

    @Test
    fun telecomIsOfferedOnlyWhenRegisteredWithTheFeatureAndNotForced() {
        assertTrue(OsCallRules.offersTelecom("dm", registered = true, hasFeature = true, forcedFallback = false))
        assertFalse(OsCallRules.offersTelecom("dm", registered = false, hasFeature = true, forcedFallback = false))
        assertFalse(OsCallRules.offersTelecom("dm", registered = true, hasFeature = false, forcedFallback = false))
        assertFalse(OsCallRules.offersTelecom("dm", registered = true, hasFeature = true, forcedFallback = true))
    }

    // Vitalik, Nov 22: only a DM call becomes a system call. A room or meeting still begins (it
    // gets the call service), but Telecom never hears of it.
    @Test
    fun aVoiceRoomRegistersNoTelecomCall() {
        assertFalse(OsCallRules.offersTelecom("room", registered = true, hasFeature = true, forcedFallback = false))
        assertEquals(OsCallSession.Path.FALLBACK, OsCallSession("u", telecomOffered = false).path)
    }

    @Test
    fun aMeetingRegistersNoTelecomCall() {
        assertFalse(OsCallRules.offersTelecom("meeting", registered = true, hasFeature = true, forcedFallback = false))
    }

    @Test
    fun anUnknownOrMissingKindRegistersNoTelecomCall() {
        assertFalse(OsCallRules.offersTelecom(null, registered = true, hasFeature = true, forcedFallback = false))
        assertFalse(OsCallRules.offersTelecom("DM", registered = true, hasFeature = true, forcedFallback = false))
        assertFalse(OsCallRules.offersTelecom("", registered = true, hasFeature = true, forcedFallback = false))
    }

    @Test
    fun theDeadlineIsTwoSeconds() {
        assertEquals(2_000L, OsCallRules.ADD_DEADLINE_MS)
    }

    @Test
    fun aCallNotAddedByTheDeadlineFallsBack() {
        val s = OsCallSession("u", telecomOffered = true)
        assertTrue(s.onDeadline())
        assertEquals(OsCallSession.Path.FALLBACK, s.path)
        // A late add after the fallback is refused: the bridge disconnects it.
        assertFalse(s.onAdded())
        assertEquals(OsCallSession.Path.FALLBACK, s.path)
    }

    @Test
    fun aCallAddedInTimeIgnoresTheDeadline() {
        val s = OsCallSession("u", telecomOffered = true)
        assertTrue(s.onAdded())
        assertFalse(s.onDeadline())
        assertEquals(OsCallSession.Path.TELECOM, s.path)
    }

    @Test
    fun aSessionWithoutTelecomStartsOnTheFallback() {
        val s = OsCallSession("u", telecomOffered = false)
        assertEquals(OsCallSession.Path.FALLBACK, s.path)
        assertFalse(s.onDeadline())
        assertFalse(s.onAdded())
        assertFalse(s.onTelecomLost())
    }

    @Test
    fun losingTelecomMidCallFallsBackOnce() {
        val pending = OsCallSession("u", telecomOffered = true)
        assertTrue(pending.onTelecomLost())
        assertEquals(OsCallSession.Path.FALLBACK, pending.path)
        assertFalse(pending.onTelecomLost())

        val live = OsCallSession("v", telecomOffered = true)
        live.onAdded()
        assertTrue(live.onTelecomLost())
        assertEquals(OsCallSession.Path.FALLBACK, live.path)
    }

    @Test
    fun endIsIdempotentAndStopsEveryLaterTransition() {
        val s = OsCallSession("u", telecomOffered = true)
        assertTrue(s.end())
        assertFalse(s.end())
        assertFalse(s.onDeadline())
        assertFalse(s.onAdded())
        assertFalse(s.onTelecomLost())
        assertEquals(OsCallSession.Path.ENDED, s.path)
    }

    @Test
    fun aNewBeginEndsEveryOtherHeldCall() {
        assertEquals(listOf("old"), OsCallRules.endAtBegin(listOf("old"), "new"))
        assertEquals(emptyList<String>(), OsCallRules.endAtBegin(listOf("new"), "new"))
        assertEquals(listOf("a", "b"), OsCallRules.endAtBegin(listOf("a", "b", "new"), "new"))
    }

    // ---- the ring-out service ----

    @Test
    fun aRingOutStartsTheServiceOnceAndAnUnansweredEndStopsIt() {
        val r = RingOut()
        assertTrue(r.on(sessionHeld = false))
        assertFalse(r.on(sessionHeld = false))
        assertTrue(r.off(sessionHeld = false))
        assertFalse(r.off(sessionHeld = false))
    }

    @Test
    fun anAnsweredCallKeepsTheServiceTheRingStarted() {
        val r = RingOut()
        r.on(sessionHeld = false)
        r.onBegin()
        assertFalse(r.ringing)
        assertFalse(r.off(sessionHeld = true))
    }

    @Test
    fun theRingOffNeverStopsTheServiceOfALiveSession() {
        val r = RingOut()
        r.on(sessionHeld = false)
        assertFalse(r.off(sessionHeld = true))
    }

    @Test
    fun aRingOutDuringASessionStartsNothing() {
        val r = RingOut()
        assertFalse(r.on(sessionHeld = true))
        assertFalse(r.off(sessionHeld = false))
    }

    // ---- the mute mirror (D2) ----

    @Test
    fun ourOwnWriteEchoesBackAndIsDropped() {
        val m = MuteMirror()
        assertEquals(true, m.fromApp(true, telecomLive = true, globalNow = false))
        assertFalse(m.telecomSaid(true))
    }

    @Test
    fun aHeadsetMuteReachesTheApp() {
        val m = MuteMirror()
        m.fromApp(false, telecomLive = true, globalNow = false)
        assertTrue(m.telecomSaid(true))
        assertTrue(m.telecomSaid(false).not())
    }

    @Test
    fun aHeadsetUnmuteAfterAnAppMuteReachesTheApp() {
        val m = MuteMirror()
        m.fromApp(true, telecomLive = true, globalNow = false)
        assertTrue(m.telecomSaid(false))
    }

    @Test
    fun theAppsAnswerWritesTheTruthBack() {
        val m = MuteMirror()
        m.fromApp(false, telecomLive = true, globalNow = false)
        assertTrue(m.telecomSaid(true))
        // The app refused the mute (a moderator's mute is not ours to lift, PTT): it answers with the
        // truth, which clears the global mute the headset set.
        assertEquals(false, m.fromApp(false, telecomLive = true, globalNow = true))
        assertFalse(m.telecomSaid(false))
    }

    @Test
    fun nothingIsWrittenWithoutALiveTelecomCallOrWhenTheGlobalAgrees() {
        val m = MuteMirror()
        assertNull(m.fromApp(true, telecomLive = false, globalNow = false))
        assertTrue(m.appMuted)
        assertNull(m.fromApp(true, telecomLive = true, globalNow = true))
    }

    // The global mic mute covers a carrier call too: while one holds ours, nothing is written and
    // the carrier call's own mute is not ours to mirror.
    @Test
    fun whileHeldTheGlobalMuteIsNeverWrittenNorMirrored() {
        val m = MuteMirror()
        m.fromApp(false, telecomLive = true, globalNow = false)
        assertNull(m.onHold(true, telecomLive = true, globalNow = false))
        assertNull(m.fromApp(true, telecomLive = true, globalNow = false))
        assertTrue(m.appMuted)
        assertFalse(m.telecomSaid(false))
        assertFalse(m.telecomSaid(true))
    }

    @Test
    fun resumingAlignsTheGlobalMuteWithTheApp() {
        val m = MuteMirror()
        m.fromApp(false, telecomLive = true, globalNow = false)
        m.onHold(true, telecomLive = true, globalNow = false)
        m.fromApp(true, telecomLive = true, globalNow = false)
        assertEquals(true, m.onHold(false, telecomLive = true, globalNow = false))
        assertFalse(m.telecomSaid(true))
    }

    @Test
    fun anEndWhileHeldLeavesTheGlobalMuteAlone() {
        val m = MuteMirror()
        m.fromApp(true, telecomLive = true, globalNow = false)
        m.onHold(true, telecomLive = true, globalNow = true)
        assertFalse(m.clearAtEnd(globalNow = true))
    }

    // Right after Telecom adds the call its first mute value can predate our alignment write: the
    // app is the truth then, so a difference re-aligns the global mute instead of muting the call.
    @Test
    fun aDifferenceWhileSettlingRealignsInsteadOfTellingTheApp() {
        val m = MuteMirror()
        m.fromApp(false, telecomLive = true, globalNow = false)
        assertEquals(MuteMirror.Telecom.REALIGN, m.fromTelecom(true, settling = true))
        assertEquals(MuteMirror.Telecom.NONE, m.fromTelecom(false, settling = true))
        assertEquals(MuteMirror.Telecom.TELL, m.fromTelecom(true, settling = false))
    }

    @Test
    fun theGlobalMuteIsClearedAtTheEndOnlyWhenOurCallSetIt() {
        val ours = MuteMirror()
        ours.fromApp(true, telecomLive = true, globalNow = false)
        assertTrue(ours.clearAtEnd(globalNow = true))
        assertFalse(ours.clearAtEnd(globalNow = false))

        val headset = MuteMirror()
        headset.telecomSaid(true)
        assertTrue(headset.clearAtEnd(globalNow = true))

        val untouched = MuteMirror()
        untouched.fromApp(false, telecomLive = false, globalNow = true)
        assertFalse(untouched.clearAtEnd(globalNow = true))
    }
}
