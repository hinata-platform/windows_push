#include "windows_push_plugin.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Microsoft.Windows.PushNotifications.h>
#include <winrt/Windows.Foundation.h>

#include <cstdint>
#include <mutex>
#include <queue>
#include <string>
#include <utility>

#include "activation.h"
#include "string_util.h"
#include "toasts.h"

extern "C" IMAGE_DOS_HEADER __ImageBase;

namespace windows_push {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodResult;
using winrt::Microsoft::Windows::PushNotifications::PushNotificationChannelStatus;
using winrt::Microsoft::Windows::PushNotifications::PushNotificationManager;

constexpr char kChannelName[] = "windows_push";
constexpr wchar_t kWindowClass[] = L"WindowsPushMessageWindow";
constexpr wchar_t kDefaultGroup[] = L"windows_push";

// WM_APP and up are reserved for the application; this window is ours alone.
constexpr UINT kWmRepliesReady = WM_APP + 1;
constexpr UINT kWmNotificationClick = WM_APP + 2;
constexpr UINT kWmRaiseWindow = WM_APP + 3;

const EncodableValue* Lookup(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(std::string(key)));
  return it == map.end() ? nullptr : &it->second;
}

std::string StringArg(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Lookup(map, key);
  if (value == nullptr) return {};
  if (const auto* text = std::get_if<std::string>(value)) return *text;
  return {};
}

std::optional<int64_t> IntArg(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Lookup(map, key);
  if (value == nullptr) return std::nullopt;
  // Dart ints arrive as int32 or int64 depending on magnitude. The names are
  // not "small"/"large": <rpcndr.h> defines `small` as a macro for char.
  if (const auto* as32 = std::get_if<int32_t>(value)) return *as32;
  if (const auto* as64 = std::get_if<int64_t>(value)) return *as64;
  return std::nullopt;
}

const EncodableMap* MapArgs(const EncodableValue* arguments) {
  return arguments == nullptr ? nullptr
                              : std::get_if<EncodableMap>(arguments);
}

winrt::hstring GroupArg(const EncodableMap& map) {
  std::string group = StringArg(map, "group");
  // The platform caps tags and groups at 64 characters.
  if (group.empty() || group.size() > 64) return kDefaultGroup;
  return winrt::to_hstring(group);
}

std::optional<ToastRequest> ParseToastRequest(const EncodableValue* arguments,
                                              bool needs_time) {
  const EncodableMap* map = MapArgs(arguments);
  if (map == nullptr) return std::nullopt;
  ToastRequest request;
  std::string tag = StringArg(*map, "tag");
  if (tag.empty() || tag.size() > 64) return std::nullopt;
  request.tag = winrt::to_hstring(tag);
  request.group = GroupArg(*map);
  request.title = winrt::to_hstring(StringArg(*map, "title"));
  request.body = winrt::to_hstring(StringArg(*map, "body"));
  request.argument = winrt::to_hstring(StringArg(*map, "argument"));
  if (needs_time) {
    auto at = IntArg(*map, "at");
    if (!at || *at <= 0) return std::nullopt;
    request.at_ms = *at;
  }
  if (auto expire = IntArg(*map, "expireMinutes"); expire && *expire > 0) {
    request.expire_minutes = *expire;
  }
  return request;
}

// A process started by a notification click is COM-activated, so Windows does
// not bring its window forward the way a normal launch does. Foreground rights
// belong to the process the user just interacted with, so this is done by hand.
void BringToForeground(HWND window) {
  if (!window) return;
  ::ShowWindow(window, ::IsIconic(window) ? SW_RESTORE : SW_SHOW);

  // SetForegroundWindow is refused unless the calling thread already owns the
  // foreground. Borrowing the foreground thread's input queue for the call is
  // the long-standing way around that.
  HWND foreground = ::GetForegroundWindow();
  DWORD other = ::GetWindowThreadProcessId(foreground, nullptr);
  DWORD self = ::GetCurrentThreadId();
  bool attached =
      other && other != self && ::AttachThreadInput(other, self, TRUE);
  ::SetForegroundWindow(window);
  ::SetActiveWindow(window);
  if (attached) ::AttachThreadInput(other, self, FALSE);

  // Even then the request can be refused. Briefly making the window topmost
  // forces it in front; dropping the flag again keeps it a normal window.
  if (::GetForegroundWindow() != window) {
    constexpr UINT kFlags = SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW;
    ::SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0, kFlags);
    ::SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0, kFlags);
    ::SetForegroundWindow(window);
  }
}

}  // namespace

struct ReplyQueue {
  struct Reply {
    std::unique_ptr<MethodResult<EncodableValue>> result;
    std::string uri;
  };
  std::mutex mutex;
  std::queue<Reply> ready;
  HWND window = nullptr;

  // Called from WinRT completion threads.
  void Push(std::unique_ptr<MethodResult<EncodableValue>> result,
            std::string uri) {
    HWND target;
    {
      std::lock_guard<std::mutex> lock(mutex);
      ready.push(Reply{std::move(result), std::move(uri)});
      target = window;
    }
    if (target) ::PostMessage(target, kWmRepliesReady, 0, 0);
  }
};

// static
void WindowsPushPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  // A no-op when the runner already called WindowsPushInitialize() from
  // wWinMain, which is the only place that catches a cold-start click.
  InitializeActivation();
  registrar->AddPlugin(std::make_unique<WindowsPushPlugin>(registrar));
}

WindowsPushPlugin::WindowsPushPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar), replies_(std::make_shared<ReplyQueue>()) {
  HINSTANCE instance = reinterpret_cast<HINSTANCE>(&__ImageBase);
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = &WindowsPushPlugin::MessageWindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kWindowClass;
  ::RegisterClassExW(&window_class);  // fails harmlessly when already there
  message_window_ = ::CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0,
                                      HWND_MESSAGE, nullptr, instance, nullptr);
  if (message_window_) {
    ::SetWindowLongPtrW(message_window_, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(this));
  }
  replies_->window = message_window_;

  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });

  top_level_delegate_ = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleTopLevelMessage(window, message, wparam, lparam);
      });

  HWND target = message_window_;
  SetActivationSink([target]() {
    if (target) ::PostMessage(target, kWmNotificationClick, 0, 0);
  });
}

WindowsPushPlugin::~WindowsPushPlugin() {
  SetActivationSink(nullptr);
  registrar_->UnregisterTopLevelWindowProcDelegate(top_level_delegate_);
  {
    std::lock_guard<std::mutex> lock(replies_->mutex);
    replies_->window = nullptr;
  }
  if (message_window_) ::DestroyWindow(message_window_);
}

// static
LRESULT CALLBACK WindowsPushPlugin::MessageWindowProc(HWND window,
                                                      UINT message,
                                                      WPARAM wparam,
                                                      LPARAM lparam) {
  auto* plugin = reinterpret_cast<WindowsPushPlugin*>(
      ::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (plugin != nullptr) {
    switch (message) {
      case kWmRepliesReady:
        plugin->FlushReplies();
        return 0;
      case kWmNotificationClick:
        plugin->DeliverClick();
        return 0;
      case kWmRaiseWindow:
        BringToForeground(plugin->TopLevelWindow());
        return 0;
    }
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

std::optional<LRESULT> WindowsPushPlugin::HandleTopLevelMessage(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  // The runner keeps its window hidden until Flutter's first frame. Raising it
  // any earlier does nothing, so a click that started the process is answered
  // once the window is about to appear. Posted, because the window is not
  // visible yet while WM_SHOWWINDOW is being handled.
  if (message == WM_SHOWWINDOW && wparam == TRUE &&
      ConsumeLaunchedFromNotification()) {
    ::PostMessage(message_window_, kWmRaiseWindow, 0, 0);
  }
  return std::nullopt;
}

HWND WindowsPushPlugin::TopLevelWindow() const {
  flutter::FlutterView* view = registrar_->GetView();
  if (view == nullptr) return nullptr;
  return ::GetAncestor(view->GetNativeWindow(), GA_ROOT);
}

void WindowsPushPlugin::DeliverClick() {
  std::string argument = PeekPendingArgument();
  // The click was a user action on this app: show it, if it is already on
  // screen and only hidden behind other windows. A window still waiting for
  // its first frame is raised on WM_SHOWWINDOW instead.
  HWND window = TopLevelWindow();
  if (window && ::IsWindowVisible(window)) BringToForeground(window);
  if (argument.empty()) return;
  // Best effort, and the buffer is only cleared once Dart acknowledged. On a
  // cold start the engine has no handler yet and replies NotImplemented, which
  // leaves the argument for getInitialNotificationClick(); an acknowledged
  // delivery keeps that path from routing it a second time.
  channel_->InvokeMethod(
      "onNotificationClick", std::make_unique<EncodableValue>(argument),
      std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
          [argument](const EncodableValue*) { AcknowledgeArgument(argument); },
          [](const std::string&, const std::string&, const EncodableValue*) {},
          []() {}));
}

void WindowsPushPlugin::FlushReplies() {
  for (;;) {
    ReplyQueue::Reply reply;
    {
      std::lock_guard<std::mutex> lock(replies_->mutex);
      if (replies_->ready.empty()) break;
      reply = std::move(replies_->ready.front());
      replies_->ready.pop();
    }
    if (!reply.result) continue;
    if (reply.uri.empty()) {
      reply.result->Success(EncodableValue());
    } else {
      reply.result->Success(EncodableValue(reply.uri));
    }
  }
}

void WindowsPushPlugin::RequestChannel(
    const std::string& remote_id,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  if (!IsPushSupported()) {
    // Read as "not available here" on the Dart side.
    result->Success(EncodableValue());
    return;
  }
  auto pending =
      std::make_shared<std::unique_ptr<MethodResult<EncodableValue>>>(
          std::move(result));
  auto replies = replies_;
  try {
    auto operation = PushNotificationManager::Default().CreateChannelAsync(
        winrt::guid(winrt::to_hstring(remote_id)));
    operation.Completed([pending, replies](auto const& op, auto) {
      std::string uri;
      try {
        auto channel_result = op.GetResults();
        if (channel_result.Status() ==
            PushNotificationChannelStatus::CompletedSuccess) {
          uri = ToUtf8(channel_result.Channel().Uri().ToString());
        }
      } catch (...) {
        // Reported as null; never worth crashing the app over.
      }
      if (*pending) replies->Push(std::move(*pending), std::move(uri));
    });
  } catch (...) {
    // A malformed remote id, or no runtime. Expected, not an error.
    if (*pending) (*pending)->Success(EncodableValue());
  }
}

void WindowsPushPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "isSupported") {
    result->Success(EncodableValue(IsPushSupported()));
    return;
  }
  if (method == "getChannelUri") {
    const EncodableMap* map = MapArgs(call.arguments());
    std::string remote_id = map == nullptr ? "" : StringArg(*map, "remoteId");
    if (remote_id.empty()) {
      result->Error("bad-args", "remoteId is required");
      return;
    }
    RequestChannel(remote_id, std::move(result));
    return;
  }
  if (method == "getInitialNotificationClick") {
    std::string argument = TakePendingArgument();
    if (argument.empty()) {
      result->Success(EncodableValue());
    } else {
      result->Success(EncodableValue(argument));
    }
    return;
  }
  if (method == "showToast" || method == "scheduleToast") {
    bool schedule = method == "scheduleToast";
    auto request = ParseToastRequest(call.arguments(), schedule);
    bool ok = request.has_value() &&
              (schedule ? ScheduleToast(*request) : ShowToast(*request));
    result->Success(EncodableValue(ok));
    return;
  }
  if (method == "cancelToast") {
    const EncodableMap* map = MapArgs(call.arguments());
    std::string tag = map == nullptr ? "" : StringArg(*map, "tag");
    if (!tag.empty()) CancelToast(winrt::to_hstring(tag), GroupArg(*map));
    result->Success();
    return;
  }
  result->NotImplemented();
}

}  // namespace windows_push
