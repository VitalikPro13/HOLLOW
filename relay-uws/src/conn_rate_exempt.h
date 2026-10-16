#pragma once
// HOLLOW_CONN_RATE_EXEMPT: addresses an operator lists so its own test machines skip
// the per-minute new-connection cap (MAX_NEW_CONNS_PER_MIN_PER_IP). Every other limit
// still holds for them. Unset or empty, nothing is exempt. Never logged.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>
#include <unordered_set>

#include "ip_key.h"

namespace conn_rate_exempt {

struct List {
    // ip_limit_key blocks, the keys the cap counts sockets under.
    std::unordered_set<std::string> keys;
    // Entries that named no address.
    size_t ignored = 0;

    bool contains(const std::string& ip_key) const { return keys.count(ip_key) > 0; }
};

// A v4 address no other machine connects from: this network (0/8, the unspecified
// address among it), multicast (224/4), reserved (240/4, the broadcast address among
// it), and loopback (127/8) unless `allow_loopback`.
inline bool v4_never_a_client(const struct in_addr& a, bool allow_loopback) {
    const uint32_t top = ntohl(a.s_addr) >> 24;
    if (top == 127) return !allow_loopback;
    return top == 0 || top >= 224;
}

// A v6 /64 holding no address another machine connects from: ::/64 (unspecified,
// loopback, the old v4-compatible form; v4-mapped peers are keyed by their v4) and
// multicast (ff00::/8).
inline bool v6_block_never_a_client(const struct in6_addr& a) {
    if (a.s6_addr[0] == 0xff) return true;
    for (int i = 0; i < 8; i++) {
        if (a.s6_addr[i] != 0) return false;
    }
    return true;
}

// The ip_limit_key an entry names: a v4 address, a v6 address (its /64), a v6 /64
// written "addr/64", or a v4-mapped v6 (its v4). Empty for anything else, which must
// never be kept as raw text (ip_limit_key hands unparseable input back unchanged), and
// for an address no client connects from, which would exempt nobody or, behind a proxy
// on the relay's own box, everybody.
inline std::string entry_key(std::string addr, bool allow_loopback = false) {
    bool block = false;
    if (addr.size() > 3 && addr.compare(addr.size() - 3, 3, "/64") == 0) {
        addr.resize(addr.size() - 3);
        block = true;
    }
    struct in_addr v4;
    if (!block && inet_pton(AF_INET, addr.c_str(), &v4) == 1) {
        if (v4_never_a_client(v4, allow_loopback)) return "";
        char text[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &v4, text, sizeof(text))) return "";
        return ip_limit_key(text);
    }
    struct in6_addr v6;
    if (inet_pton(AF_INET6, addr.c_str(), &v6) != 1) return "";
    if (IN6_IS_ADDR_V4MAPPED(&v6)) {
        if (block) return "";
        std::memcpy(&v4.s_addr, v6.s6_addr + 12, 4);
        if (v4_never_a_client(v4, allow_loopback)) return "";
    } else if (v6_block_never_a_client(v6)) {
        return "";
    }
    return ip_limit_key(addr);
}

// Entries are separated by commas or white space; an absent value is an empty list.
// `allow_loopback` is for a test relay that hears only loopback.
inline List parse(const char* value, bool allow_loopback = false) {
    List list;
    if (!value) return list;
    const std::string_view text(value);
    const std::string_view separators(", \t\r\n");
    size_t at = 0;
    while (at < text.size()) {
        const size_t start = text.find_first_not_of(separators, at);
        if (start == std::string_view::npos) break;
        size_t end = text.find_first_of(separators, start);
        if (end == std::string_view::npos) end = text.size();
        std::string key = entry_key(std::string(text.substr(start, end - start)), allow_loopback);
        if (key.empty()) {
            list.ignored++;
        } else {
            list.keys.insert(std::move(key));
        }
        at = end;
    }
    return list;
}

}  // namespace conn_rate_exempt
