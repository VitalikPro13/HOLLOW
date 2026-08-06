#pragma once
#include <cstdint>
#include <cstdlib>
#include <string>

struct Config {
    uint16_t port = 443;
    std::string public_ip;
    std::string domain = "relay.anonlisten.com";
    std::string keys_file = "keys.json";
    std::string reports_file = "reports.json";
    std::string cert_file = "/etc/letsencrypt/live/relay.anonlisten.com/fullchain.pem";
    std::string key_file = "/etc/letsencrypt/live/relay.anonlisten.com/privkey.pem";
    std::string turn_secret;
    // Media forwarder discovery (get_media_forwarder): the peer_id of the
    // infra forwarder this relay advertises. Startup-load only — rotation =
    // update the flag + restart (no hot-reload machinery by design). Empty =
    // not configured. Zero-knowledge: one static id, no per-stream metadata.
    std::string forwarder_peer_id;
};

inline void print_help() {
    fprintf(stderr,
        "hollow-relay — uWebSockets C++ relay for Hollow\n\n"
        "  --port <port>         Listen port (default: 443)\n"
        "  --public-ip <ip>      Public IP address\n"
        "  --domain <domain>     Domain name (default: relay.anonlisten.com)\n"
        "  --keys-file <path>    License keys JSON file (default: keys.json)\n"
        "  --reports-file <path> User reports JSON file (default: reports.json)\n"
        "  --cert-file <path>    TLS certificate file\n"
        "  --key-file <path>     TLS private key file\n"
        "  --forwarder-peer-id <id>  Media forwarder peer_id to advertise (get_media_forwarder)\n"
        "  --help                Show this help\n"
    );
}

inline Config parse_args(int argc, char** argv) {
    Config config;

    const char* turn_env = getenv("TURN_SECRET");
    if (turn_env) config.turn_secret = turn_env;

    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--port" && i + 1 < argc) config.port = static_cast<uint16_t>(std::stoi(argv[++i]));
        else if (arg == "--public-ip" && i + 1 < argc) config.public_ip = argv[++i];
        else if (arg == "--domain" && i + 1 < argc) config.domain = argv[++i];
        else if (arg == "--keys-file" && i + 1 < argc) config.keys_file = argv[++i];
        else if (arg == "--reports-file" && i + 1 < argc) config.reports_file = argv[++i];
        else if (arg == "--cert-file" && i + 1 < argc) config.cert_file = argv[++i];
        else if (arg == "--key-file" && i + 1 < argc) config.key_file = argv[++i];
        else if (arg == "--forwarder-peer-id" && i + 1 < argc) config.forwarder_peer_id = argv[++i];
        else if (arg == "--help") { print_help(); exit(0); }
    }
    return config;
}
