#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <timeapi.h>  // timeBeginPeriod/timeEndPeriod (WIN32_LEAN_AND_MEAN drops mmsystem)
#include <fcntl.h>
#include <io.h>
#else
#include <csignal>
#ifdef __linux__
#include <poll.h>
#include <unistd.h>
#include <chrono>
#include "pulse_monitor_capturer.h"
#include "pulse_sink_input_capturer.h"
#include "x11_window_pid.h"
#endif
#endif

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <cmath>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include "wasapi_loopback_capturer.h"
#include "process_audio_capturer.h"
#include "multi_process_capturer.h"
#include "audio_session_enum.h"
#endif
#include "wav_writer.h"
#include "opus_encoder_wrapper.h"
#include "opus_decoder_wrapper.h"
#include "ogg_opus_writer.h"
#include "audio_player.h"

// --- Ctrl+C / signal handling ---
static std::atomic<bool> g_running{true};

#ifdef _WIN32
static BOOL WINAPI ConsoleHandler(DWORD) {
  fprintf(stderr, "\nStopping...\n");
  g_running.store(false);
  return TRUE;
}
static void InstallSignalHandler() {
  SetConsoleCtrlHandler(ConsoleHandler, TRUE);
}
#else
static void SignalHandler(int) {
  g_running.store(false);
}
static void InstallSignalHandler() {
  signal(SIGINT, SignalHandler);
  signal(SIGTERM, SignalHandler);
}
#endif

// --- CLI args ---
struct Options {
  std::string mode = "system";   // system, process, packet, pipe, render, encode
  unsigned int pid = 0;          // DWORD on Windows; portable type for cross-platform parse
  unsigned int exclude_pid = 0;  // EXCLUDE this process tree from system capture
                                 // (Hollow's own PID — avoids capturing the call
                                 // audio it plays back -> echo). Used only when
                                 // pid == 0 (whole-system share). Win 10 2004+.
  unsigned int window_pid = 0;   // SHARED WINDOW's process id. The exe resolves
                                 // it to the set of audio-rendering pids (browser
                                 // audio service, etc.), INCLUDE-captures that set
                                 // and MIXES — the per-app (Discord) share path.
                                 // Takes precedence over pid/exclude_pid.
  unsigned long long window_hwnd = 0;  // SHARED WINDOW's HWND (decimal). PREFERRED
                                 // per-app entry: the exe resolves HWND -> pid
                                 // itself (GetWindowThreadProcessId), so it does
                                 // not depend on the caller knowing the pid (the
                                 // desktop source `id` IS the HWND). If set, this
                                 // overrides window_pid.
  int duration = 10;
  std::string format = "both";   // "wav", "opus", "both"
  std::string output = "captured_audio";
  int queue_cap = 50;            // packet queue capacity (matches plugin)
  int bitrate = 0;               // Opus bitrate override for encode mode (0 = default 128k)
};

static void PrintUsage() {
  fprintf(stderr,
    "Usage: screen_audio_test.exe [options]\n"
    "\n"
    "Modes:\n"
    "  system   - WASAPI loopback -> direct file write (default)\n"
    "  process  - Per-process audio capture -> direct file write\n"
    "  packet   - WASAPI -> Opus encode -> packet queue -> drain thread\n"
    "             -> Opus decode -> WAV file (mirrors plugin pipeline)\n"
    "  pipe     - WASAPI -> Opus encode -> framed binary on stdout\n"
    "             For out-of-process capture by the Flutter app\n"
    "  render   - Read framed Opus from stdin -> decode -> platform playback\n"
    "             For out-of-process audio rendering by the Flutter app\n"
    "  render-pcm - Read framed raw PCM from stdin -> platform playback (no Opus).\n"
    "             For out-of-process playback of decoded call/voice audio so it\n"
    "             renders from a SEPARATE pid (excluded from entire-screen capture)\n"
    "  encode   - Read raw PCM from stdin -> Opus encode -> framed on stdout\n"
    "             For out-of-process encoding (macOS/Linux SEND path)\n"
    "\n"
    "Options:\n"
    "  --mode system|process|packet|pipe|render  Capture mode (default: system)\n"
    "  --pid <pid>             Target process ID (process mode, INCLUDE).\n"
    "                          Omit for EXCLUDE self mode.\n"
    "  --exclude-pid <pid>     With pid==0 (whole-system), capture all audio\n"
    "                          EXCLUDING this process tree (e.g. the host app,\n"
    "                          to avoid echoing call audio). Win 10 2004+.\n"
    "  --window-hwnd <hwnd>    Per-app share (PREFERRED): the shared WINDOW's\n"
    "                          HWND (decimal). The exe resolves HWND -> pid ->\n"
    "                          audio-rendering pid set itself, INCLUDE-captures\n"
    "                          that set and mixes. Use this when the caller knows\n"
    "                          the window handle but not its pid. Win 10 2004+.\n"
    "  --window-pid <pid>      Per-app share: the shared WINDOW's process id\n"
    "                          (alternative to --window-hwnd when the pid is\n"
    "                          already known). INCLUDE-captures the resolved\n"
    "                          audio pids and mixes. Silent app -> silence\n"
    "                          (no system-audio fallback). Win 10 2004+.\n"
    "  --window-xid <xid>      Per-app share (Linux): the shared WINDOW's X11\n"
    "                          window id. Resolved to a pid via _NET_WM_PID,\n"
    "                          then that process TREE's sink-inputs are\n"
    "                          INCLUDE-captured and mixed. Silent app ->\n"
    "                          silence (no system-audio fallback).\n"
    "  --duration <seconds>    Capture duration (default: 10)\n"
    "  --format wav|opus|both  Output format (default: both)\n"
    "  --output <basename>     Output file basename (default: captured_audio)\n"
    "  --queue-cap <n>         Packet queue capacity (default: 50)\n"
    "  --bitrate <bps>         Opus bitrate for encode mode (default: 128000)\n"
    "  --help                  Show this help\n"
    "\n"
    "Packet mode outputs:\n"
    "  <basename>_raw.wav            - Raw PCM from WASAPI (before encode)\n"
    "  <basename>_packet_decoded.wav - Decoded from packets (after queue)\n"
    "  <basename>_direct_roundtrip.wav - Encode+decode without queue\n"
  );
}

static Options ParseArgs(int argc, char* argv[]) {
  Options opts;
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--help" || arg == "-h") {
      PrintUsage();
      exit(0);
    } else if (arg == "--mode" && i + 1 < argc) {
      opts.mode = argv[++i];
    } else if (arg == "--pid" && i + 1 < argc) {
      opts.pid = static_cast<unsigned int>(atoi(argv[++i]));
    } else if (arg == "--exclude-pid" && i + 1 < argc) {
      opts.exclude_pid = static_cast<unsigned int>(atoi(argv[++i]));
    } else if (arg == "--window-pid" && i + 1 < argc) {
      opts.window_pid = static_cast<unsigned int>(atoi(argv[++i]));
    } else if (arg == "--window-hwnd" && i + 1 < argc) {
      opts.window_hwnd = strtoull(argv[++i], nullptr, 10);
    } else if (arg == "--window-xid" && i + 1 < argc) {
      // Linux spelling of --window-hwnd: the shared window's X11 window id
      // (the desktop source `id` on X sessions). Resolved to a pid via
      // _NET_WM_PID inside the exe.
      opts.window_hwnd = strtoull(argv[++i], nullptr, 10);
    } else if (arg == "--duration" && i + 1 < argc) {
      opts.duration = atoi(argv[++i]);
    } else if (arg == "--format" && i + 1 < argc) {
      opts.format = argv[++i];
    } else if (arg == "--output" && i + 1 < argc) {
      opts.output = argv[++i];
    } else if (arg == "--queue-cap" && i + 1 < argc) {
      opts.queue_cap = atoi(argv[++i]);
    } else if (arg == "--bitrate" && i + 1 < argc) {
      opts.bitrate = atoi(argv[++i]);
    } else {
      fprintf(stderr, "Unknown option: %s\n", arg.c_str());
      PrintUsage();
      exit(1);
    }
  }
  return opts;
}

#ifdef _WIN32
// =============================================================================
// Original direct-write modes (system / process) — Windows only
// =============================================================================
static int RunDirectMode(const Options& opts) {
  bool want_wav = (opts.format == "wav" || opts.format == "both");
  bool want_opus = (opts.format == "opus" || opts.format == "both");

  std::mutex writer_mutex;
  WavWriter wav_writer;
  OpusEncoderWrapper* opus_enc = nullptr;
  OggOpusWriter* ogg_writer = nullptr;
  std::vector<uint8_t> opus_packet(4000);
  uint64_t total_frames = 0;
  int actual_rate = 0;
  bool first_frame = true;

  std::string wav_path = opts.output + ".wav";
  std::string ogg_path = opts.output + ".ogg";

  auto frame_callback = [&](const void* data, int bits_per_sample,
                            int sample_rate, size_t channels, size_t frames) {
    std::lock_guard<std::mutex> lock(writer_mutex);
    auto* pcm = static_cast<const int16_t*>(data);

    if (first_frame) {
      actual_rate = sample_rate;
      fprintf(stderr, "First frame: %dHz %zuch %dbit, %zu samples/frame\n",
              sample_rate, channels, bits_per_sample, frames);

      if (want_wav) {
        if (!wav_writer.Open(wav_path.c_str(), sample_rate,
                             static_cast<int>(channels), bits_per_sample)) {
          fprintf(stderr, "ERROR: Failed to open %s\n", wav_path.c_str());
          want_wav = false;
        }
      }

      if (want_opus) {
        if (sample_rate == 48000) {
          opus_enc = new OpusEncoderWrapper(48000,
                                            static_cast<int>(channels),
                                            OPUS_APPLICATION_AUDIO);
          if (opus_enc->valid()) {
            ogg_writer = new OggOpusWriter(
                ogg_path.c_str(), 48000,
                static_cast<int>(channels), opus_enc->lookahead());
          } else {
            fprintf(stderr, "ERROR: Opus encoder creation failed\n");
            delete opus_enc;
            opus_enc = nullptr;
          }
        } else {
          fprintf(stderr,
              "WARNING: Capture rate is %dHz. Opus requires 48kHz.\n"
              "         Skipping Opus encoding.\n",
              sample_rate);
          want_opus = false;
        }
      }
      first_frame = false;
    }

    if (want_wav) {
      wav_writer.WriteSamples(pcm, frames * channels);
    }

    if (opus_enc && ogg_writer) {
      int encoded = opus_enc->Encode(pcm, static_cast<int>(frames),
                                     opus_packet);
      if (encoded > 0) {
        ogg_writer->WritePacket(opus_packet.data(), encoded,
                                static_cast<int>(frames));
      }
    }

    total_frames += frames;
    if (actual_rate > 0 && total_frames % (actual_rate * 1) < frames) {
      double elapsed = static_cast<double>(total_frames) / actual_rate;
      fprintf(stderr, "\r  Captured: %.1f seconds...", elapsed);
    }
  };

  if (opts.mode == "system") {
    flutter_webrtc_plugin::WasapiLoopbackCapturer capturer;
    if (!capturer.Start(frame_callback)) {
      fprintf(stderr, "ERROR: Failed to start system loopback capture\n");
      return 1;
    }
    fprintf(stderr, "Capturing system audio...\n");

    DWORD start = GetTickCount();
    while (g_running.load()) {
      if (GetTickCount() - start >= static_cast<DWORD>(opts.duration * 1000))
        break;
      Sleep(100);
    }
    capturer.Stop();

  } else {
    if (!ProcessAudioCapturer::IsSupported()) {
      fprintf(stderr,
          "ERROR: Process loopback requires Windows 10 2004+ (build 19041)\n");
      return 1;
    }

    ProcessAudioCapturer capturer;
    bool include_mode = (opts.pid != 0);
    if (!capturer.Start(frame_callback, opts.pid, include_mode)) {
      fprintf(stderr, "ERROR: Failed to start process audio capture\n");
      return 1;
    }
    fprintf(stderr, "Capturing process audio (%s, PID %u)...\n",
            include_mode ? "INCLUDE" : "EXCLUDE-self",
            opts.pid ? opts.pid : GetCurrentProcessId());

    DWORD start = GetTickCount();
    while (g_running.load()) {
      if (GetTickCount() - start >= static_cast<DWORD>(opts.duration * 1000))
        break;
      Sleep(100);
    }
    capturer.Stop();
  }

  {
    std::lock_guard<std::mutex> lock(writer_mutex);
    wav_writer.Close();
    if (ogg_writer) { ogg_writer->Finalize(); delete ogg_writer; }
    if (opus_enc) { delete opus_enc; }
  }

  fprintf(stderr, "\n\n=== Done ===\n");
  if (actual_rate > 0) {
    double seconds = static_cast<double>(total_frames) / actual_rate;
    fprintf(stderr, "Captured: %llu frames (%.1f seconds) at %d Hz\n",
            static_cast<unsigned long long>(total_frames), seconds, actual_rate);
  }
  if (want_wav) fprintf(stderr, "WAV:  %s\n", wav_path.c_str());
  if (want_opus) fprintf(stderr, "OGG:  %s\n", ogg_path.c_str());

  return 0;
}

// =============================================================================
// Packet mode — mirrors the plugin pipeline exactly:
//
//   WASAPI capture thread:
//     callback → Opus encode → build [seq_u32_le][opus_bytes] → push to queue
//
//   Drain thread:
//     pop from queue → extract opus bytes → Opus decode → write WAV
//
// Also writes:
//   - Raw PCM WAV (what WASAPI actually delivered, before any encoding)
//   - Direct roundtrip WAV (encode+decode in callback, no queue)
//
// Comparing these three WAVs tells us exactly where corruption enters:
//   raw == clean, packet_decoded == looped  →  queue/packetization bug
//   raw == looped                           →  WASAPI itself is broken
//   raw == clean, all decoded == clean      →  pipeline is fine, must be ADM
// =============================================================================

struct PacketState {
  // Shared queue (capture thread pushes, drain thread pops)
  std::mutex queue_mutex;
  std::deque<std::vector<uint8_t>> packet_queue;
  HANDLE queue_event = nullptr;
  std::atomic<bool> active{false};

  // Capture-thread state (encoder, raw WAV, direct roundtrip)
  OpusEncoderWrapper* encoder = nullptr;
  std::vector<uint8_t> encode_buffer;
  uint32_t sequence_number = 0;

  WavWriter raw_writer;           // raw PCM from WASAPI
  WavWriter roundtrip_writer;     // encode+decode, no queue
  OpusDecoderWrapper* rt_decoder = nullptr;  // for roundtrip
  std::vector<int16_t> rt_pcm_out;

  // Drain-thread state (decoder, packet-decoded WAV)
  WavWriter packet_writer;
  OpusDecoderWrapper* pkt_decoder = nullptr;
  std::vector<int16_t> pkt_pcm_out;

  // Stats
  uint64_t total_frames = 0;
  uint32_t packets_encoded = 0;
  uint32_t packets_decoded = 0;
  uint32_t packets_dropped = 0;

  int queue_cap = 50;
  bool first_frame = true;
};

static void PacketDrainThread(PacketState* state) {
  fprintf(stderr, "[DRAIN] Thread started\n");

  while (state->active.load()) {
    WaitForSingleObject(state->queue_event, 100);
    if (!state->active.load()) break;

    std::deque<std::vector<uint8_t>> batch;
    {
      std::lock_guard<std::mutex> lock(state->queue_mutex);
      batch.swap(state->packet_queue);
    }

    for (auto& pkt : batch) {
      if (!state->active.load()) break;

      if (pkt.size() < 5) {
        fprintf(stderr, "[DRAIN] Skipping runt packet (%zu bytes)\n",
                pkt.size());
        continue;
      }

      // Parse: [seq_u32_le][opus_bytes...]
      uint32_t seq = pkt[0] | (pkt[1] << 8) | (pkt[2] << 16) | (pkt[3] << 24);
      const uint8_t* opus_data = pkt.data() + 4;
      int opus_len = static_cast<int>(pkt.size()) - 4;

      int samples = state->pkt_decoder->Decode(opus_data, opus_len,
                                                state->pkt_pcm_out);
      if (samples > 0) {
        state->packet_writer.WriteSamples(state->pkt_pcm_out.data(),
                                          samples * 2);  // stereo
        state->packets_decoded++;
      } else {
        fprintf(stderr, "[DRAIN] Decode failed for seq %u\n", seq);
      }

      // Progress log every 100 packets
      if (state->packets_decoded % 100 == 0 && state->packets_decoded > 0) {
        fprintf(stderr, "\r  [DRAIN] Decoded %u packets (dropped %u)...",
                state->packets_decoded, state->packets_dropped);
      }
    }
  }

  fprintf(stderr, "\n[DRAIN] Thread exiting. Decoded %u, dropped %u\n",
          state->packets_decoded, state->packets_dropped);
}

static int RunPacketMode(const Options& opts) {
  fprintf(stderr, "=== PACKET MODE ===\n");
  fprintf(stderr, "This mirrors the plugin's exact pipeline:\n");
  fprintf(stderr, "  WASAPI -> Opus encode -> [seq][opus] packet -> queue\n");
  fprintf(stderr, "  -> drain thread -> Opus decode -> WAV\n");
  fprintf(stderr, "Queue capacity: %d\n\n", opts.queue_cap);

  PacketState state;
  state.queue_cap = opts.queue_cap;
  state.queue_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!state.queue_event) {
    fprintf(stderr, "ERROR: CreateEvent failed\n");
    return 1;
  }

  // Create encoder (same as plugin: 48kHz stereo, AUDIO application)
  state.encoder = new OpusEncoderWrapper(48000, 2, OPUS_APPLICATION_AUDIO);
  if (!state.encoder->valid()) {
    fprintf(stderr, "ERROR: Opus encoder creation failed\n");
    return 1;
  }
  state.encode_buffer.resize(4000);

  // Create decoders
  state.rt_decoder = new OpusDecoderWrapper(48000, 2);
  state.pkt_decoder = new OpusDecoderWrapper(48000, 2);
  if (!state.rt_decoder->valid() || !state.pkt_decoder->valid()) {
    fprintf(stderr, "ERROR: Opus decoder creation failed\n");
    return 1;
  }

  // Open all three WAV files
  std::string raw_path = opts.output + "_raw.wav";
  std::string pkt_path = opts.output + "_packet_decoded.wav";
  std::string rt_path = opts.output + "_direct_roundtrip.wav";

  if (!state.raw_writer.Open(raw_path.c_str(), 48000, 2, 16)) {
    fprintf(stderr, "ERROR: Failed to open %s\n", raw_path.c_str());
    return 1;
  }
  if (!state.packet_writer.Open(pkt_path.c_str(), 48000, 2, 16)) {
    fprintf(stderr, "ERROR: Failed to open %s\n", pkt_path.c_str());
    return 1;
  }
  if (!state.roundtrip_writer.Open(rt_path.c_str(), 48000, 2, 16)) {
    fprintf(stderr, "ERROR: Failed to open %s\n", rt_path.c_str());
    return 1;
  }

  state.active.store(true);

  // Start drain thread BEFORE capture (same as plugin)
  std::thread drain_thread(PacketDrainThread, &state);

  // WASAPI capture callback — mirrors ScreenAudioCapturer::OnAudioFrame exactly
  auto frame_callback = [&state](const void* data, int bits_per_sample,
                                  int sample_rate, size_t channels,
                                  size_t frames) {
    if (!state.active.load()) return;

    auto* pcm = static_cast<const int16_t*>(data);

    if (state.first_frame) {
      fprintf(stderr, "First frame: %dHz %zuch %dbit, %zu samples/frame\n",
              sample_rate, channels, bits_per_sample, frames);
      state.first_frame = false;
    }

    // 1. Write raw PCM (what WASAPI delivered)
    state.raw_writer.WriteSamples(pcm, frames * channels);

    // 2. Opus encode (same as plugin)
    int encoded = state.encoder->Encode(pcm, static_cast<int>(frames),
                                        state.encode_buffer);
    if (encoded <= 0) return;

    // 3. Direct roundtrip: encode+decode without queue (control test)
    int rt_samples = state.rt_decoder->Decode(state.encode_buffer.data(),
                                               encoded, state.rt_pcm_out);
    if (rt_samples > 0) {
      state.roundtrip_writer.WriteSamples(state.rt_pcm_out.data(),
                                          rt_samples * channels);
    }

    // 4. Build packet: [seq_u32_le][opus_bytes] (same as plugin)
    uint32_t seq = state.sequence_number++;
    std::vector<uint8_t> packet(4 + encoded);
    packet[0] = static_cast<uint8_t>(seq);
    packet[1] = static_cast<uint8_t>(seq >> 8);
    packet[2] = static_cast<uint8_t>(seq >> 16);
    packet[3] = static_cast<uint8_t>(seq >> 24);
    std::memcpy(packet.data() + 4, state.encode_buffer.data(), encoded);

    // 5. Push to queue (same as plugin — drop if full)
    {
      std::lock_guard<std::mutex> lock(state.queue_mutex);
      if (static_cast<int>(state.packet_queue.size()) < state.queue_cap) {
        state.packet_queue.push_back(std::move(packet));
      } else {
        state.packets_dropped++;
      }
    }

    SetEvent(state.queue_event);
    state.packets_encoded++;
    state.total_frames += frames;
  };

  // Start WASAPI capture
  flutter_webrtc_plugin::WasapiLoopbackCapturer capturer;
  if (!capturer.Start(frame_callback)) {
    fprintf(stderr, "ERROR: Failed to start system loopback capture\n");
    state.active.store(false);
    SetEvent(state.queue_event);
    drain_thread.join();
    return 1;
  }
  fprintf(stderr, "Capturing system audio (packet mode)...\n");

  DWORD start = GetTickCount();
  while (g_running.load()) {
    if (GetTickCount() - start >= static_cast<DWORD>(opts.duration * 1000))
      break;
    Sleep(100);
  }

  // Stop capture first, then drain thread (same as plugin's Stop())
  capturer.Stop();
  fprintf(stderr, "\nCapture stopped. Flushing drain thread...\n");

  state.active.store(false);
  SetEvent(state.queue_event);
  drain_thread.join();

  // Finalize WAV files
  state.raw_writer.Close();
  state.packet_writer.Close();
  state.roundtrip_writer.Close();

  // Cleanup
  delete state.encoder;
  delete state.rt_decoder;
  delete state.pkt_decoder;
  CloseHandle(state.queue_event);

  // Summary
  fprintf(stderr, "\n=== PACKET MODE RESULTS ===\n");
  double seconds = state.total_frames > 0
      ? static_cast<double>(state.total_frames) / 48000.0
      : 0.0;
  fprintf(stderr, "Duration:    %.1f seconds (%llu frames)\n",
          seconds, static_cast<unsigned long long>(state.total_frames));
  fprintf(stderr, "Encoded:     %u packets\n", state.packets_encoded);
  fprintf(stderr, "Decoded:     %u packets\n", state.packets_decoded);
  fprintf(stderr, "Dropped:     %u packets (queue full)\n",
          state.packets_dropped);
  fprintf(stderr, "\nOutput files:\n");
  fprintf(stderr, "  RAW:       %s  (PCM straight from WASAPI)\n",
          raw_path.c_str());
  fprintf(stderr, "  ROUNDTRIP: %s  (encode+decode, no queue)\n",
          rt_path.c_str());
  fprintf(stderr, "  PACKET:    %s  (full queue pipeline)\n",
          pkt_path.c_str());
  fprintf(stderr, "\nCompare these files:\n");
  fprintf(stderr, "  If RAW is clean but PACKET is looped -> queue/packet bug\n");
  fprintf(stderr, "  If RAW is already looped -> WASAPI capture is broken\n");
  fprintf(stderr, "  If ALL are clean -> pipeline works, ADM is the problem\n");

  return 0;
}

// =============================================================================
// Pipe mode — out-of-process capturer for Flutter integration.
//
// Writes Opus packets to stdout (binary framed):
//   [uint16_le: payload_len][uint32_le: seq][...opus_bytes...]
//
// Control: reads single-byte commands from stdin:
//   'Q' or EOF → stop
//
// Designed to be spawned by the Flutter app as a child process.
// =============================================================================

static int RunPipeMode(const Options& opts) {
  // Switch stdout to binary mode (Windows defaults to text mode which
  // corrupts \n bytes to \r\n).
  _setmode(_fileno(stdout), _O_BINARY);
  _setmode(_fileno(stdin), _O_BINARY);

  fprintf(stderr, "[PIPE] Starting out-of-process audio capture\n");
  fprintf(stderr, "[PIPE] Duration: %d seconds (0 = until stdin EOF/Q)\n",
          opts.duration);

  OpusEncoderWrapper encoder(48000, 2, OPUS_APPLICATION_AUDIO);
  if (!encoder.valid()) {
    fprintf(stderr, "[PIPE] ERROR: Opus encoder creation failed\n");
    return 1;
  }

  std::vector<uint8_t> encode_buffer(4000);
  std::atomic<uint32_t> sequence_number{0};

  // Mutex for stdout writes (capture callback writes packets).
  std::mutex stdout_mutex;
  std::atomic<bool> active{true};

  uint64_t total_frames = 0;
  uint32_t packets_sent = 0;
  bool first_frame = true;

  auto frame_callback = [&](const void* data, int bits_per_sample,
                             int sample_rate, size_t channels, size_t frames) {
    if (!active.load()) return;

    auto* pcm = static_cast<const int16_t*>(data);

    if (first_frame) {
      fprintf(stderr, "[PIPE] First frame: %dHz %zuch %dbit, %zu samples\n",
              sample_rate, channels, bits_per_sample, frames);
      first_frame = false;
    }

    int encoded = encoder.Encode(pcm, static_cast<int>(frames), encode_buffer);
    if (encoded <= 0) return;

    // Build framed packet: [uint16_le: payload_len][uint32_le: seq][opus...]
    uint32_t seq = sequence_number.fetch_add(1);
    uint16_t payload_len = static_cast<uint16_t>(4 + encoded);

    uint8_t header[6];
    header[0] = static_cast<uint8_t>(payload_len);
    header[1] = static_cast<uint8_t>(payload_len >> 8);
    header[2] = static_cast<uint8_t>(seq);
    header[3] = static_cast<uint8_t>(seq >> 8);
    header[4] = static_cast<uint8_t>(seq >> 16);
    header[5] = static_cast<uint8_t>(seq >> 24);

    {
      std::lock_guard<std::mutex> lock(stdout_mutex);
      fwrite(header, 1, 6, stdout);
      fwrite(encode_buffer.data(), 1, encoded, stdout);
      fflush(stdout);
    }

    packets_sent++;
    total_frames += frames;

    if (packets_sent % 500 == 0) {
      double sec = static_cast<double>(total_frames) / 48000.0;
      fprintf(stderr, "[PIPE] Sent %u packets (%.1f sec)\n", packets_sent, sec);
    }
  };

  // Start capture. Precedence:
  //   --window-hwnd / --window-pid : per-app share — resolve the window to its
  //                  audio pids, INCLUDE-capture that set and mix (Discord model).
  //   --pid        : single explicit INCLUDE pid (legacy/manual).
  //   --exclude-pid: whole-system EXCLUDE the target process TREE. Entire-screen
  //                  anti-echo. The target is normally Hollow's out-of-process
  //                  VOICE-RENDER CHILD (a descendant of hollow.exe): excluding
  //                  the child drops the call voices it plays, but NOT its parent
  //                  hollow.exe — so Hollow's own in-app media is still captured.
  //                  (Voices are also SetVolume(0)'d inside hollow.exe so it never
  //                  renders them.) When no redirect child exists (e.g. share
  //                  without audio, or pre-redirect), the target is hollow.exe
  //                  itself (coarser — also drops Hollow's media).
  //   (none)       : plain system loopback.
  flutter_webrtc_plugin::WasapiLoopbackCapturer sys_capturer;
  ProcessAudioCapturer proc_capturer;
  MultiProcessCapturer multi_capturer;
  bool using_process = false;
  bool using_multi = false;

  // Per-app share is requested by EITHER a window HWND (preferred) or an
  // explicit window pid. Resolve the HWND to its owning pid here so we never
  // depend on the caller knowing the pid.
  const bool per_app_requested =
      (opts.window_hwnd != 0) || (opts.window_pid != 0);
  unsigned int resolved_window_pid = opts.window_pid;
  if (opts.window_hwnd != 0) {
    resolved_window_pid = PidForWindowHandle(opts.window_hwnd);
  }

  if (per_app_requested) {
    if (!ProcessAudioCapturer::IsSupported()) {
      fprintf(stderr,
              "[PIPE] ERROR: per-app capture requires Windows 10 2004+\n");
      return 1;
    }
    // Resolve the window pid to the audio-rendering pid set. An EMPTY set is
    // valid (silent app, OR an hwnd that no longer resolves) — the mixer emits
    // silence; we NEVER fall back to system capture on a per-app share (that is
    // what leaked Brave's audio). resolved_window_pid==0 -> empty set -> silence.
    std::vector<DWORD> pids = ResolveWindowToAudioPids(resolved_window_pid);
    fprintf(stderr,
            "[PIPE] Per-app share: window PID %u resolved to %zu audio pid(s)\n",
            resolved_window_pid, pids.size());
    if (!multi_capturer.Start(frame_callback, pids)) {
      fprintf(stderr,
              "[PIPE] ERROR: Failed to start per-app multi-capture\n");
      return 1;
    }
    using_multi = true;
    fprintf(stderr, "[PIPE] Capturing per-app audio (INCLUDE+mix)...\n");
  } else if (opts.pid != 0) {
    if (!ProcessAudioCapturer::IsSupported()) {
      fprintf(stderr, "[PIPE] ERROR: Process loopback requires Windows 10 2004+\n");
      return 1;
    }
    if (!proc_capturer.Start(frame_callback, opts.pid, true)) {
      fprintf(stderr, "[PIPE] ERROR: Failed to start process capture (PID %u)\n",
              opts.pid);
      return 1;
    }
    using_process = true;
    fprintf(stderr, "[PIPE] Capturing PID %u (INCLUDE mode)...\n", opts.pid);
  } else if (opts.exclude_pid != 0 && ProcessAudioCapturer::IsSupported()) {
    // Whole-system share, but EXCLUDE the host app's process tree so we don't
    // re-capture the call audio it's playing back (the macOS share path does the
    // same via excludesCurrentProcessAudio). Falls back to plain system loopback
    // below if this EXCLUDE capture can't start.
    if (proc_capturer.Start(frame_callback, opts.exclude_pid, false)) {
      using_process = true;
      fprintf(stderr,
              "[PIPE] Capturing system audio EXCLUDING PID %u (anti-echo)...\n",
              opts.exclude_pid);
    } else {
      fprintf(stderr,
              "[PIPE] EXCLUDE capture (PID %u) failed; falling back to system "
              "loopback (call audio may echo)\n",
              opts.exclude_pid);
    }
  }

  if (!using_process && !using_multi) {
    if (!sys_capturer.Start(frame_callback)) {
      fprintf(stderr, "[PIPE] ERROR: Failed to start WASAPI capture\n");
      return 1;
    }
    fprintf(stderr, "[PIPE] Capturing system audio...\n");
  }

  // Wait for duration or stdin signal.
  DWORD start_tick = GetTickCount();
  while (active.load() && g_running.load()) {
    if (opts.duration > 0) {
      if (GetTickCount() - start_tick >=
          static_cast<DWORD>(opts.duration * 1000))
        break;
    }

    // Non-blocking stdin check: peek for 'Q' or EOF.
    HANDLE hin = GetStdHandle(STD_INPUT_HANDLE);
    DWORD avail = 0;
    if (PeekNamedPipe(hin, nullptr, 0, nullptr, &avail, nullptr) && avail > 0) {
      char c = 0;
      DWORD read = 0;
      ReadFile(hin, &c, 1, &read, nullptr);
      if (read == 0 || c == 'Q' || c == 'q') {
        fprintf(stderr, "[PIPE] Received stop signal\n");
        break;
      }
    }

    Sleep(50);
  }

  active.store(false);
  if (using_multi)
    multi_capturer.Stop();
  else if (using_process)
    proc_capturer.Stop();
  else
    sys_capturer.Stop();

  double seconds = total_frames > 0
      ? static_cast<double>(total_frames) / 48000.0 : 0.0;
  fprintf(stderr, "[PIPE] Done. Sent %u packets (%.1f sec)\n",
          packets_sent, seconds);
  return 0;
}
#endif  // _WIN32

#ifdef __linux__
// =============================================================================
// Pipe mode (Linux) — out-of-process capturer for Flutter integration.
//
// Same contract as the Windows pipe mode: capture system output, Opus-encode,
// write framed packets to stdout:
//   [uint16_le: payload_len][uint32_le: seq][...opus_bytes...]
// Stop on stdin 'Q' or EOF. Capture source selection (mirrors Windows):
//   --window-xid / --window-pid : per-app share — resolve the X window to its
//                  pid (_NET_WM_PID), INCLUDE-capture the sink-inputs of that
//                  process TREE and mix. Unresolvable/silent app -> SILENCE,
//                  never the system mix.
//   --exclude-pid : entire-screen anti-echo — per-sink-input capture of
//                  everything EXCEPT that process tree (Hollow's call
//                  playback + own media + the render child). Falls back to
//                  the whole default-sink MONITOR if it can't start (echo
//                  returns there, acceptable degrade).
//   (none)        : whole default-sink monitor.
// =============================================================================

static int RunPipeModeLinux(const Options& opts) {
  fprintf(stderr, "[PIPE] Starting out-of-process audio capture (PulseAudio)\n");
  fprintf(stderr, "[PIPE] Duration: %d seconds (0 = until stdin EOF/Q)\n",
          opts.duration);

  OpusEncoderWrapper encoder(48000, 2, OPUS_APPLICATION_AUDIO);
  if (!encoder.valid()) {
    fprintf(stderr, "[PIPE] ERROR: Opus encoder creation failed\n");
    return 1;
  }

  std::vector<uint8_t> encode_buffer(4000);
  std::mutex stdout_mutex;
  std::atomic<bool> active{true};
  uint32_t sequence_number = 0;
  uint64_t total_frames = 0;
  uint32_t packets_sent = 0;

  // The capturer delivers exact 10ms 48k-stereo frames — Opus frame size, so
  // each callback encodes straight through with no re-blocking.
  auto frame_callback = [&](const int16_t* pcm, size_t frames) {
    if (!active.load()) return;

    int encoded = encoder.Encode(pcm, static_cast<int>(frames), encode_buffer);
    if (encoded <= 0) return;

    uint32_t seq = sequence_number++;
    uint16_t payload_len = static_cast<uint16_t>(4 + encoded);
    uint8_t header[6];
    header[0] = static_cast<uint8_t>(payload_len);
    header[1] = static_cast<uint8_t>(payload_len >> 8);
    header[2] = static_cast<uint8_t>(seq);
    header[3] = static_cast<uint8_t>(seq >> 8);
    header[4] = static_cast<uint8_t>(seq >> 16);
    header[5] = static_cast<uint8_t>(seq >> 24);

    {
      std::lock_guard<std::mutex> lock(stdout_mutex);
      fwrite(header, 1, 6, stdout);
      fwrite(encode_buffer.data(), 1, encoded, stdout);
      fflush(stdout);
    }

    packets_sent++;
    total_frames += frames;
    if (packets_sent % 500 == 0) {
      double sec = static_cast<double>(total_frames) / 48000.0;
      fprintf(stderr, "[PIPE] Sent %u packets (%.1f sec)\n", packets_sent, sec);
    }
  };

  PulseMonitorCapturer monitor_capturer;
  PulseSinkInputCapturer si_capturer;
  bool started = false;

  const bool per_app = (opts.window_hwnd != 0) || (opts.window_pid != 0);
  if (per_app) {
    const int target = opts.window_pid != 0
        ? static_cast<int>(opts.window_pid)
        : ResolveX11WindowPid(opts.window_hwnd);
    if (target == 0) {
      // Unresolvable window (stale id / wayland-native / no _NET_WM_PID):
      // the INCLUDE mixer with no matches emits SILENCE — by design we never
      // fall back to the system mix on a per-app share (audio-leak rule).
      fprintf(stderr,
              "[PIPE] Per-app share: window did not resolve to a pid — "
              "sharing silence\n");
    }
    if (!si_capturer.Start(PulseSinkInputCapturer::Mode::kIncludeTree, target,
                           frame_callback)) {
      fprintf(stderr, "[PIPE] ERROR: Failed to start per-app capture\n");
      return 1;
    }
    started = true;
    fprintf(stderr, "[PIPE] Capturing per-app audio (INCLUDE tree, pid %d)\n",
            target);
  } else if (opts.exclude_pid != 0) {
    if (si_capturer.Start(PulseSinkInputCapturer::Mode::kExcludeTree,
                          static_cast<int>(opts.exclude_pid),
                          frame_callback)) {
      started = true;
      fprintf(stderr,
              "[PIPE] Capturing system audio EXCLUDING pid %u tree "
              "(anti-echo)\n",
              opts.exclude_pid);
    } else {
      fprintf(stderr,
              "[PIPE] Per-sink-input capture failed; falling back to the "
              "whole monitor (call audio may echo)\n");
    }
  }

  if (!started) {
    if (!monitor_capturer.Start(frame_callback)) {
      fprintf(stderr, "[PIPE] ERROR: Failed to start monitor capture\n");
      return 1;
    }
    fprintf(stderr, "[PIPE] Capturing system audio (whole monitor)...\n");
  }

  // Wait for duration, stdin 'Q', or stdin EOF (parent died / stopped us).
  const auto start = std::chrono::steady_clock::now();
  while (active.load() && g_running.load()) {
    if (opts.duration > 0) {
      const auto elapsed = std::chrono::steady_clock::now() - start;
      if (elapsed >= std::chrono::seconds(opts.duration)) break;
    }

    struct pollfd pfd = {0 /* stdin */, POLLIN, 0};
    int r = poll(&pfd, 1, 100);
    if (r > 0) {
      if (pfd.revents & POLLIN) {
        char c = 0;
        ssize_t n = read(0, &c, 1);
        if (n <= 0 || c == 'Q' || c == 'q') {
          fprintf(stderr, "[PIPE] Received stop signal\n");
          break;
        }
      } else if (pfd.revents & (POLLHUP | POLLERR)) {
        fprintf(stderr, "[PIPE] stdin closed\n");
        break;
      }
    }
  }

  active.store(false);
  si_capturer.Stop();
  monitor_capturer.Stop();

  double seconds = total_frames > 0
      ? static_cast<double>(total_frames) / 48000.0 : 0.0;
  fprintf(stderr, "[PIPE] Done. Sent %u packets (%.1f sec)\n",
          packets_sent, seconds);
  return 0;
}
#endif  // __linux__

// =============================================================================
// Render mode — out-of-process audio renderer for Flutter integration.
//
// Reads framed Opus packets from stdin (binary):
//   [uint16_le: payload_len][uint32_le: seq][...opus_bytes...]
//
// Decodes with Opus and plays via waveOut. Runs until stdin EOF or 'Q'.
// =============================================================================

// AudioPlayer is defined in audio_player_{win,mac,linux}.cpp

static int RunRenderMode(const Options&) {
#ifdef _WIN32
  _setmode(_fileno(stdin), _O_BINARY);
#endif

  fprintf(stderr, "[RENDER] Starting out-of-process audio renderer\n");

  OpusDecoderWrapper decoder(48000, 2);
  if (!decoder.valid()) {
    fprintf(stderr, "[RENDER] ERROR: Opus decoder creation failed\n");
    return 1;
  }

  AudioPlayer player;
  if (!player.Start()) {
    fprintf(stderr, "[RENDER] ERROR: audio output open failed\n");
    return 1;
  }

  fprintf(stderr, "[RENDER] Audio output ready, reading packets from stdin...\n");

  std::vector<int16_t> pcm_out;
  std::vector<uint8_t> frame_buf;
  uint32_t packets_played = 0;

  // Diagnostics: packet-size histogram (tiny = silence-grade frames), max
  // inter-arrival gap, and short-decode counter per 500-packet (~5s) window.
  // These turn "the audio stutters" into numbers: a big arrival gap = the
  // transport clumps; tiny-packet dominance = the CAPTURE feeds silence;
  // rebuffers (from player stats) = the queue actually ran dry.
  uint32_t pkts_tiny = 0, pkts_small = 0, pkts_real = 0, short_decodes = 0;
  auto last_arrival = std::chrono::steady_clock::now();
  int64_t max_gap_ms = 0;

  // Read loop: [uint16_le: payload_len][payload...]
  while (g_running.load()) {
    uint8_t len_hdr[2];
    if (fread(len_hdr, 1, 2, stdin) != 2) break;

    uint16_t payload_len = len_hdr[0] | (len_hdr[1] << 8);
    if (payload_len < 5 || payload_len > 4004) {
      fprintf(stderr, "[RENDER] Bad payload len %u, skipping\n", payload_len);
      continue;
    }

    frame_buf.resize(payload_len);
    if (fread(frame_buf.data(), 1, payload_len, stdin) !=
        static_cast<size_t>(payload_len))
      break;

    auto now = std::chrono::steady_clock::now();
    int64_t gap_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                         now - last_arrival)
                         .count();
    last_arrival = now;
    if (packets_played > 0 && gap_ms > max_gap_ms) max_gap_ms = gap_ms;

    const uint8_t* opus_data = frame_buf.data() + 4;
    int opus_len = static_cast<int>(payload_len) - 4;
    if (opus_len <= 5) {
      pkts_tiny++;
    } else if (opus_len <= 25) {
      pkts_small++;
    } else {
      pkts_real++;
    }

    int samples = decoder.Decode(opus_data, opus_len, pcm_out);
    if (samples > 0) {
      if (samples != 480) short_decodes++;
      player.Push(pcm_out.data(), samples, 2);
      packets_played++;

      if (packets_played <= 5 || packets_played % 500 == 0) {
        AudioPlayer::Stats st = player.TakeStats();
        fprintf(stderr,
                "[RENDER] Played %u packets | sizes tiny/small/real "
                "%u/%u/%u | shortDec %u | maxArrivalGap %lldms | queue "
                "now/min/max %zu/%zu/%zu (samples) | rebuffers %u trims %u | "
                "pushed/filled %llu/%llu\n",
                packets_played, pkts_tiny, pkts_small, pkts_real,
                short_decodes, static_cast<long long>(max_gap_ms),
                st.queue_now, st.queue_min, st.queue_max, st.rebuffers,
                st.trims, static_cast<unsigned long long>(st.samples_pushed),
                static_cast<unsigned long long>(st.samples_filled));
        pkts_tiny = pkts_small = pkts_real = 0;
        short_decodes = 0;
        max_gap_ms = 0;
      }
    }
  }

  player.Stop();
  fprintf(stderr, "[RENDER] Done. Played %u packets\n", packets_played);
  return 0;
}

// =============================================================================
// Render-PCM mode — out-of-process RAW-PCM renderer + MIXER for Flutter.
//
// Reads framed raw interleaved 16-bit PCM from stdin, one frame per call/voice
// remote audio track:
//   [u16_le payload_len][u8 stream_id][u16_le src_rate][u8 src_channels][int16 PCM]
//   payload_len counts the bytes AFTER it (stream_id 1 + rate 2 + ch 1 + PCM).
//
// Each stream_id is one remote participant's decoded audio (delivered by the
// plugin's AudioTrackSink). They arrive independently and at possibly different
// rates/channel counts; we resample each to 48k stereo (per-stream resampler
// state, fractional cursor carried across that stream's frames) into a per-stream
// bounded buffer, and a wall-clock-paced mixer thread sums one 10ms frame across
// all streams and feeds the platform AudioPlayer (48k stereo). This is the same
// model as MultiProcessCapturer, just sink-fed instead of WASAPI-fed.
//
// Why a SEPARATE process: its audio renders under a pid != hollow.exe, so the
// entire-screen capture excludes this pid (anti-echo) while hollow.exe's own
// in-app media is still captured. The plugin SetVolume(0)'s the remote tracks so
// hollow.exe itself doesn't also render them.
// =============================================================================

#ifdef _WIN32

namespace {

// One remote participant's audio: a resampler cursor + a bounded 48k-stereo
// output buffer, all guarded by the shared mixer mutex.
struct RenderPcmStream {
  // Resampler state (source-frame cursor + carried last source frame).
  double src_pos = 0.0;
  int16_t prev_l = 0, prev_r = 0;
  bool have_prev = false;
  // Converted 48k-stereo, interleaved, awaiting the mixer.
  std::deque<int16_t> buffer;
};

constexpr int kRpDstRate = 48000;
constexpr int kRpDstCh = 2;
constexpr size_t kRpFrameInterleaved = (kRpDstRate / 100) * kRpDstCh;  // 960 = 10ms
// ~400ms per-stream cap so a fast/early stream can't grow unbounded; drop oldest.
constexpr size_t kRpMaxBuffered = kRpFrameInterleaved * 40;

// Resample one source chunk (src_rate/src_ch) to 48k stereo, appending to dst.
// Carries the cursor + last-frame in `st` so consecutive chunks of the SAME
// stream join seamlessly.
void ResampleChunkToStereo(RenderPcmStream& st, const int16_t* in,
                           size_t in_frames, int src_rate, int src_ch,
                           std::deque<int16_t>& dst) {
  if (in_frames == 0 || src_rate <= 0 || src_ch <= 0) return;

  auto src_frame = [&](long i, int16_t& l, int16_t& r) {
    if (i < 0) {
      if (st.have_prev) { l = st.prev_l; r = st.prev_r; return; }
      i = 0;
    }
    if (i >= static_cast<long>(in_frames)) i = static_cast<long>(in_frames) - 1;
    const size_t base = static_cast<size_t>(i) * static_cast<size_t>(src_ch);
    const int16_t s0 = in[base];
    if (src_ch == 1) { l = s0; r = s0; }
    else { l = s0; r = in[base + 1]; }  // ch>=2: first two channels
  };

  const double ratio = static_cast<double>(src_rate) / kRpDstRate;  // src/dst
  while (st.src_pos < static_cast<double>(in_frames)) {
    const long i0 = static_cast<long>(std::floor(st.src_pos));
    const double frac = st.src_pos - static_cast<double>(i0);
    int16_t l0, r0, l1, r1;
    src_frame(i0, l0, r0);
    src_frame(i0 + 1, l1, r1);
    const int li = static_cast<int>(static_cast<double>(l0) +
                                    (static_cast<double>(l1) - l0) * frac);
    const int ri = static_cast<int>(static_cast<double>(r0) +
                                    (static_cast<double>(r1) - r0) * frac);
    dst.push_back(static_cast<int16_t>(li));
    dst.push_back(static_cast<int16_t>(ri));
    st.src_pos += ratio;
  }
  st.src_pos -= static_cast<double>(in_frames);  // carry fraction to next chunk

  const size_t base = (in_frames - 1) * static_cast<size_t>(src_ch);
  const int16_t s0 = in[base];
  st.prev_l = s0;
  st.prev_r = (src_ch == 1) ? s0 : in[base + 1];
  st.have_prev = true;
}

}  // namespace

#endif  // _WIN32

static int RunRenderPcmMode(const Options&) {
#ifdef _WIN32
  _setmode(_fileno(stdin), _O_BINARY);

  fprintf(stderr, "[RENDER-PCM] Starting out-of-process PCM renderer+mixer\n");

  AudioPlayer player;
  if (!player.Start()) {
    fprintf(stderr, "[RENDER-PCM] ERROR: audio output open failed\n");
    return 1;
  }
  fprintf(stderr, "[RENDER-PCM] Audio output ready (%dHz %dch), "
                  "reading PCM from stdin...\n", kRpDstRate, kRpDstCh);

  std::mutex mix_mutex;
  std::map<uint8_t, RenderPcmStream> streams;  // stream_id -> resampler+buffer
  std::atomic<bool> active{true};

  // Mixer thread: wall-clock-paced, emits one summed 10ms frame per 10ms,
  // zero-filling streams that are momentarily short. Mirrors MultiProcessCapturer.
  std::thread mixer([&]() {
    timeBeginPeriod(1);
    std::vector<int16_t> frame(kRpFrameInterleaved);
    const ULONGLONG start = GetTickCount64();
    uint64_t emitted = 0;
    while (active.load()) {
      Sleep(5);
      const ULONGLONG now = GetTickCount64();
      const uint64_t due = (now - start) / 10;
      while (emitted < due && active.load()) {
        std::memset(frame.data(), 0, kRpFrameInterleaved * sizeof(int16_t));
        {
          std::lock_guard<std::mutex> lock(mix_mutex);
          for (auto& kv : streams) {
            auto& buf = kv.second.buffer;
            const size_t take = std::min(buf.size(), kRpFrameInterleaved);
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
        player.Push(frame.data(), kRpFrameInterleaved / kRpDstCh, kRpDstCh);
        ++emitted;
      }
    }
    timeEndPeriod(1);
  });

  std::vector<uint8_t> frame_buf;
  uint32_t chunks = 0;

  while (g_running.load()) {
    uint8_t len_hdr[2];
    if (fread(len_hdr, 1, 2, stdin) != 2) break;  // EOF / closed stdin
    uint16_t payload_len = len_hdr[0] | (len_hdr[1] << 8);
    if (payload_len < 4) {  // stream_id(1)+rate(2)+ch(1) minimum
      fprintf(stderr, "[RENDER-PCM] Runt payload len %u, stopping\n", payload_len);
      break;
    }

    frame_buf.resize(payload_len);
    if (fread(frame_buf.data(), 1, payload_len, stdin) !=
        static_cast<size_t>(payload_len))
      break;

    const uint8_t stream_id = frame_buf[0];
    const int src_rate = frame_buf[1] | (frame_buf[2] << 8);
    const int src_ch = frame_buf[3];
    const uint8_t* pcm_bytes = frame_buf.data() + 4;
    const size_t pcm_byte_len = payload_len - 4;
    if (src_rate <= 0 || src_ch <= 0 || (pcm_byte_len % 2) != 0) continue;

    const int16_t* in = reinterpret_cast<const int16_t*>(pcm_bytes);
    const size_t in_frames =
        (pcm_byte_len / sizeof(int16_t)) / static_cast<size_t>(src_ch);
    if (in_frames == 0) continue;

    {
      std::lock_guard<std::mutex> lock(mix_mutex);
      RenderPcmStream& st = streams[stream_id];
      ResampleChunkToStereo(st, in, in_frames, src_rate, src_ch, st.buffer);
      if (st.buffer.size() > kRpMaxBuffered) {
        st.buffer.erase(st.buffer.begin(),
                        st.buffer.begin() + (st.buffer.size() - kRpMaxBuffered));
      }
    }

    if (++chunks <= 5 || chunks % 1000 == 0) {
      fprintf(stderr, "[RENDER-PCM] chunk %u: stream %u, %zu frames @ %dHz/%dch\n",
              chunks, stream_id, in_frames, src_rate, src_ch);
    }
  }

  active.store(false);
  if (mixer.joinable()) mixer.join();
  player.Stop();
  fprintf(stderr, "[RENDER-PCM] Done. %u chunks over %zu stream(s)\n",
          chunks, streams.size());
  return 0;
#else
  // Non-Windows: the desktop voice-redirect path is Windows-only for now
  // (macOS uses excludesCurrentProcessAudio on the share capturer instead).
  fprintf(stderr, "[RENDER-PCM] Not supported on this platform\n");
  return 1;
#endif  // _WIN32
}

// =============================================================================
// Encode mode — out-of-process Opus encoder for Flutter integration.
//
// Reads raw interleaved 16-bit PCM (48kHz stereo) from stdin:
//   [uint16_le: pcm_byte_len][...int16 samples...]
//
// Re-blocks into 10ms (480-sample/channel) frames, Opus-encodes each, and
// writes framed packets to stdout in the SAME format the render path consumes:
//   [uint16_le: payload_len][uint32_le: seq][...opus_bytes...]
//
// This is the macOS/Linux SEND path: a native capturer (ScreenCaptureKit audio
// on macOS, PulseAudio monitor on Linux) delivers PCM, this mode encodes it,
// and Dart forwards the Opus frames over the WebRTC data channel (0x03). It is
// platform-agnostic (pure Opus, no capture) so it lives outside #ifdef _WIN32.
// =============================================================================

static int RunEncodeMode(const Options& opts) {
#ifdef _WIN32
  _setmode(_fileno(stdin), _O_BINARY);
  _setmode(_fileno(stdout), _O_BINARY);
#endif

  fprintf(stderr, "[ENCODE] Starting out-of-process Opus encoder\n");

  OpusEncoderWrapper encoder(48000, 2, OPUS_APPLICATION_AUDIO);
  if (!encoder.valid()) {
    fprintf(stderr, "[ENCODE] ERROR: Opus encoder creation failed\n");
    return 1;
  }
  // --bitrate overrides the default (e.g. 256000/510000 for higher fidelity).
  if (opts.bitrate > 0) {
    encoder.SetBitrate(opts.bitrate);
    fprintf(stderr, "[ENCODE] Bitrate set to %d bps\n", opts.bitrate);
  }

  const int kChannels = 2;
  const int kFrameSamples = 480;                 // 10ms @ 48kHz, per channel
  const int kFrameInterleaved = kFrameSamples * kChannels;

  std::vector<uint8_t> encode_buffer(4000);
  std::vector<int16_t> pcm_accum;                // leftover samples between reads
  pcm_accum.reserve(kFrameInterleaved * 4);
  std::vector<uint8_t> in_chunk;
  uint32_t sequence_number = 0;
  uint32_t packets_sent = 0;

  auto emit_frame = [&](const int16_t* frame) {
    int encoded = encoder.Encode(frame, kFrameSamples, encode_buffer);
    if (encoded <= 0) return;

    uint32_t seq = sequence_number++;
    uint16_t payload_len = static_cast<uint16_t>(4 + encoded);
    uint8_t header[6];
    header[0] = static_cast<uint8_t>(payload_len);
    header[1] = static_cast<uint8_t>(payload_len >> 8);
    header[2] = static_cast<uint8_t>(seq);
    header[3] = static_cast<uint8_t>(seq >> 8);
    header[4] = static_cast<uint8_t>(seq >> 16);
    header[5] = static_cast<uint8_t>(seq >> 24);

    fwrite(header, 1, 6, stdout);
    fwrite(encode_buffer.data(), 1, encoded, stdout);
    fflush(stdout);

    if (++packets_sent % 500 == 0)
      fprintf(stderr, "[ENCODE] Sent %u packets\n", packets_sent);
  };

  // Read loop: [uint16_le pcm_byte_len][pcm bytes...]
  while (g_running.load()) {
    uint8_t len_hdr[2];
    if (fread(len_hdr, 1, 2, stdin) != 2) break;  // EOF / closed stdin
    uint16_t pcm_len = len_hdr[0] | (len_hdr[1] << 8);
    if (pcm_len == 0) continue;
    if (pcm_len % 2 != 0) {
      fprintf(stderr, "[ENCODE] Odd PCM byte length %u, aborting\n", pcm_len);
      break;
    }

    in_chunk.resize(pcm_len);
    if (fread(in_chunk.data(), 1, pcm_len, stdin) != static_cast<size_t>(pcm_len))
      break;

    const int16_t* samples = reinterpret_cast<const int16_t*>(in_chunk.data());
    size_t sample_count = pcm_len / sizeof(int16_t);
    pcm_accum.insert(pcm_accum.end(), samples, samples + sample_count);

    // Drain whole 10ms frames.
    size_t off = 0;
    while (pcm_accum.size() - off >= static_cast<size_t>(kFrameInterleaved)) {
      emit_frame(pcm_accum.data() + off);
      off += kFrameInterleaved;
    }
    if (off > 0)
      pcm_accum.erase(pcm_accum.begin(), pcm_accum.begin() + off);
  }

  fprintf(stderr, "[ENCODE] Done. Sent %u packets\n", packets_sent);
  return 0;
}

// =============================================================================

int main(int argc, char* argv[]) {
  Options opts = ParseArgs(argc, argv);
  InstallSignalHandler();

  fprintf(stderr, "=== Screen Audio Test ===\n");
  fprintf(stderr, "Mode:     %s\n", opts.mode.c_str());
  if (opts.mode == "process") {
    if (opts.pid != 0)
      fprintf(stderr, "PID:      %u (INCLUDE)\n", opts.pid);
    else
      fprintf(stderr, "PID:      self (EXCLUDE)\n");
  }
  fprintf(stderr, "Duration: %d seconds\n", opts.duration);
  if (opts.mode != "packet")
    fprintf(stderr, "Format:   %s\n", opts.format.c_str());
  fprintf(stderr, "\n");

  if (opts.mode == "render") {
    return RunRenderMode(opts);
  } else if (opts.mode == "render-pcm") {
    return RunRenderPcmMode(opts);
  } else if (opts.mode == "encode") {
    return RunEncodeMode(opts);
#ifdef __linux__
  } else if (opts.mode == "pipe") {
    return RunPipeModeLinux(opts);
#endif
#ifdef _WIN32
  } else if (opts.mode == "pipe") {
    return RunPipeMode(opts);
  } else if (opts.mode == "packet") {
    return RunPacketMode(opts);
  } else if (opts.mode == "system" || opts.mode == "process") {
    return RunDirectMode(opts);
#endif
  } else {
    fprintf(stderr, "ERROR: Unknown mode '%s'\n", opts.mode.c_str());
    PrintUsage();
    return 1;
  }
}
