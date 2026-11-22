package com.anonlisten.hollow

import com.anonlisten.hollow.RouteKind.BLUETOOTH
import com.anonlisten.hollow.RouteKind.EARPIECE
import com.anonlisten.hollow.RouteKind.SPEAKER
import com.anonlisten.hollow.RouteKind.WIRED
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AudioEndpointMappingTest {
    private val builtIn = listOf(EARPIECE, SPEAKER)

    @Test
    fun loudWithOnlyBuiltInRoutesIsTheSpeaker() {
        assertEquals(SPEAKER, AudioEndpointMapping.forRequest("loud", builtIn))
    }

    @Test
    fun loudNeverBeatsAHeadset() {
        assertEquals(WIRED, AudioEndpointMapping.forRequest("loud", builtIn + WIRED))
        assertEquals(BLUETOOTH, AudioEndpointMapping.forRequest("loud", builtIn + BLUETOOTH))
    }

    @Test
    fun bluetoothWinsOverWiredWhenBothAreThere() {
        assertEquals(BLUETOOTH, AudioEndpointMapping.forRequest("loud", listOf(WIRED, SPEAKER, BLUETOOTH)))
        assertEquals(BLUETOOTH, AudioEndpointMapping.forRequest("earpiece", listOf(WIRED, EARPIECE, BLUETOOTH)))
    }

    @Test
    fun earpieceIsTheEarpieceUnlessAHeadsetIsOn() {
        assertEquals(EARPIECE, AudioEndpointMapping.forRequest("earpiece", builtIn))
        assertEquals(WIRED, AudioEndpointMapping.forRequest("earpiece", builtIn + WIRED))
    }

    @Test
    fun earpieceOnATabletChangesNothing() {
        assertNull(AudioEndpointMapping.forRequest("earpiece", listOf(SPEAKER)))
    }

    @Test
    fun loudWithNoSpeakerChangesNothing() {
        assertNull(AudioEndpointMapping.forRequest("loud", listOf(EARPIECE)))
    }

    @Test
    fun anExactPickIsHonouredOnlyWhenItExists() {
        assertEquals(SPEAKER, AudioEndpointMapping.forRequest("speaker", builtIn + WIRED))
        assertEquals(EARPIECE, AudioEndpointMapping.forRequest("earpiece", listOf(EARPIECE)))
        assertNull(AudioEndpointMapping.forRequest("bluetooth", builtIn))
        assertEquals(WIRED, AudioEndpointMapping.forRequest("wired-headset", builtIn + WIRED + BLUETOOTH))
        assertNull(AudioEndpointMapping.forRequest("nonsense", builtIn))
    }

    @Test
    fun aCallStartsOnTheSpeakerWhenLoudAndNoHeadset() {
        assertEquals(SPEAKER, AudioEndpointMapping.startingEndpoint(loud = true, available = builtIn))
        assertEquals(EARPIECE, AudioEndpointMapping.startingEndpoint(loud = false, available = builtIn))
    }

    @Test
    fun aHeadsetLeavesTheStartToTelecom() {
        assertNull(AudioEndpointMapping.startingEndpoint(loud = true, available = builtIn + WIRED))
        assertNull(AudioEndpointMapping.startingEndpoint(loud = false, available = builtIn + BLUETOOTH))
    }

    @Test
    fun noStartingEndpointWhenTheWantedOneIsMissing() {
        assertNull(AudioEndpointMapping.startingEndpoint(loud = false, available = listOf(SPEAKER)))
        assertNull(AudioEndpointMapping.startingEndpoint(loud = true, available = emptyList()))
    }

    @Test
    fun typeNamesMatchTheForkAndRoundTrip() {
        assertEquals("bluetooth", BLUETOOTH.typeName)
        assertEquals("wired-headset", WIRED.typeName)
        assertEquals("speaker", SPEAKER.typeName)
        assertEquals("earpiece", EARPIECE.typeName)
        for (kind in RouteKind.values()) assertEquals(kind, RouteKind.fromTypeName(kind.typeName))
        assertNull(RouteKind.fromTypeName(null))
    }
}
