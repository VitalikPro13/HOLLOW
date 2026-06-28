// Linux audio device enumeration via libpulse.
//
// WHY THIS EXISTS: the prebuilt webrtc-sdk libwebrtc.so on Linux ships an
// AudioDeviceModule whose PulseAudio init fails on PipeWire-pulse systems and
// silently falls back to AudioDeviceDummy, so RTCAudioDevice::RecordingDevices()
// / PlayoutDevices() return 0 → the mic/speaker pickers come up empty (the V4L2
// camera path is independent and works). A plain libpulse client connects to the
// same pipewire-pulse server fine, so we enumerate directly here — exactly the
// pattern macOS uses (MacAudioDevices via CoreAudio behind hollowMacAudioDevices).
//
// Exposed over the FlutterWebRTC.Method channel as "hollowLinuxAudioDevices",
// returning {"input": [{id,name,isDefault}], "output": [...]} — the SAME shape
// the Dart side already parses for hollowMacAudioDevices.

#include "hollow_pulse_devices.h"

#include <pulse/pulseaudio.h>

#include <string>
#include <vector>

namespace hollow_pulse {

namespace {

struct EnumState {
  pa_threaded_mainloop* mainloop = nullptr;
  pa_context* context = nullptr;
  std::vector<AudioDevice> sources;  // inputs (microphones)
  std::vector<AudioDevice> sinks;    // outputs (speakers)
  std::string default_source_name;
  std::string default_sink_name;
  bool sources_done = false;
  bool sinks_done = false;
  bool server_done = false;
  bool failed = false;
};

void context_state_cb(pa_context* c, void* userdata) {
  auto* st = static_cast<EnumState*>(userdata);
  pa_context_state_t state = pa_context_get_state(c);
  switch (state) {
    case PA_CONTEXT_READY:
    case PA_CONTEXT_FAILED:
    case PA_CONTEXT_TERMINATED:
      pa_threaded_mainloop_signal(st->mainloop, 0);
      break;
    default:
      break;
  }
}

void server_info_cb(pa_context* /*c*/, const pa_server_info* info,
                    void* userdata) {
  auto* st = static_cast<EnumState*>(userdata);
  if (info) {
    if (info->default_source_name)
      st->default_source_name = info->default_source_name;
    if (info->default_sink_name)
      st->default_sink_name = info->default_sink_name;
  }
  st->server_done = true;
  pa_threaded_mainloop_signal(st->mainloop, 0);
}

void source_info_cb(pa_context* /*c*/, const pa_source_info* info, int eol,
                    void* userdata) {
  auto* st = static_cast<EnumState*>(userdata);
  if (eol > 0) {
    st->sources_done = true;
    pa_threaded_mainloop_signal(st->mainloop, 0);
    return;
  }
  if (!info) return;
  // Skip monitor sources (loopback of sinks) — they're not real microphones.
  if (info->monitor_of_sink != PA_INVALID_INDEX) return;
  AudioDevice d;
  d.id = info->name ? info->name : "";
  d.name = info->description ? info->description
                             : (info->name ? info->name : "Microphone");
  d.is_default = (st->default_source_name == d.id);
  if (!d.id.empty()) st->sources.push_back(std::move(d));
}

void sink_info_cb(pa_context* /*c*/, const pa_sink_info* info, int eol,
                  void* userdata) {
  auto* st = static_cast<EnumState*>(userdata);
  if (eol > 0) {
    st->sinks_done = true;
    pa_threaded_mainloop_signal(st->mainloop, 0);
    return;
  }
  if (!info) return;
  AudioDevice d;
  d.id = info->name ? info->name : "";
  d.name = info->description ? info->description
                            : (info->name ? info->name : "Speaker");
  d.is_default = (st->default_sink_name == d.id);
  if (!d.id.empty()) st->sinks.push_back(std::move(d));
}

// Wait until `done` flips true or the context dies. Returns false on failure.
bool wait_for(EnumState* st, const bool& done) {
  while (!done) {
    if (pa_context_get_state(st->context) != PA_CONTEXT_READY) return false;
    pa_threaded_mainloop_wait(st->mainloop);
  }
  return true;
}

}  // namespace

bool EnumerateDevices(std::vector<AudioDevice>* inputs,
                      std::vector<AudioDevice>* outputs) {
  EnumState st;
  st.mainloop = pa_threaded_mainloop_new();
  if (!st.mainloop) return false;

  pa_mainloop_api* api = pa_threaded_mainloop_get_api(st.mainloop);
  st.context = pa_context_new(api, "hollow-audio-enum");
  if (!st.context) {
    pa_threaded_mainloop_free(st.mainloop);
    return false;
  }

  pa_context_set_state_callback(st.context, context_state_cb, &st);

  if (pa_context_connect(st.context, nullptr, PA_CONTEXT_NOFLAGS, nullptr) < 0) {
    pa_context_unref(st.context);
    pa_threaded_mainloop_free(st.mainloop);
    return false;
  }

  pa_threaded_mainloop_lock(st.mainloop);
  if (pa_threaded_mainloop_start(st.mainloop) < 0) {
    pa_threaded_mainloop_unlock(st.mainloop);
    pa_context_disconnect(st.context);
    pa_context_unref(st.context);
    pa_threaded_mainloop_free(st.mainloop);
    return false;
  }

  // Wait for the context to become READY (or fail).
  for (;;) {
    pa_context_state_t state = pa_context_get_state(st.context);
    if (state == PA_CONTEXT_READY) break;
    if (state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED) {
      st.failed = true;
      break;
    }
    pa_threaded_mainloop_wait(st.mainloop);
  }

  if (!st.failed) {
    // 1) default source/sink names, 2) sources, 3) sinks.
    if (pa_operation* op =
            pa_context_get_server_info(st.context, server_info_cb, &st)) {
      pa_operation_unref(op);
      wait_for(&st, st.server_done);
    }
    if (pa_operation* op = pa_context_get_source_info_list(
            st.context, source_info_cb, &st)) {
      pa_operation_unref(op);
      wait_for(&st, st.sources_done);
    }
    if (pa_operation* op =
            pa_context_get_sink_info_list(st.context, sink_info_cb, &st)) {
      pa_operation_unref(op);
      wait_for(&st, st.sinks_done);
    }
  }

  pa_threaded_mainloop_unlock(st.mainloop);
  pa_threaded_mainloop_stop(st.mainloop);
  pa_context_disconnect(st.context);
  pa_context_unref(st.context);
  pa_threaded_mainloop_free(st.mainloop);

  if (st.failed) return false;

  *inputs = std::move(st.sources);
  *outputs = std::move(st.sinks);
  return true;
}

}  // namespace hollow_pulse
