cmake_minimum_required(VERSION 3.16)
project(hollow-relay LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_C_STANDARD 11)

add_library(uSockets STATIC
    uSockets/src/bsd.c
    uSockets/src/context.c
    uSockets/src/loop.c
    uSockets/src/socket.c
    uSockets/src/eventing/epoll_kqueue.c
    uSockets/src/eventing/gcd.c
    uSockets/src/eventing/libuv.c
    # uSockets' crypto/openssl.c with the shared-read repair (the file says why)
    src/usockets_ssl.c
    uSockets/src/crypto/sni_tree.cpp
)
target_compile_definitions(uSockets PRIVATE LIBUS_USE_OPENSSL)
target_include_directories(uSockets PUBLIC uSockets/src)

add_executable(hollow-relay
    src/main.cpp
    src/crypto.cpp
    src/license.cpp
    src/reports.cpp
    src/http_handlers.cpp
    src/snapshot.cpp
    src/ws_handler.cpp
)
target_include_directories(hollow-relay PRIVATE
    uWebSockets/src
    uSockets/src
    src
)
# The signed release links libsodium's archive, so one relay built on Ubuntu
# 22.04 also runs where only a newer libsodium soname exists (26.10 has only
# libsodium.so.26, #153). A build here keeps the system's shared libsodium.
option(HOLLOW_STATIC_SODIUM "Link libsodium statically (the signed release build)" OFF)
if(HOLLOW_STATIC_SODIUM)
    find_library(HOLLOW_SODIUM_ARCHIVE NAMES libsodium.a)
    if(NOT HOLLOW_SODIUM_ARCHIVE)
        message(FATAL_ERROR "HOLLOW_STATIC_SODIUM is on, but no libsodium.a was found (install libsodium-dev)")
    endif()
    message(STATUS "libsodium: ${HOLLOW_SODIUM_ARCHIVE} (static)")
    set(HOLLOW_SODIUM ${HOLLOW_SODIUM_ARCHIVE})
else()
    set(HOLLOW_SODIUM sodium)
endif()

target_link_libraries(hollow-relay PRIVATE
    uSockets
    ssl
    crypto
    ${HOLLOW_SODIUM}
    z
    pthread
)
target_compile_definitions(hollow-relay PRIVATE LIBUS_USE_OPENSSL)
