// Linux audio device enumeration via libpulse. See hollow_pulse_devices.cc.
#ifndef HOLLOW_PULSE_DEVICES_H_
#define HOLLOW_PULSE_DEVICES_H_

#include <string>
#include <vector>

namespace hollow_pulse {

struct AudioDevice {
  std::string id;    // PulseAudio source/sink name (stable identifier)
  std::string name;  // human-readable description
  bool is_default = false;
};

// Enumerates real microphones (inputs) and speakers (outputs) via libpulse,
// connecting to the running PulseAudio / pipewire-pulse server. Returns false
// if the server can't be reached (caller should leave the lists untouched).
// Monitor sources (sink loopbacks) are excluded from inputs.
bool EnumerateDevices(std::vector<AudioDevice>* inputs,
                      std::vector<AudioDevice>* outputs);

}  // namespace hollow_pulse

#endif  // HOLLOW_PULSE_DEVICES_H_
