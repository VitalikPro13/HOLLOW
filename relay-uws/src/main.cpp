#include <App.h>
#include <sodium.h>
#include <openssl/ssl.h>
#include <csignal>
#include <atomic>
#include <cstdio>
#include <string>
#include <sys/stat.h>
#include <vector>

#include "config.h"
#include "state.h"
#include "crypto.h"
#include "http_handlers.h"
#include "snapshot.h"
#include "ws_handler.h"

static std::atomic<bool> should_shutdown{false};

// What the shutdown tick needs to end the process: the snapshot goes out
// first, then every loop handle closes so run() actually returns.
struct ShutdownCtx {
    RelayState* state = nullptr;
    uWS::SSLApp* app = nullptr;
    std::vector<struct us_timer_t*> timers;
};
static ShutdownCtx g_shutdown;

static void signal_handler(int /*sig*/) {
    should_shutdown.store(true);
}

// What the certificate reload tick compares against. A renewal rewrites the
// files under a running relay, and OpenSSL applies a replaced cert/key on an
// SSL_CTX to new connections only, so a renewal costs nothing and restarts
// nothing.
struct CertWatch {
    const Config* config = nullptr;
    uWS::SSLApp* app = nullptr;
    time_t cert_mtime = 0;
    time_t key_mtime = 0;
};
static CertWatch g_cert_watch;

static bool file_mtime(const std::string& path, time_t& out) {
    struct stat st;
    if (::stat(path.c_str(), &st) != 0) return false;
    out = st.st_mtime;
    return true;
}

// The pair is loaded into a scratch context first: a copy that catches the
// relay mid-write would otherwise install a certificate that does not match
// the key it is serving with, and there is no way back from that on a live
// context.
static bool reload_certificate(CertWatch* w) {
    SSL_CTX* scratch = SSL_CTX_new(TLS_server_method());
    if (!scratch) return false;
    bool ok = SSL_CTX_use_certificate_chain_file(scratch, w->config->cert_file.c_str()) == 1
        && SSL_CTX_use_PrivateKey_file(scratch, w->config->key_file.c_str(), SSL_FILETYPE_PEM) == 1
        && SSL_CTX_check_private_key(scratch) == 1;
    SSL_CTX_free(scratch);
    if (!ok) return false;

    auto* live = static_cast<SSL_CTX*>(w->app->getNativeHandle());
    if (!live) return false;
    return SSL_CTX_use_certificate_chain_file(live, w->config->cert_file.c_str()) == 1
        && SSL_CTX_use_PrivateKey_file(live, w->config->key_file.c_str(), SSL_FILETYPE_PEM) == 1
        && SSL_CTX_check_private_key(live) == 1;
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
    restore_from_fdstore(state);

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

    g_shutdown.state = &state;
    g_shutdown.app = &app;

    app.listen(config.port, [&](auto* listen_socket) {
        if (listen_socket) {
            fprintf(stderr, "[main] Listening on port %d (TLS)\n", config.port);

            auto* loop = reinterpret_cast<struct us_loop_t*>(uWS::Loop::get());

            // License reload timer (30s)
            auto* license_timer = us_create_timer(loop, 0, sizeof(RelayState*));
            *reinterpret_cast<RelayState**>(us_timer_ext(license_timer)) = &state;
            us_timer_set(license_timer, [](struct us_timer_t* t) {
                auto* s = *reinterpret_cast<RelayState**>(us_timer_ext(t));
                s->license.try_reload(*s);
            }, 30000, 30000);
            g_shutdown.timers.push_back(license_timer);

            // TLS certificate reload timer (60s)
            g_cert_watch.config = &config;
            g_cert_watch.app = &app;
            file_mtime(config.cert_file, g_cert_watch.cert_mtime);
            file_mtime(config.key_file, g_cert_watch.key_mtime);
            auto* cert_timer = us_create_timer(loop, 0, sizeof(CertWatch*));
            *reinterpret_cast<CertWatch**>(us_timer_ext(cert_timer)) = &g_cert_watch;
            us_timer_set(cert_timer, [](struct us_timer_t* t) {
                auto* w = *reinterpret_cast<CertWatch**>(us_timer_ext(t));
                time_t cert_m = 0, key_m = 0;
                if (!file_mtime(w->config->cert_file, cert_m)) return;
                if (!file_mtime(w->config->key_file, key_m)) return;
                if (cert_m == w->cert_mtime && key_m == w->key_mtime) return;
                if (!reload_certificate(w)) {
                    fprintf(stderr, "[main] TLS certificate reload failed, keeping the previous one\n");
                    return;
                }
                w->cert_mtime = cert_m;
                w->key_mtime = key_m;
                fprintf(stderr, "[main] TLS certificate reloaded\n");
            }, 60000, 60000);
            g_shutdown.timers.push_back(cert_timer);

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
            g_shutdown.timers.push_back(guest_timer);

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
            g_shutdown.timers.push_back(buffer_timer);

            // Shutdown check timer (1s). The snapshot goes out while every
            // buffer is still intact; then the timers and app.close() (listen
            // socket plus every connection) release the loop. Closing only
            // the listen socket, as this once did, left the loop alive on the
            // timers and the open sockets until systemd's stop timeout killed
            // the process.
            auto* shutdown_timer = us_create_timer(loop, 0, sizeof(void*));
            us_timer_set(shutdown_timer, [](struct us_timer_t* t) {
                if (!should_shutdown.load()) return;
                fprintf(stderr, "[main] Shutting down...\n");
                snapshot_to_fdstore(*g_shutdown.state);
                for (auto* pt : g_shutdown.timers) us_timer_close(pt);
                g_shutdown.timers.clear();
                us_timer_close(t);
                g_shutdown.app->close();
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
