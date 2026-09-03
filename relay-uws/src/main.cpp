#include <App.h>
#include <sodium.h>
#include <openssl/ssl.h>
#include <csignal>
#include <atomic>
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
    state.reports.load_from_file(config.reports_file);

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    auto app = uWS::SSLApp({
        .key_file_name = config.key_file.c_str(),
        .cert_file_name = config.cert_file.c_str(),
        .ssl_prefer_low_memory_usage = 1,
    });

    // Enable TLS session resumption (session tickets)
    // Reconnecting clients reuse cached session keys — ~10x faster handshake
    auto* ssl_ctx = static_cast<SSL_CTX*>(app.getNativeHandle());
    if (ssl_ctx) {
        SSL_CTX_set_session_cache_mode(ssl_ctx, SSL_SESS_CACHE_SERVER);
        SSL_CTX_sess_set_cache_size(ssl_ctx, 20000);
        fprintf(stderr, "[main] TLS session resumption enabled (cache: 20k)\n");
    }

    setup_ws_handler(app, state, config);
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

            // The 120s signaling-room cleanup timer is GONE with the HTTP
            // /register + /bootstrap table it swept (see http_handlers.cpp).

            // Guest idle timeout timer (60s) — disconnect guests with no binary activity for 30 min
            auto* guest_timer = us_create_timer(loop, 0, sizeof(RelayState*));
            *reinterpret_cast<RelayState**>(us_timer_ext(guest_timer)) = &state;
            us_timer_set(guest_timer, [](struct us_timer_t* t) {
                auto* s = *reinterpret_cast<RelayState**>(us_timer_ext(t));
                auto now = std::chrono::steady_clock::now();
                std::vector<SSLWebSocket*> to_close;
                for (auto* ws : s->guest_sockets) {
                    auto* d = ws->getUserData();
                    auto idle = std::chrono::duration_cast<std::chrono::seconds>(
                        now - d->last_binary_activity).count();
                    if (idle >= GUEST_IDLE_SECS) {
                        to_close.push_back(ws);
                    }
                }
                for (auto* ws : to_close) {
                    ws->end(1008, "guest_idle");
                }
            }, 60000, 60000);

            // Offline message buffer TTL sweep (300s)
            auto* buffer_timer = us_create_timer(loop, 0, sizeof(RelayState*));
            *reinterpret_cast<RelayState**>(us_timer_ext(buffer_timer)) = &state;
            us_timer_set(buffer_timer, [](struct us_timer_t* t) {
                auto* s = *reinterpret_cast<RelayState**>(us_timer_ext(t));
                sweep_offline_buffer(*s);
                sweep_link_codes(*s);
                sweep_link_guesses(*s);
                s->reports.save_if_dirty();
            }, 300000, 300000);

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

    state.reports.save_if_dirty();
    fprintf(stderr, "[main] Hollow relay shut down\n");
    return 0;
}
