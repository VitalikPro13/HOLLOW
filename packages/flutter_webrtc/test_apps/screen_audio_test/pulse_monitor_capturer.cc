#ifdef __linux__

#include "pulse_monitor_capturer.h"

#include <pulse/error.h>
#include <pulse/pulseaudio.h>
#include <pulse/simple.h>

#include <cstdio>
#include <vector>

namespace {

struct ServerInfoResult {
  std::string default_sink;
  bool done = false;
};

void ServerInfoCallback(pa_context*, const pa_server_info* info,
                        void* userdata) {
  auto* result = static_cast<ServerInfoResult*>(userdata);
  if (info && info->default_sink_name)
    result->default_sink = info->default_sink_name;
  result->done = true;
}

}  // namespace

PulseMonitorCapturer::~PulseMonitorCapturer() { Stop(); }

std::string PulseMonitorCapturer::QueryDefaultSinkMonitor() {
  // Minimal synchronous roundtrip on the async API: connect, one
  // get_server_info, disconnect. pa_simple can't enumerate, so this is the
  // only way to learn the default sink's name.
  pa_mainloop* ml = pa_mainloop_new();
  if (!ml) return "";
  pa_context* ctx = pa_context_new(pa_mainloop_get_api(ml), "Hollow");
  if (!ctx) {
    pa_mainloop_free(ml);
    return "";
  }

  std::string monitor;
  if (pa_context_connect(ctx, nullptr, PA_CONTEXT_NOFLAGS, nullptr) >= 0) {
    // Wait for the context to become ready (or fail).
    bool ready = false, failed = false;
    while (!ready && !failed) {
      if (pa_mainloop_iterate(ml, 1, nullptr) < 0) break;
      pa_context_state_t st = pa_context_get_state(ctx);
      if (st == PA_CONTEXT_READY) ready = true;
      else if (!PA_CONTEXT_IS_GOOD(st)) failed = true;
    }

    if (ready) {
      ServerInfoResult result;
      pa_operation* op =
          pa_context_get_server_info(ctx, ServerInfoCallback, &result);
      if (op) {
        while (!result.done) {
          if (pa_mainloop_iterate(ml, 1, nullptr) < 0) break;
        }
        pa_operation_unref(op);
      }
      if (!result.default_sink.empty())
        monitor = result.default_sink + ".monitor";
    }
    pa_context_disconnect(ctx);
  }

  pa_context_unref(ctx);
  pa_mainloop_free(ml);
  return monitor;
}

bool PulseMonitorCapturer::Start(FrameCallback callback) {
  if (running_.load()) return true;
  callback_ = std::move(callback);

  pa_sample_spec ss = {};
  ss.format = PA_SAMPLE_S16LE;
  ss.channels = kChannels;
  ss.rate = kSampleRate;

  // Low-latency record buffering: 10ms fragments.
  pa_buffer_attr ba = {};
  ba.maxlength = (uint32_t)-1;
  ba.tlength = (uint32_t)-1;
  ba.prebuf = (uint32_t)-1;
  ba.minreq = (uint32_t)-1;
  ba.fragsize = kBytesPerBuf;

  // "@DEFAULT_MONITOR@" is the server-side alias for the default sink's
  // monitor source (PulseAudio namereg; also implemented by pipewire-pulse).
  int error = 0;
  pa_ = pa_simple_new(nullptr, "Hollow", PA_STREAM_RECORD, "@DEFAULT_MONITOR@",
                      "Screen Share Audio", &ss, nullptr, &ba, &error);
  if (!pa_) {
    fprintf(stderr,
            "[PULSE-MONITOR] @DEFAULT_MONITOR@ open failed (%s), querying "
            "default sink...\n",
            pa_strerror(error));
    std::string monitor = QueryDefaultSinkMonitor();
    if (monitor.empty()) {
      fprintf(stderr, "[PULSE-MONITOR] ERROR: could not resolve the default "
                      "sink's monitor source\n");
      return false;
    }
    fprintf(stderr, "[PULSE-MONITOR] Falling back to '%s'\n", monitor.c_str());
    pa_ = pa_simple_new(nullptr, "Hollow", PA_STREAM_RECORD, monitor.c_str(),
                        "Screen Share Audio", &ss, nullptr, &ba, &error);
    if (!pa_) {
      fprintf(stderr, "[PULSE-MONITOR] ERROR: pa_simple_new('%s') failed: %s\n",
              monitor.c_str(), pa_strerror(error));
      return false;
    }
  }

  running_.store(true);
  thread_ = std::thread(&PulseMonitorCapturer::CaptureThread, this);
  fprintf(stderr, "[PULSE-MONITOR] Capturing system output (48kHz stereo)\n");
  return true;
}

void PulseMonitorCapturer::CaptureThread() {
  std::vector<int16_t> buf(kSamplesPerBuf);
  int error = 0;

  // pa_simple_read blocks until the full 10ms chunk arrives. While a call is
  // live Hollow itself keeps the sink active, so the monitor keeps flowing.
  while (running_.load()) {
    if (pa_simple_read(static_cast<pa_simple*>(pa_), buf.data(), kBytesPerBuf,
                       &error) < 0) {
      fprintf(stderr, "[PULSE-MONITOR] pa_simple_read failed: %s\n",
              pa_strerror(error));
      break;
    }
    if (!running_.load()) break;
    callback_(buf.data(), kFramesPerBuf);
  }
}

void PulseMonitorCapturer::Stop() {
  if (!running_.exchange(false) && !thread_.joinable()) return;
  // The read loop wakes within one 10ms fragment in the normal case. If the
  // monitor source is suspended (idle sink, nothing playing) the read can
  // block longer; the parent process kills us after a 2s grace anyway.
  if (thread_.joinable()) thread_.join();
  if (pa_) {
    pa_simple_free(static_cast<pa_simple*>(pa_));
    pa_ = nullptr;
  }
}

#endif  // __linux__
