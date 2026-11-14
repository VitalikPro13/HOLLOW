#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cwctype>
#include <string>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

extern "C" {
__declspec(dllexport) unsigned long NvOptimusEnablement = 0x00000001;
__declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
}

namespace {

bool IsLinkLaunch(const wchar_t* command_line) {
  if (command_line == nullptr) return false;
  std::wstring lower(command_line);
  for (auto& c : lower) c = static_cast<wchar_t>(::towlower(c));
  return lower.find(L"hollow://") != std::wstring::npos;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Single instance: a running copy of this exe (matched by exe path) gets our
  // command line, with any hollow:// link, over WM_COPYDATA and we exit before
  // Flutter boots. app_links answers false both when no copy runs and when the
  // copy did not take the link within 5 s (hung, or elevated), so a link launch
  // tries once more; a link still refused is lost when the Dart PID lock ends
  // this second process.
  if (SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }
  if (IsLinkLaunch(command_line)) {
    ::Sleep(1000);
    if (SendAppLinkToInstance()) {
      return EXIT_SUCCESS;
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // Windows runs SKIA, not Impeller. Impeller became the Windows default in
  // Flutter 3.47 and it is GLES over ANGLE over D3D11, not Vulkan. Measured
  // on the same build, same 1280x800 window, same screen:
  //
  //            Impeller    Skia
  //   VRAM       247 MB    54 MB     4.5x
  //   commit  483-732 MB   214 MB    steady instead of swinging
  //   idle CPU    12.7%    10.5%     Skia slightly cheaper
  //
  // The cost scales with WINDOW AREA (~52 MB + ~189 MB per megapixel), so a
  // 1440p window would sit near 750 MB of VRAM doing nothing. The engine
  // exposes no sample-count or render-target-pool control to apps
  // (flutter/flutter#178264). Full workings in tmp4.md section 18.
  //
  // This is TEMPORARY. Flutter's docs say the opt-out will be removed in a
  // future release, so RE-TEST THIS ON EVERY FLUTTER UPGRADE: if the engine's
  // render-target memory improves, delete this line and drop
  // HollowShaderWarmUp from lib/main.dart with it.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"hollow", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
