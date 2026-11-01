#ifndef FLUTTER_PLUGIN_WINDOWS_PUSH_STRING_UTIL_H_
#define FLUTTER_PLUGIN_WINDOWS_PUSH_STRING_UTIL_H_

#include <windows.h>
#include <winrt/base.h>

#include <string>

namespace windows_push {

inline std::string ToUtf8(const wchar_t* value, size_t length) {
  if (length == 0) return {};
  int size = ::WideCharToMultiByte(CP_UTF8, 0, value, static_cast<int>(length),
                                   nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string out(size, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, value, static_cast<int>(length),
                        out.data(), size, nullptr, nullptr);
  return out;
}

inline std::string ToUtf8(const winrt::hstring& value) {
  return ToUtf8(value.c_str(), value.size());
}

}  // namespace windows_push

#endif  // FLUTTER_PLUGIN_WINDOWS_PUSH_STRING_UTIL_H_
