#pragma once
// HOLLOW_CONN_RATE_EXEMPT: addresses an operator lists so its own test machines skip
// the per-minute new-connection cap (MAX_NEW_CONNS_PER_MIN_PER_IP). Every other limit
// still holds for them. Unset or empty, nothing is exempt. Never logged.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <cstddef>
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

// The ip_limit_key an entry names: a v4 address, a v6 address (its /64), a v6 /64
// written "addr/64", or a v4-mapped v6 (its v4). Empty for anything else, which must
// never be kept as raw text: ip_limit_key hands unparseable input back unchanged.
inline std::string entry_key(std::string addr) {
    bool block = false;
    if (addr.size() > 3 && addr.compare(addr.size() - 3, 3, "/64") == 0) {
        addr.resize(addr.size() - 3);
        block = true;
    }
    struct in_addr v4;
    if (!block && inet_pton(AF_INET, addr.c_str(), &v4) == 1) {
        char text[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &v4, text, sizeof(text))) return "";
        return ip_limit_key(text);
    }
    struct in6_addr v6;
    if (inet_pton(AF_INET6, addr.c_str(), &v6) != 1) return "";
    if (block && IN6_IS_ADDR_V4MAPPED(&v6)) return "";
    return ip_limit_key(addr);
}

// Entries are separated by commas or white space; an absent value is an empty list.
inline List parse(const char* value) {
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
        std::string key = entry_key(std::string(text.substr(start, end - start)));
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
