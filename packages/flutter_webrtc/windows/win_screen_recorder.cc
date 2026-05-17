#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "win_screen_recorder.h"

#include <audioclient.h>
#include <avrt.h>
#include <d3d11_1.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <ksmedia.h>
#include <mferror.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.Metadata.h>

#include <cstring>
#include <iostream>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "mf.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "windowsapp.lib")
#pragma comment(lib, "Mmdevapi.lib")
#pragma comment(lib, "Avrt.lib")

namespace flutter_webrtc_plugin {
namespace {

constexpr UINT32 kFps = 30;
constexpr UINT32 kVideoBitrate = 8'000'000;
constexpr UINT32 kAudioBitrate = 160'000;
constexpr UINT32 kSystemAudioSampleRate = 48000;
constexpr UINT32 kMicSampleRate = 44100;
constexpr UINT32 kAudioChannels = 2;
constexpr REFERENCE_TIME kHns100PerSec = 10'000'000LL;
constexpr int kFrameDurationMs = 10;

template <class T>
void SafeRelease(T*& p) {
  if (p) { p->Release(); p = nullptr; }
}

inline int16_t FloatToS16(float s) {
  if (s > 1.0f) s = 1.0f;
  if (s < -1.0f) s = -1.0f;
  return static_cast<int16_t>(s * 32767.0f);
}

bool IsFloatFmt(const WAVEFORMATEX* f) {
  if (f->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
  if (f->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(f);
    return ext->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
  }
  return false;
}

INT64 QpcTo100ns(INT64 qpc, const LARGE_INTEGER& freq) {
  return static_cast<INT64>(
      static_cast<double>(qpc) / freq.QuadPart * 10'000'000.0);
}

bool IsGraphicsCaptureAvailable() {
  return winrt::Windows::Foundation::Metadata::ApiInformation::IsTypePresent(
      L"Windows.Graphics.Capture.GraphicsCaptureSession");
}

winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice
WrapD3D11Device(ID3D11Device* d3d) {
  ComPtr<IDXGIDevice> dxgi;
  d3d->QueryInterface(IID_PPV_ARGS(&dxgi));
  winrt::com_ptr<::IInspectable> inspectable;
  CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(), inspectable.put());
  return inspectable.as<
      winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice>();
}

ID3D11Texture2D* GetDXGITexture(
    winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame const& frame,
    ID3D11Device* device) {
  auto surface = frame.Surface();
  auto interop = surface.as<
      Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
  ID3D11Texture2D* tex = nullptr;
  interop->GetInterface(IID_PPV_ARGS(&tex));
  return tex;
}

HRESULT CreateAudioMediaType(UINT32 sample_rate, UINT32 channels,
                             IMFMediaType** out) {
  ComPtr<IMFMediaType> mt;
  HRESULT hr = MFCreateMediaType(&mt);
  if (FAILED(hr)) return hr;
  mt->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  mt->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
  mt->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  mt->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate);
  mt->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
  mt->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, kAudioBitrate / 8);
  *out = mt.Detach();
  return S_OK;
}

HRESULT CreatePcmInputType(UINT32 sample_rate, UINT32 channels,
                           IMFMediaType** out) {
  ComPtr<IMFMediaType> mt;
  HRESULT hr = MFCreateMediaType(&mt);
  if (FAILED(hr)) return hr;
  mt->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  mt->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  mt->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  mt->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate);
  mt->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
  mt->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, channels * 2);
  mt->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, sample_rate * channels * 2);
  *out = mt.Detach();
  return S_OK;
}

}  // namespace

WinScreenRecorder& WinScreenRecorder::GetInstance() {
  static WinScreenRecorder instance;
  return instance;
}

WinScreenRecorder::WinScreenRecorder() {
  QueryPerformanceFrequency(&qpc_freq_);
}

WinScreenRecorder::~WinScreenRecorder() {
  if (recording_.load()) {
    recording_.store(false);
    audio_running_.store(false);
    Cleanup();
  }
}

// ---------------------------------------------------------------------------
// D3D11
// ---------------------------------------------------------------------------

bool WinScreenRecorder::InitD3D11() {
  D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0};
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT |
               D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 flags, levels, 1, D3D11_SDK_VERSION,
                                 device_.ReleaseAndGetAddressOf(),
                                 nullptr,
                                 ctx_.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    // Retry without VIDEO_SUPPORT (some GPUs lack it).
    flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                           flags, levels, 1, D3D11_SDK_VERSION,
                           device_.ReleaseAndGetAddressOf(),
                           nullptr,
                           ctx_.ReleaseAndGetAddressOf());
  }
  if (FAILED(hr)) {
    std::cerr << "[WinRec] D3D11CreateDevice failed: 0x" << std::hex << hr << "\n";
    return false;
  }

  // Enable multi-threaded D3D11 access (MF + Graphics Capture on different threads).
  ComPtr<ID3D10Multithread> mt;
  if (SUCCEEDED(device_.As(&mt))) {
    mt->SetMultithreadProtected(TRUE);
  }

  return true;
}

// ---------------------------------------------------------------------------
// Sink Writer
// ---------------------------------------------------------------------------

bool WinScreenRecorder::InitSinkWriter(const std::wstring& path,
                                       UINT32 w, UINT32 h) {
  HRESULT hr = MFStartup(MF_VERSION);
  if (FAILED(hr)) {
    std::cerr << "[WinRec] MFStartup failed\n";
    return false;
  }

  ComPtr<IMFAttributes> attrs;
  MFCreateAttributes(&attrs, 2);
  attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
  attrs->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);

  hr = MFCreateSinkWriterFromURL(path.c_str(), nullptr, attrs.Get(),
                                 writer_.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    std::cerr << "[WinRec] MFCreateSinkWriterFromURL failed: 0x" << std::hex << hr << "\n";
    return false;
  }

  // --- Video output (H.264) ---
  {
    ComPtr<IMFMediaType> out_mt;
    MFCreateMediaType(&out_mt);
    out_mt->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    out_mt->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    out_mt->SetUINT32(MF_MT_AVG_BITRATE, kVideoBitrate);
    MFSetAttributeSize(out_mt.Get(), MF_MT_FRAME_SIZE, w, h);
    MFSetAttributeRatio(out_mt.Get(), MF_MT_FRAME_RATE, kFps, 1);
    out_mt->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeRatio(out_mt.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);

    hr = writer_->AddStream(out_mt.Get(), &video_idx_);
    if (FAILED(hr)) {
      std::cerr << "[WinRec] AddStream(video) failed: 0x" << std::hex << hr << "\n";
      return false;
    }

    // Video input type: BGRA (what Graphics Capture produces).
    ComPtr<IMFMediaType> in_mt;
    MFCreateMediaType(&in_mt);
    in_mt->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    in_mt->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_ARGB32);
    MFSetAttributeSize(in_mt.Get(), MF_MT_FRAME_SIZE, w, h);
    MFSetAttributeRatio(in_mt.Get(), MF_MT_FRAME_RATE, kFps, 1);
    in_mt->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeRatio(in_mt.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);

    hr = writer_->SetInputMediaType(video_idx_, in_mt.Get(), nullptr);
    if (FAILED(hr)) {
      std::cerr << "[WinRec] SetInputMediaType(video) failed: 0x" << std::hex << hr << "\n";
      return false;
    }
  }

  // --- System audio output (AAC) ---
  {
    ComPtr<IMFMediaType> out_mt;
    CreateAudioMediaType(kSystemAudioSampleRate, kAudioChannels, &out_mt);
    hr = writer_->AddStream(out_mt.Get(), &sys_audio_idx_);
    if (FAILED(hr)) {
      std::cerr << "[WinRec] AddStream(sys audio) failed (non-fatal)\n";
    } else {
      ComPtr<IMFMediaType> in_mt;
      CreatePcmInputType(kSystemAudioSampleRate, kAudioChannels, &in_mt);
      hr = writer_->SetInputMediaType(sys_audio_idx_, in_mt.Get(), nullptr);
      if (FAILED(hr)) {
        std::cerr << "[WinRec] SetInputMediaType(sys audio) failed (non-fatal)\n";
      } else {
        has_sys_audio_ = true;
      }
    }
  }

  // --- Mic audio output (AAC) ---
  {
    ComPtr<IMFMediaType> out_mt;
    CreateAudioMediaType(kMicSampleRate, kAudioChannels, &out_mt);
    hr = writer_->AddStream(out_mt.Get(), &mic_audio_idx_);
    if (FAILED(hr)) {
      std::cerr << "[WinRec] AddStream(mic) failed (non-fatal)\n";
    } else {
      ComPtr<IMFMediaType> in_mt;
      CreatePcmInputType(kMicSampleRate, kAudioChannels, &in_mt);
      hr = writer_->SetInputMediaType(mic_audio_idx_, in_mt.Get(), nullptr);
      if (FAILED(hr)) {
        std::cerr << "[WinRec] SetInputMediaType(mic) failed (non-fatal)\n";
      } else {
        has_mic_audio_ = true;
      }
    }
  }

  return true;
}

// ---------------------------------------------------------------------------
// Graphics Capture
// ---------------------------------------------------------------------------

bool WinScreenRecorder::InitGraphicsCapture(HMONITOR monitor,
                                            UINT32 w, UINT32 h) {
  auto interop = winrt::get_activation_factory<
      winrt::Windows::Graphics::Capture::GraphicsCaptureItem,
      IGraphicsCaptureItemInterop>();

  HRESULT hr = S_OK;
  winrt::Windows::Graphics::Capture::GraphicsCaptureItem item{nullptr};
  hr = interop->CreateForMonitor(
      monitor,
      winrt::guid_of<winrt::Windows::Graphics::Capture::GraphicsCaptureItem>(),
      reinterpret_cast<void**>(winrt::put_abi(item)));
  if (FAILED(hr) || !item) {
    std::cerr << "[WinRec] CreateForMonitor failed: 0x" << std::hex << hr << "\n";
    return false;
  }
  item_ = item;

  auto winrt_device = WrapD3D11Device(device_.Get());

  pool_ = winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool::
      CreateFreeThreaded(
          winrt_device,
          winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,
          2, {static_cast<int32_t>(w), static_cast<int32_t>(h)});

  revoker_ = pool_.FrameArrived(
      winrt::auto_revoke,
      [this](auto const& pool, auto const&) { OnFrameArrived(pool, nullptr); });

  session_ = pool_.CreateCaptureSession(item_);
  session_.IsCursorCaptureEnabled(true);

  // Create a staging texture for CPU readback (MF Sink Writer with ARGB32
  // input needs CPU-accessible buffers on most encoder configurations).
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = w;
  desc.Height = h;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_STAGING;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  hr = device_->CreateTexture2D(&desc, nullptr, staging_tex_.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    std::cerr << "[WinRec] CreateTexture2D(staging) failed\n";
    return false;
  }

  return true;
}

// ---------------------------------------------------------------------------
// Frame handling
// ---------------------------------------------------------------------------

void WinScreenRecorder::OnFrameArrived(
    winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool const& pool,
    winrt::Windows::Foundation::IInspectable const&) {
  if (!recording_.load()) return;

  auto frame = pool.TryGetNextFrame();
  if (!frame) return;

  LARGE_INTEGER qpc;
  QueryPerformanceCounter(&qpc);

  // Frame rate limiting: skip frames that arrive faster than kFps.
  const INT64 min_interval = qpc_freq_.QuadPart / kFps;
  if (last_frame_qpc_ != 0 && (qpc.QuadPart - last_frame_qpc_) < min_interval) {
    frame.Close();
    return;
  }
  last_frame_qpc_ = qpc.QuadPart;

  auto* tex = GetDXGITexture(frame, device_.Get());
  if (tex) {
    WriteVideoFrame(tex, qpc.QuadPart);
    tex->Release();
  }
  frame.Close();
}

void WinScreenRecorder::WriteVideoFrame(ID3D11Texture2D* tex, INT64 qpc) {
  std::lock_guard<std::mutex> lock(mtx_);
  if (!writer_) return;

  if (!writer_started_) {
    HRESULT hr = writer_->BeginWriting();
    if (FAILED(hr)) {
      std::cerr << "[WinRec] BeginWriting failed: 0x" << std::hex << hr << "\n";
      return;
    }
    writer_started_ = true;
    base_qpc_ = qpc;
  }

  INT64 ts = QpcTo100ns(qpc - base_qpc_, qpc_freq_);
  if (ts < 0) ts = 0;

  // Copy GPU texture to staging for CPU access.
  ctx_->CopyResource(staging_tex_.Get(), tex);

  D3D11_MAPPED_SUBRESOURCE mapped = {};
  HRESULT hr = ctx_->Map(staging_tex_.Get(), 0, D3D11_MAP_READ, 0, &mapped);
  if (FAILED(hr)) return;

  UINT32 image_size = mapped.RowPitch * cap_h_;

  ComPtr<IMFMediaBuffer> buf;
  hr = MFCreateMemoryBuffer(image_size, &buf);
  if (SUCCEEDED(hr)) {
    BYTE* dst = nullptr;
    buf->Lock(&dst, nullptr, nullptr);
    // Copy row-by-row in case pitch differs from width * 4.
    for (UINT32 y = 0; y < cap_h_; ++y) {
      memcpy(dst + y * cap_w_ * 4,
             static_cast<const BYTE*>(mapped.pData) + y * mapped.RowPitch,
             cap_w_ * 4);
    }
    buf->Unlock();
    buf->SetCurrentLength(cap_w_ * 4 * cap_h_);

    ComPtr<IMFSample> sample;
    MFCreateSample(&sample);
    sample->AddBuffer(buf.Get());
    sample->SetSampleTime(ts);
    sample->SetSampleDuration(10'000'000LL / kFps);

    writer_->WriteSample(video_idx_, sample.Get());
  }

  ctx_->Unmap(staging_tex_.Get(), 0);
}

// ---------------------------------------------------------------------------
// Audio capture
// ---------------------------------------------------------------------------

void WinScreenRecorder::StartAudioCapture() {
  audio_running_.store(true);

  if (has_sys_audio_) {
    loopback_event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    loopback_thread_ = std::thread(&WinScreenRecorder::AudioThread, this, true);
  }
  if (has_mic_audio_) {
    mic_event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    mic_thread_ = std::thread(&WinScreenRecorder::AudioThread, this, false);
  }
}

void WinScreenRecorder::AudioThread(bool loopback) {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool com_init = SUCCEEDED(hr);

  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* dev = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  WAVEFORMATEX* fmt = nullptr;
  HANDLE mm_task = nullptr;
  HANDLE& evt = loopback ? loopback_event_ : mic_event_;
  const DWORD stream_idx = loopback ? sys_audio_idx_ : mic_audio_idx_;
  const char* tag = loopback ? "loopback" : "mic";

  auto cleanup = [&]() {
    if (client) client->Stop();
    if (mm_task) AvRevertMmThreadCharacteristics(mm_task);
    SafeRelease(capture);
    SafeRelease(client);
    SafeRelease(dev);
    SafeRelease(enumerator);
    if (fmt) { CoTaskMemFree(fmt); fmt = nullptr; }
    if (com_init) CoUninitialize();
  };

  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator),
                        reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr)) { cleanup(); return; }

  EDataFlow flow = loopback ? eRender : eCapture;
  hr = enumerator->GetDefaultAudioEndpoint(flow, eConsole, &dev);
  if (FAILED(hr)) {
    std::cerr << "[WinRec] " << tag << " GetDefaultAudioEndpoint failed\n";
    if (loopback) captured_system_audio_ = false;
    cleanup();
    return;
  }

  hr = dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                     reinterpret_cast<void**>(&client));
  if (FAILED(hr)) { cleanup(); return; }

  hr = client->GetMixFormat(&fmt);
  if (FAILED(hr)) { cleanup(); return; }

  bool is_float = IsFloatFmt(fmt);

  DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
  if (loopback) flags |= AUDCLNT_STREAMFLAGS_LOOPBACK;

  hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags,
                          kHns100PerSec, 0, fmt, nullptr);
  if (FAILED(hr)) {
    std::cerr << "[WinRec] " << tag << " Initialize failed: 0x"
              << std::hex << hr << "\n";
    cleanup();
    return;
  }

  hr = client->SetEventHandle(evt);
  if (FAILED(hr)) { cleanup(); return; }

  hr = client->GetService(__uuidof(IAudioCaptureClient),
                          reinterpret_cast<void**>(&capture));
  if (FAILED(hr)) { cleanup(); return; }

  DWORD task_idx = 0;
  mm_task = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task_idx);

  hr = client->Start();
  if (FAILED(hr)) { cleanup(); return; }

  if (loopback) captured_system_audio_ = true;

  const UINT32 native_rate = fmt->nSamplesPerSec;
  const UINT32 native_ch = fmt->nChannels;

  while (audio_running_.load()) {
    DWORD wait = WaitForSingleObject(evt, 2000);
    if (!audio_running_.load()) break;
    if (wait != WAIT_OBJECT_0) continue;

    UINT32 pkt = 0;
    capture->GetNextPacketSize(&pkt);
    while (pkt > 0 && audio_running_.load()) {
      BYTE* raw = nullptr;
      UINT32 frames = 0;
      DWORD buf_flags = 0;
      hr = capture->GetBuffer(&raw, &frames, &buf_flags, nullptr, nullptr);
      if (FAILED(hr)) break;

      LARGE_INTEGER qpc;
      QueryPerformanceCounter(&qpc);

      // Convert to int16 PCM.
      const size_t total = static_cast<size_t>(frames) * native_ch;
      std::vector<int16_t> pcm(total);

      if (buf_flags & AUDCLNT_BUFFERFLAGS_SILENT) {
        memset(pcm.data(), 0, total * sizeof(int16_t));
      } else if (is_float) {
        const float* src = reinterpret_cast<const float*>(raw);
        for (size_t i = 0; i < total; ++i)
          pcm[i] = FloatToS16(src[i]);
      } else {
        memcpy(pcm.data(), raw, total * sizeof(int16_t));
      }

      capture->ReleaseBuffer(frames);

      WriteAudioPcm(pcm.data(), frames, native_rate, native_ch,
                     qpc.QuadPart, stream_idx);

      capture->GetNextPacketSize(&pkt);
    }
  }

  cleanup();
}

void WinScreenRecorder::WriteAudioPcm(const int16_t* data, UINT32 frames,
                                      UINT32 sample_rate, UINT32 channels,
                                      INT64 qpc, DWORD stream_idx) {
  std::lock_guard<std::mutex> lock(mtx_);
  if (!writer_ || !writer_started_) return;

  INT64 ts = QpcTo100ns(qpc - base_qpc_, qpc_freq_);
  if (ts < 0) ts = 0;

  UINT32 byte_count = frames * channels * sizeof(int16_t);
  ComPtr<IMFMediaBuffer> buf;
  HRESULT hr = MFCreateMemoryBuffer(byte_count, &buf);
  if (FAILED(hr)) return;

  BYTE* dst = nullptr;
  buf->Lock(&dst, nullptr, nullptr);
  memcpy(dst, data, byte_count);
  buf->Unlock();
  buf->SetCurrentLength(byte_count);

  ComPtr<IMFSample> sample;
  MFCreateSample(&sample);
  sample->AddBuffer(buf.Get());
  sample->SetSampleTime(ts);
  sample->SetSampleDuration(
      static_cast<INT64>(frames) * 10'000'000LL / sample_rate);

  writer_->WriteSample(stream_idx, sample.Get());
}

// ---------------------------------------------------------------------------
// Start / Stop
// ---------------------------------------------------------------------------

void WinScreenRecorder::Start(const std::string& output_path,
                              Completion completion) {
  if (recording_.load()) {
    completion("Already recording");
    return;
  }

  if (!IsGraphicsCaptureAvailable()) {
    completion("Screen recording requires Windows 10 version 1903 or later");
    return;
  }

  captured_system_audio_ = false;
  has_sys_audio_ = false;
  has_mic_audio_ = false;
  writer_started_ = false;
  base_qpc_ = 0;
  last_frame_qpc_ = 0;

  // Convert path to wide string.
  int len = MultiByteToWideChar(CP_UTF8, 0, output_path.c_str(), -1, nullptr, 0);
  std::wstring wpath(len, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, output_path.c_str(), -1, &wpath[0], len);
  if (!wpath.empty() && wpath.back() == L'\0') wpath.pop_back();

  // Get primary monitor.
  POINT pt = {0, 0};
  HMONITOR monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO mi = {sizeof(MONITORINFO)};
  if (!GetMonitorInfoW(monitor, &mi)) {
    completion("Failed to get monitor info");
    return;
  }
  cap_w_ = mi.rcMonitor.right - mi.rcMonitor.left;
  cap_h_ = mi.rcMonitor.bottom - mi.rcMonitor.top;

  if (!InitD3D11()) {
    Cleanup();
    completion("Failed to initialize Direct3D 11");
    return;
  }

  if (!InitSinkWriter(wpath, cap_w_, cap_h_)) {
    Cleanup();
    completion("Failed to initialize Media Foundation encoder");
    return;
  }

  if (!InitGraphicsCapture(monitor, cap_w_, cap_h_)) {
    Cleanup();
    completion("Failed to initialize screen capture");
    return;
  }

  recording_.store(true);
  session_.StartCapture();
  StartAudioCapture();

  std::cerr << "[WinRec] recording started " << cap_w_ << "x" << cap_h_
            << " sys_audio=" << has_sys_audio_ << " mic=" << has_mic_audio_ << "\n";
  completion("");
}

void WinScreenRecorder::Stop(Completion completion) {
  if (!recording_.load()) {
    completion("");
    return;
  }

  recording_.store(false);
  audio_running_.store(false);

  // Signal audio events to unblock threads.
  if (loopback_event_) SetEvent(loopback_event_);
  if (mic_event_) SetEvent(mic_event_);
  if (loopback_thread_.joinable()) loopback_thread_.join();
  if (mic_thread_.joinable()) mic_thread_.join();

  // Stop capture session.
  if (session_) {
    session_.Close();
    session_ = nullptr;
  }
  revoker_.revoke();
  if (pool_) {
    pool_.Close();
    pool_ = nullptr;
  }
  item_ = nullptr;

  // Finalize MP4.
  {
    std::lock_guard<std::mutex> lock(mtx_);
    if (writer_ && writer_started_) {
      HRESULT hr = writer_->Finalize();
      if (FAILED(hr)) {
        std::cerr << "[WinRec] Finalize failed: 0x" << std::hex << hr << "\n";
        Cleanup();
        completion("Failed to finalize recording");
        return;
      }
    }
  }

  Cleanup();
  std::cerr << "[WinRec] recording stopped\n";
  completion("");
}

void WinScreenRecorder::Cleanup() {
  writer_.Reset();
  staging_tex_.Reset();
  ctx_.Reset();
  device_.Reset();

  if (loopback_event_) { CloseHandle(loopback_event_); loopback_event_ = nullptr; }
  if (mic_event_) { CloseHandle(mic_event_); mic_event_ = nullptr; }

  writer_started_ = false;
  has_sys_audio_ = false;
  has_mic_audio_ = false;
  MFShutdown();
}

}  // namespace flutter_webrtc_plugin
