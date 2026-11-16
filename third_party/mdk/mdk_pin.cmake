# The mdk SDK behind fvp (video_player on desktop and Android) decodes peer video.
# Unpinned, fvp downloads whatever SourceForge's nightly holds that day, with no
# checksum. This pins the tagged GitHub release, by sha256, at the version fvp's
# Swift package pins on Apple. Android repeats the version and digest in
# android/build.gradle.kts. Bump all three together with fvp.
#
# fvp asks for one fixed file name per platform, which the release does not always
# carry (Windows ships mdk-sdk-windows-x64-vs2026.7z, the nightly's
# mdk-sdk-windows-x64.7z), so the asset is fetched here under fvp's name and handed
# over through a file:// URL. fvp checks the sha256 again before extracting.
set(HOLLOW_MDK_VERSION "0.40.1")
set(_hollow_mdk_release "https://github.com/wang-bin/mdk-sdk/releases/download/v${HOLLOW_MDK_VERSION}")
if(WIN32)
  set(_hollow_mdk_asset "mdk-sdk-windows-x64-vs2026.7z")
  set(_hollow_mdk_file "mdk-sdk-windows-x64.7z")
  set(_hollow_mdk_sha256 "15b37964a57c62edd4abd078c5866cd4ff35f70c0dd1ca1b0a3d463213df8338")
elseif(CMAKE_SYSTEM_NAME MATCHES "Linux")
  set(_hollow_mdk_asset "mdk-sdk-linux-x64.tar.xz")
  set(_hollow_mdk_file "mdk-sdk-linux-x64.tar.xz")
  set(_hollow_mdk_sha256 "e53a38b6bcdce99cea852ecff25b0e4acc67539418a04b7c27868c24c130021d")
else()
  return()
endif()

set(_hollow_mdk_dir "${CMAKE_BINARY_DIR}/mdk-pin")
set(_hollow_mdk_path "${_hollow_mdk_dir}/${_hollow_mdk_file}")
set(_hollow_mdk_have OFF)
if(EXISTS "${_hollow_mdk_path}")
  file(SHA256 "${_hollow_mdk_path}" _hollow_mdk_got)
  if("${_hollow_mdk_got}" STREQUAL "${_hollow_mdk_sha256}")
    set(_hollow_mdk_have ON)
  endif()
endif()
if(NOT _hollow_mdk_have)
  # A wrong digest ends the configure inside file(DOWNLOAD); only a verified file
  # ever takes the name fvp reads.
  file(REMOVE "${_hollow_mdk_path}" "${_hollow_mdk_path}.part")
  file(DOWNLOAD "${_hollow_mdk_release}/${_hollow_mdk_asset}" "${_hollow_mdk_path}.part"
    EXPECTED_HASH SHA256=${_hollow_mdk_sha256}
    STATUS _hollow_mdk_status
  )
  list(GET _hollow_mdk_status 0 _hollow_mdk_code)
  if(NOT _hollow_mdk_code EQUAL 0)
    file(REMOVE "${_hollow_mdk_path}.part")
    message(FATAL_ERROR "mdk ${HOLLOW_MDK_VERSION} (${_hollow_mdk_asset}) did not download: ${_hollow_mdk_status}")
  endif()
  file(RENAME "${_hollow_mdk_path}.part" "${_hollow_mdk_path}")
endif()

if("${_hollow_mdk_dir}" MATCHES "^/")
  set(FVP_DEPS_URL "file://${_hollow_mdk_dir}")
else()
  set(FVP_DEPS_URL "file:///${_hollow_mdk_dir}")
endif()
set(FVP_DEPS_SHA256 "${_hollow_mdk_sha256}")
message(STATUS "mdk pinned: ${HOLLOW_MDK_VERSION} ${_hollow_mdk_asset} sha256 ${_hollow_mdk_sha256}")
