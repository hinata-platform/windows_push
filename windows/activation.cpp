#include "activation.h"

#include <appmodel.h>
#include <winrt/Microsoft.Windows.AppLifecycle.h>
#include <winrt/Microsoft.Windows.AppNotifications.h>
#include <winrt/Microsoft.Windows.PushNotifications.h>
#include <winrt/Windows.Foundation.h>

#include <mutex>
#include <utility>

#include "string_util.h"

namespace windows_push {

namespace {

using winrt::Microsoft::Windows::AppNotifications::AppNotificationManager;
using winrt::Microsoft::Windows::PushNotifications::PushNotificationManager;

std::mutex g_mutex;
std::string g_pending_argument;
std::function<void()> g_sink;
bool g_initialized = false;
bool g_launched_from_notification = false;

void OnNotificationClicked(std::string argument) {
  if (argument.empty()) return;
  std::function<void()> sink;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_pending_argument = std::move(argument);
    sink = g_sink;
  }
  if (sink) sink();
}

void RegisterPush() {
  // Registering with the push platform is what lets WNS start the app,
  // through the COM server declared in the package manifest, when a
  // notification arrives while it is closed.
  try {
    if (PushNotificationManager::IsSupported()) {
      PushNotificationManager::Default().Register();
    }
  } catch (...) {
  }
}

void RegisterNotificationClicks() {
  try {
    auto manager = AppNotificationManager::Default();
    // The payload travels in the toast's `launch` attribute, which surfaces
    // as Argument(). Arguments() parses it as key=value pairs and would turn
    // a path into one key with an empty value.
    manager.NotificationInvoked([](auto const&, auto const& args) {
      OnNotificationClicked(ToUtf8(args.Argument()));
    });
    // After the handler, or a click is delivered before anyone listens.
    manager.Register();
  } catch (...) {
    // No package identity or no runtime: a click just opens the app.
  }
}

// A click that starts the process does not arrive through NotificationInvoked:
// the process is COM-activated with `----AppNotificationActivated: -Embedding`,
// Register() succeeds, and the event still never fires. The payload of the
// activation that started the process sits in the activated-event args, which
// are only readable after Register().
void ConsumeLaunchActivation() {
  try {
    using winrt::Microsoft::Windows::AppLifecycle::AppInstance;
    using winrt::Microsoft::Windows::AppLifecycle::ExtendedActivationKind;
    using winrt::Microsoft::Windows::AppNotifications::
        AppNotificationActivatedEventArgs;

    auto activated = AppInstance::GetCurrent().GetActivatedEventArgs();
    if (activated.Kind() != ExtendedActivationKind::AppNotification) return;
    auto args = activated.Data().as<AppNotificationActivatedEventArgs>();
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      g_launched_from_notification = true;
    }
    OnNotificationClicked(ToUtf8(args.Argument()));
  } catch (...) {
  }
}

}  // namespace

void InitializeActivation() {
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_initialized) return;
    g_initialized = true;
  }
  if (!HasPackageIdentity()) return;
  RegisterPush();
  RegisterNotificationClicks();
  ConsumeLaunchActivation();
}

void SetActivationSink(std::function<void()> sink) {
  std::function<void()> announce;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_sink = std::move(sink);
    if (!g_pending_argument.empty()) announce = g_sink;
  }
  // A click that arrived before the plugin existed (the cold start) parked
  // its argument without anyone to tell.
  if (announce) announce();
}

std::string PeekPendingArgument() {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_pending_argument;
}

std::string TakePendingArgument() {
  std::lock_guard<std::mutex> lock(g_mutex);
  std::string argument;
  argument.swap(g_pending_argument);
  return argument;
}

void AcknowledgeArgument(const std::string& argument) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_pending_argument == argument) g_pending_argument.clear();
}

bool ConsumeLaunchedFromNotification() {
  std::lock_guard<std::mutex> lock(g_mutex);
  bool launched = g_launched_from_notification;
  g_launched_from_notification = false;
  return launched;
}

bool HasPackageIdentity() {
  UINT32 length = 0;
  return ::GetCurrentPackageFullName(&length, nullptr) !=
         APPMODEL_ERROR_NO_PACKAGE;
}

bool IsPushSupported() {
  if (!HasPackageIdentity()) return false;
  try {
    return PushNotificationManager::IsSupported();
  } catch (...) {
    return false;
  }
}

}  // namespace windows_push
