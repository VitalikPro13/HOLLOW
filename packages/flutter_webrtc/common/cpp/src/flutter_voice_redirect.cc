#include "flutter_voice_redirect.h"

#ifdef _WIN32

#include "flutter_webrtc_base.h"

#include <algorithm>
#include <cstring>

namespace flutter_webrtc_plugin {

namespace {
// libwebrtc delivers remote audio as 10ms frames; a 48k stereo frame is 1920
// bytes. The wire length is u16, so a single packet's PCM must stay under
// ~65500 bytes. OnData frames are always well under this, but clamp defensively.
constexpr size_t kMaxPcmBytesPerPacket = 60000;

// libwebrtc's own track volume tops out here too.
constexpr float kMaxGain = 10.0f;

// Taps one connection may hold, so one peer's receivers never take the stream
// ids every other voice needs: 16 legs x 16 fit the 256 ids.
constexpr size_t kMaxVoicesPerConnection = 16;

float ClampGain(double volume) {
  if (!(volume > 0.0)) return 0.0f;  // NaN and negatives are silence
  return volume > kMaxGain ? kMaxGain : static_cast<float>(volume);
}
}  // namespace

// === AudioTrackSink: tag + forward one remote track's decoded PCM ============
class FlutterVoiceRedirect::Sink : public AudioTrackSink {
 public:
  Sink(FlutterVoiceRedirect* owner, uint8_t stream_id, double volume)
      : owner_(owner), stream_id_(stream_id), gain_(ClampGain(volume)) {}

  void SetGain(double volume) { gain_.store(ClampGain(volume)); }
  float Gain() const { return gain_.load(); }
  // After this nothing more reaches the child, even before RemoveSink runs.
  void Detach() { live_.store(false); }

  void OnData(const void* audio_data, int bits_per_sample, int sample_rate,
              size_t number_of_channels, size_t number_of_frames) override {
    if (bits_per_sample != 16 || sample_rate <= 0 || number_of_channels == 0 ||
        number_of_frames == 0) {
      return;
    }
    // The tap sits upstream of the track volume, so the listener's deafen or
    // slider only holds if it is applied here.
    const float gain = gain_.load();
    if (!live_.load() || gain <= 0.0f) return;
    size_t pcm_bytes =
        number_of_frames * number_of_channels * sizeof(int16_t);
    if (pcm_bytes > kMaxPcmBytesPerPacket) pcm_bytes = kMaxPcmBytesPerPacket;

    // Frame: [u16 payload_len][u8 stream_id][u16 rate][u8 ch][pcm...]
    // payload_len counts the bytes AFTER it.
    const size_t payload_len = 1 + 2 + 1 + pcm_bytes;
    std::vector<uint8_t> pkt(2 + payload_len);
    pkt[0] = static_cast<uint8_t>(payload_len & 0xFF);
    pkt[1] = static_cast<uint8_t>((payload_len >> 8) & 0xFF);
    pkt[2] = stream_id_;
    pkt[3] = static_cast<uint8_t>(sample_rate & 0xFF);
    pkt[4] = static_cast<uint8_t>((sample_rate >> 8) & 0xFF);
    pkt[5] = static_cast<uint8_t>(number_of_channels & 0xFF);
    std::memcpy(pkt.data() + 6, audio_data, pcm_bytes);
    if (gain != 1.0f) {
      const int16_t* in = static_cast<const int16_t*>(audio_data);
      for (size_t i = 0; i < pcm_bytes / sizeof(int16_t); ++i) {
        const float v = std::clamp(static_cast<float>(in[i]) * gain, -32768.0f,
                                   32767.0f);
        const int16_t out = static_cast<int16_t>(v);
        std::memcpy(pkt.data() + 6 + i * sizeof(int16_t), &out, sizeof(out));
      }
    }

    owner_->EnqueuePacket(std::move(pkt));
  }

 private:
  FlutterVoiceRedirect* owner_;
  uint8_t stream_id_;
  std::atomic<float> gain_;
  std::atomic<bool> live_{true};
};

// === lifecycle ===============================================================

FlutterVoiceRedirect::FlutterVoiceRedirect() = default;

FlutterVoiceRedirect::~FlutterVoiceRedirect() {
  // Best-effort: tear the child + writer down. Tracks are detached by Stop();
  // by the time we're destroyed the base/tracks may be gone, so we don't touch
  // them here — just the child/writer we own. Same safe ordering as Stop():
  // stop + abort-any-stuck-WriteFile + join BEFORE closing the pipe handle.
  if (writer_running_.exchange(false) && writer_thread_.joinable()) {
    queue_cv_.notify_all();
    CancelSynchronousIo(writer_thread_.native_handle());
    writer_thread_.join();
  } else if (writer_thread_.joinable()) {
    writer_thread_.join();
  }
  ShutdownChild();
  running_.store(false);
}

std::wstring FlutterVoiceRedirect::FindRenderExe() {
  wchar_t module_path[MAX_PATH] = {0};
  DWORD n = GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return L"";
  std::wstring dir(module_path, n);
  size_t slash = dir.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return L"";
  dir = dir.substr(0, slash + 1);  // include trailing separator

  const wchar_t* names[] = {L"screen_audio_capturer.exe",
                            L"screen_audio_test.exe"};
  for (const wchar_t* name : names) {
    std::wstring candidate = dir + name;
    if (GetFileAttributesW(candidate.c_str()) != INVALID_FILE_ATTRIBUTES) {
      return candidate;
    }
  }
  return L"";
}

bool FlutterVoiceRedirect::SpawnChild() {
  if (child_process_ != nullptr) return true;

  std::wstring exe = FindRenderExe();
  if (exe.empty()) {
    OutputDebugStringA(
        "[VOICE-REDIRECT] render-pcm exe not found next to app\n");
    return false;
  }

  // Anonymous pipe for the child's stdin. The READ end must be inheritable (the
  // child reads it); keep OUR write end non-inheritable.
  SECURITY_ATTRIBUTES sa = {};
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;
  sa.lpSecurityDescriptor = nullptr;

  HANDLE stdin_rd = nullptr, stdin_wr = nullptr;
  if (!CreatePipe(&stdin_rd, &stdin_wr, &sa, 0)) {
    OutputDebugStringA("[VOICE-REDIRECT] CreatePipe failed\n");
    return false;
  }
  // Our write end stays in-process only.
  SetHandleInformation(stdin_wr, HANDLE_FLAG_INHERIT, 0);

  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = stdin_rd;
  // Let the child's stdout/stderr go to ours (diagnostics). NULL is also fine.
  si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
  si.hStdError = GetStdHandle(STD_ERROR_HANDLE);

  PROCESS_INFORMATION pi = {};
  std::wstring cmd = L"\"" + exe + L"\" --mode render-pcm";
  // CreateProcessW may modify the command-line buffer -> use a mutable copy.
  std::vector<wchar_t> cmd_buf(cmd.begin(), cmd.end());
  cmd_buf.push_back(L'\0');

  BOOL ok = CreateProcessW(
      nullptr, cmd_buf.data(), nullptr, nullptr, /*bInheritHandles=*/TRUE,
      CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);

  // The child owns the read end now; close our copy regardless of success.
  CloseHandle(stdin_rd);

  if (!ok) {
    OutputDebugStringA("[VOICE-REDIRECT] CreateProcess(render-pcm) failed\n");
    CloseHandle(stdin_wr);
    return false;
  }

  child_process_ = pi.hProcess;
  child_thread_ = pi.hThread;
  child_stdin_wr_ = stdin_wr;
  child_pid_.store(pi.dwProcessId);
  OutputDebugStringA("[VOICE-REDIRECT] render-pcm child spawned\n");
  return true;
}

void FlutterVoiceRedirect::ShutdownChild() {
  // Closing our stdin write end gives the child EOF -> it exits its read loop.
  if (child_stdin_wr_) {
    CloseHandle(child_stdin_wr_);
    child_stdin_wr_ = nullptr;
  }
  if (child_process_) {
    if (WaitForSingleObject(child_process_, 1500) != WAIT_OBJECT_0) {
      TerminateProcess(child_process_, 0);
      WaitForSingleObject(child_process_, 500);
    }
    CloseHandle(child_process_);
    child_process_ = nullptr;
  }
  if (child_thread_) {
    CloseHandle(child_thread_);
    child_thread_ = nullptr;
  }
  child_pid_.store(0);
}

void FlutterVoiceRedirect::EnqueuePacket(std::vector<uint8_t>&& packet) {
  if (!writer_running_.load()) return;
  std::lock_guard<std::mutex> lock(queue_mutex_);
  // Bound the queue (~1s of 10ms frames across a few streams). Drop OLDEST so a
  // momentary pipe stall can't grow memory and latency stays bounded.
  constexpr size_t kMaxQueued = 600;
  if (queue_.size() >= kMaxQueued) {
    queue_.pop_front();
  }
  queue_.push_back(std::move(packet));
  queue_cv_.notify_one();
}

void FlutterVoiceRedirect::WriterLoop() {
  while (writer_running_.load()) {
    std::vector<uint8_t> pkt;
    {
      std::unique_lock<std::mutex> lock(queue_mutex_);
      queue_cv_.wait(lock, [this]() {
        return !writer_running_.load() || !queue_.empty();
      });
      if (!writer_running_.load() && queue_.empty()) break;
      if (queue_.empty()) continue;
      pkt = std::move(queue_.front());
      queue_.pop_front();
    }

    HANDLE h = child_stdin_wr_;
    if (h == nullptr) continue;
    const uint8_t* data = pkt.data();
    size_t remaining = pkt.size();
    while (remaining > 0 && writer_running_.load()) {
      DWORD written = 0;
      if (!WriteFile(h, data, static_cast<DWORD>(remaining), &written,
                     nullptr) ||
          written == 0) {
        // Child gone / pipe broken — stop the writer; Stop() will clean up.
        OutputDebugStringA("[VOICE-REDIRECT] pipe write failed\n");
        writer_running_.store(false);
        break;
      }
      data += written;
      remaining -= written;
    }
  }
}

bool FlutterVoiceRedirect::ChildLost() const {
  if (child_process_ == nullptr) return false;
  return !writer_running_.load() ||
         WaitForSingleObject(child_process_, 0) == WAIT_OBJECT_0;
}

void FlutterVoiceRedirect::StartWriter() {
  if (writer_running_.load()) return;
  // A writer stopped by a failed write is still joinable; assigning over it
  // would std::terminate.
  if (writer_thread_.joinable()) writer_thread_.join();
  writer_running_.store(true);
  writer_thread_ = std::thread([this]() { WriterLoop(); });
}

void FlutterVoiceRedirect::DropClosedConnections(FlutterWebRTCBase* base) {
  Detach(base,
         std::stable_partition(entries_.begin(), entries_.end(),
                               [base](const Entry& e) {
                                 return base->PeerConnectionForId(e.pc_id) !=
                                        nullptr;
                               }),
         /*restore=*/false);
}

size_t FlutterVoiceRedirect::TapsOn(const std::string& pc_id) const {
  return static_cast<size_t>(
      std::count_if(entries_.begin(), entries_.end(), [&pc_id](const Entry& e) {
        return e.tapped && e.pc_id == pc_id;
      }));
}

bool FlutterVoiceRedirect::Start(FlutterWebRTCBase* base,
                                 const std::vector<Target>& targets) {
  if (base == nullptr) return false;

  // A child that died mid-share is not replaced before Stop: the capturer
  // excludes only its pid, so a new child's voices would reach the share.
  // Until then every voice stays silent in hollow.exe.
  const bool fresh = child_process_ == nullptr;
  const bool lost = ChildLost();
  if (lost) OutputDebugStringA("[VOICE-REDIRECT] render-pcm child lost\n");
  if (!lost) {
    if (!SpawnChild()) return false;
    StartWriter();
  }
  DropClosedConnections(base);

  for (const Target& t : targets) {
    if (t.pc_id.empty() || t.receiver_id.empty()) continue;
    // Only the named connection's receivers: a track id is the sender's
    // choice and could name our microphone or another member (HOL-SEC-191).
    RTCPeerConnection* pc = base->PeerConnectionForId(t.pc_id);
    if (pc == nullptr) {
      OutputDebugStringA("[VOICE-REDIRECT] connection not found\n");
      continue;
    }
    std::vector<scoped_refptr<RTCAudioTrack>> tracks;
    auto receivers = pc->receivers();
    for (scoped_refptr<RTCRtpReceiver> receiver : receivers.std_vector()) {
      scoped_refptr<RTCMediaTrack> track = receiver->track();
      if (nullptr == track.get()) continue;
      if (receiver->id().std_string() == t.receiver_id &&
          track->kind().std_string() == "audio") {
        tracks.push_back(scoped_refptr<RTCAudioTrack>(
            static_cast<RTCAudioTrack*>(track.get())));
      }
    }
    if (tracks.empty()) {
      OutputDebugStringA("[VOICE-REDIRECT] receiver not found\n");
      continue;
    }

    // Re-attach every receiver under this name: one the connection opened
    // since may share it, and a wrapper says nothing of which track is new.
    // In-process playout stays 0 throughout.
    Detach(base,
           std::stable_partition(entries_.begin(), entries_.end(),
                                 [&t](const Entry& e) {
                                   return e.pc_id != t.pc_id ||
                                          e.receiver_id != t.receiver_id;
                                 }),
           /*restore=*/false);
    for (const auto& track : tracks) {
      // Over a cap the voice gets no tap and stays silent in hollow.exe: the
      // listener misses it, the share never hears it.
      const int stream_id =
          TapsOn(t.pc_id) < kMaxVoicesPerConnection ? FreeStreamId() : -1;
      const bool tapped = stream_id >= 0;
      if (!tapped) {
        OutputDebugStringA("[VOICE-REDIRECT] voice over its cap kept silent\n");
      }
      Entry entry;
      entry.pc_id = t.pc_id;
      entry.receiver_id = t.receiver_id;
      entry.track = track;
      entry.tapped = tapped;
      entry.stream_id = static_cast<uint8_t>(tapped ? stream_id : 0);
      entry.sink = std::make_shared<Sink>(this, entry.stream_id, t.volume);
      base->audio_op_queue().Post(
          "voiceRedirectAttach", [track, sink = entry.sink, tapped]() {
            if (tapped) track->AddSink(sink.get());
            track->SetVolume(0.0);
          });
      entries_.push_back(std::move(entry));
    }
  }

  running_.store(!lost && !entries_.empty());
  if (entries_.empty() && fresh) {
    // Nothing got attached, so no share relies on this child yet.
    Stop(base);
    return false;
  }
  return !lost;
}

int FlutterVoiceRedirect::FreeStreamId() const {
  for (int id = 0; id <= 0xFF; ++id) {
    if (std::none_of(entries_.begin(), entries_.end(), [id](const Entry& e) {
          return e.tapped && e.stream_id == id;
        })) {
      return id;
    }
  }
  return -1;
}

bool FlutterVoiceRedirect::SetWantedVolume(const std::string& pc_id,
                                           const std::string& receiver_id,
                                           double volume) {
  bool found = false;
  for (Entry& e : entries_) {
    if (e.pc_id == pc_id && e.receiver_id == receiver_id) {
      e.sink->SetGain(volume);
      found = true;
    }
  }
  return found;
}

void FlutterVoiceRedirect::Detach(FlutterWebRTCBase* base,
                                  std::vector<Entry>::iterator first,
                                  bool restore) {
  for (auto it = first; it != entries_.end(); ++it) {
    it->sink->Detach();
    const double wanted = restore ? it->sink->Gain() : 0.0;
    auto op = [track = it->track, sink = it->sink, tapped = it->tapped,
               restore, wanted]() {
      if (tapped) track->RemoveSink(sink.get());
      if (restore) track->SetVolume(wanted);
    };
    // Through the queue, behind any volume op still waiting on it.
    if (base != nullptr) {
      base->audio_op_queue().Post("voiceRedirectDetach", std::move(op));
    } else {
      op();
    }
  }
  entries_.erase(first, entries_.end());
}

void FlutterVoiceRedirect::Stop(FlutterWebRTCBase* base) {
  // Each voice goes back to hollow.exe at the volume the listener wants, not
  // full volume: a deafened listener stays deafened after the share.
  Detach(base, entries_.begin(), /*restore=*/true);

  // Stop the writer thread cleanly. It may be parked on the condvar (woken by
  // notify) or, in the worst case, blocked inside WriteFile on a stalled child.
  // CancelSynchronousIo aborts a stuck WriteFile so we can join WITHOUT closing
  // the pipe handle out from under the thread (which would be a use-after-close).
  if (writer_running_.exchange(false) && writer_thread_.joinable()) {
    queue_cv_.notify_all();
    CancelSynchronousIo(writer_thread_.native_handle());
    writer_thread_.join();
  } else if (writer_thread_.joinable()) {
    writer_thread_.join();
  }

  // Now no thread touches child_stdin_wr_ — safe to close the pipe + child.
  ShutdownChild();

  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    queue_.clear();
  }
  running_.store(false);
}

}  // namespace flutter_webrtc_plugin

#endif  // _WIN32
