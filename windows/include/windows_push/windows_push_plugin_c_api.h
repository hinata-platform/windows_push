#ifndef FLUTTER_PLUGIN_WINDOWS_PUSH_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_WINDOWS_PUSH_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

// Registers the app with the push and notification platforms and reads the
// activation that started this process.
//
// Call it at the top of wWinMain, right after CoInitializeEx and before any
// window or engine exists. When a notification click starts the app, Windows
// COM-activates it and delivers the activation almost immediately; registering
// once the Flutter window is up is too late for that cold start. The plugin
// calls this itself when it registers, so a warm click works without it, but
// only the early call catches the click that launched the app.
//
// Safe to call more than once, and safe in a build without package identity:
// it then does nothing.
FLUTTER_PLUGIN_EXPORT void WindowsPushInitialize(void);

FLUTTER_PLUGIN_EXPORT void WindowsPushPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_WINDOWS_PUSH_PLUGIN_C_API_H_
