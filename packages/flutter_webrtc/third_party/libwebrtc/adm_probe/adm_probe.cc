// Reproduces the Linux PulseAudio ADM defect behind Hollow issue #72:
// Init -> Terminate -> Init leaves the module unable to start recording or
// playout (StartRecording() times out after 10 s). Exit code 0 = every cycle
// started both streams, 1 = a start failed.
#include <chrono>
#include <cstdio>
#include <cstdlib>

#include "api/audio/audio_device.h"
#include "api/audio/create_audio_device_module.h"
#include "api/environment/environment_factory.h"
#include "rtc_base/logging.h"

using webrtc::AudioDeviceModule;

namespace {

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

bool StartBoth(AudioDeviceModule* adm, int cycle) {
  bool ok = true;
  int64_t t0 = NowMs();
  int r = adm->InitRecording();
  std::printf("[cycle %d] InitRecording=%d\n", cycle, r);
  r = adm->StartRecording();
  std::printf("[cycle %d] StartRecording=%d (%lld ms) Recording()=%d\n", cycle,
              r, (long long)(NowMs() - t0), adm->Recording() ? 1 : 0);
  if (r != 0 || !adm->Recording()) ok = false;

  t0 = NowMs();
  r = adm->InitPlayout();
  std::printf("[cycle %d] InitPlayout=%d\n", cycle, r);
  r = adm->StartPlayout();
  std::printf("[cycle %d] StartPlayout=%d (%lld ms) Playing()=%d\n", cycle, r,
              (long long)(NowMs() - t0), adm->Playing() ? 1 : 0);
  if (r != 0 || !adm->Playing()) ok = false;

  adm->StopRecording();
  adm->StopPlayout();
  return ok;
}

}  // namespace

int main(int argc, char** argv) {
  const int cycles = argc > 1 ? std::atoi(argv[1]) : 2;
  webrtc::LogMessage::LogToDebug(webrtc::LS_INFO);
  webrtc::LogMessage::LogTimestamps(true);

  webrtc::Environment env = webrtc::CreateEnvironment();
  auto adm = webrtc::CreateAudioDeviceModule(
      env, AudioDeviceModule::kPlatformDefaultAudio);
  if (!adm) {
    std::printf("no ADM\n");
    return 2;
  }

  bool all_ok = true;
  for (int cycle = 1; cycle <= cycles; ++cycle) {
    int r = adm->Init();
    std::printf("[cycle %d] Init=%d Initialized()=%d\n", cycle, r,
                adm->Initialized() ? 1 : 0);
    if (r != 0) return 3;
    adm->SetRecordingDevice(0);
    adm->SetPlayoutDevice(0);
    adm->InitMicrophone();
    adm->InitSpeaker();
    if (!StartBoth(adm.get(), cycle)) all_ok = false;
    r = adm->Terminate();
    std::printf("[cycle %d] Terminate=%d\n", cycle, r);
  }
  std::printf("RESULT %s\n", all_ok ? "PASS" : "FAIL");
  return all_ok ? 0 : 1;
}
