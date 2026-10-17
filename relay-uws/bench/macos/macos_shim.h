// Bench-only: lets the Linux relay compile on macOS for local load runs. Force-included
// by bench/macos/build.sh, never by a production build. Restart persistence (the memfd
// snapshot to systemd's fd store) has no macOS counterpart, so it fails cleanly here.
#pragma once
#ifdef __APPLE__
#include <cerrno>
#include <sys/socket.h>
#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 1U
#endif
#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 0
#endif
static inline int memfd_create(const char*, unsigned int) {
    errno = ENOSYS;
    return -1;
}
#endif
