#pragma once
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>

#include <unistd.h>

#include "breaker.h"
#include "conn_limits.h"
#include "conn_rate_exempt.h"
#include "deny_list.h"
#include "license_pool.h"
#include "push_port.h"
#include "server_stats.h"
#include "session.h"

struct Config {
    uint16_t port = 443;
    // unused, kept so old unit files keep starting
    std::string public_ip;
    std::string domain = "relay.anonlisten.com";
    std::string keys_file = "keys.json";
    // The operator denylist (deny_list.h): read at start, re-read on every change.
    std::string denylist_file = "denylist.json";
    std::string reports_file = "reports.json";
    std::string cert_file = "/etc/letsencrypt/live/relay.anonlisten.com/fullchain.pem";
    std::string key_file = "/etc/letsencrypt/live/relay.anonlisten.com/privkey.pem";
    std::string turn_secret;
    // Media forwarder discovery (get_media_forwarder): the peer_id of the
    // infra forwarder this relay advertises. Startup-load only — rotation =
    // update the flag + restart (no hot-reload machinery by design). Empty =
    // not configured. Zero-knowledge: one static id, no per-stream metadata.
    std::string forwarder_peer_id;
    // HOLLOW_PUSH_PORT: the push sidecar's loopback port (push_port.h).
    uint16_t push_port = push_port::DEFAULT;
    // How long a session outlives its socket (--session-grace-secs, 30 to 600).
    int64_t session_grace_secs = session::DEFAULT_GRACE_SECS;
    // HOLLOW_CONN_RATE_EXEMPT, read from the environment only: it names the operator's
    // own addresses, so it belongs in the root-only environment file, never a flag.
    conn_rate_exempt::List conn_rate_exempt;
    // Connection limits and the breaker's mode, from the environment (conn_limits.h).
    conn_limits::Limits limits;
    // PUBLIC_STATS=off: /server-stats leaves out the online count and the activity
    // counters (server_stats.h). On by default.
    bool public_stats = true;
    // PUBLIC_DENY_COUNTS=on: /server-stats also names how many servers, identities and
    // networks the denylist holds (never which). Off by default, and only with PUBLIC_STATS.
    bool public_deny_counts = false;
#ifdef HOLLOW_RELAY_TEST_LOOPBACK
    // HOLLOW_RELAY_TEST_BACKPRESSURE: a send buffer the live tests drain inside one
    // session tick (run_live.sh). Never compiled into a relay that serves anyone.
    unsigned int test_max_backpressure = 0;
    // HOLLOW_RELAY_TEST_BREAKER_W / _T: the breaker's budgets and its times divided by
    // these, so the live tests trip it and watch pauses end in seconds.
    int64_t test_breaker_w = 1;
    int64_t test_breaker_t = 1;
    // HOLLOW_RELAY_TEST_SEND_BUDGET: a tiny send-buffer budget so the live tests trip the
    // fan-out breaker without allocating gigabytes. Never in a relay that serves anyone.
    uint64_t test_send_budget = 0;
    // HOLLOW_RELAY_TEST_STALL_MS: a short not-draining window so the live tests watch a
    // non-reading receiver get closed in seconds. Never in a relay that serves anyone.
    int64_t test_stall_ms = 0;
#endif
};

// --session-grace-secs: a number outside 30..600 is held to the nearer end, and
// anything that is not a number stops the relay before it listens.
inline int64_t parse_grace_secs(const char* text) {
    char* end = nullptr;
    errno = 0;
    const long long v = strtoll(text, &end, 10);
    if (end == text || *end != '\0' || errno == ERANGE) {
        fprintf(stderr, "[config] --session-grace-secs takes whole seconds, 30 to 600\n");
        exit(2);
    }
    if (v < session::MIN_GRACE_SECS || v > session::MAX_GRACE_SECS) {
        const int64_t held = v < session::MIN_GRACE_SECS ? session::MIN_GRACE_SECS : session::MAX_GRACE_SECS;
        fprintf(stderr, "[config] --session-grace-secs %lld is outside 30 to 600, using %lld\n", v,
                static_cast<long long>(held));
        return held;
    }
    return v;
}

inline void print_help() {
    fprintf(stderr,
        "hollow-relay, the uWebSockets C++ relay for Hollow\n\n"
        "  --port <port>         Listen port (default: 443)\n"
        "  --domain <host>       Public host clients connect to; used for the TURN URIs (default: relay.anonlisten.com)\n"
        "  --keys-file <path>    License keys JSON file (default: keys.json)\n"
        "  --denylist-file <path>  Servers, identities and addresses this relay refuses (default: denylist.json)\n"
        "  --check-denylist <path> Read a denylist file the way the relay would, print its counts or its first error, and exit\n"
        "  --check-keys <path>   Read an access-key file the way the relay would, print whether it reads and how many keys it lists, and exit (non-zero only for a file that is there but does not read)\n"
        "  --check-limits        Print the connection limits and breaker mode the environment sets, and exit (non-zero if any value was not taken as written)\n"
        "  --reports-file <path> User reports JSON file (default: reports.json)\n"
        "  --cert-file <path>    TLS certificate file\n"
        "  --key-file <path>     TLS private key file\n"
        "  --forwarder-peer-id <id>  Media forwarder peer_id to advertise (get_media_forwarder)\n"
        "  --session-grace-secs <n>  How long a dropped device's session waits for it, 30 to 600 (default: 120)\n"
        "  --help                Show this help\n"
    );
}

// --check-denylist: the operator's check before a write (deploy/lib/manage.sh, check-host.sh).
// Prints counts or where the file is wrong, never an entry; exit 0 only for a good file.
inline int check_denylist(const char* path) {
    deny::Loaded l = deny::load(path);
    if (l.read == deny::Read::Missing) {
        printf("missing: %s\n", path);
        return 1;
    }
    if (l.read == deny::Read::Bad) {
        printf("unreadable: %s\n", l.error.c_str());
        return 1;
    }
    printf("ok: %zu servers, %zu identities, %zu networks\n", l.list.servers.size(), l.list.identities.size(),
           l.list.networks.size());
    if (const size_t n = deny::legacy_shaped(l.list)) {
        printf("warning: %zu server %s 32 hexadecimal characters. Older servers have ids like that, and so do the "
               "rooms of direct messages and of a person's own devices, so such an entry blocks whatever room has "
               "that id. Keep it only if you are sure it names a server.\n",
               n, n == 1 ? "entry has" : "entries have");
    }
    return 0;
}

// --check-keys: check-host.sh's look at keys.json. A file that is there but does not read
// shuts the relay to everyone (HOL-SEC-220), so only that exits non-zero; a missing file
// is an open relay. Prints counts, never a key.
inline int check_keys(const char* path) {
    std::ifstream f(path);
    if (!f.is_open()) {
        if (access(path, F_OK) != 0) {
            printf("missing: the relay is open to everyone\n");
            return 0;
        }
        printf("unreadable: %s cannot be opened\n", path);
        return 1;
    }
    std::stringstream text;
    text << f.rdbuf();
    const std::optional<KeysFile> file = parse_keys_file(text.str());
    if (!file) {
        printf("unreadable: %s is not a keys file (an object with \"enabled\" true or false and a \"keys\" list)\n",
               path);
        return 1;
    }
    printf("ok: %s, %zu key(s)\n", file->enabled ? "members only" : "open to everyone", file->keys.size());
    return 0;
}

// The box's memory, which sizes the connected-socket budget.
inline uint64_t ram_bytes() {
    const long pages = sysconf(_SC_PHYS_PAGES);
    const long size = sysconf(_SC_PAGESIZE);
    return pages > 0 && size > 0 ? static_cast<uint64_t>(pages) * static_cast<uint64_t>(size) : (2ull << 30);
}

// The limits the environment sets, each value not taken as written said once.
inline conn_limits::Parsed limits_from_env() {
#ifdef HOLLOW_RELAY_TEST_LOOPBACK
    const bool test_build = true;
#else
    const bool test_build = false;
#endif
    return conn_limits::parse([](const char* k) { return getenv(k); }, ram_bytes(), test_build);
}

// --check-limits: what check-host.sh and manage.sh show the operator. Exit 0 only when
// every value was taken as written.
inline int check_limits() {
    const conn_limits::Parsed p = limits_from_env();
    for (const auto& note : p.notes) printf("warning: %s\n", note.c_str());
    printf("ok: %s\n", conn_limits::describe(p.limits).c_str());
    const char* exempt = getenv("HOLLOW_CONN_RATE_EXEMPT");
    printf("rate exemption: %zu address block(s)\n",
           exempt && *exempt ? conn_rate_exempt::parse(exempt).keys.size() : size_t{0});
    return p.notes.empty() ? 0 : 1;
}

inline Config parse_args(int argc, char** argv) {
    Config config;
    for (int i = 1; i < argc; i++) {
        if (std::string(argv[i]) == "--check-limits") exit(check_limits());
    }
    for (int i = 1; i < argc; i++) {
        if (std::string(argv[i]) != "--check-keys") continue;
        if (i + 1 >= argc) {
            fprintf(stderr, "[config] --check-keys takes the file to check\n");
            exit(2);
        }
        exit(check_keys(argv[i + 1]));
    }
    for (int i = 1; i < argc; i++) {
        if (std::string(argv[i]) != "--check-denylist") continue;
        if (i + 1 >= argc) {
            fprintf(stderr, "[config] --check-denylist takes the file to check\n");
            exit(2);
        }
        exit(check_denylist(argv[i + 1]));
    }

    if (const auto p = push_port::parse(getenv("HOLLOW_PUSH_PORT"))) {
        config.push_port = *p;
    } else {
        fprintf(stderr, "[config] HOLLOW_PUSH_PORT must be a port number from 1 to 65535\n");
        exit(2);
    }
    if (config.push_port != push_port::DEFAULT) fprintf(stderr, "[config] Push sidecar port: %u\n", config.push_port);
    const char* turn_env = getenv("TURN_SECRET");
    if (turn_env) config.turn_secret = turn_env;
    config.public_stats = server_stats::parse_public_stats(getenv("PUBLIC_STATS"));
    config.public_deny_counts = server_stats::parse_opt_in(getenv("PUBLIC_DENY_COUNTS"));
    if (!config.public_stats) fprintf(stderr, "[config] Public stats off: /server-stats shows memory only\n");
    {
        const conn_limits::Parsed p = limits_from_env();
        for (const auto& note : p.notes) fprintf(stderr, "[config] %s\n", note.c_str());
        config.limits = p.limits;
        fprintf(stderr, "[config] Limits: %s\n", conn_limits::describe(config.limits).c_str());
    }
    const char* exempt = getenv("HOLLOW_CONN_RATE_EXEMPT");
    if (exempt && *exempt) {
#ifdef HOLLOW_RELAY_TEST_LOOPBACK
        config.conn_rate_exempt = conn_rate_exempt::parse(exempt, true);
#else
        config.conn_rate_exempt = conn_rate_exempt::parse(exempt);
#endif
        fprintf(stderr, "[config] New-connection rate exemption: %zu address block(s), %zu entry(s) ignored\n",
                config.conn_rate_exempt.keys.size(), config.conn_rate_exempt.ignored);
    }

#ifdef HOLLOW_RELAY_TEST_LOOPBACK
    if (const char* bp = getenv("HOLLOW_RELAY_TEST_BACKPRESSURE")) {
        config.test_max_backpressure = static_cast<unsigned int>(strtoul(bp, nullptr, 10));
    }
    if (const char* w = getenv("HOLLOW_RELAY_TEST_BREAKER_W")) config.test_breaker_w = strtoll(w, nullptr, 10);
    if (const char* t = getenv("HOLLOW_RELAY_TEST_BREAKER_T")) config.test_breaker_t = strtoll(t, nullptr, 10);
    if (const char* sb = getenv("HOLLOW_RELAY_TEST_SEND_BUDGET")) {
        config.test_send_budget = strtoull(sb, nullptr, 10);
    }
    if (const char* sm = getenv("HOLLOW_RELAY_TEST_STALL_MS")) {
        config.test_stall_ms = strtoll(sm, nullptr, 10);
    }
#endif

    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--port" && i + 1 < argc) config.port = static_cast<uint16_t>(std::stoi(argv[++i]));
        else if (arg == "--public-ip" && i + 1 < argc) config.public_ip = argv[++i];
        else if (arg == "--domain" && i + 1 < argc) config.domain = argv[++i];
        else if (arg == "--keys-file" && i + 1 < argc) config.keys_file = argv[++i];
        else if (arg == "--denylist-file" && i + 1 < argc) config.denylist_file = argv[++i];
        else if (arg == "--reports-file" && i + 1 < argc) config.reports_file = argv[++i];
        else if (arg == "--cert-file" && i + 1 < argc) config.cert_file = argv[++i];
        else if (arg == "--key-file" && i + 1 < argc) config.key_file = argv[++i];
        else if (arg == "--forwarder-peer-id" && i + 1 < argc) config.forwarder_peer_id = argv[++i];
        else if (arg == "--session-grace-secs" && i + 1 < argc) config.session_grace_secs = parse_grace_secs(argv[++i]);
        else if (arg == "--help") { print_help(); exit(0); }
    }
    return config;
}
