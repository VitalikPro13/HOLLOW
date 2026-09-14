#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kWindowChannel[] = "hollow/window";

int64_t AsInt64(LONG value) { return static_cast<int64_t>(value); }

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannel,
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleWindowMethod(call, std::move(result));
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Let window_manager control when the window is shown to avoid
  // the white flash on startup. Don't auto-show on first frame.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleWindowMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "enterFullscreen") {
    result->Success(flutter::EncodableValue(EnterFullscreen()));
  } else if (method == "exitFullscreen") {
    result->Success(flutter::EncodableValue(ExitFullscreen()));
  } else if (method == "isFullscreen") {
    result->Success(flutter::EncodableValue(is_fullscreen_));
  } else if (method == "queryWindow") {
    result->Success(flutter::EncodableValue(QueryWindow()));
  } else {
    result->NotImplemented();
  }
}

bool FlutterWindow::EnterFullscreen() {
  HWND hwnd = GetHandle();
  if (!hwnd) return false;
  if (is_fullscreen_) return true;

  saved_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
  saved_placement_.length = sizeof(saved_placement_);
  if (!GetWindowPlacement(hwnd, &saved_placement_)) return false;

  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  if (!GetMonitorInfo(monitor, &mi)) return false;

  is_fullscreen_ = true;
  // WS_MAXIMIZE has to go with the frame: window_manager's WM_NCCALCSIZE
  // handler insets a zoomed frameless window by 8px, which would show as a
  // border around a window that is meant to cover the monitor exactly.
  SetWindowLongPtr(hwnd, GWL_STYLE,
                   saved_style_ &
                       ~(WS_THICKFRAME | WS_MAXIMIZEBOX | WS_MAXIMIZE));
  // Never HWND_TOPMOST: a window covering its monitor with no thick frame is
  // already what the shell drops the taskbar behind, and topmost would also
  // cover other apps' notifications.
  SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
               mi.rcMonitor.right - mi.rcMonitor.left,
               mi.rcMonitor.bottom - mi.rcMonitor.top,
               SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  return true;
}

bool FlutterWindow::ExitFullscreen() {
  HWND hwnd = GetHandle();
  if (!hwnd) return false;
  if (!is_fullscreen_) return true;

  SetWindowLongPtr(hwnd, GWL_STYLE, saved_style_ & ~WS_MAXIMIZE);
  // The placement carries SW_SHOWMAXIMIZED when the window was maximized
  // before, so a maximized window restores through the normal maximize path
  // instead of being sized to a remembered rect. The DWM margins are never
  // touched in either direction, which is what brings the frameless title bar
  // and the resize border back exactly as they were.
  SetWindowPlacement(hwnd, &saved_placement_);
  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                   SWP_FRAMECHANGED);
  is_fullscreen_ = false;
  return true;
}

flutter::EncodableMap FlutterWindow::QueryWindow() {
  flutter::EncodableMap out;
  out[flutter::EncodableValue("fullscreen")] =
      flutter::EncodableValue(is_fullscreen_);

  HWND hwnd = GetHandle();
  if (!hwnd) return out;

  LONG_PTR style = GetWindowLongPtr(hwnd, GWL_STYLE);
  out[flutter::EncodableValue("zoomed")] =
      flutter::EncodableValue(IsZoomed(hwnd) != 0);
  out[flutter::EncodableValue("thickFrame")] =
      flutter::EncodableValue((style & WS_THICKFRAME) != 0);
  out[flutter::EncodableValue("maximizeBox")] =
      flutter::EncodableValue((style & WS_MAXIMIZEBOX) != 0);

  // Who owns the keyboard. A frame change that leaves the Flutter child
  // unfocused silently kills every focus-routed shortcut, Escape included.
  HWND view = flutter_controller_ && flutter_controller_->view()
                  ? flutter_controller_->view()->GetNativeWindow()
                  : nullptr;
  out[flutter::EncodableValue("focused")] =
      flutter::EncodableValue(view != nullptr && GetFocus() == view);
  out[flutter::EncodableValue("foreground")] =
      flutter::EncodableValue(GetForegroundWindow() == hwnd);

  RECT rect = {};
  GetWindowRect(hwnd, &rect);
  out[flutter::EncodableValue("left")] = flutter::EncodableValue(AsInt64(rect.left));
  out[flutter::EncodableValue("top")] = flutter::EncodableValue(AsInt64(rect.top));
  out[flutter::EncodableValue("right")] =
      flutter::EncodableValue(AsInt64(rect.right));
  out[flutter::EncodableValue("bottom")] =
      flutter::EncodableValue(AsInt64(rect.bottom));

  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mi)) {
    out[flutter::EncodableValue("monLeft")] =
        flutter::EncodableValue(AsInt64(mi.rcMonitor.left));
    out[flutter::EncodableValue("monTop")] =
        flutter::EncodableValue(AsInt64(mi.rcMonitor.top));
    out[flutter::EncodableValue("monRight")] =
        flutter::EncodableValue(AsInt64(mi.rcMonitor.right));
    out[flutter::EncodableValue("monBottom")] =
        flutter::EncodableValue(AsInt64(mi.rcMonitor.bottom));
  }
  return out;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
