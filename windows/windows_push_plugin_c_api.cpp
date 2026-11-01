#include "include/windows_push/windows_push_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "activation.h"
#include "windows_push_plugin.h"

void WindowsPushInitialize(void) { windows_push::InitializeActivation(); }

void WindowsPushPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  windows_push::WindowsPushPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
