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
#include <pulse/rtclock.h>
#include <unistd.h>

#include <string>
#include <vector>
#include <mutex>
#include <random>
#include <cstdlib>
#include <map>
#include <memory>
#include <cstdio>

namespace hollow_pulse {

void InitializeRouting() {
  static std::once_flag initialized;
  std::call_once(initialized, [] {
    std::random_device random;
    const auto token = std::to_string(random()) + "-" + std::to_string(random());
    setenv("PULSE_PROP_hollow.instance", token.c_str(), 1);
  });
}

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
  if (eol != 0) {
    if (eol < 0) st->failed = true;
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
  if (eol != 0) {
    if (eol < 0) st->failed = true;
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
    if (st->failed) return false;
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
  auto* timer = pa_context_rttime_new(st.context, pa_rtclock_now() + 2 * PA_USEC_PER_SEC,
      [](pa_mainloop_api*, pa_time_event*, const timeval*, void* data) {
        auto* state = static_cast<EnumState*>(data);
        state->failed = true;
        pa_threaded_mainloop_signal(state->mainloop, 0);
      }, &st);
  for (;;) {
    if (st.failed) break;
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

  api->time_free(timer);
  pa_threaded_mainloop_unlock(st.mainloop);
  pa_threaded_mainloop_stop(st.mainloop);
  pa_context_disconnect(st.context);
  pa_context_unref(st.context);
  pa_threaded_mainloop_free(st.mainloop);

  if (st.failed || !st.server_done || !st.sources_done || !st.sinks_done) return false;

  *inputs = std::move(st.sources);
  *outputs = std::move(st.sinks);
  return true;
}

namespace {

class AudioRouter {
 public:
  ~AudioRouter() { Close(); }

  bool Select(const std::string& name, bool input) {
    std::lock_guard<std::mutex> guard(mutex_);
    if (!Connect()) return false;
    pa_threaded_mainloop_lock(loop_);
    (input ? source_ : sink_) = name;
    if (input) {
      Release(pa_context_get_source_output_info_list(context_, SourceOutput, this));
    } else {
      Release(pa_context_get_sink_input_info_list(context_, SinkInput, this));
    }
    pa_threaded_mainloop_unlock(loop_);
    return true;
  }

 private:
  static void Release(pa_operation* op) { if (op) pa_operation_unref(op); }

  static void Moved(pa_context* context, int success, void*) {
    if (!success) std::fprintf(stderr, "[HOLLOW-AUDIO] PulseAudio routing failed: %s\n",
                              pa_strerror(pa_context_errno(context)));
  }

  struct PendingRoute {
    AudioRouter* router;
    uint64_t key;
    uint32_t stream;
    bool input;
  };

  void Route(uint32_t client, uint32_t stream, bool input) {
    if (client == PA_INVALID_INDEX) return;
    const auto key = next_route_++;
    auto request = std::make_unique<PendingRoute>(PendingRoute{this, key, stream, input});
    auto* data = request.get();
    pending_[key] = std::move(request);
    auto* op = pa_context_get_client_info(context_, client,
        [](pa_context* context, const pa_client_info* info, int eol, void* userdata) {
          auto* request = static_cast<PendingRoute*>(userdata);
          auto* self = request->router;
          if (info && self->OwnStream(info->proplist)) {
            const auto& name = request->input ? self->source_ : self->sink_;
            if (!name.empty()) {
              Release(request->input
                  ? pa_context_move_source_output_by_name(context, request->stream, name.c_str(), Moved, nullptr)
                  : pa_context_move_sink_input_by_name(context, request->stream, name.c_str(), Moved, nullptr));
            }
          }
          if (eol) self->pending_.erase(request->key);
        }, data);
    if (!op) pending_.erase(key);
    Release(op);
  }

  bool OwnStream(pa_proplist* props) {
    const char* pid = pa_proplist_gets(props, PA_PROP_APPLICATION_PROCESS_ID);
    const char* token = pa_proplist_gets(props, "hollow.instance");
    const char* ours = getenv("PULSE_PROP_hollow.instance");
    return pid && std::to_string(getpid()) == pid && token && ours && std::string(token) == ours;
  }

  static void SinkInput(pa_context*, const pa_sink_input_info* info,
                        int eol, void* data) {
    auto* self = static_cast<AudioRouter*>(data);
    if (eol || !info || self->sink_.empty()) return;
    // A move produces a CHANGE event too. NEW is the only subscription we
    // handle, so the route cannot recursively move itself.
    self->Route(info->client, info->index, false);
  }

  static void SourceOutput(pa_context*, const pa_source_output_info* info,
                           int eol, void* data) {
    auto* self = static_cast<AudioRouter*>(data);
    if (eol || !info || self->source_.empty()) return;
    self->Route(info->client, info->index, true);
  }

  static void Subscription(pa_context* context, pa_subscription_event_type_t event,
                            uint32_t index, void* data) {
    if ((event & PA_SUBSCRIPTION_EVENT_TYPE_MASK) != PA_SUBSCRIPTION_EVENT_NEW) return;
    switch (event & PA_SUBSCRIPTION_EVENT_FACILITY_MASK) {
      case PA_SUBSCRIPTION_EVENT_SINK_INPUT:
        Release(pa_context_get_sink_input_info(context, index, SinkInput, data));
        break;
      case PA_SUBSCRIPTION_EVENT_SOURCE_OUTPUT:
        Release(pa_context_get_source_output_info(context, index, SourceOutput, data));
        break;
      default: break;
    }
  }

  bool Connect() {
    if (loop_) {
      pa_threaded_mainloop_lock(loop_);
      const bool ready = pa_context_get_state(context_) == PA_CONTEXT_READY;
      pa_threaded_mainloop_unlock(loop_);
      if (ready) return true;
      Close();
    }
    loop_ = pa_threaded_mainloop_new();
    if (!loop_) return false;
    auto* api = pa_threaded_mainloop_get_api(loop_);
    context_ = pa_context_new(api, "hollow-audio-routing");
    if (!context_) { Close(); return false; }
    pa_context_set_state_callback(context_, [](pa_context*, void* data) {
      auto* self = static_cast<AudioRouter*>(data);
      pa_threaded_mainloop_signal(self->loop_, 0);
    }, this);
    if (pa_context_connect(context_, nullptr, PA_CONTEXT_NOFLAGS, nullptr) < 0 ||
        pa_threaded_mainloop_start(loop_) < 0) { Close(); return false; }
    started_ = true;
    pa_threaded_mainloop_lock(loop_);
    timed_out_ = false;
    auto* timer = pa_context_rttime_new(context_, pa_rtclock_now() + 2 * PA_USEC_PER_SEC,
        [](pa_mainloop_api*, pa_time_event*, const timeval*, void* data) {
          auto* self = static_cast<AudioRouter*>(data);
          self->timed_out_ = true;
          pa_threaded_mainloop_signal(self->loop_, 0);
        }, this);
    while (!timed_out_ && PA_CONTEXT_IS_GOOD(pa_context_get_state(context_)) &&
           pa_context_get_state(context_) != PA_CONTEXT_READY) {
      pa_threaded_mainloop_wait(loop_);
    }
    const bool ready = !timed_out_ && pa_context_get_state(context_) == PA_CONTEXT_READY;
    api->time_free(timer);
    if (ready) {
      pa_context_set_subscribe_callback(context_, Subscription, this);
      Release(pa_context_subscribe(context_, static_cast<pa_subscription_mask_t>(
          PA_SUBSCRIPTION_MASK_SINK_INPUT | PA_SUBSCRIPTION_MASK_SOURCE_OUTPUT), nullptr, nullptr));
    }
    pa_threaded_mainloop_unlock(loop_);
    if (!ready) Close();
    return ready;
  }

  void Close() {
    if (started_) pa_threaded_mainloop_stop(loop_);
    if (context_) {
      pa_context_disconnect(context_);
      pa_context_unref(context_);
    }
    if (loop_) pa_threaded_mainloop_free(loop_);
    context_ = nullptr;
    loop_ = nullptr;
    started_ = false;
    pending_.clear();
  }

  std::mutex mutex_;
  pa_threaded_mainloop* loop_ = nullptr;
  pa_context* context_ = nullptr;
  bool started_ = false;
  bool timed_out_ = false;
  std::string source_, sink_;
  uint64_t next_route_ = 0;
  std::map<uint64_t, std::unique_ptr<PendingRoute>> pending_;
};

}  // namespace

bool SelectDevice(const std::string& device_id, bool input) {
  std::vector<AudioDevice> inputs, outputs;
  if (!EnumerateDevices(&inputs, &outputs)) return false;
  const auto& devices = input ? inputs : outputs;
  for (const auto& device : devices) {
    if (device.id == device_id || ((device_id.empty() || device_id == "default") && device.is_default)) {
      static AudioRouter router;
      return router.Select(device.id, input);
    }
  }
  return false;
}

}  // namespace hollow_pulse
