package com.anonlisten.hollow

import com.anonlisten.hollow.RouteKind.BLUETOOTH
import com.anonlisten.hollow.RouteKind.EARPIECE
import com.anonlisten.hollow.RouteKind.SPEAKER
import com.anonlisten.hollow.RouteKind.WIRED

/** A call audio route, named as the fork's route picker names it (`AudioDeviceKind.typeName`). */
enum class RouteKind(val typeName: String) {
    EARPIECE("earpiece"),
    SPEAKER("speaker"),
    WIRED("wired-headset"),
    BLUETOOTH("bluetooth");

    companion object {
        fun fromTypeName(name: String?): RouteKind? = values().firstOrNull { it.typeName == name }
    }
}

/**
 * Where a route request lands while Telecom owns the call's audio (#154). Pure, so the
 * headset-wins rule is pinned by a JVM test: "loud" means the loudest SENSIBLE route, never the
 * phone's own speaker over a headset someone is wearing (memory feedback_mobile_call_audio_route).
 */
object AudioEndpointMapping {
    const val LOUD = "loud"
    const val QUIET = "earpiece"

    /**
     * [request] is [LOUD] (speaker on), [QUIET] (speaker off) or an exact route type name from the
     * picker; null = leave the route alone. Speaker off with a headset on stays on the headset,
     * as the fork's audioswitch path does today. An exact pick is honoured only when it exists.
     */
    fun forRequest(request: String, available: Collection<RouteKind>): RouteKind? {
        val exact = RouteKind.fromTypeName(request)
        return when {
            request == LOUD -> headset(available) ?: SPEAKER.takeIf { it in available }
            request == QUIET -> headset(available) ?: EARPIECE.takeIf { it in available }
            exact != null -> exact.takeIf { it in available }
            else -> null
        }
    }

    /** The route Telecom starts the call on: none while a headset is attached (Telecom picks it). */
    fun startingEndpoint(loud: Boolean, available: Collection<RouteKind>): RouteKind? {
        if (headset(available) != null) return null
        val wanted = if (loud) SPEAKER else EARPIECE
        return wanted.takeIf { it in available }
    }

    private fun headset(available: Collection<RouteKind>): RouteKind? = when {
        BLUETOOTH in available -> BLUETOOTH
        WIRED in available -> WIRED
        else -> null
    }
}
