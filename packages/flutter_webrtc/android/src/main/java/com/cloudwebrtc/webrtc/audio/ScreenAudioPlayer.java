package com.cloudwebrtc.webrtc.audio;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Build;
import android.util.Log;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Hollow fork: native PCM player for RECEIVED screen-share audio on Android.
 *
 * The desktop app decodes + plays shared audio in an out-of-process exe; a
 * phone can't spawn one, so Dart decodes the Opus frames in Rust and streams
 * raw PCM here via the {@code startScreenAudioPlayer / writeScreenAudioPcm /
 * stopScreenAudioPlayer} method channel.
 *
 * <p>Critically, this plays on the MEDIA stream ({@link AudioAttributes#USAGE_MEDIA}
 * + {@link AudioAttributes#CONTENT_TYPE_MUSIC}), NOT the voice-communication
 * path. A WebRTC call puts the device in {@code MODE_IN_COMMUNICATION} with
 * AEC/AGC/NS active; routing music through that mangles it. A separate MEDIA
 * AudioTrack sidesteps the call's capture/render processing entirely.
 *
 * <p>PCM is interleaved 48 kHz stereo signed-16-bit little-endian — matching
 * the senders (see the desktop OpusDecoderWrapper / encode mode).
 *
 * <p>Writes arrive on the Flutter platform thread (~250 small buffers/sec).
 * {@link AudioTrack#write} can block when the track buffer is full, so the
 * platform thread only enqueues; a dedicated writer thread drains the queue
 * into the track. When the queue backs up (slow drain / underrun storm) the
 * OLDEST buffers are dropped — a stale audio buffer is a tiny glitch, a
 * growing backlog is unbounded latency. Mirrors the desktop ring-buffer drop.
 */
public class ScreenAudioPlayer {
  private static final String TAG = "ScreenAudioPlayer";

  private static final int SAMPLE_RATE = 48000;
  private static final int CHANNEL_CONFIG = AudioFormat.CHANNEL_OUT_STEREO;
  private static final int ENCODING = AudioFormat.ENCODING_PCM_16BIT;

  // Cap the pending queue at ~1 second of audio (each buffer ~10 ms). When
  // full we drop the oldest. 120 buffers * ~10 ms ≈ 1.2 s of slack.
  private static final int MAX_QUEUED_BUFFERS = 120;

  private final AudioManager audioManager;
  private AudioTrack track;
  private Thread writerThread;
  private volatile boolean running = false;
  private final BlockingQueue<byte[]> queue = new ArrayBlockingQueue<>(MAX_QUEUED_BUFFERS);

  private long writtenBytes = 0;
  private int droppedBuffers = 0;

  // Last route the caller asked us to follow, so start() can re-apply it.
  private boolean speakerPinned = false;

  public ScreenAudioPlayer(Context context) {
    this.audioManager =
        (AudioManager) context.getApplicationContext().getSystemService(Context.AUDIO_SERVICE);
  }

  public synchronized boolean start() {
    if (running) return true;

    int minBuf = AudioTrack.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, ENCODING);
    if (minBuf <= 0) {
      Log.e(TAG, "getMinBufferSize failed: " + minBuf);
      return false;
    }
    // Give the track a generous buffer (4x min) so brief jitter doesn't underrun.
    int bufSize = minBuf * 4;

    try {
      AudioAttributes attrs = new AudioAttributes.Builder()
          .setUsage(AudioAttributes.USAGE_MEDIA)
          .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
          .build();
      AudioFormat format = new AudioFormat.Builder()
          .setSampleRate(SAMPLE_RATE)
          .setChannelMask(CHANNEL_CONFIG)
          .setEncoding(ENCODING)
          .build();

      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        track = new AudioTrack.Builder()
            .setAudioAttributes(attrs)
            .setAudioFormat(format)
            .setBufferSizeInBytes(bufSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build();
      } else {
        track = new AudioTrack(attrs, format, bufSize,
            AudioTrack.MODE_STREAM, AudioManager.AUDIO_SESSION_ID_GENERATE);
      }
    } catch (Exception e) {
      Log.e(TAG, "AudioTrack create failed", e);
      track = null;
      return false;
    }

    if (track.getState() != AudioTrack.STATE_INITIALIZED) {
      Log.e(TAG, "AudioTrack not initialized");
      releaseTrack();
      return false;
    }

    running = true;
    writtenBytes = 0;
    droppedBuffers = 0;
    queue.clear();

    track.play();
    // Re-apply the current route so a track created while speakerphone is
    // already ON gets pinned (otherwise it would start muted — see below).
    applyPreferredDevice();

    writerThread = new Thread(this::writerLoop, "ScreenAudioWriter");
    writerThread.start();

    Log.i(TAG, "started (minBuf=" + minBuf + " bufSize=" + bufSize + ")");
    return true;
  }

  /**
   * Follow the call's output route. The speakerphone toggle goes through the
   * audioswitch lib's DEPRECATED {@code setSpeakerphoneOn(true)}, a global
   * routing override that — in MODE_IN_COMMUNICATION — steals this media
   * track's default speaker route, silencing it (the earpiece route doesn't,
   * since media never routes to the earpiece). Pinning the track to the
   * built-in speaker with {@link AudioTrack#setPreferredDevice} keeps it
   * playing through the speaker regardless of that override, without touching
   * the call's routing or this track's clean USAGE_MEDIA / separate-volume
   * path. {@code speakerOn=false} clears the pin → default routing (media
   * falls back to the speaker, never the earpiece). API 23+; no-op below.
   */
  public synchronized void setPreferredOutput(boolean speakerOn) {
    speakerPinned = speakerOn;
    applyPreferredDevice();
  }

  private void applyPreferredDevice() {
    if (track == null || audioManager == null
        || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
      return;
    }
    AudioDeviceInfo target = null;
    if (speakerPinned) {
      for (AudioDeviceInfo d : audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
        if (d.getType() == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) {
          target = d;
          break;
        }
      }
    }
    // target == null restores default routing (correct for the non-speaker case).
    boolean ok = track.setPreferredDevice(target);
    if (!ok) {
      Log.w(TAG, "setPreferredDevice(" + (speakerPinned ? "SPEAKER" : "default") + ") refused");
    }
  }

  /** Enqueue one decoded PCM buffer. Non-blocking; drops oldest when full. */
  public void write(byte[] pcm) {
    if (!running || pcm == null || pcm.length == 0) return;
    // Drop oldest until there's room, then offer. The writer thread is the
    // only consumer; this producer is the single platform thread.
    while (!queue.offer(pcm)) {
      byte[] discarded = queue.poll();
      if (discarded == null) break; // race: drained empty, retry offer
      droppedBuffers++;
      if (droppedBuffers <= 5 || droppedBuffers % 250 == 0) {
        Log.w(TAG, "queue full, dropped buffer #" + droppedBuffers);
      }
    }
  }

  private void writerLoop() {
    while (running) {
      byte[] buf;
      try {
        buf = queue.poll(200, TimeUnit.MILLISECONDS);
      } catch (InterruptedException e) {
        break;
      }
      if (buf == null) continue;
      AudioTrack t = track;
      if (t == null) break;
      try {
        int off = 0;
        while (off < buf.length && running) {
          int n = t.write(buf, off, buf.length - off);
          if (n < 0) {
            Log.e(TAG, "AudioTrack.write error " + n);
            break;
          }
          off += n;
        }
        writtenBytes += off;
      } catch (Exception e) {
        Log.e(TAG, "write failed", e);
      }
    }
  }

  public synchronized void stop() {
    if (!running && track == null) return;
    Log.i(TAG, "stopping (wrote " + writtenBytes + " bytes, dropped "
        + droppedBuffers + " buffers)");
    running = false;
    if (writerThread != null) {
      writerThread.interrupt();
      try {
        writerThread.join(500);
      } catch (InterruptedException ignored) {
      }
      writerThread = null;
    }
    queue.clear();
    releaseTrack();
  }

  private void releaseTrack() {
    if (track != null) {
      try {
        if (track.getPlayState() == AudioTrack.PLAYSTATE_PLAYING) {
          track.pause();
          track.flush();
        }
        track.stop();
      } catch (Exception ignored) {
      }
      try {
        track.release();
      } catch (Exception ignored) {
      }
      track = null;
    }
  }
}
