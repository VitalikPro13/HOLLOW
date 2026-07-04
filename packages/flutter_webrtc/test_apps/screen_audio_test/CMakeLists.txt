cmake_minimum_required(VERSION 3.20)
project(screen_audio_test LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.24.0")
  cmake_policy(SET CMP0135 NEW)
endif()

# macOS: build a universal (arm64 + x86_64) binary down to the same OS floor as
# Hollow.app (10.15). The render path (AudioQueue) works on every supported
# version — only the future SEND tap will be @available-gated to 14.2+.
if(APPLE)
  if(NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "" FORCE)
  endif()
  if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "10.15" CACHE STRING "" FORCE)
  endif()
endif()

include(FetchContent)

# --- Opus v1.5.2 ---
FetchContent_Declare(
  opus
  URL https://github.com/xiph/opus/archive/refs/tags/v1.5.2.tar.gz
)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(opus)

# --- libogg v1.3.5 ---
FetchContent_Declare(
  ogg
  URL https://github.com/xiph/ogg/archive/refs/tags/v1.3.5.tar.gz
)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(INSTALL_DOCS OFF CACHE BOOL "" FORCE)
set(INSTALL_CMAKE_PACKAGE_MODULE OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(ogg)

# --- Common sources (all platforms) ---
set(COMMON_SOURCES
  main.cpp
  opus_encoder_wrapper.cpp
  opus_decoder_wrapper.cpp
  ogg_opus_writer.cpp
)

# --- Platform-specific sources ---
if(WIN32)
  list(APPEND COMMON_SOURCES
    process_audio_capturer.cc
    multi_process_capturer.cc
    audio_session_enum.cc
    ../../windows/wasapi_loopback_capturer.cc
    audio_player_win.cpp
  )
elseif(APPLE)
  list(APPEND COMMON_SOURCES
    audio_player_mac.cpp
  )
elseif(UNIX)
  list(APPEND COMMON_SOURCES
    audio_player_linux.cpp
    pulse_monitor_capturer.cc
    pulse_sink_input_capturer.cc
    x11_window_pid.cc
  )
endif()

add_executable(screen_audio_test ${COMMON_SOURCES})

target_include_directories(screen_audio_test PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(screen_audio_test PRIVATE opus ogg)

target_compile_definitions(screen_audio_test PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
)

# --- Platform-specific config ---
if(WIN32)
  target_include_directories(screen_audio_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../windows
  )
  target_link_libraries(screen_audio_test PRIVATE
    Mmdevapi.lib Avrt.lib ole32.lib RuntimeObject.lib winmm.lib user32.lib
  )
  # Static CRT linking — no MSVCP140/VCRUNTIME140 dependency.
  set_property(TARGET screen_audio_test PROPERTY
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  set_property(TARGET opus PROPERTY
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  set_property(TARGET ogg PROPERTY
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

elseif(APPLE)
  find_library(AUDIOTOOLBOX_LIB AudioToolbox REQUIRED)
  find_library(COREAUDIO_LIB CoreAudio REQUIRED)
  target_link_libraries(screen_audio_test PRIVATE
    ${AUDIOTOOLBOX_LIB} ${COREAUDIO_LIB}
  )

elseif(UNIX)
  find_package(PkgConfig REQUIRED)
  find_package(Threads REQUIRED)
  # libpulse (async API) for the per-sink-input capturer + default-sink query;
  # libpulse-simple for the plain monitor/playback streams.
  pkg_check_modules(PULSE REQUIRED libpulse-simple libpulse)
  target_include_directories(screen_audio_test PRIVATE ${PULSE_INCLUDE_DIRS})
  target_link_libraries(screen_audio_test PRIVATE
    ${PULSE_LIBRARIES} Threads::Threads
  )
  # libX11 (optional): resolves a shared window's X id -> _NET_WM_PID for
  # per-app audio capture. Without it, per-app shares mix silence.
  pkg_check_modules(X11 x11)
  if(X11_FOUND)
    target_compile_definitions(screen_audio_test PRIVATE HAVE_X11)
    target_include_directories(screen_audio_test PRIVATE ${X11_INCLUDE_DIRS})
    target_link_libraries(screen_audio_test PRIVATE ${X11_LIBRARIES})
  else()
    message(WARNING "libX11 dev headers not found — per-app screen-share \
audio will capture SILENCE (install libx11-dev).")
  endif()
endif()
