#ifndef FLUTTER_VOICE_REDIRECT_HXX
#define FLUTTER_VOICE_REDIRECT_HXX

// Hollow fork (Windows-only): out-of-process redirect of REMOTE call/voice audio.
//
// Why: during an ENTIRE-SCREEN share with audio, we capture the whole system so
// viewers hear apps + Hollow's own in-app media. But we must NOT re-capture the
// call voices Hollow plays (echo). Windows can only filter loopback by process
// TREE, and Hollow's call voices + its in-app media render from the SAME
// hollow.exe — so they can't be split in-process. The fix: while such a share is
// active, play the remote voices from a SEPARATE child process (render-pcm) and
// SetVolume(0) the remote tracks inside hollow.exe. The entire-screen capture
// then EXCLUDES the child's pid (a descendant of hollow.exe), dropping only the
// voices while keeping hollow.exe's media.
//
// This class taps each remote audio track via AudioTrackSink (decoded PCM,
// upstream of the output volume so SetVolume(0) doesn't silence the tap), tags
// each with a stream id, and forwards framed PCM to the child's stdin over a pipe
// drained by a dedicated writer thread (so the libwebrtc audio thread never
// blocks). Mixing + resampling happen in the child (screen_audio_test --mode
// render-pcm). Restored fully on stop (RemoveSink + SetVolume(1.0)).
//
// Lifetime: child pid is published so the screen-audio capturer can exclude it.

#ifdef _WIN32

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "rtc_audio_track.h"
#include "rtc_media_track.h"
#include "rtc_types.h"

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

class FlutterWebRTCBase;

class FlutterVoiceRedirect {
 public:
  FlutterVoiceRedirect();
  ~FlutterVoiceRedirect();

  FlutterVoiceRedirect(const FlutterVoiceRedirect&) = delete;
  FlutterVoiceRedirect& operator=(const FlutterVoiceRedirect&) = delete;

  // Begin redirecting the given REMOTE audio track ids to the out-of-process
  // renderer. Spawns the child (if not already running), AddSink + SetVolume(0)
  // on each resolvable track. Tracks already being redirected are left as-is;
  // new ones are added. Returns true if the child is running afterwards. On
  // success, child_pid() is the renderer pid to exclude from screen capture.
  bool Start(FlutterWebRTCBase* base, const std::vector<std::string>& track_ids);

  // Stop redirecting: RemoveSink + SetVolume(1.0) on every tracked track, stop
  // the writer, and shut the child down. Safe to call when not running.
  void Stop(FlutterWebRTCBase* base);

  bool active() const { return running_.load(); }

  // The render-pcm child process id (0 if not running). The screen-audio
  // capturer excludes this pid's tree for the entire-screen anti-echo.
  DWORD child_pid() const { return child_pid_.load(); }

 private:
  // One redirected remote track: its sink + a refptr that keeps it alive while
  // the sink is attached + the stream id it forwards under.
  class Sink;  // defined in the .cc
  struct Entry {
    scoped_refptr<RTCAudioTrack> track;
    std::unique_ptr<Sink> sink;
    uint8_t stream_id = 0;
  };

  // --- child process / pipe ---
  bool SpawnChild();        // CreateProcess(render-pcm) + stdin pipe
  void ShutdownChild();     // close stdin, wait, terminate, close handles
  void WriterLoop();        // drains queue_ -> child stdin (WriteFile)
  // Enqueue one framed PCM packet (called from the audio thread via Sink).
  void EnqueuePacket(std::vector<uint8_t>&& packet);

  static std::wstring FindRenderExe();  // locate screen_audio_capturer.exe

  std::atomic<bool> running_{false};
  std::atomic<DWORD> child_pid_{0};

  // Child handles (guarded by start/stop, single-threaded w.r.t. lifecycle).
  HANDLE child_process_ = nullptr;
  HANDLE child_thread_ = nullptr;
  HANDLE child_stdin_wr_ = nullptr;  // our write end of the child's stdin

  // Tracks currently redirected, keyed by track id.
  std::map<std::string, Entry> entries_;
  uint8_t next_stream_id_ = 0;

  // PCM packet queue: audio threads push, writer thread pops -> pipe.
  std::mutex queue_mutex_;
  std::condition_variable queue_cv_;
  std::deque<std::vector<uint8_t>> queue_;
  std::atomic<bool> writer_running_{false};
  std::thread writer_thread_;
};

}  // namespace flutter_webrtc_plugin

#endif  // _WIN32

#endif  // FLUTTER_VOICE_REDIRECT_HXX
