#ifndef FLUTTER_PLUGIN_WINDOWS_PUSH_ACTIVATION_H_
#define FLUTTER_PLUGIN_WINDOWS_PUSH_ACTIVATION_H_

#include <windows.h>

#include <functional>
#include <string>

namespace windows_push {

// Registers with PushNotificationManager and AppNotificationManager and reads
// the activation that started the process. Idempotent; see
// WindowsPushInitialize() for why it has to run at the top of wWinMain.
void InitializeActivation();

// Called with the argument of a clicked notification, on whatever thread the
// platform delivered it. Set once by the plugin; a click that arrives earlier
// is parked in the buffer below and announced when the sink is set.
void SetActivationSink(std::function<void()> sink);

// The argument of the last click nobody has acknowledged yet, without
// removing it.
std::string PeekPendingArgument();

// Removes and returns the pending argument. Only Dart's explicit request for
// the initial click and an acknowledged delivery drain the buffer: on a cold
// start the click fires while the engine is still booting, and a delivery that
// reached no handler must leave the argument for getInitialNotificationClick.
std::string TakePendingArgument();

// Clears the buffer if it still holds |argument|.
void AcknowledgeArgument(const std::string& argument);

// True once, after a notification click started this process: the window has
// to be raised by hand once it is on screen, because a COM-activated process
// has no foreground rights of its own.
bool ConsumeLaunchedFromNotification();

// Whether the process runs with package identity. Push, the toast activator
// and the classic toast notifier all need it; a plain `flutter run` has none.
bool HasPackageIdentity();

// Whether this machine and build can mint a push channel.
bool IsPushSupported();

}  // namespace windows_push

#endif  // FLUTTER_PLUGIN_WINDOWS_PUSH_ACTIVATION_H_
