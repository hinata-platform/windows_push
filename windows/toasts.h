#ifndef FLUTTER_PLUGIN_WINDOWS_PUSH_TOASTS_H_
#define FLUTTER_PLUGIN_WINDOWS_PUSH_TOASTS_H_

#include <winrt/base.h>

#include <cstdint>

namespace windows_push {

// A local toast. Clicking it takes the same activation path as a push, so its
// |argument| reaches Dart through the same click stream.
struct ToastRequest {
  winrt::hstring tag;
  winrt::hstring group;
  winrt::hstring title;
  winrt::hstring body;
  winrt::hstring argument;
  int64_t at_ms = 0;  // epoch milliseconds, UTC; 0 = show now
  int64_t expire_minutes = 10;
};

// Each returns false without package identity or when Windows refused.
bool ShowToast(const ToastRequest& request);
bool ScheduleToast(const ToastRequest& request);
void CancelToast(const winrt::hstring& tag, const winrt::hstring& group);

}  // namespace windows_push

#endif  // FLUTTER_PLUGIN_WINDOWS_PUSH_TOASTS_H_
