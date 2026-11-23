package com.anonlisten.hollow

/** The bridge's decisions that need no Android types, so JVM tests pin them (#154). */
object OsCallRules {
    /** A session Telecom has not ADDED by then runs on the fallback (D5). Not "active": an
     *  answered DM can still take seconds to connect its media. */
    const val ADD_DEADLINE_MS = 2_000L

    /** The `kind` of the one session that may become a system call. */
    const val DM = "dm"

    /** Every Telecom call stays out of the phone's call history (R-AR-04). */
    const val LOG_EXCLUDED = true

    /** How long an OS hang-up waits for Dart's `end` before it asks again. */
    const val OS_HANG_UP_WAIT_MS = 3_000L

    /**
     * Only an answered DM call becomes a Telecom call: the system has no call screen for a room,
     * so a voice room or meeting runs in the app, on the call service and its CallStyle alone. An
     * unknown kind stays in the app too.
     */
    fun offersTelecom(kind: String?, registered: Boolean, hasFeature: Boolean, forcedFallback: Boolean): Boolean =
        kind == DM && registered && hasFeature && !forcedFallback

    /**
     * The calls to end when [beginning] begins: every other one held. The bridge runs one call at
     * a time, so this also drops any held call outside Dart's `live` set (one whose end was lost).
     */
    fun endAtBegin(held: List<String>, beginning: String): List<String> =
        held.filter { it != beginning }

    /** Only a begun session's notification is a CallStyle call; a ring-out's is a plain one. */
    fun showsAsCall(look: CallLook): Boolean = !look.ringing

    /**
     * The foreground types to try, in order: phoneCall + microphone, then phoneCall alone (the
     * microphone type is the one Android refuses from the background), then microphone alone.
     */
    fun foregroundAttempts(phoneCall: Int, microphone: Int, micAllowed: Boolean): List<Int> {
        val mic = if (micAllowed) microphone else 0
        return listOf(phoneCall or mic, phoneCall, mic).filter { it != 0 }.distinct()
    }

    /**
     * Whether every refused type ends the service: only on its first start. A refused microphone
     * upgrade keeps the phoneCall foreground the call already runs on.
     */
    fun finishWhenRefused(upgrade: Boolean): Boolean = !upgrade

    /** Dart's `kHiddenNotificationTitle`: the title of a call whose name may not show. */
    const val HIDDEN_TITLE = "Hollow"

    /** The largest avatar side Dart sends; a call notification shows it at about 64 dp. */
    const val AVATAR_MAX_SIDE = 256

    /**
     * The avatar the notification may show: raw RGBA pixels Dart drew (never peer-encoded bytes,
     * so no Android decoder sees them), exactly [side] squared, and only beside a name. A hidden
     * title hides the face too (HOL-SEC-155), whatever Dart sent.
     */
    fun avatarFor(title: String, side: Int?, rgba: ByteArray?): CallAvatar? {
        if (side == null || rgba == null) return null
        if (title.isBlank() || title == HIDDEN_TITLE) return null
        if (side !in 1..AVATAR_MAX_SIDE || rgba.size != side * side * 4) return null
        return CallAvatar(side, rgba)
    }

    /**
     * Whether a notification the person swiped away is posted again. Android 14+ lets a plain
     * foreground-service notification (the ring-out's) be dismissed whatever `setOngoing` says;
     * while the service still carries a call or ring it comes back.
     */
    fun repostsAfterDismiss(hasLook: Boolean, foregroundTypes: Int): Boolean =
        hasLook && foregroundTypes != 0
}

/** A square avatar as premultiplied RGBA bytes, row by row ([OsCallRules.avatarFor]). */
class CallAvatar(val side: Int, val rgba: ByteArray)

/**
 * A call we place keeps the call service up while it rings out (Dart's `ringOut`), with no OS
 * call: the microphone foreground type cannot be taken from the background, and the answer may
 * find the app there. Once a session begins, the service belongs to it.
 */
class RingOut {
    var ringing = false
        private set

    /** Ring-out started. True = start the call service. */
    fun on(sessionHeld: Boolean): Boolean {
        if (sessionHeld || ringing) return false
        ringing = true
        return true
    }

    /** Ring-out over (answered, cancelled, declined). True = stop the call service. */
    fun off(sessionHeld: Boolean): Boolean {
        if (!ringing) return false
        ringing = false
        return !sessionHeld
    }

    /** Ring-out asked again with a new look (its name blanked). True = re-post the notification. */
    fun repost(sessionHeld: Boolean): Boolean = ringing && !sessionHeld

    /** A session began: it takes the running service over. */
    fun onBegin() {
        ringing = false
    }
}

/** One begun uuid's path: Telecom (pending, then added), the fallback, or ended. */
class OsCallSession(val uuid: String, telecomOffered: Boolean) {
    enum class Path { TELECOM_PENDING, TELECOM, HUNG_UP, FALLBACK, ENDED }

    var path = if (telecomOffered) Path.TELECOM_PENDING else Path.FALLBACK
        private set

    /** Telecom added the call. False = too late (fallback or ended): disconnect it. */
    fun onAdded(): Boolean {
        if (path != Path.TELECOM_PENDING) return false
        path = Path.TELECOM
        return true
    }

    /** The add deadline passed. True = fall back now. */
    fun onDeadline(): Boolean {
        if (path != Path.TELECOM_PENDING) return false
        path = Path.FALLBACK
        return true
    }

    /**
     * The person hung up from the OS (lock screen, headset, car). True = tell Dart. Such a call
     * never falls back: it ends with Dart's `end`, never carries on with no OS surface.
     */
    fun onOsHangUp(): Boolean {
        if (path != Path.TELECOM) return false
        path = Path.HUNG_UP
        return true
    }

    /** addCall failed or its scope ended while the session lives. True = fall back now. */
    fun onTelecomLost(): Boolean {
        if (path != Path.TELECOM_PENDING && path != Path.TELECOM) return false
        path = Path.FALLBACK
        return true
    }

    /** True only for the first end. */
    fun end(): Boolean {
        if (path == Path.ENDED) return false
        path = Path.ENDED
        return true
    }
}

/**
 * The app's mute against Telecom's, which IS the global mic mute (spike D2): a headset, car or
 * watch mute arrives as Telecom's mute, and the app's own mute is written to the global one so
 * every surface shows the truth and an in-app unmute after a headset mute is heard. The global
 * mute also covers a carrier call, so while one holds ours nothing is written or mirrored.
 */
class MuteMirror {
    var appMuted = false
        private set
    private var held = false
    private var wroteMute = false
    private var telecomMuted = false

    /** The app's `setMuted`. Returns the global mic mute to write, or null to leave it. */
    fun fromApp(muted: Boolean, telecomLive: Boolean, globalNow: Boolean): Boolean? {
        appMuted = muted
        if (!telecomLive || held || globalNow == muted) return null
        if (muted) wroteMute = true
        return muted
    }

    enum class Telecom { NONE, TELL, REALIGN }

    /**
     * Telecom's mute changed. A value the app already holds is our own echo (NONE). While
     * [settling] (just added) a difference can predate our alignment write, and the app is the
     * truth then: REALIGN writes the app's mute again. Otherwise TELL the app (a headset or car).
     */
    fun fromTelecom(muted: Boolean, settling: Boolean): Telecom {
        if (held || muted == appMuted) return Telecom.NONE
        if (settling) return Telecom.REALIGN
        if (muted) telecomMuted = true
        return Telecom.TELL
    }

    /**
     * Telecom held or resumed our call; returns the global mute to write, or null. A hold for a
     * carrier call lifts a global mute our call set (it would mute that call too); the resume puts
     * the app's mute back, as fromApp.
     */
    fun onHold(held: Boolean, telecomLive: Boolean, globalNow: Boolean): Boolean? {
        if (held) {
            this.held = true
            return if (globalNow && (wroteMute || telecomMuted)) false else null
        }
        this.held = false
        return fromApp(appMuted, telecomLive, globalNow)
    }

    /** At the end: true = clear the global mute, when our call (or its Telecom side) set it. */
    fun clearAtEnd(globalNow: Boolean): Boolean = !held && globalNow && (wroteMute || telecomMuted)
}
