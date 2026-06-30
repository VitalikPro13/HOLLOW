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
}  // namespace

// === AudioTrackSink: tag + forward one remote track's decoded PCM ============
class FlutterVoiceRedirect::Sink : public AudioTrackSink {
 public:
  Sink(FlutterVoiceRedirect* owner, uint8_t stream_id)
      : owner_(owner), stream_id_(stream_id) {}

  void OnData(const void* audio_data, int bits_per_sample, int sample_rate,
              size_t number_of_channels, size_t number_of_frames) override {
    if (bits_per_sample != 16 || sample_rate <= 0 || number_of_channels == 0 ||
        number_of_frames == 0) {
      return;
    }
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

    owner_->EnqueuePacket(std::move(pkt));
  }

 private:
  FlutterVoiceRedirect* owner_;
  uint8_t stream_id_;
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
  if (child_process_ != nullptr) return true;  // already up

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

bool FlutterVoiceRedirect::Start(FlutterWebRTCBase* base,
                                 const std::vector<std::string>& track_ids) {
  if (base == nullptr) return false;

  if (!SpawnChild()) {
    return false;
  }

  // Start the writer thread once.
  if (!writer_running_.exchange(true)) {
    writer_thread_ = std::thread([this]() { WriterLoop(); });
  }

  for (const std::string& id : track_ids) {
    if (id.empty()) continue;
    if (entries_.find(id) != entries_.end()) continue;  // already redirecting

    scoped_refptr<RTCMediaTrack> track = base->MediaTrackForId(id);
    if (track == nullptr) {
      OutputDebugStringA("[VOICE-REDIRECT] track id not found\n");
      continue;
    }
    if (track->kind().std_string() != "audio") continue;

    auto audio_track =
        scoped_refptr<RTCAudioTrack>(static_cast<RTCAudioTrack*>(track.get()));

    Entry entry;
    entry.stream_id = next_stream_id_++;
    entry.track = audio_track;
    entry.sink = std::make_unique<Sink>(this, entry.stream_id);

    audio_track->AddSink(entry.sink.get());
    audio_track->SetVolume(0.0);  // mute hollow.exe's own playout of this track
    entries_.emplace(id, std::move(entry));
  }

  running_.store(!entries_.empty());
  if (entries_.empty()) {
    // Nothing got attached — don't leave a child running for no reason.
    Stop(base);
    return false;
  }
  return true;
}

void FlutterVoiceRedirect::Stop(FlutterWebRTCBase* base) {
  // Detach sinks + restore volume on every tracked track. After RemoveSink no
  // new packets enter the queue (the only producers are these sinks).
  for (auto& kv : entries_) {
    Entry& e = kv.second;
    if (e.track && e.sink) {
      e.track->RemoveSink(e.sink.get());
      e.track->SetVolume(1.0);  // restore normal in-process playout
    }
  }
  entries_.clear();
  next_stream_id_ = 0;

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
  (void)base;
}

}  // namespace flutter_webrtc_plugin

#endif  // _WIN32
