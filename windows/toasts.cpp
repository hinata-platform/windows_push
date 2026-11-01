#include "toasts.h"

#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

#include <chrono>
#include <string>

// Scheduled through the classic Windows.UI.Notifications API, because the App
// SDK's AppNotificationManager can show a toast but not schedule one. Both post
// under the same package identity, and a click on either kind goes to the
// toast activator declared in the package manifest, so it surfaces with the
// toast's `launch` attribute as Argument() exactly like a push.
//
// CreateToastNotifier() without an AUMID needs package identity: a plain
// `flutter run` throws here, and the functions report false instead.

namespace windows_push {

namespace {

namespace toast = winrt::Windows::UI::Notifications;
using winrt::Windows::Foundation::DateTime;
using winrt::Windows::Foundation::IReference;
using winrt::Windows::Foundation::TimeSpan;

// WinRT DateTime counts 100 ns ticks since 1601-01-01 (the FILETIME epoch).
DateTime FromEpochMs(int64_t epoch_ms) {
  constexpr int64_t kTicksPerMs = 10'000;
  constexpr int64_t kUnixEpochInTicks = 116'444'736'000'000'000;
  return DateTime{TimeSpan{kUnixEpochInTicks + epoch_ms * kTicksPerMs}};
}

int64_t NowEpochMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

std::wstring XmlEscape(const winrt::hstring& value) {
  std::wstring out;
  out.reserve(value.size());
  for (wchar_t c : value) {
    switch (c) {
      case L'&': out += L"&amp;"; break;
      case L'<': out += L"&lt;"; break;
      case L'>': out += L"&gt;"; break;
      case L'"': out += L"&quot;"; break;
      case L'\'': out += L"&apos;"; break;
      default: out += c;
    }
  }
  return out;
}

winrt::Windows::Data::Xml::Dom::XmlDocument BuildToastXml(
    const ToastRequest& request) {
  std::wstring xml = L"<toast launch=\"" + XmlEscape(request.argument) +
                     L"\" activationType=\"foreground\"><visual>"
                     L"<binding template=\"ToastGeneric\"><text>" +
                     XmlEscape(request.title) + L"</text><text>" +
                     XmlEscape(request.body) +
                     L"</text></binding></visual></toast>";
  winrt::Windows::Data::Xml::Dom::XmlDocument document;
  document.LoadXml(winrt::hstring(xml));
  return document;
}

void RemoveScheduled(const toast::ToastNotifier& notifier,
                     const winrt::hstring& tag, const winrt::hstring& group) {
  for (auto const& scheduled : notifier.GetScheduledToastNotifications()) {
    if (scheduled.Tag() == tag && scheduled.Group() == group) {
      notifier.RemoveFromSchedule(scheduled);
    }
  }
}

}  // namespace

bool ShowToast(const ToastRequest& request) {
  try {
    auto notifier = toast::ToastNotificationManager::CreateToastNotifier();
    RemoveScheduled(notifier, request.tag, request.group);
    toast::ToastNotification notification(BuildToastXml(request));
    notification.Tag(request.tag);
    notification.Group(request.group);
    notification.ExpirationTime(IReference<DateTime>(
        FromEpochMs(NowEpochMs() + request.expire_minutes * 60'000)));
    // The same tag and group replace a toast that is already on screen.
    notifier.Show(notification);
    return true;
  } catch (...) {
    return false;
  }
}

bool ScheduleToast(const ToastRequest& request) {
  int64_t now = NowEpochMs();
  int64_t expires = request.at_ms + request.expire_minutes * 60'000;
  if (expires <= now) return false;
  // AddToSchedule rejects a delivery time that is not in the future. A moment
  // that already passed (the app was suspended, the clock jumped) is still
  // worth showing while the toast would not have expired yet.
  if (request.at_ms <= now + 1'000) return ShowToast(request);
  try {
    auto notifier = toast::ToastNotificationManager::CreateToastNotifier();
    RemoveScheduled(notifier, request.tag, request.group);
    toast::ScheduledToastNotification scheduled(BuildToastXml(request),
                                                FromEpochMs(request.at_ms));
    scheduled.Tag(request.tag);
    scheduled.Group(request.group);
    scheduled.ExpirationTime(IReference<DateTime>(FromEpochMs(expires)));
    notifier.AddToSchedule(scheduled);
    return true;
  } catch (...) {
    return false;
  }
}

void CancelToast(const winrt::hstring& tag, const winrt::hstring& group) {
  try {
    auto notifier = toast::ToastNotificationManager::CreateToastNotifier();
    RemoveScheduled(notifier, tag, group);
  } catch (...) {
  }
  try {
    toast::ToastNotificationManager::History().Remove(tag, group);
  } catch (...) {
  }
}

}  // namespace windows_push
