# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(hollow LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "hollow")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# Copy OpenSSL DLLs required by SQLCipher at runtime.
set(OPENSSL_BIN_DIR "C:/Program Files/OpenSSL-Win64/bin")
install(FILES
  "${OPENSSL_BIN_DIR}/libcrypto-3-x64.dll"
  "${OPENSSL_BIN_DIR}/libssl-3-x64.dll"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Copy bundled ffmpeg binary used by VideoThumbnailService for first-frame
# WebP thumbnail extraction. Sourced via scripts/fetch_ffmpeg.ps1.
# See HOLLOW_PLAN.md Phase 6.75 "Video preview in chats".
set(BUNDLED_FFMPEG_SRC "${CMAKE_SOURCE_DIR}/../vendor/ffmpeg/ffmpeg-win-x64.exe")
if(EXISTS "${BUNDLED_FFMPEG_SRC}")
  install(PROGRAMS "${BUNDLED_FFMPEG_SRC}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    RENAME "ffmpeg.exe"
    COMPONENT Runtime)
else()
  message(WARNING
    "vendor/ffmpeg/ffmpeg-win-x64.exe not found. "
    "Run scripts/fetch_ffmpeg.ps1 to populate it. "
    "Video thumbnail extraction will be disabled at runtime.")
endif()

# Copy bundled screen audio capturer (out-of-process WASAPI→Opus for screen
# share audio). Built from packages/flutter_webrtc/test_apps/screen_audio_test/.
set(SCREEN_AUDIO_EXE "${CMAKE_SOURCE_DIR}/../packages/flutter_webrtc/test_apps/screen_audio_test/build/Release/screen_audio_test.exe")
if(EXISTS "${SCREEN_AUDIO_EXE}")
  install(PROGRAMS "${SCREEN_AUDIO_EXE}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    RENAME "screen_audio_capturer.exe"
    COMPONENT Runtime)
else()
  message(WARNING
    "screen_audio_test.exe not found. "
    "Build packages/flutter_webrtc/test_apps/screen_audio_test/ first. "
    "Screen share audio will be unavailable.")
endif()

# Copy the bundled `shoes` REALITY tunnel client (anti-censorship transport).
# Ships next to hollow.exe; the Rust node spawns it as a local SOCKS5 proxy when
# the user enables proxy mode. Built from cfal/shoes (MIT) via scripts/build_shoes.ps1.
# See HOLLOW_PLAN.md "Fight Government Censorship".
set(BUNDLED_SHOES_SRC "${CMAKE_SOURCE_DIR}/../vendor/shoes/shoes-win-x64.exe")
if(EXISTS "${BUNDLED_SHOES_SRC}")
  install(PROGRAMS "${BUNDLED_SHOES_SRC}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    RENAME "shoes.exe"
    COMPONENT Runtime)
else()
  message(WARNING
    "vendor/shoes/shoes-win-x64.exe not found. "
    "Run scripts/build_shoes.ps1 to populate it. "
    "Anti-censorship proxy mode will be unavailable.")
endif()

# === Visual C++ runtime (VCRUNTIME140 / VCRUNTIME140_1 / MSVCP140) ===
# hollow.exe, hollow_core.dll, flutter_webrtc_plugin.dll and mdk.dll all import
# the MSVC C++ runtime. A fresh Windows install does NOT have these unless the
# user separately installed the "VC++ 2015-2022 Redistributable", so without
# bundling them the app fails to launch with "VCRUNTIME140.dll was not found".
# (The api-ms-win-crt-*.dll the binaries also import are the Universal CRT,
# which IS part of Windows 10+ itself — those we deliberately do NOT ship.)
#
# InstallRequiredSystemLibraries locates the version-correct redistributable
# DLLs that match the active MSVC toolset (auto-tracks Visual Studio upgrades,
# so this never silently ships a stale runtime), sourced from the licensed
# VC\Redist\MSVC\<ver>\x64\Microsoft.VC14x.CRT\ folder — NOT from System32.
# We drive the install() ourselves (SKIP=TRUE) so the DLLs land flat next to
# hollow.exe (the module's default puts them in a bin/ subfolder) and only in
# Release/Profile (Debug uses the non-redistributable debug runtime).
set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
set(CMAKE_INSTALL_UCRT_LIBRARIES FALSE)
include(InstallRequiredSystemLibraries)
if(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
  install(PROGRAMS ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS}
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    CONFIGURATIONS Profile;Release
    COMPONENT Runtime)
else()
  message(WARNING
    "InstallRequiredSystemLibraries found no VC++ runtime DLLs to bundle. "
    "Users without the VC++ Redistributable may fail to launch hollow.exe. "
    "Ensure the Visual Studio C++ workload (with the redistributable) is installed.")
endif()
