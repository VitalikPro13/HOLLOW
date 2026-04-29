#include <App.h>
#include <sodium.h>
#include <csignal>
#include <atomic>
#include <algorithm>
#include <cstdio>

#include "config.h"
#include "state.h"
#include "crypto.h"
#include "http_handlers.h"
#include "ws_handler.h"

static std::atomic<bool> should_shutdown{false};
static struct us_listen_socket_t* global_listen_socket = nullptr;

static void signal_handler(int /*sig*/) {
    should_shutdown.store(true);
}

static void cleanup_stale_signaling(RelayState& state) {
    uint64_t now = now_unix_secs();
    for (auto it = state.signaling_rooms.begin(); it != state.signaling_rooms.end(); ) {
        auto& peers = it->second;
        peers.erase(
            std::remove_if(peers.begin(), peers.end(),
                [now](const PeerEntry& p) {
                    return now - p.last_seen >= 180;
                }),
            peers.end()
        );
        if (peers.empty()) {
            it = state.signaling_rooms.erase(it);
        } else {
            ++it;
        }
    }
}

int main(int argc, char** argv) {
    if (sodium_init() < 0) {
        fprintf(stderr, "Failed to initialize libsodium\n");
        return 1;
    }

    Config config = parse_args(argc, argv);

    fprintf(stderr, "========================================\n");
    fprintf(stderr, "Hollow Relay (uWebSockets C++)\n");
    fprintf(stderr, "Port: %d\n", config.port);
    fprintf(stderr, "========================================\n");

    RelayState state;

    if (!state.license.load_from_file(config.keys_file)) {
        fprintf(stderr, "[main] No keys file, license system disabled\n");
    }

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    auto app = uWS::SSLApp({
        .key_file_name = config.key_file.c_str(),
        .cert_file_name = config.cert_file.c_str(),
        .ssl_prefer_low_memory_usage = 1,
    });

    setup_ws_handler(app, state);
    setup_http_handlers(app, state, config);

    app.listen(config.port, [&](auto* listen_socket) {
        if (listen_socket) {
            global_listen_socket = listen_socket;
            fprintf(stderr, "[main] Listening on port %d (TLS)\n", config.port);

            auto* loop = reinterpret_cast<struct us_loop_t*>(uWS::Loop::get());

            // License reload timer (30s)
            auto* license_timer = us_create_timer(loop, 0, sizeof(RelayState*));
            *reinterpret_cast<RelayState**>(us_timer_ext(license_timer)) = &state;
            us_timer_set(license_timer, [](struct us_timer_t* t) {
                auto* s = *reinterpret_cast<RelayState**>(us_timer_ext(t));
                s->license.try_reload(*s);
            }, 30000, 30000);

            // Signaling cleanup timer (120s)
            auto* cleanup_timer = us_create_timer(loop, 0, sizeof(RelayState*));
            *reinterpret_cast<RelayState**>(us_timer_ext(cleanup_timer)) = &state;
            us_timer_set(cleanup_timer, [](struct us_timer_t* t) {
                auto* s = *reinterpret_cast<RelayState**>(us_timer_ext(t));
                cleanup_stale_signaling(*s);
            }, 120000, 120000);

            // Shutdown check timer (1s)
            auto* shutdown_timer = us_create_timer(loop, 0, sizeof(void*));
            *reinterpret_cast<struct us_listen_socket_t**>(us_timer_ext(shutdown_timer)) = listen_socket;
            us_timer_set(shutdown_timer, [](struct us_timer_t* t) {
                if (should_shutdown.load()) {
                    auto* ls = *reinterpret_cast<struct us_listen_socket_t**>(us_timer_ext(t));
                    us_listen_socket_close(1, ls);
                    us_timer_close(t);
                    fprintf(stderr, "[main] Shutting down...\n");
                }
            }, 1000, 1000);
        } else {
            fprintf(stderr, "[main] FATAL: Failed to listen on port %d\n", config.port);
            exit(1);
        }
    });

    app.run();

    fprintf(stderr, "[main] Hollow relay shut down\n");
    return 0;
}
