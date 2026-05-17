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

namespace flutter_webrtc_plugin {

using Microsoft::WRL::ComPtr;

class WinScreenRecorder {
 public:
  static WinScreenRecorder& GetInstance();

  WinScreenRecorder(const WinScreenRecorder&) = delete;
  WinScreenRecorder& operator=(const WinScreenRecorder&) = delete;

  using Completion = std::function<void(const std::string& error)>;

  void Start(const std::string& output_path, Completion completion);
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
  void OnFrameArrived(
      winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool const& pool,
      winrt::Windows::Foundation::IInspectable const&);
  void WriteVideoFrame(ID3D11Texture2D* tex, INT64 qpc);
  void WriteAudioPcm(const int16_t* data, UINT32 frames,
                     UINT32 sample_rate, UINT32 channels,
                     INT64 qpc, DWORD stream_idx);
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
  DWORD sys_audio_idx_ = 0;
  DWORD mic_audio_idx_ = 0;
  bool writer_started_ = false;
  INT64 base_qpc_ = 0;
  LARGE_INTEGER qpc_freq_ = {};
  bool has_sys_audio_ = false;
  bool has_mic_audio_ = false;
  INT64 last_frame_qpc_ = 0;

  // Graphics Capture
  winrt::Windows::Graphics::Capture::GraphicsCaptureItem item_{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool pool_{nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureSession session_{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool::FrameArrived_revoker revoker_;

  // Audio threads
  std::thread loopback_thread_;
  std::thread mic_thread_;
  std::atomic<bool> audio_running_{false};
  HANDLE loopback_event_ = nullptr;
  HANDLE mic_event_ = nullptr;

  UINT32 cap_w_ = 0;
  UINT32 cap_h_ = 0;
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_WIN_SCREEN_RECORDER_H_
