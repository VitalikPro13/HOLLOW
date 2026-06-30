#include "audio_session_enum.h"

#ifdef _WIN32

#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <tlhelp32.h>
#include <wrl/client.h>

#include <algorithm>
#include <cwctype>
#include <unordered_map>
#include <unordered_set>

#include "capture_log.h"

#pragma comment(lib, "Mmdevapi.lib")

using Microsoft::WRL::ComPtr;

namespace {

std::wstring ToLower(std::wstring s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return s;
}

// Lowercased executable basename for a pid, or L"" if it can't be queried.
std::wstring ImageNameForPid(DWORD pid) {
  if (pid == 0) return L"";
  HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!h) return L"";
  wchar_t buf[MAX_PATH];
  DWORD size = MAX_PATH;
  std::wstring image;
  if (QueryFullProcessImageNameW(h, 0, buf, &size)) {
    std::wstring full(buf, size);
    size_t slash = full.find_last_of(L"\\/");
    image = (slash == std::wstring::npos) ? full : full.substr(slash + 1);
    image = ToLower(image);
  }
  CloseHandle(h);
  return image;
}

// Known shell/system host images we must NOT walk *up into* when finding a
// window's top-level ancestor — they are shared parents of unrelated apps, so
// treating their whole subtree as "this app" would over-capture system audio.
bool IsShellOrSystemHost(const std::wstring& image) {
  static const wchar_t* kHosts[] = {
      L"explorer.exe", L"svchost.exe",  L"services.exe", L"wininit.exe",
      L"winlogon.exe", L"userinit.exe", L"runtimebroker.exe", L"",
  };
  for (const wchar_t* h : kHosts) {
    if (image == h) return true;
  }
  return false;
}

// Snapshot of the process tree: child pid -> parent pid, and pid -> image.
struct ProcessTree {
  std::unordered_map<DWORD, DWORD> parent;
  std::unordered_map<DWORD, std::wstring> image;  // lowercased basename
};

ProcessTree SnapshotProcessTree() {
  ProcessTree tree;
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE) return tree;

  PROCESSENTRY32W pe = {};
  pe.dwSize = sizeof(pe);
  if (Process32FirstW(snap, &pe)) {
    do {
      tree.parent[pe.th32ProcessID] = pe.th32ParentProcessID;
      tree.image[pe.th32ProcessID] = ToLower(pe.szExeFile);
    } while (Process32NextW(snap, &pe));
  }
  CloseHandle(snap);
  return tree;
}

// Walk parents from `pid` up to the last non-shell ancestor (bounded depth,
// cycle-guarded — pids can be reused so the parent map is not guaranteed acyclic
// and a reused pid could point back into the chain).
DWORD TopNonShellAncestor(const ProcessTree& tree, DWORD pid) {
  DWORD top = pid;
  std::unordered_set<DWORD> seen;
  for (int depth = 0; depth < 12; ++depth) {
    if (!seen.insert(top).second) break;  // cycle
    auto pit = tree.parent.find(top);
    if (pit == tree.parent.end()) break;
    DWORD parent = pit->second;
    if (parent == 0 || parent == top) break;
    auto iit = tree.image.find(parent);
    const std::wstring parent_image =
        (iit != tree.image.end()) ? iit->second : L"";
    if (IsShellOrSystemHost(parent_image)) break;  // don't cross the shell
    top = parent;
  }
  return top;
}

// Is `pid` inside the subtree rooted at `root` (root counts as inside)?
bool IsInSubtree(const ProcessTree& tree, DWORD pid, DWORD root) {
  DWORD cur = pid;
  std::unordered_set<DWORD> seen;
  for (int depth = 0; depth < 24; ++depth) {
    if (cur == root) return true;
    if (!seen.insert(cur).second) break;  // cycle guard
    auto pit = tree.parent.find(cur);
    if (pit == tree.parent.end()) break;
    DWORD parent = pit->second;
    if (parent == 0 || parent == cur) break;
    // Stop at the shell boundary: never claim a process is "in this app's
    // subtree" by chaining through explorer.exe/svchost.exe.
    auto iit = tree.image.find(parent);
    const std::wstring parent_image =
        (iit != tree.image.end()) ? iit->second : L"";
    if (IsShellOrSystemHost(parent_image)) break;
    cur = parent;
  }
  return false;
}

}  // namespace

DWORD PidForWindowHandle(unsigned long long hwnd_value) {
  if (hwnd_value == 0) return 0;
  HWND hwnd = reinterpret_cast<HWND>(static_cast<uintptr_t>(hwnd_value));
  if (!IsWindow(hwnd)) {
    CAPLOG("AudioSessionEnum: hwnd %llu is not a valid window", hwnd_value);
    return 0;
  }
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  CAPLOG("AudioSessionEnum: hwnd %llu -> window pid %u", hwnd_value, pid);
  return pid;
}

std::vector<AudioSessionInfo> EnumerateRenderAudioSessions() {
  std::vector<AudioSessionInfo> out;

  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  if (FAILED(hr)) {
    CAPLOG("AudioSessionEnum: CoCreateInstance(MMDeviceEnumerator) 0x%08x", hr);
    return out;
  }

  // Loop ALL active render endpoints for completeness (a per-app stream may be
  // bound to a non-default device).
  ComPtr<IMMDeviceCollection> devices;
  hr = enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &devices);
  if (FAILED(hr) || !devices) {
    CAPLOG("AudioSessionEnum: EnumAudioEndpoints 0x%08x", hr);
    return out;
  }

  UINT device_count = 0;
  devices->GetCount(&device_count);

  for (UINT d = 0; d < device_count; ++d) {
    ComPtr<IMMDevice> device;
    if (FAILED(devices->Item(d, &device)) || !device) continue;

    ComPtr<IAudioSessionManager2> mgr;
    if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL,
                                nullptr, &mgr)) ||
        !mgr) {
      continue;
    }

    ComPtr<IAudioSessionEnumerator> sessions;
    if (FAILED(mgr->GetSessionEnumerator(&sessions)) || !sessions) continue;

    int session_count = 0;
    sessions->GetCount(&session_count);

    for (int s = 0; s < session_count; ++s) {
      ComPtr<IAudioSessionControl> ctrl;
      if (FAILED(sessions->GetSession(s, &ctrl)) || !ctrl) continue;

      ComPtr<IAudioSessionControl2> ctrl2;
      if (FAILED(ctrl.As(&ctrl2)) || !ctrl2) continue;

      // Skip the system/hidden sounds session (pid 0, not a real app).
      if (ctrl2->IsSystemSoundsSession() == S_OK) continue;

      DWORD pid = 0;
      if (FAILED(ctrl2->GetProcessId(&pid)) || pid == 0) continue;

      AudioSessionState state = AudioSessionStateInactive;
      ctrl->GetState(&state);

      AudioSessionInfo info;
      info.pid = pid;
      info.image = ImageNameForPid(pid);
      info.active = (state == AudioSessionStateActive);
      out.push_back(std::move(info));
    }
  }

  return out;
}

std::vector<DWORD> ResolveWindowToAudioPids(DWORD window_pid) {
  std::vector<DWORD> result;
  if (window_pid == 0) return result;

  // EnumerateRenderAudioSessions needs a COM-initialized thread. The exe's main
  // thread (which calls this before starting capture) is NOT initialized — only
  // the capture threads init COM — so do it here. Only uninit if WE initialized
  // it (S_OK/S_FALSE); RPC_E_CHANGED_MODE means COM is already up on this thread
  // in another apartment, which still serves our transient CoCreateInstance.
  HRESULT hr_com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool we_init_com = (hr_com == S_OK || hr_com == S_FALSE);

  const std::vector<AudioSessionInfo> sessions = EnumerateRenderAudioSessions();
  const ProcessTree tree = SnapshotProcessTree();

  const std::wstring target_image = ImageNameForPid(window_pid);
  const DWORD top_ancestor = TopNonShellAncestor(tree, window_pid);

  CAPLOG("AudioSessionEnum: window pid %u image='%ls' topAncestor %u, %zu render session(s)",
         window_pid, target_image.c_str(), top_ancestor, sessions.size());

  std::unordered_set<DWORD> include;
  for (const AudioSessionInfo& s : sessions) {
    bool match = false;
    const char* why = "";

    if (s.pid == window_pid) {
      match = true; why = "self";
    } else if (!target_image.empty() && s.image == target_image) {
      // Browser/Electron multi-process: every helper (renderer, audio service,
      // GPU) shares the top-level exe name. This is the strongest signal.
      match = true; why = "image";
    } else if (IsInSubtree(tree, s.pid, window_pid)) {
      match = true; why = "descendant-of-window";
    } else if (top_ancestor != window_pid &&
               IsInSubtree(tree, s.pid, top_ancestor)) {
      // Window is a tab/renderer; the audio service hangs off the browser root.
      match = true; why = "descendant-of-root";
    }

    if (match) {
      CAPLOG("AudioSessionEnum:   INCLUDE pid %u image='%ls' active=%d (%s)",
             s.pid, s.image.c_str(), s.active ? 1 : 0, why);
      include.insert(s.pid);
    }
  }

  result.assign(include.begin(), include.end());
  if (result.empty()) {
    CAPLOG("AudioSessionEnum: no audio sessions match window pid %u -> "
           "capturing silence (app renders no audio)", window_pid);
  }

  if (we_init_com) CoUninitialize();
  return result;
}

#endif  // _WIN32
