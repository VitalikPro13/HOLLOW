#include "libwebrtc.h"
#include "rtc_audio_device.h"
#include <hollow_pulse_devices.h>
#include <cstdio>

int main() {
  std::vector<hollow_pulse::AudioDevice> inputs, outputs;
  if (!hollow_pulse::EnumerateDevices(&inputs, &outputs)) return 1;
  for (const auto& d : outputs) std::printf("Pulse output: %s | %s\n", d.id.c_str(), d.name.c_str());
  for (const auto& d : inputs) std::printf("Pulse input: %s | %s\n", d.id.c_str(), d.name.c_str());
  libwebrtc::LibWebRTC::Initialize();
  auto factory = libwebrtc::LibWebRTC::CreateRTCPeerConnectionFactory();
  factory->Initialize();
  auto audio = factory->GetAudioDevice();
  for (int i = 0; i < audio->PlayoutDevices(); ++i) {
    char name[256] = {}, guid[256] = {};
    audio->PlayoutDeviceName(i, name, guid);
    std::printf("ADM output %d: %s | %s\n", i, name, guid);
  }
  for (int i = 0; i < audio->RecordingDevices(); ++i) {
    char name[256] = {}, guid[256] = {};
    audio->RecordingDeviceName(i, name, guid);
    std::printf("ADM input %d: %s | %s\n", i, name, guid);
  }
  audio = nullptr;
  factory = nullptr;
  libwebrtc::LibWebRTC::Terminate();
}
