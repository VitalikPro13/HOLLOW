#ifndef SCREEN_AUDIO_TEST_X11_WINDOW_PID_H_
#define SCREEN_AUDIO_TEST_X11_WINDOW_PID_H_

#ifdef __linux__

// Resolve an X11 window id (the desktop-capturer source id on X sessions) to
// its owning process via the _NET_WM_PID property. Returns 0 when it can't
// (no DISPLAY, wayland-native window, property unset, bad window id, or the
// exe was built without libX11 headers).
int ResolveX11WindowPid(unsigned long window_id);

#endif  // __linux__

#endif  // SCREEN_AUDIO_TEST_X11_WINDOW_PID_H_
