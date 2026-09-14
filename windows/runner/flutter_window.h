#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void HandleWindowMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool EnterFullscreen();
  bool ExitFullscreen();
  flutter::EncodableMap QueryWindow();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Fullscreen lives here rather than in window_manager 0.5.1: its enter
  // branch is skipped for a frameless window (which ours is), and its exit
  // path clears framelessness and the DWM margins, which is the squished
  // restore.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
  bool is_fullscreen_ = false;
  LONG_PTR saved_style_ = 0;
  WINDOWPLACEMENT saved_placement_ = {};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
