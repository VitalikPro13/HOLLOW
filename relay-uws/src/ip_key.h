#pragma once
// The address blocks per-address state is keyed by: connection caps by ip_limit_key,
// fair shares by share_block. Never logged.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <cstring>
#include <string>

// An address with the low bits of a v6 one cleared from byte `keep_bytes` on, and
// `suffix` appended. IPv4 clients on the dual-stack [::] listener arrive
// V4-MAPPED (uWS prints them as uncompressed v6 hex) and MUST be unmapped to
// their dotted quad first, or every v4 client collapses into one "::" bucket.
// Unparseable input falls back to the raw text (per-address).
inline std::string address_block(const std::string& ip, size_t keep_bytes, const char* suffix) {
    if (ip.find(':') == std::string::npos) return ip;
    struct in6_addr addr;
    if (inet_pton(AF_INET6, ip.c_str(), &addr) != 1) return ip;
    if (IN6_IS_ADDR_V4MAPPED(&addr)) {
        struct in_addr v4;
        std::memcpy(&v4, addr.s6_addr + 12, 4);
        char buf4[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &v4, buf4, sizeof(buf4))) return ip;
        return std::string(buf4);
    }
    std::memset(addr.s6_addr + keep_bytes, 0, 16 - keep_bytes);
    char buf[INET6_ADDRSTRLEN];
    if (!inet_ntop(AF_INET6, &addr, buf, sizeof(buf))) return ip;
    return std::string(buf) + suffix;
}

// Key for per-IP limiting. IPv6 aggregates by /64: a single host typically owns
// an entire /64, so per-address counting would be trivially bypassed.
inline std::string ip_limit_key(const std::string& ip) {
    return address_block(ip, 8, "/64");
}

// The block fair shares are kept by (fair_share.h): a v4 address, or the /48 of
// a v6 one, the block a single site is given. By /64, whoever holds one /48
// would hold 65,536 shares.
inline std::string share_block(const std::string& ip) {
    return address_block(ip, 6, "/48");
}
