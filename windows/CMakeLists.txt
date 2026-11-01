# file(ARCHIVE_EXTRACT) for the Windows App SDK fetch needs 3.18. Every Visual
# Studio that builds current Flutter ships a newer CMake.
cmake_minimum_required(VERSION 3.18)

set(PROJECT_NAME "windows_push")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.18...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "windows_push_plugin")

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/WindowsAppSDK.cmake")

list(APPEND PLUGIN_SOURCES
  "activation.cpp"
  "activation.h"
  "string_util.h"
  "toasts.cpp"
  "toasts.h"
  "windows_push_plugin.cpp"
  "windows_push_plugin.h"
)

add_library(${PLUGIN_NAME} SHARED
  "include/windows_push/windows_push_plugin_c_api.h"
  "windows_push_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. Exports go through FLUTTER_PLUGIN_EXPORT.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
# C++/WinRT pulls in <experimental/coroutine> under C++17, and the STL of
# Visual Studio 2026 (MSVC 14.5x) turns its deprecation into error STL1011.
# This is Microsoft's documented escape hatch, named in the error text.
target_compile_definitions(${PLUGIN_NAME} PRIVATE
  _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter flutter_wrapper_plugin windows_push_app_sdk)

# Nothing to bundle: the Windows App Runtime comes from the framework package
# the MSIX depends on (see `dart run windows_push:patch_manifest`).
set(windows_push_bundled_libraries
  ""
  PARENT_SCOPE
)
