package com.anonlisten.hollow

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.telecom.DisconnectCause
import android.util.Log
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlResult
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallEndpointCompat
import androidx.core.telecom.CallsManager
import com.cloudwebrtc.webrtc.CallForegroundService
import com.cloudwebrtc.webrtc.audio.AudioSwitchManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The OS call session on Android (#154, DESIGN_OS_CALLS 3): the `hollow/os_call` channel, one
 * core-telecom call mirroring the app's answered DM call, and [HollowCallService] for every
 * session's lifetime (DM, voice room or meeting). One call at a time, everything on the main
 * thread. A session Telecom does not carry (a room or meeting, no telecom feature, registration
 * refused, addCall failed or not added in 2 s, a debug-forced fallback) runs as before Telecom
 * existed: audioswitch owns the audio, the service and its CallStyle still run, and Dart hears
 * `{ok: false}` or `osFailed`.
 *
 * Registered from MainActivity only, so a background engine (an FCM wake) never gets one.
 */
object OsCallBridge {
    private const val TAG = "HollowOsCall"

    /** Telecom mute values this soon after the add may predate our alignment write. */
    private const val MUTE_SETTLE_MS = 1_000L

    private val main = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var app: Context? = null
    private var calls: CallsManager? = null
    private var registered = false
    private var debuggable = false
    private var forcedFallback = false
    private var channel: MethodChannel? = null

    /** The last call's Telecom teardown: the next addCall waits for it. */
    private var teardown: Job? = null

    private class Call(
        val uuid: String,
        var title: String,
        var avatar: CallAvatar?,
        val video: Boolean,
        val loud: Boolean,
        telecom: Boolean,
    ) {
        val session = OsCallSession(uuid, telecom)
        val mute = MuteMirror()
        var control: CallControlScope? = null
        var job: Job? = null
        var current: CallEndpointCompat? = null
        var endpoints: List<CallEndpointCompat> = emptyList()
        var pendingRoute: String? = null
        var wantActive = false
        var held = false
        var connectedAt: Long? = null
        var addedAt = 0L

        val telecomLive get() = control != null && session.path == OsCallSession.Path.TELECOM
        fun look() = CallLook(title, mute.appMuted, connectedAt, avatar = avatar)
    }

    private var call: Call? = null
    private val ringOut = RingOut()

    fun attach(context: Context, messenger: BinaryMessenger) {
        app = context.applicationContext
        debuggable = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        register()
        channel = MethodChannel(messenger, "hollow/os_call").also { ch ->
            ch.setMethodCallHandler { c, result ->
                try {
                    result.success(handle(c))
                } catch (e: Exception) {
                    Log.w(TAG, "${c.method} failed: $e")
                    result.error("os_call", e.javaClass.simpleName, null)
                }
            }
        }
    }

    /** The activity's engine is going: every OS call goes with it (no ghost call, A2-6). */
    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        endAll("engine detached")
        CallForegroundService.appOwnsCallService = false
    }

    /** Ends whatever the bridge holds; Dart is not asked (its engine is gone or going). */
    fun endAll(why: String) {
        if (ringOut.off(sessionHeld = call != null)) HollowCallService.stop()
        val c = call ?: return
        Log.i(TAG, "ending ${c.uuid}: $why")
        endCall(c.uuid, "local")
    }

    /** Back in the foreground (a permission dialog closed, the app reopened): N7's mic upgrade. */
    fun onForeground() {
        if (call != null) HollowCallService.addMicIfGranted()
    }

    private fun handle(c: MethodCall): Any? {
        val uuid = c.argument<String>("uuid")
        return when (c.method) {
            "available" -> available(c.argument<Boolean>("forceFallback") == true)
            "begin" -> begin(
                uuid ?: return mapOf("ok" to false),
                c.argument<String>("kind"),
                c.argument<String>("title") ?: OsCallRules.HIDDEN_TITLE,
                c,
                c.argument<Boolean>("video") ?: false,
                c.argument<Boolean>("loud") ?: true,
            )
            "ringOut" -> {
                val title = c.argument<String>("title") ?: OsCallRules.HIDDEN_TITLE
                ringOut(c.argument<Boolean>("on") == true, title, avatarOf(title, c)); null
            }
            "connected" -> { connected(uuid); null }
            "setMuted" -> { setMuted(uuid, c.argument<Boolean>("muted") ?: false); null }
            "requestUnhold" -> { requestUnhold(uuid); null }
            "update" -> { update(uuid, c.argument<String>("title"), c); null }
            "end" -> { if (uuid != null) endCall(uuid, c.argument<String>("reason") ?: "local"); null }
            else -> null
        }
    }

    // Every look carries its avatar afresh: one left out of a call is gone from the notification.
    private fun avatarOf(title: String, c: MethodCall): CallAvatar? =
        OsCallRules.avatarFor(title, c.argument<Int>("avatarSide"), c.argument<ByteArray>("avatar"))

    @SuppressLint("MissingPermission")
    private fun register() {
        val ctx = app ?: return
        if (registered || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            calls = CallsManager(ctx).also {
                it.registerAppWithTelecom(
                    CallsManager.CAPABILITY_BASELINE or CallsManager.CAPABILITY_SUPPORTS_VIDEO_CALLING)
            }
            registered = true
        } catch (e: Exception) {
            Log.w(TAG, "Telecom registration refused: $e")
        }
    }

    private fun hasTelecomFeature(ctx: Context): Boolean {
        val pm = ctx.packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.hasSystemFeature(PackageManager.FEATURE_TELECOM)
        } else {
            @Suppress("DEPRECATION")
            pm.hasSystemFeature(PackageManager.FEATURE_CONNECTION_SERVICE)
        }
    }

    private fun offersTelecom(kind: String?): Boolean {
        val ctx = app ?: return false
        return OsCallRules.offersTelecom(kind, registered, hasTelecomFeature(ctx), forcedFallback || debugPropFallback())
    }

    // Debug builds only: `adb shell setprop debug.hollow.os_call_fallback 1` runs the next sessions
    // on the fallback without a rebuild (the device checks of session A's (b)). Nothing is exported.
    private fun debugPropFallback(): Boolean {
        if (!debuggable) return false
        return try {
            val p = ProcessBuilder("getprop", "debug.hollow.os_call_fallback").redirectErrorStream(true).start()
            val value = p.inputStream.bufferedReader().use { it.readText() }.trim()
            p.waitFor()
            value == "1"
        } catch (e: Exception) {
            false
        }
    }

    // Dart's service calls this first: from then on the app's service, not the fork's, holds the
    // call foreground service (a build without the Dart side keeps the fork's). The forced
    // fallback is the debug override for the fallback checks (rev 4); release builds ignore it.
    private fun available(forceFallback: Boolean): Boolean {
        if (forceFallback && debuggable) forcedFallback = true
        CallForegroundService.appOwnsCallService = true
        return offersTelecom(OsCallRules.DM)
    }

    // No OS call while a call we place rings: only the call service, so the mic can be
    // taken while the app is still in front.
    private fun ringOut(on: Boolean, title: String, avatar: CallAvatar?) {
        val ctx = app ?: return
        if (on) {
            val look = CallLook(title, muted = false, connectedAt = null, ringing = true, avatar = avatar)
            if (ringOut.on(sessionHeld = call != null)) {
                HollowCallService.start(ctx, look)
                debugStatus("ring-out")
            } else if (ringOut.repost(sessionHeld = call != null)) {
                HollowCallService.update(look)
            }
        } else if (ringOut.off(sessionHeld = call != null)) {
            HollowCallService.stop()
            debugStatus("ring-out end")
        }
    }

    private fun begin(
        uuid: String,
        kind: String?,
        title: String,
        args: MethodCall,
        video: Boolean,
        loud: Boolean,
    ): Map<String, Boolean> {
        val ctx = app ?: return mapOf("ok" to false)
        call?.let { held ->
            if (held.uuid == uuid) return mapOf("ok" to (held.session.path != OsCallSession.Path.FALLBACK))
        }
        for (stale in OsCallRules.endAtBegin(listOfNotNull(call?.uuid), uuid)) endCall(stale, "local")
        val telecom = offersTelecom(kind)
        val c = Call(uuid, title, avatarOf(title, args), video, loud, telecom)
        call = c
        ringOut.onBegin()
        HollowCallService.start(ctx, c.look())
        if (!telecom) {
            Log.i(TAG, if (kind == OsCallRules.DM) "begin $uuid on the fallback (telecom unavailable or forced)"
                else "begin $uuid: a $kind runs in the app")
            debugStatus("begin-fallback")
            return mapOf("ok" to false)
        }
        AudioSwitchManager.takeAudioForTelecom(router)
        val waitFor = teardown
        c.job = main.launch { addCall(c, waitFor) }
        main.launch {
            delay(OsCallRules.ADD_DEADLINE_MS)
            if (call === c && c.session.onDeadline()) fallBack(c, "not added in ${OsCallRules.ADD_DEADLINE_MS} ms")
        }
        debugStatus("begin")
        return mapOf("ok" to true)
    }

    @SuppressLint("MissingPermission")
    private suspend fun addCall(c: Call, waitFor: Job?) {
        val manager = calls ?: return
        waitFor?.join()
        try {
            val attributes = CallAttributesCompat(
                c.title,
                Uri.parse("hollow:${c.uuid}"),
                CallAttributesCompat.DIRECTION_OUTGOING,
                if (c.video) CallAttributesCompat.CALL_TYPE_VIDEO_CALL else CallAttributesCompat.CALL_TYPE_AUDIO_CALL,
                CallAttributesCompat.SUPPORTS_SET_INACTIVE,
                startingEndpoint(manager, c.loud),
                OsCallRules.LOG_EXCLUDED,
            )
            manager.addCall(
                attributes,
                onAnswer = { },
                onDisconnect = { cause ->
                    Log.i(TAG, "Telecom ended ${c.uuid} (${cause.code})")
                    if (call === c && c.session.onOsHangUp()) send("osEnd", mapOf("uuid" to c.uuid))
                },
                onSetActive = { if (call === c) setHeld(c, false) },
                onSetInactive = { if (call === c) setHeld(c, true) },
            ) { onAdded(c, this) }
            // The Telecom call is over. After an OS hang-up Dart ends the session; one it has not
            // ended in time is asked again and loses its Telecom audio, never falls back (it would
            // carry on with no OS surface). Any other loss runs on the fallback.
            if (call === c) {
                if (c.session.path == OsCallSession.Path.HUNG_UP) {
                    delay(OsCallRules.OS_HANG_UP_WAIT_MS)
                    if (call === c) afterUnansweredHangUp(c)
                } else if (c.session.onTelecomLost()) {
                    fallBack(c, "Telecom call ended")
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "addCall failed for ${c.uuid}: $e")
            if (call === c && c.session.onTelecomLost()) fallBack(c, "addCall failed: ${e.javaClass.simpleName}")
        }
    }

    // Phase 1's start route, handed to Telecom so it starts there (spike D5: core-telecom may
    // otherwise move a call off the speaker at start). Best effort: no answer = Telecom decides.
    private suspend fun startingEndpoint(manager: CallsManager, loud: Boolean): CallEndpointCompat? = try {
        withTimeoutOrNull(300) { manager.getAvailableStartingCallEndpoints().first() }?.let { list ->
            val pick = AudioEndpointMapping.startingEndpoint(loud, list.mapNotNull { kindOf(it) })
            if (pick == null) null else list.firstOrNull { kindOf(it) == pick }
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }

    private fun onAdded(c: Call, scope: CallControlScope) {
        if (call !== c || !c.session.onAdded()) {
            scope.launch { scope.disconnect(DisconnectCause(DisconnectCause.LOCAL)) }
            return
        }
        c.control = scope
        c.addedAt = SystemClock.elapsedRealtime()
        Log.i(TAG, "Telecom added ${c.uuid}")
        writeGlobalMute(c.mute.fromApp(c.mute.appMuted, c.telecomLive, globalMute()))
        if (c.wantActive) scope.launch { scope.setActive() }
        scope.launch {
            scope.currentCallEndpoint.collect {
                c.current = it
                AudioSwitchManager.instance?.notifyRouteChanged()
                debugStatus("route")
            }
        }
        scope.launch {
            scope.availableEndpoints.collect { list ->
                c.endpoints = list
                c.pendingRoute?.let { pending ->
                    c.pendingRoute = null
                    applyRoute(c, pending)
                }
                AudioSwitchManager.instance?.notifyRouteChanged()
            }
        }
        scope.launch {
            scope.isMuted.collect { muted ->
                if (call !== c) return@collect
                val settling = SystemClock.elapsedRealtime() - c.addedAt < MUTE_SETTLE_MS
                when (c.mute.fromTelecom(muted, settling)) {
                    MuteMirror.Telecom.TELL -> send("osMute", mapOf("uuid" to c.uuid, "muted" to muted))
                    MuteMirror.Telecom.REALIGN ->
                        writeGlobalMute(c.mute.fromApp(c.mute.appMuted, c.telecomLive, globalMute()))
                    MuteMirror.Telecom.NONE -> {}
                }
            }
        }
        debugStatus("added")
    }

    private fun setHeld(c: Call, held: Boolean) {
        if (c.held == held) return
        c.held = held
        writeGlobalMute(c.mute.onHold(held, c.telecomLive, globalMute()))
        send("osHold", mapOf("uuid" to c.uuid, "held" to held))
        debugStatus(if (held) "held" else "resumed")
    }

    // The session goes on without Telecom: audioswitch takes the audio as it would have, a global
    // mute our Telecom call set is lifted (no one else would), a hold ends (nothing could resume
    // it now) and Dart marks the key unmirrored.
    private fun fallBack(c: Call, why: String) {
        Log.w(TAG, "${c.uuid} falls back: $why")
        c.job?.cancel()
        clearGlobalMute(c)
        c.control = null
        if (c.held) setHeld(c, false)
        AudioSwitchManager.releaseAudioFromTelecom(true)
        send("osFailed", mapOf("uuid" to c.uuid, "why" to why))
        debugStatus("fallback")
    }

    private fun afterUnansweredHangUp(c: Call) {
        Log.w(TAG, "${c.uuid} hung up from the OS, Dart has not ended it: asking again")
        c.job?.cancel()
        clearGlobalMute(c)
        c.control = null
        AudioSwitchManager.releaseAudioFromTelecom(false)
        send("osEnd", mapOf("uuid" to c.uuid))
        debugStatus("hang-up again")
    }

    private fun connected(uuid: String?) {
        val c = callFor(uuid) ?: return
        if (c.connectedAt == null) c.connectedAt = System.currentTimeMillis()
        HollowCallService.update(c.look())
        c.wantActive = true
        c.control?.let { scope -> main.launch { scope.setActive() } }
        debugStatus("connected")
    }

    private fun setMuted(uuid: String?, muted: Boolean) {
        val c = callFor(uuid) ?: return
        writeGlobalMute(c.mute.fromApp(muted, c.telecomLive, globalMute()))
        HollowCallService.update(c.look())
        debugStatus(if (muted) "muted" else "unmuted")
    }

    // Telecom never resumes a call it put on hold for a carrier call (spike D3), and it raises
    // onSetActive only for its own requests: our setActive succeeding IS the resume.
    private fun requestUnhold(uuid: String?) {
        val c = callFor(uuid) ?: return
        val scope = c.control ?: return
        if (!c.held) return
        main.launch {
            val result = scope.setActive()
            if (result is CallControlResult.Success && call === c) setHeld(c, false)
        }
    }

    // Only the CallStyle can be renamed: core-telecom 1.1.0 has no way to change a live call's
    // display name, so a headset or car keeps the name it was given at begin.
    private fun update(uuid: String?, title: String?, args: MethodCall) {
        val c = callFor(uuid) ?: return
        if (title != null) c.title = title
        c.avatar = avatarOf(c.title, args)
        HollowCallService.update(c.look())
    }

    private fun endCall(uuid: String, reason: String) {
        val c = call ?: return
        if (c.uuid != uuid) return
        val wasTelecom = c.session.path == OsCallSession.Path.TELECOM_PENDING ||
            c.session.path == OsCallSession.Path.TELECOM || c.session.path == OsCallSession.Path.HUNG_UP
        if (!c.session.end()) return
        call = null
        clearGlobalMute(c)
        if (wasTelecom) AudioSwitchManager.releaseAudioFromTelecom(false)
        HollowCallService.stop()
        val scope = c.control
        c.control = null
        teardown = main.launch {
            if (scope != null) {
                val code = when (reason) {
                    "remote" -> DisconnectCause.REMOTE
                    "failed" -> DisconnectCause.ERROR
                    else -> DisconnectCause.LOCAL
                }
                try {
                    scope.disconnect(DisconnectCause(code))
                } catch (e: Exception) {
                    Log.w(TAG, "disconnect failed: $e")
                }
            }
            c.job?.cancel()
        }
        Log.i(TAG, "ended $uuid ($reason)")
        debugStatus("end")
    }

    private fun globalMute(): Boolean = audio()?.isMicrophoneMute ?: false

    private fun writeGlobalMute(value: Boolean?) {
        if (value != null) audio()?.isMicrophoneMute = value
    }

    private fun clearGlobalMute(c: Call) {
        if (c.mute.clearAtEnd(globalMute())) writeGlobalMute(false)
    }

    private fun callFor(uuid: String?): Call? = call?.takeIf { it.uuid == uuid }

    /** The notification's hang-up: the app's own end path decides (1.4). */
    fun onUserHangUp() {
        val c = call
        if (c != null) send("osEnd", mapOf("uuid" to c.uuid))
        else if (ringOut.ringing) send("osRingOutEnd", null)
    }

    /** The notification's mute button: the app's own toggle decides and answers with setMuted. */
    fun onUserToggleMute() {
        val c = call ?: return
        send("osMute", mapOf("uuid" to c.uuid, "muted" to !c.mute.appMuted))
    }

    private val router = object : AudioSwitchManager.TelecomAudio {
        override fun requestRoute(request: String) {
            val c = call ?: return
            if (c.control == null || c.endpoints.isEmpty()) {
                c.pendingRoute = request
                return
            }
            applyRoute(c, request)
        }

        override fun currentRoute(): String? = call?.current?.let { kindOf(it)?.typeName }
    }

    private fun applyRoute(c: Call, request: String) {
        val scope = c.control ?: return
        val target = AudioEndpointMapping.forRequest(request, c.endpoints.mapNotNull { kindOf(it) }) ?: return
        if (c.current?.let { kindOf(it) } == target) return
        val endpoint = c.endpoints.firstOrNull { kindOf(it) == target } ?: return
        main.launch {
            val result = scope.requestEndpointChange(endpoint)
            Log.i(TAG, "route $request -> ${target.typeName}: ${result.javaClass.simpleName}")
        }
    }

    private fun kindOf(e: CallEndpointCompat): RouteKind? = when (e.type) {
        CallEndpointCompat.TYPE_EARPIECE -> RouteKind.EARPIECE
        CallEndpointCompat.TYPE_SPEAKER -> RouteKind.SPEAKER
        CallEndpointCompat.TYPE_WIRED_HEADSET -> RouteKind.WIRED
        CallEndpointCompat.TYPE_BLUETOOTH -> RouteKind.BLUETOOTH
        else -> null
    }

    private fun send(method: String, args: Any?) {
        main.launch { channel?.invokeMethod(method, args) }
    }

    private fun audio(): AudioManager? = app?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    // Debug builds only: one line per transition for the emulator and Pixel checks. Names nothing.
    private fun debugStatus(event: String) {
        if (!debuggable) return
        val am = audio() ?: return
        val c = call
        val recs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            am.activeRecordingConfigurations.joinToString { if (it.isClientSilenced) "silenced" else "live" }
        } else "n/a"
        Log.i(TAG, "STATUS $event mode=${am.mode} micMute=${am.isMicrophoneMute} path=${c?.session?.path} " +
            "route=${c?.current?.let { kindOf(it)?.typeName }} held=${c?.held} " +
            "fgs=${HollowCallService.grantedTypes} telecomAudio=${AudioSwitchManager.telecomOwnsAudio()} " +
            "forkFgsOff=${CallForegroundService.appOwnsCallService} recs=[$recs]")
    }
}
