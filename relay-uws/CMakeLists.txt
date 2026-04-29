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
    uSockets/src/crypto/openssl.c
    uSockets/src/crypto/sni_tree.cpp
)
target_compile_definitions(uSockets PRIVATE LIBUS_USE_OPENSSL)
target_include_directories(uSockets PUBLIC uSockets/src)

add_executable(hollow-relay
    src/main.cpp
    src/crypto.cpp
    src/license.cpp
    src/http_handlers.cpp
    src/ws_handler.cpp
)
target_include_directories(hollow-relay PRIVATE
    uWebSockets/src
    uSockets/src
    src
)
target_link_libraries(hollow-relay PRIVATE
    uSockets
    ssl
    crypto
    sodium
    z
    pthread
)
target_compile_definitions(hollow-relay PRIVATE LIBUS_USE_OPENSSL)
