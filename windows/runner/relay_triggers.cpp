// winsock2 before windows.h, or windows.h drags in the old winsock.
#include <winsock2.h>
#include <ws2ipdef.h>
#include <iphlpapi.h>

#include "relay_triggers.h"

namespace {

void NETIOAPI_API_ OnInterfaceChange(PVOID context, PMIB_IPINTERFACE_ROW,
                                     MIB_NOTIFICATION_TYPE) {
  static_cast<RelayTriggerSource*>(context)->QueueNetwork();
}

}  // namespace

UINT RelayTriggerSource::NetworkMessage() {
  static const UINT message =
      RegisterWindowMessageW(L"HollowRelayNetworkChanged");
  return message;
}

RelayTriggerSource::RelayTriggerSource(HWND window) : window_(window) {}

RelayTriggerSource::~RelayTriggerSource() {
  // Returns only once no callback is running, so none outlives this object.
  if (notify_) {
    CancelMibChangeNotify2(notify_);
  }
}

bool RelayTriggerSource::Start(bool initial_notification) {
  if (notify_) {
    return true;
  }
  return NotifyIpInterfaceChange(AF_UNSPEC, OnInterfaceChange, this,
                                 initial_notification ? TRUE : FALSE,
                                 &notify_) == NO_ERROR;
}

void RelayTriggerSource::QueueNetwork() {
  const UINT message = NetworkMessage();
  if (message == 0 || queued_.exchange(true)) {
    return;
  }
  if (!PostMessageW(window_, message, 0, 0)) {
    queued_ = false;
  }
}

const char* RelayTriggerSource::EventFor(UINT message, WPARAM wparam) {
  const UINT network = NetworkMessage();
  if (network != 0 && message == network) {
    queued_ = false;
    return "network";
  }
  if (message == WM_POWERBROADCAST && wparam == PBT_APMRESUMEAUTOMATIC) {
    return "wake";
  }
  return nullptr;
}
