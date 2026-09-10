#pragma once
#include <string>
#include <vector>

// The TURN URIs this relay advertises. They are built from the relay's own
// public address (--domain) because a self-hosted relay handing out the
// official host's URIs sends its clients to a coturn that rejects them.

// The address with any trailing ":port" removed. The port belongs to the WSS
// listener, not to TURN, which has its own fixed ports. A bracketed IPv6
// literal keeps its brackets, and a bare one is left alone: its colons are
// address, not a port.
inline std::string turn_host(const std::string& relay_host) {
    if (!relay_host.empty() && relay_host.front() == '[') {
        size_t close = relay_host.find(']');
        if (close != std::string::npos) return relay_host.substr(0, close + 1);
        return relay_host;
    }
    size_t colon = relay_host.find(':');
    if (colon == std::string::npos) return relay_host;
    if (relay_host.find(':', colon + 1) != std::string::npos) return relay_host;
    std::string port = relay_host.substr(colon + 1);
    if (port.empty()) return relay_host;
    for (char c : port) {
        if (c < '0' || c > '9') return relay_host;
    }
    return relay_host.substr(0, colon);
}

inline std::vector<std::string> turn_uris(const std::string& relay_host) {
    std::string host = turn_host(relay_host);
    return {
        "turn:" + host + ":3478",
        "turn:" + host + ":3478?transport=tcp",
        "turns:" + host + ":5349",
    };
}
