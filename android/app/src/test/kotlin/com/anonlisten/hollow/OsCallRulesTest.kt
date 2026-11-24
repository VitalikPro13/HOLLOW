package com.anonlisten.hollow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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

    // #154 review MED-3: after a hang-up from the lock screen, a headset or a car the call never
    // carries on with no OS surface; it waits for Dart's end.
    @Test
    fun anOsHangUpNeverFallsBack() {
        val s = OsCallSession("u", telecomOffered = true)
        s.onAdded()
        assertTrue(s.onOsHangUp())
        assertFalse(s.onOsHangUp())
        assertFalse(s.onTelecomLost())
        assertEquals(OsCallSession.Path.HUNG_UP, s.path)
        assertTrue(s.end())
    }

    @Test
    fun onlyALiveTelecomCallCanBeHungUpFromTheOs() {
        assertFalse(OsCallSession("p", telecomOffered = true).onOsHangUp())
        assertFalse(OsCallSession("f", telecomOffered = false).onOsHangUp())
    }

    @Test
    fun telecomCallsStayOutOfTheCallHistory() {
        assertTrue(OsCallRules.LOG_EXCLUDED)
    }

    @Test
    fun theForegroundTriesPhoneCallAloneBeforeTheMicrophoneAlone() {
        val phone = 0x4
        val mic = 0x80
        assertEquals(listOf(phone or mic, phone, mic), OsCallRules.foregroundAttempts(phone, mic, micAllowed = true))
        assertEquals(listOf(phone), OsCallRules.foregroundAttempts(phone, mic, micAllowed = false))
    }

    @Test
    fun aRefusedMicrophoneUpgradeKeepsTheRunningForeground() {
        assertFalse(OsCallRules.finishWhenRefused(upgrade = true))
        assertTrue(OsCallRules.finishWhenRefused(upgrade = false))
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

    // A call ringing out is no call to the system (Nov 22): no CallStyle, no call chip.
    @Test
    fun onlyABegunSessionShowsAsACall() {
        assertFalse(OsCallRules.showsAsCall(CallLook("Ada", muted = false, connectedAt = null, ringing = true)))
        assertTrue(OsCallRules.showsAsCall(CallLook("Ada", muted = false, connectedAt = null)))
    }

    // Like the phone's own calls (Vitalik, Nov 24): the system's Hang up first (left), then ours in
    // order, Speaker in the centre and Mute on the right. CallStyle shows three buttons at most.
    @Test
    fun aCallShowsSpeakerThenMuteBesideTheSystemHangUp() {
        val buttons = OsCallRules.callButtons(CallLook("Ada", muted = false, connectedAt = null))
        assertEquals(listOf(CallButton.SPEAKER, CallButton.MUTE), buttons)
        assertTrue(1 + buttons.size <= OsCallRules.CALL_STYLE_MAX_BUTTONS)
    }

    @Test
    fun aRingOutHasNoButtonsOfItsOwn() {
        assertTrue(OsCallRules.callButtons(CallLook("Ada", muted = false, connectedAt = null, ringing = true)).isEmpty())
    }

    @Test
    fun speakerKeepsItsLabelAndShowsItsStateMuteSaysWhatItDoes() {
        val quiet = CallLook("Ada", muted = false, connectedAt = null)
        val loud = CallLook("Ada", muted = true, connectedAt = null, speaker = true)
        assertEquals("Speaker", OsCallRules.label(CallButton.SPEAKER, quiet))
        assertEquals("Speaker", OsCallRules.label(CallButton.SPEAKER, loud))
        assertFalse(OsCallRules.isOn(CallButton.SPEAKER, quiet))
        assertTrue(OsCallRules.isOn(CallButton.SPEAKER, loud))
        assertEquals("Mute", OsCallRules.label(CallButton.MUTE, quiet))
        assertEquals("Unmute", OsCallRules.label(CallButton.MUTE, loud))
        assertTrue(OsCallRules.isOn(CallButton.MUTE, loud))
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

    // The global mic mute also mutes the carrier call that holds ours: the hold lifts the mute our
    // call set, and a Hollow call ending during the carrier call leaves that call unmuted.
    @Test
    fun holdingForACarrierCallLiftsTheMuteOurCallSet() {
        val m = MuteMirror()
        assertEquals(true, m.fromApp(true, telecomLive = true, globalNow = false))
        assertEquals(false, m.onHold(true, telecomLive = true, globalNow = true))
        // The resume puts the app's mute back.
        assertEquals(true, m.onHold(false, telecomLive = true, globalNow = false))
    }

    @Test
    fun aHeadsetMuteIsLiftedForTheCarrierCallToo() {
        val m = MuteMirror()
        m.fromApp(false, telecomLive = true, globalNow = false)
        assertTrue(m.telecomSaid(true))
        assertEquals(false, m.onHold(true, telecomLive = true, globalNow = true))
    }

    @Test
    fun aHoldNeverTouchesAMuteOurCallDidNotSet() {
        val m = MuteMirror()
        m.fromApp(false, telecomLive = true, globalNow = false)
        assertNull(m.onHold(true, telecomLive = true, globalNow = true))
    }

    @Test
    fun anEndWhileHeldLeavesNoMuteOfOursOnTheCarrierCall() {
        val m = MuteMirror()
        m.fromApp(true, telecomLive = true, globalNow = false)
        assertEquals(false, m.onHold(true, telecomLive = true, globalNow = true))
        // Global mute is off now; a mute the carrier call sets itself is not ours to clear.
        assertFalse(m.clearAtEnd(globalNow = false))
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

    // ---- the call notification's avatar (HOL-SEC-155: a hidden name hides the face too) ----

    private fun pixels(side: Int) = ByteArray(side * side * 4) { 0x7f }

    @Test
    fun anAvatarRidesOnlyWithAName() {
        assertNotNull(OsCallRules.avatarFor("dm", "Ada", 2, pixels(2)))
        assertNull(OsCallRules.avatarFor("dm", OsCallRules.HIDDEN_TITLE, 2, pixels(2)))
        assertNull(OsCallRules.avatarFor("dm", "", 2, pixels(2)))
        assertNull(OsCallRules.avatarFor("dm", "  ", 2, pixels(2)))
    }

    @Test
    fun anAvatarIsExactlyTheSquareOfPixelsItClaims() {
        assertNull(OsCallRules.avatarFor("dm", "Ada", null, pixels(2)))
        assertNull(OsCallRules.avatarFor("dm", "Ada", 2, null))
        assertNull(OsCallRules.avatarFor("dm", "Ada", 2, ByteArray(15)))
        assertNull(OsCallRules.avatarFor("dm", "Ada", 2, ByteArray(17)))
        assertNull(OsCallRules.avatarFor("dm", "Ada", 0, ByteArray(0)))
        assertNull(OsCallRules.avatarFor("dm", "Ada", -2, pixels(2)))
        assertNotNull(OsCallRules.avatarFor("dm", "Ada", OsCallRules.AVATAR_MAX_SIDE, pixels(OsCallRules.AVATAR_MAX_SIDE)))
        val over = OsCallRules.AVATAR_MAX_SIDE + 1
        assertNull(OsCallRules.avatarFor("dm", "Ada", over, pixels(over)))
        // A side whose square overflows an Int never matches a real array.
        assertNull(OsCallRules.avatarFor("dm", "Ada", 46_341, ByteArray(4)))
    }

    @Test
    fun theHiddenTitleIsDartsHiddenTitle() {
        assertEquals("Hollow", OsCallRules.HIDDEN_TITLE)
    }

    // ---- a swiped-away call notification (Android 14+ lets the person dismiss a plain one) ----

    @Test
    fun aDismissedNotificationComesBackWhileTheServiceCarriesALook() {
        assertTrue(OsCallRules.repostsAfterDismiss(hasLook = true, foregroundTypes = 0x84))
        assertTrue(OsCallRules.repostsAfterDismiss(hasLook = true, foregroundTypes = -1))
        assertFalse(OsCallRules.repostsAfterDismiss(hasLook = false, foregroundTypes = 0x84))
        assertFalse(OsCallRules.repostsAfterDismiss(hasLook = true, foregroundTypes = 0))
    }

    @Test
    fun aRingOutAskedAgainWhileRingingIsReposted() {
        val r = RingOut()
        assertFalse(r.repost(sessionHeld = false))
        assertTrue(r.on(sessionHeld = false))
        assertTrue(r.repost(sessionHeld = false))
        assertFalse(r.repost(sessionHeld = true))
        r.onBegin()
        assertFalse(r.repost(sessionHeld = false))
    }

    @Test
    fun aRoomNeverCarriesAFace() {
        assertNotNull(OsCallRules.avatarFor(OsCallRules.DM, "Ada", 2, pixels(2)))
        assertNull(OsCallRules.avatarFor("room", "Lounge · Den", 2, pixels(2)))
        assertNull(OsCallRules.avatarFor("meeting", "Meeting with Ada", 2, pixels(2)))
        assertNull(OsCallRules.avatarFor(null, "Ada", 2, pixels(2)))
        assertNull(OsCallRules.avatarFor("DM", "Ada", 2, pixels(2)))
    }

    // R-AR-04 on the native side: once a call's or ring's title reads "Hollow", a later named
    // title (a Dart bug, a stale update) never brings the name, or with it the face, back.
    @Test
    fun aBlankedTitleNeverTakesBackItsName() {
        val t = TitleLatch()
        assertEquals("Ada", t.take("Ada"))
        assertEquals(OsCallRules.HIDDEN_TITLE, t.take(OsCallRules.HIDDEN_TITLE))
        assertEquals(OsCallRules.HIDDEN_TITLE, t.take("Ada"))
        assertTrue(t.blanked)
        assertNull(OsCallRules.avatarFor(OsCallRules.DM, t.take("Ada"), 2, pixels(2)))
        val blank = TitleLatch()
        assertEquals(OsCallRules.HIDDEN_TITLE, blank.take(" "))
        assertEquals(OsCallRules.HIDDEN_TITLE, blank.take("Ada"))
    }

    @Test
    fun aNewRingStartsItsTitleOver() {
        val r = RingOut()
        assertTrue(r.on(sessionHeld = false))
        assertEquals(OsCallRules.HIDDEN_TITLE, r.title.take(OsCallRules.HIDDEN_TITLE))
        assertEquals(OsCallRules.HIDDEN_TITLE, r.title.take("Ada"))
        assertTrue(r.off(sessionHeld = false))
        assertFalse(r.title.blanked)
        assertTrue(r.on(sessionHeld = false))
        assertEquals("Bob", r.title.take("Bob"))
    }
}
