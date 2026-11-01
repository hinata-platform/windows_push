#ifndef FLUTTER_PLUGIN_WINDOWS_PUSH_PLUGIN_H_
#define FLUTTER_PLUGIN_WINDOWS_PUSH_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <windows.h>

#include <memory>
#include <optional>

namespace windows_push {

struct ReplyQueue;

// The method channel "windows_push":
//
//   isSupported() -> bool
//   getChannelUri({remoteId}) -> String?   null when unavailable, never throws
//   getInitialNotificationClick() -> String?
//   showToast({tag, group, title, body, argument, expireMinutes}) -> bool
//   scheduleToast({..., at (epoch ms UTC)}) -> bool
//   cancelToast({tag, group})
//
// and calls Dart with onNotificationClick(argument) when a notification is
// clicked while the app runs.
//
// WinRT completes its callbacks off the platform thread, and a MethodResult
// must not be completed from there. Everything that arrives off-thread is
// parked and handed over through a message-only window the plugin owns.
class WindowsPushPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit WindowsPushPlugin(flutter::PluginRegistrarWindows* registrar);
  virtual ~WindowsPushPlugin();

  WindowsPushPlugin(const WindowsPushPlugin&) = delete;
  WindowsPushPlugin& operator=(const WindowsPushPlugin&) = delete;

 private:
  static LRESULT CALLBACK MessageWindowProc(HWND window, UINT message,
                                            WPARAM wparam, LPARAM lparam);

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::optional<LRESULT> HandleTopLevelMessage(HWND window, UINT message,
                                               WPARAM wparam, LPARAM lparam);

  void RequestChannel(
      const std::string& remote_id,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void DeliverClick();
  void FlushReplies();
  HWND TopLevelWindow() const;

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::shared_ptr<ReplyQueue> replies_;
  HWND message_window_ = nullptr;
  int top_level_delegate_ = 0;
};

}  // namespace windows_push

#endif  // FLUTTER_PLUGIN_WINDOWS_PUSH_PLUGIN_H_
