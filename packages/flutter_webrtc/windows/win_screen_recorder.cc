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

#include <algorithm>
#include <chrono>
#include <cstring>
#include <iostream>

// Older SDK headers may lack these (Win8.1+ WASAPI auto-conversion flags).
#ifndef AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
#define AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM 0x80000000
#endif
#ifndef AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
#define AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY 0x08000000
#endif

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
// One shared audio format for capture, mixing, and the AAC track. WASAPI's
// AUTOCONVERTPCM does the per-device rate/channel/float conversion — the old
// design wrote each device's NATIVE format into a track declared 48k/44.1k
// stereo, so a 44.1k or mono device produced pitched/soundless tracks.
constexpr UINT32 kMixSampleRate = 48000;
constexpr UINT32 kAudioChannels = 2;
constexpr REFERENCE_TIME kHns100PerSec = 10'000'000LL;
constexpr int kFrameDurationMs = 10;

template <class T>
void SafeRelease(T*& p) {
  if (p) { p->Release(); p = nullptr; }
}

std::wstring Widen(const std::string& s) {
  if (s.empty()) return std::wstring();
  int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring w(len, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], len);
  if (!w.empty() && w.back() == L'\0') w.pop_back();
  return w;
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

  // --- Audio output (AAC): ONE mixed loopback+mic track ---
  // Two separate AAC tracks (the old design) broke playback: mainstream
  // players render only the FIRST audio track, so the mic (track 2) was
  // silently ignored — "the recording misses my own voice" (issue #53).
  {
    ComPtr<IMFMediaType> out_mt;
    CreateAudioMediaType(kMixSampleRate, kAudioChannels, &out_mt);
    hr = writer_->AddStream(out_mt.Get(), &audio_idx_);
    if (FAILED(hr)) {
      std::cerr << "[WinRec] AddStream(audio) failed (non-fatal): 0x"
                << std::hex << hr << "\n";
    } else {
      ComPtr<IMFMediaType> in_mt;
      CreatePcmInputType(kMixSampleRate, kAudioChannels, &in_mt);
      hr = writer_->SetInputMediaType(audio_idx_, in_mt.Get(), nullptr);
      if (FAILED(hr)) {
        std::cerr << "[WinRec] SetInputMediaType(audio) failed (non-fatal): 0x"
                  << std::hex << hr << "\n";
      } else {
        has_audio_ = true;
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

  if (has_audio_) {
    loopback_event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    mic_event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    loopback_thread_ = std::thread(&WinScreenRecorder::AudioThread, this, true);
    mic_thread_ = std::thread(&WinScreenRecorder::AudioThread, this, false);
    mix_thread_ = std::thread(&WinScreenRecorder::MixThread, this);
  }
}

void WinScreenRecorder::AudioThread(bool loopback) {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool com_init = SUCCEEDED(hr);

  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* dev = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  HANDLE mm_task = nullptr;
  HANDLE& evt = loopback ? loopback_event_ : mic_event_;
  const char* tag = loopback ? "loopback" : "mic";

  auto cleanup = [&]() {
    if (client) client->Stop();
    if (mm_task) AvRevertMmThreadCharacteristics(mm_task);
    SafeRelease(capture);
    SafeRelease(client);
    SafeRelease(dev);
    SafeRelease(enumerator);
    if (com_init) CoUninitialize();
  };

  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator),
                        reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr)) { cleanup(); return; }

  // Prefer the endpoint Hollow is configured to use (loopback: the device
  // remote voices actually play on; mic: the device the call captures from).
  // Fall back to the eConsole default so a stale/unplugged id still records.
  const std::string& want_id = loopback ? render_device_id_ : capture_device_id_;
  if (!want_id.empty()) {
    std::wstring wid = Widen(want_id);
    hr = enumerator->GetDevice(wid.c_str(), &dev);
    if (FAILED(hr) || !dev) {
      std::cerr << "[WinRec] " << tag << " GetDevice('" << want_id
                << "') failed: 0x" << std::hex << hr << " — using default\n";
      dev = nullptr;
    }
  }
  if (!dev) {
    EDataFlow flow = loopback ? eRender : eCapture;
    hr = enumerator->GetDefaultAudioEndpoint(flow, eConsole, &dev);
    if (FAILED(hr)) {
      std::cerr << "[WinRec] " << tag << " GetDefaultAudioEndpoint failed\n";
      if (loopback) captured_system_audio_ = false;
      cleanup();
      return;
    }
  }

  hr = dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                     reinterpret_cast<void**>(&client));
  if (FAILED(hr)) { cleanup(); return; }

  // Fixed shared format: WASAPI converts whatever the device natively runs
  // (44.1k, mono, float, 7.1) to s16 interleaved 48k stereo for us. The old
  // native-format capture fed mismatched PCM into a fixed-format AAC stream
  // — pitched or dead tracks depending on the device (issue #53).
  WAVEFORMATEX want = {};
  want.wFormatTag = WAVE_FORMAT_PCM;
  want.nChannels = static_cast<WORD>(kAudioChannels);
  want.nSamplesPerSec = kMixSampleRate;
  want.wBitsPerSample = 16;
  want.nBlockAlign = static_cast<WORD>(kAudioChannels * 2);
  want.nAvgBytesPerSec = kMixSampleRate * kAudioChannels * 2;

  DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
  if (loopback) flags |= AUDCLNT_STREAMFLAGS_LOOPBACK;

  hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags,
                          kHns100PerSec, 0, &want, nullptr);
  if (FAILED(hr)) {
    std::cerr << "[WinRec] " << tag << " Initialize failed: 0x"
              << std::hex << hr << "\n";
    if (loopback) captured_system_audio_ = false;
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

  // Cap each ring at ~2 s so a wedged mixer can't grow them unbounded.
  constexpr size_t kMaxRingSamples =
      static_cast<size_t>(kMixSampleRate) * kAudioChannels * 2;

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

      const size_t total = static_cast<size_t>(frames) * kAudioChannels;
      {
        std::lock_guard<std::mutex> lk(ring_mtx_);
        auto& ring = loopback ? sys_ring_ : mic_ring_;
        if (ring.size() + total <= kMaxRingSamples) {
          const size_t old = ring.size();
          ring.resize(old + total);
          if (buf_flags & AUDCLNT_BUFFERFLAGS_SILENT) {
            memset(ring.data() + old, 0, total * sizeof(int16_t));
          } else {
            memcpy(ring.data() + old, raw, total * sizeof(int16_t));
          }
        }
      }

      capture->ReleaseBuffer(frames);
      capture->GetNextPacketSize(&pkt);
    }
  }

  cleanup();
}

// Timeline mixer: sums the loopback and mic rings into the ONE audio track on
// its own clock. Consumption lags real time by kMixLatencyMs so capture-thread
// jitter never punches holes, and a source with no data contributes zeros
// instead of stalling the track — WASAPI loopback delivers NO packets while
// the system is silent, so "wait for both sources" would freeze the audio.
void WinScreenRecorder::MixThread() {
  constexpr INT64 kMixLatencyMs = 60;
  std::vector<int16_t> sys_take, mic_take, mixed;
  INT64 start_qpc = 0;

  while (audio_running_.load()) {
    std::this_thread::sleep_for(std::chrono::milliseconds(kFrameDurationMs));

    {
      std::lock_guard<std::mutex> lock(mtx_);
      if (!writer_ || !writer_started_) {
        // Video hasn't begun the writer yet — drop buffered audio so the
        // track starts aligned with the first video frame.
        std::lock_guard<std::mutex> lk(ring_mtx_);
        sys_ring_.clear();
        mic_ring_.clear();
        continue;
      }
    }

    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    if (start_qpc == 0) {
      start_qpc = now.QuadPart;
      mix_base_ts_ = QpcTo100ns(start_qpc - base_qpc_, qpc_freq_);
      if (mix_base_ts_ < 0) mix_base_ts_ = 0;
      continue;
    }

    INT64 elapsed_100ns = QpcTo100ns(now.QuadPart - start_qpc, qpc_freq_) -
                          kMixLatencyMs * 10'000LL;
    if (elapsed_100ns <= 0) continue;
    INT64 owed = elapsed_100ns * kMixSampleRate / kHns100PerSec -
                 mix_frames_written_;
    if (owed <= 0) continue;
    // A scheduler stall must not burst an unbounded write.
    owed = std::min<INT64>(owed, kMixSampleRate / 4);

    const size_t want = static_cast<size_t>(owed) * kAudioChannels;
    sys_take.assign(want, 0);
    mic_take.assign(want, 0);
    {
      std::lock_guard<std::mutex> lk(ring_mtx_);
      const size_t s = std::min(want, sys_ring_.size());
      std::copy(sys_ring_.begin(), sys_ring_.begin() + s, sys_take.begin());
      sys_ring_.erase(sys_ring_.begin(), sys_ring_.begin() + s);
      const size_t m = std::min(want, mic_ring_.size());
      std::copy(mic_ring_.begin(), mic_ring_.begin() + m, mic_take.begin());
      mic_ring_.erase(mic_ring_.begin(), mic_ring_.begin() + m);
    }

    mixed.resize(want);
    for (size_t i = 0; i < want; ++i) {
      int v = static_cast<int>(sys_take[i]) + static_cast<int>(mic_take[i]);
      if (v > 32767) v = 32767;
      if (v < -32768) v = -32768;
      mixed[i] = static_cast<int16_t>(v);
    }
    WriteMixedPcm(mixed.data(), static_cast<UINT32>(owed));
  }
}

void WinScreenRecorder::WriteMixedPcm(const int16_t* data, UINT32 frames) {
  std::lock_guard<std::mutex> lock(mtx_);
  if (!writer_ || !writer_started_ || !has_audio_) return;

  const INT64 ts =
      mix_base_ts_ + mix_frames_written_ * kHns100PerSec / kMixSampleRate;
  // The timeline advances even if a write fails, so one bad sample can't
  // shift everything after it.
  mix_frames_written_ += frames;

  UINT32 byte_count = frames * kAudioChannels * sizeof(int16_t);
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
      static_cast<INT64>(frames) * kHns100PerSec / kMixSampleRate);

  hr = writer_->WriteSample(audio_idx_, sample.Get());
  if (FAILED(hr) && !audio_write_err_logged_) {
    // The old code discarded this HRESULT — an audio-less file finalized
    // "successfully" with zero evidence anywhere.
    std::cerr << "[WinRec] WriteSample(audio) failed: 0x" << std::hex << hr
              << "\n";
    audio_write_err_logged_ = true;
  }
}

// ---------------------------------------------------------------------------
// Start / Stop
// ---------------------------------------------------------------------------

void WinScreenRecorder::Start(const std::string& output_path,
                              const std::string& render_device_id,
                              const std::string& capture_device_id,
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
  has_audio_ = false;
  writer_started_ = false;
  base_qpc_ = 0;
  last_frame_qpc_ = 0;
  mix_frames_written_ = 0;
  mix_base_ts_ = 0;
  audio_write_err_logged_ = false;
  render_device_id_ = render_device_id;
  capture_device_id_ = capture_device_id;
  {
    std::lock_guard<std::mutex> lk(ring_mtx_);
    sys_ring_.clear();
    mic_ring_.clear();
  }

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
            << " audio=" << has_audio_
            << " render_dev=" << (render_device_id_.empty() ? "default" : render_device_id_)
            << " capture_dev=" << (capture_device_id_.empty() ? "default" : capture_device_id_)
            << "\n";
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
  if (mix_thread_.joinable()) mix_thread_.join();
  std::cerr << "[WinRec] audio frames mixed: " << mix_frames_written_ << "\n";

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

  {
    std::lock_guard<std::mutex> lk(ring_mtx_);
    sys_ring_.clear();
    mic_ring_.clear();
  }
  writer_started_ = false;
  has_audio_ = false;
  MFShutdown();
}

}  // namespace flutter_webrtc_plugin
