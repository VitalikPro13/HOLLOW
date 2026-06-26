cmake_minimum_required(VERSION 3.15)
set(PROJECT_NAME "flutter_webrtc")
project(${PROJECT_NAME} LANGUAGES CXX C)

# C++20 for C++/WinRT (Windows.Graphics.Capture).
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if (CMAKE_VERSION VERSION_GREATER_EQUAL "3.24.0")
  cmake_policy(SET CMP0135 NEW)
endif()

# Add the libwebrtc dependency
include("${CMAKE_CURRENT_SOURCE_DIR}/../third_party/CMakeLists.txt")

# --- Opus v1.5.2 (for screen share audio encoding/decoding) ---
include(FetchContent)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
FetchContent_Declare(
  opus
  URL https://github.com/xiph/opus/archive/refs/tags/v1.5.2.tar.gz
  EXCLUDE_FROM_ALL
)
FetchContent_MakeAvailable(opus)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "flutter_webrtc_plugin")

add_definitions(-DLIB_WEBRTC_API_DLL)
add_definitions(-DRTC_DESKTOP_DEVICE)

add_library(${PLUGIN_NAME} SHARED
  "../common/cpp/src/flutter_common.cc"
  "../common/cpp/src/flutter_data_channel.cc"
  "../common/cpp/src/flutter_data_packet_cryptor.cc"
  "../common/cpp/src/flutter_frame_cryptor.cc"
  "../common/cpp/src/flutter_media_stream.cc"
  "../common/cpp/src/flutter_utf8_sanitize.cc"
  "../common/cpp/src/flutter_peerconnection.cc"
  "../common/cpp/src/flutter_frame_capturer.cc"
  "../common/cpp/src/flutter_video_renderer.cc"
  "../common/cpp/src/flutter_screen_capture.cc"
  "../common/cpp/src/flutter_webrtc.cc"
  "../common/cpp/src/flutter_webrtc_base.cc"
  "../common/cpp/src/flutter_capture_gain_processor.cc"
  "application_loopback_capturer.cc"
  "loopback_capturer_factory.cc"
  "flutter_webrtc_plugin.cc"
  "task_runner_windows.cc"
  "wasapi_loopback_capturer.cc"
  "win_screen_recorder.cc"
  "opus_encoder_wrapper.cpp"
  "opus_decoder_wrapper.cpp"
  "process_audio_capturer.cc"
  "wasapi_audio_renderer.cc"
  "screen_audio_capturer.cc"
  # native_screen_capturer.cc dropped from the build: it depends on the custom
  # libwebrtc CreateFromBGRA, absent in stock m144.7559.09 (adopted in the 1.5.2
  # rebase). Screen share uses libwebrtc's own desktop capturer now; the file
  # stays in-tree, re-add it + define HOLLOW_USE_NATIVE_SCREEN_CAPTURER + link a
  # libwebrtc with CreateFromBGRA to restore the resolution-cap native path.
  # See project_flutter_webrtc_152_upgrade.
)

include_directories(
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/cpp/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/svpng"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/include"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/cpp/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/include"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/lib/libwebrtc.dll.lib"
  opus
  mfplat.lib
  mfreadwrite.lib
  mfuuid.lib
  mf.lib
  d3d11.lib
  dxgi.lib
  windowsapp.lib
  RuntimeObject.lib
  # Added with upstream 1.5.2's application loopback capturer (#2060).
  avrt.lib
  ksuser.lib
  mmdevapi.lib
  ole32.lib
  uuid.lib
  winmm.lib
)

target_compile_options(${PLUGIN_NAME} PRIVATE /await)

# List of absolute paths to libraries that should be bundled with the plugin
set(flutter_webrtc_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/lib/libwebrtc.dll"
  PARENT_SCOPE
)
