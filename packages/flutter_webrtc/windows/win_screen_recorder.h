#ifndef FLUTTER_WEBRTC_WIN_SCREEN_RECORDER_H_
#define FLUTTER_WEBRTC_WIN_SCREEN_RECORDER_H_

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace flutter_webrtc_plugin {

using Microsoft::WRL::ComPtr;

class WinScreenRecorder {
 public:
  static WinScreenRecorder& GetInstance();

  WinScreenRecorder(const WinScreenRecorder&) = delete;
  WinScreenRecorder& operator=(const WinScreenRecorder&) = delete;

  using Completion = std::function<void(const std::string& error)>;

  // `render_device_id` / `capture_device_id` are MMDevice endpoint ids (the
  // ones Hollow's settings hold via win32audio) — empty = system default.
  // Recording MUST loopback the endpoint Hollow actually plays remote voices
  // to and capture the mic Hollow actually uses; the eConsole defaults were
  // why "headset selected in Hollow + speakers as Windows default" produced
  // a silent recording (issue #53).
  void Start(const std::string& output_path,
             const std::string& render_device_id,
             const std::string& capture_device_id,
             Completion completion);
  void Stop(Completion completion);

  bool IsRecording() const { return recording_.load(); }
  bool LastCapturedSystemAudio() const { return captured_system_audio_; }

 private:
  WinScreenRecorder();
  ~WinScreenRecorder();

  bool InitD3D11();
  bool InitSinkWriter(const std::wstring& path, UINT32 w, UINT32 h);
  bool InitGraphicsCapture(HMONITOR monitor, UINT32 w, UINT32 h);
  void StartAudioCapture();
  void AudioThread(bool loopback);
  void MixThread();
  void OnFrameArrived(
      winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool const& pool,
      winrt::Windows::Foundation::IInspectable const&);
  void WriteVideoFrame(ID3D11Texture2D* tex, INT64 qpc);
  void WriteMixedPcm(const int16_t* data, UINT32 frames);
  void Cleanup();

  std::atomic<bool> recording_{false};
  bool captured_system_audio_ = false;
  std::mutex mtx_;

  // D3D11
  ComPtr<ID3D11Device> device_;
  ComPtr<ID3D11DeviceContext> ctx_;
  ComPtr<ID3D11Texture2D> staging_tex_;

  // Media Foundation
  ComPtr<IMFSinkWriter> writer_;
  DWORD video_idx_ = 0;
  DWORD audio_idx_ = 0;  // ONE mixed loopback+mic track (see InitSinkWriter)
  bool writer_started_ = false;
  INT64 base_qpc_ = 0;
  LARGE_INTEGER qpc_freq_ = {};
  bool has_audio_ = false;
  INT64 last_frame_qpc_ = 0;

  // Graphics Capture
  winrt::Windows::Graphics::Capture::GraphicsCaptureItem item_{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool pool_{nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureSession session_{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool::FrameArrived_revoker revoker_;

  // Audio threads
  std::thread loopback_thread_;
  std::thread mic_thread_;
  std::thread mix_thread_;
  std::atomic<bool> audio_running_{false};
  HANDLE loopback_event_ = nullptr;
  HANDLE mic_event_ = nullptr;

  // Mixer state: capture threads append s16 interleaved 48k stereo into the
  // rings (ring_mtx_); the mixer thread drains both on its own clock, sums
  // with saturation, and writes the single audio track.
  std::mutex ring_mtx_;
  std::vector<int16_t> sys_ring_;
  std::vector<int16_t> mic_ring_;
  INT64 mix_frames_written_ = 0;
  INT64 mix_base_ts_ = 0;
  bool audio_write_err_logged_ = false;
  std::string render_device_id_;
  std::string capture_device_id_;

  UINT32 cap_w_ = 0;
  UINT32 cap_h_ = 0;
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_WIN_SCREEN_RECORDER_H_
