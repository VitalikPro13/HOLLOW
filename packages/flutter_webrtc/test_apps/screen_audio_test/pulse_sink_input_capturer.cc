#ifdef __linux__

#include "pulse_sink_input_capturer.h"

#include <pulse/pulseaudio.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

// ~400ms per-stream cap so a stream the mixer briefly starves on can't grow
// unbounded; drop oldest (real-time audio — stale samples are worthless).
constexpr size_t kMaxBufferedSamples =
    PulseSinkInputCapturer::kSamplesPerBuf * 40;

// Read /proc/<pid>/stat and return the parent pid, or -1. The comm field can
// contain spaces and parens, so parse from the LAST ')'.
int ParentPid(int pid) {
  char path[64];
  snprintf(path, sizeof(path), "/proc/%d/stat", pid);
  FILE* f = fopen(path, "r");
  if (!f) return -1;
  char buf[512];
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  if (n == 0) return -1;
  buf[n] = '\0';
  const char* close_paren = strrchr(buf, ')');
  if (!close_paren) return -1;
  char state = 0;
  int ppid = -1;
  if (sscanf(close_paren + 1, " %c %d", &state, &ppid) != 2) return -1;
  return ppid;
}

// True if `ancestor` is `pid` or one of its ancestors. Catches browser /
// Electron audio-service children whose window is owned by the parent.
bool PidInTree(int pid, int ancestor) {
  for (int depth = 0; depth < 64 && pid > 1; ++depth) {
    if (pid == ancestor) return true;
    pid = ParentPid(pid);
    if (pid <= 0) return false;
  }
  return pid == ancestor;
}

// Carries one pending sink-input attach through the async sink-info query
// (we need the sink's monitor source name before connecting the stream).
struct PendingAttach {
  PulseSinkInputCapturer* self;
  uint32_t si_idx;
  uint32_t sink_idx;
};

// Carries one pending relevance decision through the async client-info query
// (native PipeWire clients omit application.process.id on the stream; the
// CLIENT object carries the kernel-verified pipewire.sec.pid).
struct PendingClientResolve {
  PulseSinkInputCapturer* self;
  uint32_t si_idx;
  uint32_t sink_idx;
  std::string app_name;
  bool decided = false;
};

}  // namespace

// C-signature trampolines for the libpulse callbacks.
struct PulseSinkInputThunks {
  static void ContextState(pa_context*, void* ud) {
    static_cast<PulseSinkInputCapturer*>(ud)->OnContextState();
  }
  static void Subscribe(pa_context*, pa_subscription_event_type_t t,
                        uint32_t idx, void* ud) {
    static_cast<PulseSinkInputCapturer*>(ud)->OnSubscribeEvent(
        static_cast<int>(t), idx);
  }
  static void SinkInputInfo(pa_context*, const pa_sink_input_info* i, int eol,
                            void* ud) {
    static_cast<PulseSinkInputCapturer*>(ud)->OnSinkInputInfo(i, eol);
  }
  // userdata = heap PendingClientResolve (client-info query result).
  static void ClientInfoForResolve(pa_context*, const pa_client_info* i,
                                   int eol, void* ud) {
    auto* pending = static_cast<PendingClientResolve*>(ud);
    if (eol) {
      // Client vanished before we could ask: decide with pid 0 so the
      // sink-input isn't silently forgotten (EXCLUDE mode still captures it).
      if (!pending->decided) {
        pending->self->DecideAndAttach(pending->si_idx, pending->sink_idx, 0,
                                       pending->app_name);
      }
      delete pending;
      return;
    }
    if (pending->decided || !i) return;
    pending->decided = true;
    int pid = 0;
    const char* pid_s =
        pa_proplist_gets(i->proplist, PA_PROP_APPLICATION_PROCESS_ID);
    if (!pid_s) pid_s = pa_proplist_gets(i->proplist, "pipewire.sec.pid");
    if (pid_s) pid = atoi(pid_s);
    pending->self->DecideAndAttach(pending->si_idx, pending->sink_idx, pid,
                                   pending->app_name);
  }

  // userdata = heap PendingAttach (sink-info query result).
  static void SinkInfoForAttach(pa_context*, const pa_sink_info* i, int eol,
                                void* ud) {
    auto* pending = static_cast<PendingAttach*>(ud);
    if (eol) {
      delete pending;
      return;
    }
    if (i && i->monitor_source_name) {
      pending->self->sink_monitors_[pending->sink_idx] =
          i->monitor_source_name;
      pending->self->AttachStream(pending->si_idx, i->monitor_source_name);
    }
  }
  // userdata = heap uint32_t* with the sink-input idx (identifies the buffer).
  static void StreamRead(pa_stream* s, size_t, void* ud_pair);
};

// The read callback needs BOTH the capturer and the sink-input idx.
namespace {
struct StreamUd {
  PulseSinkInputCapturer* self;
  uint32_t si_idx;
};
}  // namespace

void PulseSinkInputThunks::StreamRead(pa_stream* s, size_t, void* ud) {
  auto* su = static_cast<StreamUd*>(ud);
  su->self->OnStreamRead(s, su->si_idx);
}

PulseSinkInputCapturer::~PulseSinkInputCapturer() { Stop(); }

bool PulseSinkInputCapturer::Start(Mode mode, int target_pid,
                                   FrameCallback callback) {
  if (running_.load()) return true;
  mode_ = mode;
  target_pid_ = target_pid;
  callback_ = std::move(callback);

  ml_ = pa_threaded_mainloop_new();
  if (!ml_) return false;
  ctx_ = pa_context_new(pa_threaded_mainloop_get_api(ml_), "Hollow");
  if (!ctx_) {
    pa_threaded_mainloop_free(ml_);
    ml_ = nullptr;
    return false;
  }

  pa_context_set_state_callback(ctx_, PulseSinkInputThunks::ContextState,
                                this);
  if (pa_context_connect(ctx_, nullptr, PA_CONTEXT_NOFLAGS, nullptr) < 0 ||
      pa_threaded_mainloop_start(ml_) < 0) {
    pa_context_unref(ctx_);
    ctx_ = nullptr;
    pa_threaded_mainloop_free(ml_);
    ml_ = nullptr;
    return false;
  }

  // Wait for the context to reach READY (or fail).
  pa_threaded_mainloop_lock(ml_);
  bool ready = false;
  for (;;) {
    pa_context_state_t st = pa_context_get_state(ctx_);
    if (st == PA_CONTEXT_READY) {
      ready = true;
      break;
    }
    if (!PA_CONTEXT_IS_GOOD(st)) break;
    pa_threaded_mainloop_wait(ml_);
  }

  if (!ready) {
    pa_threaded_mainloop_unlock(ml_);
    Stop();
    return false;
  }

  // Track sink-inputs coming/going for the whole capture lifetime.
  pa_context_set_subscribe_callback(ctx_, PulseSinkInputThunks::Subscribe,
                                    this);
  pa_operation* op = pa_context_subscribe(
      ctx_, PA_SUBSCRIPTION_MASK_SINK_INPUT, nullptr, nullptr);
  if (op) pa_operation_unref(op);

  // Attach to everything already playing. Streams connect asynchronously; the
  // mixer emits silence until the first one delivers.
  op = pa_context_get_sink_input_info_list(
      ctx_, PulseSinkInputThunks::SinkInputInfo, this);
  if (op) pa_operation_unref(op);
  pa_threaded_mainloop_unlock(ml_);

  running_.store(true);
  mixer_ = std::thread(&PulseSinkInputCapturer::MixerThread, this);
  fprintf(stderr,
          "[PULSE-SI] Capturing per-sink-input (%s, target pid %d)\n",
          mode_ == Mode::kExcludeTree ? "EXCLUDE tree" : "INCLUDE tree",
          target_pid_);
  return true;
}

void PulseSinkInputCapturer::OnContextState() {
  pa_context_state_t st = pa_context_get_state(ctx_);
  if (st == PA_CONTEXT_READY || !PA_CONTEXT_IS_GOOD(st))
    pa_threaded_mainloop_signal(ml_, 0);
}

void PulseSinkInputCapturer::OnSubscribeEvent(int event_type, uint32_t idx) {
  const int facility = event_type & PA_SUBSCRIPTION_EVENT_FACILITY_MASK;
  const int type = event_type & PA_SUBSCRIPTION_EVENT_TYPE_MASK;
  if (facility != PA_SUBSCRIPTION_EVENT_SINK_INPUT) return;

  if (type == PA_SUBSCRIPTION_EVENT_REMOVE) {
    DropStream(idx);
    return;
  }
  // NEW or CHANGE: (re)evaluate relevance via a fresh info query.
  pa_operation* op = pa_context_get_sink_input_info(
      ctx_, idx, PulseSinkInputThunks::SinkInputInfo, this);
  if (op) pa_operation_unref(op);
}

bool PulseSinkInputCapturer::IsRelevantPidApp(
    int pid, const std::string& app_name) const {
  if (mode_ == Mode::kIncludeTree) {
    // Per-app share: ONLY the target app's tree. Unknown pid -> not captured;
    // unresolvable target -> silence. NEVER the system mix.
    return target_pid_ > 0 && pid > 0 && PidInTree(pid, target_pid_);
  }

  // kExcludeTree (entire-screen anti-echo): everything EXCEPT Hollow's own
  // audio. The name check catches streams whose pid we couldn't resolve but
  // that we play ourselves (the render child names its stream "Hollow" too).
  if (app_name == "Hollow") return false;
  if (pid > 0 && target_pid_ > 0 && PidInTree(pid, target_pid_)) return false;
  return true;
}

void PulseSinkInputCapturer::OnSinkInputInfo(const pa_sink_input_info* i,
                                             int eol) {
  if (eol || !i) return;

  const char* pid_s =
      pa_proplist_gets(i->proplist, PA_PROP_APPLICATION_PROCESS_ID);
  const char* app_s = pa_proplist_gets(i->proplist, PA_PROP_APPLICATION_NAME);
  const int pid = pid_s ? atoi(pid_s) : 0;
  const std::string app = app_s ? app_s : "";

  if (pid == 0 && i->client != PA_INVALID_INDEX) {
    // Native PipeWire clients (pw-play, mpv --ao=pipewire, some games) don't
    // put application.process.id on the STREAM — fetch the pid from the
    // CLIENT object (kernel-verified pipewire.sec.pid) before deciding.
    auto* pending = new PendingClientResolve{this, i->index, i->sink, app};
    pa_operation* op = pa_context_get_client_info(
        ctx_, i->client, PulseSinkInputThunks::ClientInfoForResolve, pending);
    if (op) {
      pa_operation_unref(op);
      return;
    }
    delete pending;  // query refused — fall through and decide with pid 0
  }

  DecideAndAttach(i->index, i->sink, pid, app);
}

void PulseSinkInputCapturer::DecideAndAttach(uint32_t si_idx,
                                             uint32_t sink_idx, int pid,
                                             const std::string& app_name) {
  bool have;
  {
    std::lock_guard<std::mutex> lock(mix_mu_);
    have = streams_.count(si_idx) > 0;
  }

  if (!IsRelevantPidApp(pid, app_name)) {
    fprintf(stderr,
            "[PULSE-SI] sink-input %u (app='%s' pid=%d): not relevant\n",
            si_idx, app_name.c_str(), pid);
    if (have) DropStream(si_idx);
    return;
  }
  if (have) return;

  // Reserve the slot NOW (the sink-info query below is async — a CHANGE event
  // for the same sink-input must not double-attach).
  {
    std::lock_guard<std::mutex> lock(mix_mu_);
    streams_[si_idx];  // default-constructed, stream still null
  }

  auto cached = sink_monitors_.find(sink_idx);
  if (cached != sink_monitors_.end()) {
    AttachStream(si_idx, cached->second);
    return;
  }
  auto* pending = new PendingAttach{this, si_idx, sink_idx};
  pa_operation* op = pa_context_get_sink_info_by_index(
      ctx_, sink_idx, PulseSinkInputThunks::SinkInfoForAttach, pending);
  if (op) {
    pa_operation_unref(op);
  } else {
    delete pending;
    DropStream(si_idx);
  }
}

void PulseSinkInputCapturer::AttachStream(uint32_t si_idx,
                                          const std::string& monitor_source) {
  {
    // The slot may have been dropped (REMOVE raced the sink-info query).
    std::lock_guard<std::mutex> lock(mix_mu_);
    auto it = streams_.find(si_idx);
    if (it == streams_.end() || it->second.stream != nullptr) return;
  }

  pa_sample_spec ss = {};
  ss.format = PA_SAMPLE_S16LE;
  ss.channels = kChannels;
  ss.rate = kSampleRate;  // the server resamples the monitor data for us

  pa_stream* s = pa_stream_new(ctx_, "hollow-si-capture", &ss, nullptr);
  if (!s) {
    DropStream(si_idx);
    return;
  }

  // Capture ONLY this sink-input's contribution to its sink.
  if (pa_stream_set_monitor_stream(s, si_idx) < 0) {
    fprintf(stderr, "[PULSE-SI] set_monitor_stream(%u) failed: %s\n", si_idx,
            pa_strerror(pa_context_errno(ctx_)));
    pa_stream_unref(s);
    DropStream(si_idx);
    return;
  }

  auto* ud = new StreamUd{this, si_idx};
  pa_stream_set_read_callback(s, PulseSinkInputThunks::StreamRead, ud);

  pa_buffer_attr ba = {};
  ba.maxlength = (uint32_t)-1;
  ba.tlength = (uint32_t)-1;
  ba.prebuf = (uint32_t)-1;
  ba.minreq = (uint32_t)-1;
  ba.fragsize = kBytesPerBuf;

  if (pa_stream_connect_record(s, monitor_source.c_str(), &ba,
                               PA_STREAM_ADJUST_LATENCY) < 0) {
    fprintf(stderr, "[PULSE-SI] connect_record(%u, %s) failed: %s\n", si_idx,
            monitor_source.c_str(), pa_strerror(pa_context_errno(ctx_)));
    pa_stream_set_read_callback(s, nullptr, nullptr);
    delete ud;
    pa_stream_unref(s);
    DropStream(si_idx);
    return;
  }

  {
    std::lock_guard<std::mutex> lock(mix_mu_);
    auto it = streams_.find(si_idx);
    if (it == streams_.end()) {
      // Dropped while connecting — tear back down.
      pa_stream_set_read_callback(s, nullptr, nullptr);
      pa_stream_disconnect(s);
      delete ud;
      pa_stream_unref(s);
      return;
    }
    it->second.stream = s;
    it->second.read_ud = ud;
  }
  attached_.fetch_add(1);
  fprintf(stderr, "[PULSE-SI] Attached sink-input %u (via %s), %u active\n",
          si_idx, monitor_source.c_str(), attached_.load());
}

void PulseSinkInputCapturer::OnStreamRead(pa_stream* s, uint32_t si_idx) {
  while (pa_stream_readable_size(s) > 0) {
    const void* data = nullptr;
    size_t nbytes = 0;
    if (pa_stream_peek(s, &data, &nbytes) < 0) return;
    if (nbytes == 0) return;
    if (data) {
      const auto* samples = static_cast<const int16_t*>(data);
      const size_t count = nbytes / sizeof(int16_t);
      std::lock_guard<std::mutex> lock(mix_mu_);
      auto it = streams_.find(si_idx);
      if (it != streams_.end()) {
        auto& buf = it->second.buffer;
        buf.insert(buf.end(), samples, samples + count);
        if (buf.size() > kMaxBufferedSamples) {
          const size_t drop = buf.size() - kMaxBufferedSamples;
          buf.erase(buf.begin(), buf.begin() + drop);
        }
      }
    }
    // data == nullptr with nbytes > 0 is a hole — just drop it.
    pa_stream_drop(s);
  }
}

void PulseSinkInputCapturer::DropStream(uint32_t si_idx) {
  pa_stream* s = nullptr;
  void* ud = nullptr;
  {
    std::lock_guard<std::mutex> lock(mix_mu_);
    auto it = streams_.find(si_idx);
    if (it == streams_.end()) return;
    s = it->second.stream;
    ud = it->second.read_ud;
    streams_.erase(it);
  }
  if (s) {
    // Clear the read callback BEFORE freeing its userdata (both happen on the
    // mainloop thread, so no in-flight callback can race this).
    pa_stream_set_read_callback(s, nullptr, nullptr);
    delete static_cast<StreamUd*>(ud);
    pa_stream_disconnect(s);
    pa_stream_unref(s);
    attached_.fetch_sub(1);
    fprintf(stderr, "[PULSE-SI] Detached sink-input %u, %u active\n", si_idx,
            attached_.load());
  }
}

void PulseSinkInputCapturer::MixerThread() {
  std::vector<int16_t> frame(kSamplesPerBuf);
  const auto start = std::chrono::steady_clock::now();
  uint64_t emitted = 0;

  while (running_.load()) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    const auto now = std::chrono::steady_clock::now();
    const uint64_t due =
        std::chrono::duration_cast<std::chrono::milliseconds>(now - start)
            .count() /
        10;
    while (emitted < due && running_.load()) {
      std::memset(frame.data(), 0, kSamplesPerBuf * sizeof(int16_t));
      {
        std::lock_guard<std::mutex> lock(mix_mu_);
        for (auto& kv : streams_) {
          auto& buf = kv.second.buffer;
          const size_t take =
              std::min(buf.size(), static_cast<size_t>(kSamplesPerBuf));
          for (size_t i = 0; i < take; ++i) {
            int32_t m = static_cast<int32_t>(frame[i]) +
                        static_cast<int32_t>(buf[i]);
            if (m > 32767) m = 32767;
            if (m < -32768) m = -32768;
            frame[i] = static_cast<int16_t>(m);
          }
          buf.erase(buf.begin(), buf.begin() + take);
        }
      }
      callback_(frame.data(), kFramesPerBuf);
      ++emitted;
    }
  }
}

void PulseSinkInputCapturer::Stop() {
  const bool was_running = running_.exchange(false);
  if (mixer_.joinable()) mixer_.join();

  if (ml_ && ctx_) {
    pa_threaded_mainloop_lock(ml_);
    // Collect under the mix lock, tear down under the mainloop lock.
    std::vector<std::pair<pa_stream*, void*>> to_close;
    {
      std::lock_guard<std::mutex> lock(mix_mu_);
      for (auto& kv : streams_) {
        if (kv.second.stream)
          to_close.emplace_back(kv.second.stream, kv.second.read_ud);
      }
      streams_.clear();
    }
    for (auto& [s, ud] : to_close) {
      pa_stream_set_read_callback(s, nullptr, nullptr);
      delete static_cast<StreamUd*>(ud);
      pa_stream_disconnect(s);
      pa_stream_unref(s);
    }
    pa_context_set_subscribe_callback(ctx_, nullptr, nullptr);
    pa_context_set_state_callback(ctx_, nullptr, nullptr);
    pa_context_disconnect(ctx_);
    pa_context_unref(ctx_);
    ctx_ = nullptr;
    pa_threaded_mainloop_unlock(ml_);
  }
  if (ml_) {
    pa_threaded_mainloop_stop(ml_);
    pa_threaded_mainloop_free(ml_);
    ml_ = nullptr;
  }
  sink_monitors_.clear();
  attached_.store(0);
  if (was_running) fprintf(stderr, "[PULSE-SI] Stopped\n");
}

#endif  // __linux__
