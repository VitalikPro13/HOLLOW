#ifndef SCREEN_AUDIO_TEST_AUDIO_SESSION_ENUM_H_
#define SCREEN_AUDIO_TEST_AUDIO_SESSION_ENUM_H_

// Windows-only: enumerate active audio render sessions and resolve a shared
// WINDOW's process id to the SET of process ids that actually render its audio.
//
// Why this exists: sharing a specific window must capture only THAT app's audio
// (Discord-parity). The naive GetWindowThreadProcessId(hwnd) gives the window's
// process, which is the WRONG process for browsers/Electron — those render audio
// in a separate "Audio Service" utility child process. A WASAPI process-loopback
// INCLUDE on the window pid alone therefore yields silence. The fix is to
// enumerate the system's audio sessions, then map the window pid to the relevant
// audio-rendering pids via the process tree + image name, and INCLUDE that set.

#ifdef _WIN32

#include <windows.h>

#include <string>
#include <vector>

// One active (or inactive) audio render session on the system.
struct AudioSessionInfo {
  DWORD pid = 0;
  std::wstring image;  // lowercased basename, e.g. L"brave.exe" ("" if unknown)
  bool active = false;  // AudioSessionStateActive at enumeration time
};

// Enumerate audio render sessions across ALL render endpoints. Best-effort:
// returns whatever it can; failures on a single endpoint are skipped. Requires
// the calling thread to have CoInitializeEx'd (the capture thread does).
std::vector<AudioSessionInfo> EnumerateRenderAudioSessions();

// Resolve a top-level window HANDLE to its owning process id via
// GetWindowThreadProcessId. Returns 0 if the hwnd is invalid. This is the
// RELIABLE entry point: libwebrtc's desktop source `id` IS the decimal HWND, so
// passing the HWND through and resolving the pid HERE avoids depending on
// libwebrtc to populate a pid field (which it does NOT, reliably).
DWORD PidForWindowHandle(unsigned long long hwnd_value);

// Resolve a shared window's process id to the INCLUDE set of audio-rendering
// process ids. Returns the pids to capture (process-loopback INCLUDE), or an
// EMPTY vector if the window's app renders no audio (e.g. Notepad) — in which
// case the caller must capture silence, NOT fall back to system audio.
//
// Resolution rule (union, most-specific first):
//   * the window pid itself;
//   * any audio session whose image name matches the window's image name
//     (covers browser/Electron multi-process: every helper shares the exe name);
//   * any audio session pid that is a descendant of the window pid OR of the
//     window's top-level (non-shell) ancestor (covers an audio child with a
//     DIFFERENT exe name, and the browser-root case where the window is a tab).
std::vector<DWORD> ResolveWindowToAudioPids(DWORD window_pid);

#endif  // _WIN32

#endif  // SCREEN_AUDIO_TEST_AUDIO_SESSION_ENUM_H_
