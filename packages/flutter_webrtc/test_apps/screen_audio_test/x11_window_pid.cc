#ifdef __linux__

#include "x11_window_pid.h"

#include <cstdio>

#ifdef HAVE_X11

#include <X11/Xatom.h>
#include <X11/Xlib.h>

namespace {
// A stale/invalid window id raises BadWindow, and Xlib's DEFAULT error
// handler exits the process — swallow it instead (we return 0).
int IgnoreXErrors(Display*, XErrorEvent*) { return 0; }
}  // namespace

int ResolveX11WindowPid(unsigned long window_id) {
  if (window_id == 0) return 0;
  Display* display = XOpenDisplay(nullptr);
  if (!display) {
    fprintf(stderr, "[X11-PID] No X display (wayland-native session?)\n");
    return 0;
  }
  XSetErrorHandler(IgnoreXErrors);

  int pid = 0;
  Atom net_wm_pid = XInternAtom(display, "_NET_WM_PID", True);
  if (net_wm_pid != None) {
    Atom actual_type = None;
    int actual_format = 0;
    unsigned long nitems = 0, bytes_after = 0;
    unsigned char* prop = nullptr;
    if (XGetWindowProperty(display, static_cast<Window>(window_id),
                           net_wm_pid, 0, 1, False, XA_CARDINAL, &actual_type,
                           &actual_format, &nitems, &bytes_after,
                           &prop) == Success &&
        prop) {
      if (actual_type == XA_CARDINAL && actual_format == 32 && nitems >= 1) {
        pid = static_cast<int>(*reinterpret_cast<unsigned long*>(prop));
      }
      XFree(prop);
    }
  }

  XCloseDisplay(display);
  fprintf(stderr, "[X11-PID] Window 0x%lx -> pid %d\n", window_id, pid);
  return pid;
}

#else  // !HAVE_X11

int ResolveX11WindowPid(unsigned long) {
  fprintf(stderr, "[X11-PID] Built without libX11 — cannot resolve window\n");
  return 0;
}

#endif  // HAVE_X11

#endif  // __linux__
