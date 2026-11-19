package com.anonlisten.hollow

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/**
 * Poster stills for a video the person picked (video_thumbnail_service.dart), cut by
 * the platform decoder because phones ship no ffmpeg. Dart sends only files outside
 * the data root: an attachment there is ciphertext and is never copied out in plain.
 * Dart picks the frame from the sampled lumas, the same rule on every platform.
 *
 * Every call answers by its `deadlineMs` and runs on a thread of its own, so a file
 * that hangs the decoder costs one stuck thread, never the next poster. The stuck
 * retriever is released by its own thread when the decoder returns: the class is
 * not thread-safe, and release() racing a native frame call can take the process
 * down.
 */
object VideoPoster {
    const val CHANNEL = "hollow/video_poster"

    private val workers = Executors.newCachedThreadPool()
    private val watchdog = Executors.newSingleThreadScheduledExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            val path = call.argument<String>("path")
            val job: () -> Any? = when (call.method) {
                "sample" -> {
                    val times = call.argument<List<Number>>("timesMs").orEmpty().map { it.toLong() }
                    ({ sample(path!!, times) })
                }
                "frame" -> {
                    val atMs = call.argument<Number>("atMs")?.toLong() ?: 0L
                    val maxHeight = call.argument<Number>("maxHeight")?.toInt() ?: 480
                    ({ frame(path!!, atMs, maxHeight) })
                }
                else -> {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
            }
            if (path == null || !File(path).canRead()) {
                result.success(null)
                return@setMethodCallHandler
            }
            val deadlineMs = (call.argument<Number>("deadlineMs")?.toLong() ?: 4000L)
                .coerceIn(100L, 10_000L)
            val answered = AtomicBoolean(false)
            fun answer(value: Any?) {
                if (answered.compareAndSet(false, true)) main.post { result.success(value) }
            }
            val expiry = watchdog.schedule({ answer(null) }, deadlineMs, TimeUnit.MILLISECONDS)
            workers.execute {
                // A decoder failure (or an out-of-memory frame) is no poster, never a crash.
                val reply = try { job() } catch (e: Throwable) { null }
                expiry.cancel(false)
                answer(reply)
            }
        }
    }

    private fun <T> withRetriever(path: String, body: (MediaMetadataRetriever) -> T): T {
        val retriever = MediaMetadataRetriever()
        try {
            // By descriptor: the platform opens nothing else by name for us.
            FileInputStream(path).use { retriever.setDataSource(it.fd) }
            return body(retriever)
        } finally {
            try { retriever.release() } catch (e: Exception) {}
        }
    }

    /** Duration and displayed size. */
    private fun metadata(r: MediaMetadataRetriever): MutableMap<String, Any?> {
        fun meta(key: Int) = r.extractMetadata(key)?.toLongOrNull() ?: 0L
        val w = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
        val h = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
        val turned = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION) % 180 != 0L
        return mutableMapOf(
            "durationMs" to meta(MediaMetadataRetriever.METADATA_KEY_DURATION),
            "width" to (if (turned) h else w),
            "height" to (if (turned) w else h),
        )
    }

    /** Duration, displayed size, and one luma (0-255, or null) per time. */
    private fun sample(path: String, times: List<Long>): Map<String, Any?> = withRetriever(path) { r ->
        val out = metadata(r)
        val durationMs = out["durationMs"] as Long
        out["lumas"] = times.map { ms ->
            if (ms > 0 && durationMs > 0 && ms >= durationMs) {
                null
            } else {
                frameAt(r, ms, 32, 32)?.let { bitmap -> meanLuma(bitmap).also { bitmap.recycle() } }
            }
        }
        out
    }

    /** A JPEG no taller than [maxHeight] under "image", with the metadata, or null. */
    private fun frame(path: String, atMs: Long, maxHeight: Int): Map<String, Any?>? = withRetriever(path) { r ->
        val out = metadata(r)
        val bitmap = frameAt(r, atMs, maxHeight * 2, maxHeight) ?: return@withRetriever null
        val jpeg = ByteArrayOutputStream()
        val ok = bitmap.compress(Bitmap.CompressFormat.JPEG, 90, jpeg)
        bitmap.recycle()
        if (!ok) return@withRetriever null
        out["image"] = jpeg.toByteArray()
        out
    }

    /** The frame at [ms], shown upright and fitted inside maxW x maxH. */
    private fun frameAt(r: MediaMetadataRetriever, ms: Long, maxW: Int, maxH: Int): Bitmap? {
        val us = ms * 1000
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            return r.getScaledFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST, maxW, maxH)
        }
        val full = r.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST) ?: return null
        val scale = minOf(maxW.toFloat() / full.width, maxH.toFloat() / full.height)
        if (scale >= 1f) return full
        val scaled = Bitmap.createScaledBitmap(
            full, max(1, (full.width * scale).toInt()), max(1, (full.height * scale).toInt()), true)
        if (scaled !== full) full.recycle()
        return scaled
    }

    private fun meanLuma(bitmap: Bitmap): Double {
        val px = IntArray(bitmap.width * bitmap.height)
        if (px.isEmpty()) return 0.0
        bitmap.getPixels(px, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        var sum = 0.0
        for (c in px) {
            sum += 0.299 * ((c shr 16) and 0xFF) + 0.587 * ((c shr 8) and 0xFF) + 0.114 * (c and 0xFF)
        }
        return sum / px.size
    }
}
