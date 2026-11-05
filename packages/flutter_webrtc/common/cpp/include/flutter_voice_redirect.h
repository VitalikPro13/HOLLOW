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
// This class taps each named receiver's track via AudioTrackSink (decoded PCM,
// upstream of the output volume so SetVolume(0) doesn't silence the tap), tags
// each with a stream id, and forwards framed PCM to the child's stdin over a pipe
// drained by a dedicated writer thread (so the libwebrtc audio thread never
// blocks). Mixing + resampling happen in the child (screen_audio_test --mode
// render-pcm). The sink applies each voice's wanted volume itself (it taps
// PCM upstream of the track volume); stop restores that volume in-process.
//
// Lifetime: child pid is published so the screen-audio capturer can exclude it.

#ifdef _WIN32

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
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

  // One received voice, named by its connection and receiver (never by its
  // track id, which the sender writes: HOL-SEC-191), and its wanted volume.
  struct Target {
    std::string pc_id;
    std::string receiver_id;
    double volume = 0.0;
  };

  // Begin redirecting the named voices to the out-of-process renderer.
  // Spawns the child if needed; each voice found among ITS connection's
  // receivers gets a sink and in-process volume 0, unknown ones are skipped.
  // Incremental: a name already redirected is re-attached with the new
  // volume, so a receiver the connection opened under it since is covered,
  // and voices of closed connections are dropped. A child that died stays
  // lost until Stop (new voices only go silent in-process). Returns true if
  // the child is running afterwards.
  bool Start(FlutterWebRTCBase* base, const std::vector<Target>& targets);

  // Stop redirecting: every voice plays in-process again at its last wanted
  // volume, then the writer and child shut down. Safe when not running.
  void Stop(FlutterWebRTCBase* base);

  // Records the wanted volume of a redirected voice, so a volume change
  // during the share never brings back hollow.exe's own playout of it.
  // False when that receiver is not redirected.
  bool SetWantedVolume(const std::string& pc_id,
                       const std::string& receiver_id,
                       double volume);

  bool active() const { return running_.load(); }

  // The render-pcm child process id (0 if not running). The screen-audio
  // capturer excludes this pid's tree for the entire-screen anti-echo.
  DWORD child_pid() const { return child_pid_.load(); }

 private:
  class Sink;  // defined in the .cc
  // One redirected receiver. Track ops run on the audio op queue, which
  // holds the sink alive until its RemoveSink has run.
  struct Entry {
    std::string pc_id;
    std::string receiver_id;
    scoped_refptr<RTCAudioTrack> track;
    std::shared_ptr<Sink> sink;
    // False: over a cap, silent in-process with no sink on the track.
    bool tapped = true;
    uint8_t stream_id = 0;
  };

  // The lowest stream id no tapped receiver holds, or -1 when all 256 are
  // taken. Each connection taps at most kMaxVoicesPerConnection; a voice
  // over either cap stays silent in-process (fails closed for its own
  // connection only).
  int FreeStreamId() const;
  size_t TapsOn(const std::string& pc_id) const;

  // Drops (without restoring) voices whose connection is gone.
  void DropClosedConnections(FlutterWebRTCBase* base);

  // The child exited or its pipe broke since it was spawned.
  bool ChildLost() const;
  void StartWriter();

  // Detaches entries [first, end) and erases them; restores in-process
  // playout at the wanted volume when [restore].
  void Detach(FlutterWebRTCBase* base, std::vector<Entry>::iterator first,
              bool restore);

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

  // Receivers currently redirected; one connection may repeat a receiver id.
  std::vector<Entry> entries_;

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
