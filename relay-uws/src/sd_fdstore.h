#pragma once
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <string>

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// systemd's file descriptor store, hand-rolled: the two sd_notify verbs the
// relay needs plus LISTEN_FDS on the way back. One datagram each, so linking
// libsystemd (whose dev package is not on the box) buys nothing.
//
// Requires `NotifyAccess=main` and `FileDescriptorStoreMax=1` on the unit;
// without them systemd drops the datagram and logs a warning of its own.
namespace fdstore {

namespace detail {

inline bool notify(const std::string& msg, int fd) {
    const char* path = getenv("NOTIFY_SOCKET");
    if (!path || (path[0] != '/' && path[0] != '@')) return false;
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    size_t plen = strnlen(path, sizeof(addr.sun_path));
    if (plen >= sizeof(addr.sun_path)) return false;
    memcpy(addr.sun_path, path, plen);
    if (path[0] == '@') addr.sun_path[0] = 0;  // abstract namespace
    auto alen = static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + plen);

    int sock = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (sock < 0) return false;
    iovec iov{};
    iov.iov_base = const_cast<char*>(msg.data());
    iov.iov_len = msg.size();
    msghdr mh{};
    mh.msg_name = &addr;
    mh.msg_namelen = alen;
    mh.msg_iov = &iov;
    mh.msg_iovlen = 1;
    alignas(cmsghdr) char cbuf[CMSG_SPACE(sizeof(int))] = {};
    if (fd >= 0) {
        mh.msg_control = cbuf;
        mh.msg_controllen = sizeof(cbuf);
        cmsghdr* c = CMSG_FIRSTHDR(&mh);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(c), &fd, sizeof(int));
    }
    ssize_t n = sendmsg(sock, &mh, MSG_NOSIGNAL);
    close(sock);
    return n == static_cast<ssize_t>(msg.size());
}

}  // namespace detail

inline bool available() {
    const char* p = getenv("NOTIFY_SOCKET");
    return p && *p;
}

// systemd keeps its own duplicate; the caller still owns `fd`.
inline bool store(int fd, const std::string& name) {
    return detail::notify("FDSTORE=1\nFDNAME=" + name + "\n", fd);
}

inline bool remove(const std::string& name) {
    return detail::notify("FDSTOREREMOVE=1\nFDNAME=" + name + "\n", -1);
}

// The stored fd named `name` that systemd passed to this process, or -1. Every
// passed fd arrives inheritable, so all of them are marked close-on-exec and
// the ones not taken are closed; the LISTEN_* variables are cleared so a child
// can never mistake them for its own.
inline int take(const std::string& name) {
    const char* pid = getenv("LISTEN_PID");
    const char* nfds = getenv("LISTEN_FDS");
    const char* names = getenv("LISTEN_FDNAMES");
    if (!pid || !nfds) return -1;
    bool ours = strtol(pid, nullptr, 10) == static_cast<long>(getpid());
    long n = strtol(nfds, nullptr, 10);
    if (!ours || n <= 0 || n > 64) return -1;

    std::string list = names ? names : "";
    int found = -1;
    size_t start = 0;
    for (long i = 0; i < n; i++) {
        int fd = 3 + static_cast<int>(i);
        size_t end = list.find(':', start);
        std::string nm = (start <= list.size())
            ? list.substr(start, end == std::string::npos ? std::string::npos : end - start)
            : std::string();
        start = (end == std::string::npos) ? list.size() + 1 : end + 1;
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        bool match = (nm == name) || (!names && n == 1);
        if (found < 0 && match) found = fd; else close(fd);
    }
    unsetenv("LISTEN_PID");
    unsetenv("LISTEN_FDS");
    unsetenv("LISTEN_FDNAMES");
    return found;
}

}  // namespace fdstore
