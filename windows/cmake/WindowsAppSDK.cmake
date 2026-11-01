# Windows App SDK for the plugin.
#
# A Flutter plugin is a plain CMake project, while the Windows App SDK ships as
# NuGet packages with MSBuild targets and no pre-generated C++ headers: the
# projection has to be produced from the shipped .winmd metadata. This module
# does that without MSBuild and without a vendored binary:
#
#   1. download the Foundation NuGet package (an ordinary zip) at configure
#      time, and cppwinrt too when the Windows SDK has no generator of its own
#   2. run cppwinrt.exe over the metadata to generate winrt/Microsoft.Windows.*.h
#   3. expose the headers as the `windows_push_app_sdk` interface target
#
# Only PushNotificationManager can mint a WNS channel for a packaged Win32 app;
# the classic PushNotificationChannelManager authenticates against a retired
# endpoint. Nothing here is linked at runtime: the classes come from the
# Windows App Runtime framework package the MSIX depends on.

set(WASDK_FOUNDATION_VERSION "2.3.5")

# The generator MUST match the cppwinrt the Windows SDK ships, because the
# generated headers are consumed together with the SDK's own winrt/base.h: only
# the App SDK namespaces are generated, not a full projection, so base.h is
# never ours. A mismatched generator produces headers whose static_assert
# rejects that base.h with "Mismatched C++/WinRT headers".
#
# Which version that is depends on the machine: a dev box and a CI runner ship
# different Windows Kits. So it is read out of the SDK's own base.h instead of
# pinned. The fallback is what Windows Kits 10.0.26100.0 ships.
set(WASDK_CPPWINRT_FALLBACK "2.0.250303.1")

set(_wasdk_base_headers "")
foreach(_kit_root "$ENV{ProgramFiles\(x86\)}/Windows Kits/10" "$ENV{ProgramFiles}/Windows Kits/10")
  if(EXISTS "${_kit_root}/Include")
    file(GLOB _found "${_kit_root}/Include/*/cppwinrt/winrt/base.h")
    list(APPEND _wasdk_base_headers ${_found})
  endif()
endforeach()
# Prefer the kit the build actually targets; otherwise the newest installed one.
set(_wasdk_base_h "")
if(CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION)
  foreach(_candidate ${_wasdk_base_headers})
    if(_candidate MATCHES "/Include/${CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION}/")
      set(_wasdk_base_h "${_candidate}")
    endif()
  endforeach()
endif()
if(NOT _wasdk_base_h AND _wasdk_base_headers)
  list(SORT _wasdk_base_headers)
  list(GET _wasdk_base_headers -1 _wasdk_base_h)
endif()

set(WASDK_CPPWINRT_VERSION "${WASDK_CPPWINRT_FALLBACK}")
# The SDK ships its own generator next to its headers, which matches them by
# definition. It is the first choice; nuget.org does not carry every build the
# SDK ships (Windows Kits 10.0.26100 on windows-2025 has 2.0.250303.5).
set(WASDK_SDK_CPPWINRT_EXE "")
if(_wasdk_base_h)
  file(STRINGS "${_wasdk_base_h}" _wasdk_version_line
       REGEX "^#define[ \t]+CPPWINRT_VERSION[ \t]" LIMIT_COUNT 1)
  if(_wasdk_version_line MATCHES "\"([0-9][0-9A-Za-z.-]*)\"")
    set(WASDK_CPPWINRT_VERSION "${CMAKE_MATCH_1}")
    message(STATUS "windows_push: SDK cppwinrt is ${WASDK_CPPWINRT_VERSION} (${_wasdk_base_h})")
  endif()
  if(_wasdk_base_h MATCHES "^(.*)/Include/([^/]+)/cppwinrt/winrt/base.h$")
    foreach(_arch x64 x86 arm64)
      set(_exe "${CMAKE_MATCH_1}/bin/${CMAKE_MATCH_2}/${_arch}/cppwinrt.exe")
      if(NOT WASDK_SDK_CPPWINRT_EXE AND EXISTS "${_exe}")
        set(WASDK_SDK_CPPWINRT_EXE "${_exe}")
      endif()
    endforeach()
  endif()
endif()

set(WASDK_ROOT "${CMAKE_BINARY_DIR}/windows_push_app_sdk")
set(WASDK_FOUNDATION_DIR "${WASDK_ROOT}/foundation")
set(WASDK_CPPWINRT_DIR "${WASDK_ROOT}/cppwinrt")
set(WASDK_PROJECTION_DIR "${WASDK_ROOT}/projection")

# --- 1. fetch -----------------------------------------------------------------
# |ok| reports success instead of aborting, so a version that turns out not to
# exist on nuget.org can be retried with another one.
function(_wasdk_fetch package version destination ok)
  set(${ok} TRUE PARENT_SCOPE)
  if(EXISTS "${destination}/.fetched")
    # The marker records the version, so switching versions (a different SDK on
    # this machine, a bumped pin) actually re-downloads.
    file(READ "${destination}/.fetched" fetched)
    if(fetched STREQUAL version)
      return()
    endif()
    file(REMOVE_RECURSE "${destination}")
  endif()
  set(archive "${WASDK_ROOT}/${package}.${version}.zip")
  string(TOLOWER "${package}" lower)
  message(STATUS "windows_push: fetching ${package} ${version}")
  file(DOWNLOAD
    "https://api.nuget.org/v3-flatcontainer/${lower}/${version}/${lower}.${version}.nupkg"
    "${archive}" STATUS status TLS_VERIFY ON)
  list(GET status 0 code)
  if(NOT code EQUAL 0)
    list(GET status 1 reason)
    message(STATUS "windows_push: ${package} ${version} unavailable: ${reason}")
    file(REMOVE "${archive}")
    set(${ok} FALSE PARENT_SCOPE)
    return()
  endif()
  file(ARCHIVE_EXTRACT INPUT "${archive}" DESTINATION "${destination}")
  file(REMOVE "${archive}")
  file(WRITE "${destination}/.fetched" "${version}")
endfunction()

_wasdk_fetch("Microsoft.WindowsAppSDK.Foundation" "${WASDK_FOUNDATION_VERSION}"
             "${WASDK_FOUNDATION_DIR}" _wasdk_ok)
if(NOT _wasdk_ok)
  message(FATAL_ERROR
    "Could not download Microsoft.WindowsAppSDK.Foundation ${WASDK_FOUNDATION_VERSION}")
endif()

if(WASDK_SDK_CPPWINRT_EXE)
  set(WASDK_CPPWINRT_EXE "${WASDK_SDK_CPPWINRT_EXE}")
  message(STATUS "windows_push: using the SDK's ${WASDK_CPPWINRT_EXE}")
else()
  _wasdk_fetch("Microsoft.Windows.CppWinRT" "${WASDK_CPPWINRT_VERSION}"
               "${WASDK_CPPWINRT_DIR}" _wasdk_ok)
  # Falling back keeps the build going; a mismatch then surfaces as a clear
  # "Mismatched C++/WinRT headers" error rather than a download failure.
  if(NOT _wasdk_ok AND NOT WASDK_CPPWINRT_VERSION STREQUAL WASDK_CPPWINRT_FALLBACK)
    message(WARNING "windows_push: cppwinrt ${WASDK_CPPWINRT_VERSION} is not on "
                    "nuget.org, falling back to ${WASDK_CPPWINRT_FALLBACK}")
    set(WASDK_CPPWINRT_VERSION "${WASDK_CPPWINRT_FALLBACK}")
    _wasdk_fetch("Microsoft.Windows.CppWinRT" "${WASDK_CPPWINRT_VERSION}"
                 "${WASDK_CPPWINRT_DIR}" _wasdk_ok)
  endif()
  if(NOT _wasdk_ok)
    message(FATAL_ERROR "Could not download Microsoft.Windows.CppWinRT ${WASDK_CPPWINRT_VERSION}")
  endif()
  set(WASDK_CPPWINRT_EXE "${WASDK_CPPWINRT_DIR}/bin/cppwinrt.exe")
endif()

# --- 2. generate the C++/WinRT projection -------------------------------------
#
# Generate ONLY the namespaces the plugin uses and merely *reference* the rest
# of the metadata. Feeding the whole metadata folder as `-input` fails:
# Microsoft.Security.Authentication.OAuth references Microsoft.UI.WindowId, a
# WinUI type that lives in a package we neither ship nor need. `-reference sdk`
# supplies the Windows SDK types the projection builds on.
#
# The marker ties the projection to both versions, so a new SDK or generator
# regenerates it instead of mixing old headers with a new base.h.
set(_wasdk_projection_stamp "${WASDK_FOUNDATION_VERSION}/${WASDK_CPPWINRT_VERSION}/${WASDK_CPPWINRT_EXE}")
set(_wasdk_projection_marker "${WASDK_PROJECTION_DIR}/.generated")
set(_wasdk_projection_current "")
if(EXISTS "${_wasdk_projection_marker}")
  file(READ "${_wasdk_projection_marker}" _wasdk_projection_current)
endif()
if(NOT _wasdk_projection_current STREQUAL _wasdk_projection_stamp)
  file(REMOVE_RECURSE "${WASDK_PROJECTION_DIR}")
  message(STATUS "windows_push: generating the C++/WinRT projection")
  execute_process(
    COMMAND "${WASDK_CPPWINRT_EXE}"
            -input "${WASDK_FOUNDATION_DIR}/metadata/Microsoft.Windows.PushNotifications.winmd"
            -input "${WASDK_FOUNDATION_DIR}/metadata/Microsoft.Windows.AppLifecycle.winmd"
            # A toast click activates the app through AppNotifications, not
            # through the push path.
            -input "${WASDK_FOUNDATION_DIR}/metadata/Microsoft.Windows.AppNotifications.winmd"
            -reference "${WASDK_FOUNDATION_DIR}/metadata"
            -reference sdk
            -output "${WASDK_PROJECTION_DIR}"
    RESULT_VARIABLE cppwinrt_result
    OUTPUT_VARIABLE cppwinrt_output
    ERROR_VARIABLE cppwinrt_output)
  if(NOT cppwinrt_result EQUAL 0)
    message(FATAL_ERROR "cppwinrt failed: ${cppwinrt_output}")
  endif()
  file(WRITE "${_wasdk_projection_marker}" "${_wasdk_projection_stamp}")
endif()

# --- 3. the target ------------------------------------------------------------
if(NOT TARGET windows_push_app_sdk)
  add_library(windows_push_app_sdk INTERFACE)
  target_include_directories(windows_push_app_sdk INTERFACE
    "${WASDK_PROJECTION_DIR}"
    "${WASDK_FOUNDATION_DIR}/include")
  # C++/WinRT's activation entry points.
  target_link_libraries(windows_push_app_sdk INTERFACE "windowsapp.lib")
endif()
