#ifndef RUNNER_RELAY_TRIGGERS_H_
#define RUNNER_RELAY_TRIGGERS_H_

#include <windows.h>

#include <atomic>

// Network changes and wake from sleep for lib/src/core/services/relay_triggers.dart.
// OS network callbacks run on a pool thread, so each becomes a window message
// that reaches Dart on the platform thread.
class RelayTriggerSource {
 public:
  explicit RelayTriggerSource(HWND window);
  ~RelayTriggerSource();

  RelayTriggerSource(const RelayTriggerSource&) = delete;
  RelayTriggerSource& operator=(const RelayTriggerSource&) = delete;

  // `initial_notification` makes the OS call back once at registration (tests).
  bool Start(bool initial_notification = false);

  // The event a window message carries ("network" or "wake"), else nullptr.
  const char* EventFor(UINT message, WPARAM wparam);

  // Posts the network message unless one is still queued. Any thread.
  void QueueNetwork();

  static UINT NetworkMessage();

 private:
  HWND window_;
  HANDLE notify_ = nullptr;
  std::atomic<bool> queued_{false};
};

#endif  // RUNNER_RELAY_TRIGGERS_H_
