package com.cloudwebrtc.webrtc.audio;

import android.annotation.SuppressLint;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioPlaybackCaptureConfiguration;
import android.media.AudioRecord;
import android.media.projection.MediaProjection;
import android.os.Build;
import android.util.Log;

import androidx.annotation.RequiresApi;

/**
 * Hollow fork: system-audio capturer for SENT screen-share audio on Android.
 *
 * The send-side mirror of {@link ScreenAudioPlayer}: taps other apps' playback
 * via {@link AudioPlaybackCaptureConfiguration} (API 29+) during the active
 * MediaProjection session — the SAME projection instance the screen-video
 * capturer owns (Android 14 forbids creating a second projection from the same
 * permission grant). Raw PCM chunks are handed to {@link PcmSink} on the main
 * thread; Dart Opus-encodes them in Rust and ships 0x03 data-channel frames.
 *
 * <p>This path is fully INDEPENDENT of the mic: the call's voice capture keeps
 * running untouched, so the user talks over the shared audio (Discord parity).
 * It also bypasses the voice-comm AEC/AGC processing that mangles music.
 *
 * <p>Format matches every other screen-audio hop: interleaved 48 kHz stereo
 * signed-16-bit little-endian.
 *
 * <p>Limitation (surfaced in the app UI): apps that set
 * {@code android:allowAudioPlaybackCapture="false"} / ALLOW_CAPTURE_BY_NONE
 * (some DRM/media apps) produce silence — the OS filters them out.
 */
@RequiresApi(api = Build.VERSION_CODES.Q)
public class ScreenShareAudioCapturer {
  private static final String TAG = "ScreenShareAudioCapturer";

  private static final int SAMPLE_RATE = 48000;
  private static final int CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_STEREO;
  private static final int ENCODING = AudioFormat.ENCODING_PCM_16BIT;
  // Read 20 ms per chunk (48k * 0.02 * 2ch * 2B). Rust re-frames to 10 ms
  // Opus frames internally, so the chunk size only sets channel traffic.
  private static final int CHUNK_BYTES = 3840;

  public interface PcmSink {
    /** Called on the capture thread with an owned copy of the chunk. */
    void onPcm(byte[] chunk);
  }

  private AudioRecord record;
  private Thread readerThread;
  private volatile boolean running = false;

  /**
   * Start capturing other apps' playback. {@code projection} MUST be the live
   * projection of the running screen-video capture. Returns false when the
   * AudioRecord can't be built (e.g. missing RECORD_AUDIO permission).
   */
  @SuppressLint("MissingPermission") // RECORD_AUDIO is granted before any call starts.
  public synchronized boolean start(MediaProjection projection, PcmSink sink) {
    if (running) return true;
    if (projection == null || sink == null) return false;

    try {
      AudioPlaybackCaptureConfiguration config =
          new AudioPlaybackCaptureConfiguration.Builder(projection)
              .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
              .addMatchingUsage(AudioAttributes.USAGE_GAME)
              .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
              .build();

      AudioFormat format = new AudioFormat.Builder()
          .setEncoding(ENCODING)
          .setSampleRate(SAMPLE_RATE)
          .setChannelMask(CHANNEL_CONFIG)
          .build();

      int minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, ENCODING);
      int bufSize = Math.max(minBuf * 4, CHUNK_BYTES * 8);

      record = new AudioRecord.Builder()
          .setAudioFormat(format)
          .setBufferSizeInBytes(bufSize)
          .setAudioPlaybackCaptureConfig(config)
          .build();
    } catch (Exception e) {
      Log.e(TAG, "AudioRecord build failed", e);
      record = null;
      return false;
    }

    if (record.getState() != AudioRecord.STATE_INITIALIZED) {
      Log.e(TAG, "AudioRecord not initialized");
      record.release();
      record = null;
      return false;
    }

    try {
      record.startRecording();
    } catch (IllegalStateException e) {
      Log.e(TAG, "startRecording failed", e);
      record.release();
      record = null;
      return false;
    }

    // The config gives no format guarantees — log what we actually got. A
    // mismatch here (e.g. mono, non-48k) corrupts the fixed 48k-stereo wire
    // format downstream, so this line is the first thing to check on bad audio.
    Log.i(TAG, "Playback capture format: rate=" + record.getSampleRate()
        + " channels=" + record.getFormat().getChannelCount()
        + " encoding=" + record.getFormat().getEncoding());

    running = true;
    readerThread = new Thread(() -> {
      // Real audio priority (nice -19 + audio cgroup) — Thread.MAX_PRIORITY is
      // a weak hint the scheduler largely ignores; this is what WebRTC's own
      // AudioRecord thread uses. A delayed read overruns the AudioRecord ring
      // and drops hardware audio (a clean, regular gap).
      android.os.Process.setThreadPriority(
          android.os.Process.THREAD_PRIORITY_URGENT_AUDIO);
      byte[] buf = new byte[CHUNK_BYTES];
      while (running) {
        int n = record.read(buf, 0, buf.length, AudioRecord.READ_BLOCKING);
        if (n > 0) {
          byte[] chunk = new byte[n];
          System.arraycopy(buf, 0, chunk, 0, n);
          sink.onPcm(chunk);
        } else if (n < 0) {
          Log.w(TAG, "AudioRecord.read error " + n + ", stopping");
          break;
        }
      }
    }, "HollowScreenShareAudioCap");
    readerThread.start();

    Log.i(TAG, "Playback capture started (48k stereo s16)");
    return true;
  }

  public synchronized void stop() {
    if (!running && record == null) return;
    running = false;
    if (readerThread != null) {
      try {
        readerThread.join(1000);
      } catch (InterruptedException ignored) {
        Thread.currentThread().interrupt();
      }
      readerThread = null;
    }
    if (record != null) {
      try {
        record.stop();
      } catch (IllegalStateException ignored) {
      }
      record.release();
      record = null;
    }
    Log.i(TAG, "Playback capture stopped");
  }

  public boolean isRunning() {
    return running;
  }
}
