#ifndef FLUTTER_WEBRTC_CAPTURE_LOG_H_
#define FLUTTER_WEBRTC_CAPTURE_LOG_H_

#pragma warning(push)
#pragma warning(disable: 4996)  // fopen

#include <windows.h>
#include <cstdio>
#include <cstdarg>
#include <mutex>
#include <string>

namespace flutter_webrtc_plugin {

// File-based logger for native screen capture debugging.
// Writes to %APPDATA%\.hollow\capture_debug.log
class CaptureLog {
 public:
  static CaptureLog& Get() {
    static CaptureLog instance;
    return instance;
  }

  void Write(const char* fmt, ...) {
    std::lock_guard<std::mutex> lock(mtx_);
    if (!file_) Open();
    if (!file_) return;

    LARGE_INTEGER qpc;
    QueryPerformanceCounter(&qpc);
    double secs = static_cast<double>(qpc.QuadPart - start_qpc_.QuadPart) /
                  freq_.QuadPart;
    fprintf(file_, "[%.3f] ", secs);

    va_list args;
    va_start(args, fmt);
    vfprintf(file_, fmt, args);
    va_end(args);

    fprintf(file_, "\n");
    fflush(file_);
  }

 private:
  CaptureLog() {
    QueryPerformanceFrequency(&freq_);
    QueryPerformanceCounter(&start_qpc_);
  }

  ~CaptureLog() {
    if (file_) fclose(file_);
  }

  void Open() {
    char* appdata = nullptr;
    size_t len = 0;
    if (_dupenv_s(&appdata, &len, "APPDATA") != 0 || !appdata) return;
    std::string path = std::string(appdata) + "\\.hollow";
    free(appdata);
    CreateDirectoryA(path.c_str(), nullptr);
    path += "\\capture_debug.log";
    file_ = fopen(path.c_str(), "a");
    if (file_) {
      fprintf(file_, "\n=== Capture session started ===\n");
      fflush(file_);
    }
  }

  FILE* file_ = nullptr;
  std::mutex mtx_;
  LARGE_INTEGER freq_ = {};
  LARGE_INTEGER start_qpc_ = {};
};

#define CAPLOG(...) ::flutter_webrtc_plugin::CaptureLog::Get().Write(__VA_ARGS__)

}  // namespace flutter_webrtc_plugin

#pragma warning(pop)

#endif  // FLUTTER_WEBRTC_CAPTURE_LOG_H_
