package com.anonlisten.hollow

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The bundled UI sound pack (#55) and the outgoing ringback on Android, over `hollow/sfx`.
 *
 * Not audioplayers: audioplayers_android writes the GLOBAL `AudioManager.mode` (MODE_NORMAL)
 * and `isSpeakerphoneOn = false` whenever a player's audio context is applied, which takes a
 * live call out of MODE_IN_COMMUNICATION and pulls a speaker call back to the earpiece (#154).
 * The rule here: never touch AudioManager (mode, speakerphone, communication device) and never
 * request or abandon audio focus. A MediaPlayer only mixes into the route that is live.
 *
 * A cue while the phone is in call mode plays as call signalling, so it follows the call's
 * route and volume (at the ear on an earpiece call); otherwise it keeps the media attributes
 * the audioplayers cues used. The ringback always keeps media: it plays while dialling, before
 * the call picks its route.
 */
object HollowSfx {
    private val mediaAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()

    private val callAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    private lateinit var appContext: Context

    // One player per asset and attributes, kept and restarted from the top. Calls arrive one at
    // a time on the platform thread, so a cue during a player's setup cannot build a second one.
    private val players = HashMap<String, MediaPlayer>()
    private var loop: MediaPlayer? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        MethodChannel(messenger, "hollow/sfx").setMethodCallHandler { call, result ->
            val asset = call.argument<String>("asset") ?: ""
            val volume = (call.argument<Number>("volume") ?: 1.0).toFloat()
            when (call.method) {
                "play" -> { play(asset, volume); result.success(null) }
                "startLoop" -> { startLoop(asset, volume); result.success(null) }
                "stopLoop" -> { stopLoop(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun play(asset: String, volume: Float) {
        val attributes = if (inCallMode()) callAttributes else mediaAttributes
        val key = "${attributes.usage}|$asset"
        val player = players[key] ?: newPlayer(asset, attributes, key, looping = false)
            ?.also { players[key] = it } ?: return
        try {
            player.setVolume(volume, volume)
            player.seekTo(0)
            player.start()
        } catch (e: IllegalStateException) {
            // A player in its error state: drop it, the next cue builds a fresh one.
            players.remove(key)
            player.release()
        }
    }

    // Reads the mode only; this class never sets it.
    private fun inCallMode(): Boolean {
        val audio = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
        val mode = audio.mode
        return mode == AudioManager.MODE_IN_COMMUNICATION || mode == AudioManager.MODE_IN_CALL
    }

    private fun startLoop(asset: String, volume: Float) {
        stopLoop()
        val player = newPlayer(asset, mediaAttributes, null, looping = true) ?: return
        try {
            player.setVolume(volume, volume)
            player.start()
            loop = player
        } catch (e: IllegalStateException) {
            player.release()
        }
    }

    private fun stopLoop() {
        val player = loop ?: return
        loop = null
        try {
            player.stop()
        } catch (e: IllegalStateException) {
        }
        player.release()
    }

    private fun newPlayer(
        asset: String,
        attributes: AudioAttributes,
        key: String?,
        looping: Boolean,
    ): MediaPlayer? {
        val player = MediaPlayer()
        return try {
            player.setAudioAttributes(attributes)
            setSource(player, asset)
            player.isLooping = looping
            player.setOnErrorListener { mp, _, _ ->
                if (key != null && players[key] === mp) players.remove(key)
                if (loop === mp) loop = null
                mp.release()
                true
            }
            player.prepare()
            player
        } catch (e: Exception) {
            player.release()
            null
        }
    }

    private fun setSource(player: MediaPlayer, asset: String) {
        val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(asset)
        try {
            appContext.assets.openFd(key).use { fd ->
                player.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
            }
        } catch (e: java.io.FileNotFoundException) {
            // openFd refuses an asset stored compressed: play a cached copy instead.
            val copy = File(appContext.cacheDir, "hollow_sfx/" + key.substringAfterLast('/'))
            if (!copy.exists()) {
                copy.parentFile?.mkdirs()
                // Renamed into place whole, so a copy cut short is never played.
                val part = File(copy.path + ".part")
                appContext.assets.open(key).use { input ->
                    part.outputStream().use { input.copyTo(it) }
                }
                part.renameTo(copy)
            }
            player.setDataSource(copy.path)
        }
    }
}
