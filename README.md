# windows_push

Push notifications for Flutter on Windows through the Windows Push
Notification Services (WNS): a channel URI for your server, the click on a
notification routed to Dart whether it found the app running or started it,
and local toasts that click the same way.

`firebase_messaging` has no Windows implementation, and the existing toast
packages only show notifications the app raises itself. This package covers
the part in between: the channel your server pushes to, and what happens when
someone clicks the result.

```dart
final push = WindowsPush.instance;

// Listen first, then ask for the click that started the app.
push.onNotificationClick.listen(openRoute);
final initial = await push.getInitialNotificationClick();
if (initial != null) openRoute(initial);

// Ask on every start; channels expire after 30 days.
final uri = await push.getChannelUri(remoteId: '<service principal Object ID>');
if (uri != null) await myServer.registerWindowsDevice(uri);
```

Off Windows, without package identity (a plain `flutter run`), or on a machine
without push support, `isSupported()` is false, `getChannelUri` returns null
and the toast methods return false. Nothing throws.

## What you need

- **An MSIX package.** WNS, the toast activator and the toast notifier all
  need package identity.
- **An Entra directory and an app registration in it, set to multi-tenant.**
  Two of its GUIDs are needed, and they are easy to mix up:
  - the **Application (client) ID** goes into the package manifest
    (`patch_manifest --app-id`) and is what your server authenticates as;
  - the **Object ID of its service principal** is the `remoteId` of
    `getChannelUri`. Open the registration, follow "Managed application in
    local directory" and take the Object ID there. The Object ID on the
    registration's own overview page is a different GUID and gets no channel.

  A plain Microsoft account
  without a directory can no longer create app registrations, and a
  registration for personal accounts only never gets a WNS token: the tenant
  endpoints refuse it (AADSTS9002331) and `/consumers` refuses WNS as a target
  (AADSTS9002332).
- **A client secret for that registration, on your server.** The server gets a
  token from `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token`
  with the scope `https://wns.windows.com/.default` and posts toast XML to the
  channel URI. The old package SID flow against `login.live.com` is retired.

The PFN mapping by email that older Microsoft documentation describes was not
needed in our setup.

## Setup

### 1. Register early in `wWinMain`

In `windows/runner/main.cpp`, right after `CoInitializeEx`:

```cpp
#include <windows_push/windows_push_plugin_c_api.h>

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  WindowsPushInitialize();
```

A click that starts the app COM-activates the process and is delivered right
away, long before the Flutter engine runs. The plugin registers itself too,
so clicks reach a running app without this line, but only the early call
catches the click that launched it.

### 2. Patch the package manifest

The manifest needs two COM activators and, normally, a dependency on the
Windows App Runtime. With the [msix](https://pub.dev/packages/msix) package,
split `msix:create` into its two halves and patch in between:

```sh
flutter build windows --release
dart run msix:build
dart run windows_push:patch_manifest --app-id=<client ID> --runtime=2
dart run msix:pack
```

Other packaging flows work the same way: pass `--manifest=<path>` and run it
before `makeappx` seals the package. The tool is idempotent.

| Option | Meaning |
| --- | --- |
| `--app-id` | Application (client) ID of the app registration. Required. Not the `remoteId` of `getChannelUri`. |
| `--runtime` | Major version of the Windows App Runtime framework to depend on, such as `2`. Leave it out when you ship the runtime self-contained. |
| `--runtime-version` | MinVersion of that dependency. Default `2.3.1.0` for runtime 2. `0.0.0.0` is rejected by the Store. |
| `--toast-clsid` | CLSID the shell activates when a toast is clicked. By default it is derived from the package name. **It must never change once you ship**, or every toast already in Action Center stops opening the app. |
| `--display-name` | Name of the COM servers. Default: the package display name. |
| `--manifest` | Default `build/windows/x64/runner/Release/AppxManifest.xml`. |

Do not set `toast_activator` in `msix_config`; the tool refuses a manifest
that already has one, because the Windows App SDK needs its own arguments.

**Framework-dependent or self-contained.** `--runtime=2` makes Windows install
the Windows App Runtime from the Store alongside your app, and is what the
Store expects. Without it, you ship the runtime yourself, which this package
does not do for you.

## Clicks

The argument of a click is the toast's `launch` attribute, exactly as your
server or `showToast` set it; route it however your app routes links. A click
while the app runs arrives on `onNotificationClick` and brings the window to
the front. A click that starts the app is kept natively until
`getInitialNotificationClick()` reads it, and the window is raised once
Flutter shows its first frame. The native side only forgets a click once Dart
has taken it, so it is never lost and never delivered twice.

## Local toasts

```dart
await push.scheduleToast(
  tag: 'focus-end',
  at: DateTime.now().add(const Duration(minutes: 25)),
  title: 'Focus time is over',
  body: 'Take a short break.',
  argument: '/time/focus',
);
await push.cancelToast('focus-end');
```

Showing and scheduling use the same package identity and the same activator
as pushes, so their clicks take the same path. A tag and group pair replaces
an earlier toast with the same pair. A time that already passed shows the
toast at once unless it would have expired. For anything richer (images,
buttons, progress) use a toast package and keep this one for push.

## Build notes

The plugin downloads the Windows App SDK Foundation package from nuget.org at
configure time and generates only the C++/WinRT headers it uses. It generates
them with the `cppwinrt.exe` of the Windows SDK the build targets, because
generated headers must match the SDK's own `winrt/base.h`; only when that SDK
has no generator does it fetch the matching version from nuget.org.
Nothing extra ships next to your executable.

The plugin builds with Visual Studio 2022 and 2026. If another plugin breaks
under Visual Studio 2026 with error STL1011 about `<experimental/coroutine>`,
add `add_definitions(-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)`
to your app's `windows/CMakeLists.txt`.

Switching between `--debug` and `--release` in the same build folder can leave
a stale Dart snapshot in the release output: native changes show up, Dart
changes do not. Compare the time of `Release/data/app.so` with your sources
when that happens.

## Example

[`example/`](example) shows the status, the channel URI and the last click,
and has buttons for a local toast. [`example/tool/send_push.dart`](example/tool/send_push.dart)
is a minimal server that sends one push to a channel URI.

## License

MIT
