#include "http_handlers.h"
#include "ws_handler.h"
#include "measure.h"
#include "json.hpp"
#include "server_stats.h"
#include "version.h"
#include <cmath>
#include <cstdio>
#include <fstream>
#include <sstream>

using json = nlohmann::json;
using HttpResponse = uWS::HttpResponse<true>;
using HttpRequest = uWS::HttpRequest;

static void cors_headers(HttpResponse* res) {
    res->writeHeader("Access-Control-Allow-Origin", "*");
    res->writeHeader("Content-Type", "application/json");
}

// NOTE: the HTTP signaling endpoints POST /register, POST /unregister and
// GET /bootstrap/:room_code were REMOVED, along with the peer table they fed
// (`signaling_rooms` / `PeerEntry` in state.h and its sweeper in main.cpp).
//
// They were dead weight with a live cost. The client retired this path in July
// 2026 — peer discovery rides the authenticated WebSocket now (`discover_peers`
// plus the members snapshot on join; see the comment at swarm.rs's node start)
// — but the routes stayed open to the internet, where /bootstrap handed any
// anonymous caller the peer_ids AND network addresses of everyone who had
// registered in a room whose code they could guess or observe, and /register
// buffered an unbounded request body before it looked at a single field.
// Nothing authenticated the reader, and there is no caller identity at the HTTP
// layer to bind one to — the same reasoning that removed /turn-credentials
// below. Do not reintroduce an HTTP variant of any of them.

static void handle_health(HttpResponse* res) {
    cors_headers(res);
    res->end(R"({"status":"ok","service":"hollow-signaling"})");
}

// NOTE: the open HTTP GET /turn-credentials endpoint was REMOVED. It handed
// out valid time-limited TURN credentials to any unauthenticated caller, which
// made the TURN service farmable for free relay bandwidth by anyone at all.
// TURN credentials are issued ONLY over the authenticated,
// non-guest WebSocket (`get_turn_credentials` in ws_handler.cpp), which has
// been the client path since 0.7.1. Do not reintroduce an HTTP variant: there
// is no caller identity at the HTTP layer to bind the credential to.

static void handle_server_stats(HttpResponse* res, RelayState& state, const Config& config) {
    cors_headers(res);

    if (state.stats_cache.has_prev && state.stats_cache.is_fresh()) {
        res->end(state.stats_cache.cached_json);
        return;
    }

    uint64_t mem_total_kb = 0, mem_available_kb = 0;
    {
        std::ifstream f("/proc/meminfo");
        if (f.is_open()) {
            std::string line;
            while (std::getline(f, line)) {
                if (line.compare(0, 9, "MemTotal:") == 0) {
                    std::istringstream iss(line);
                    std::string label; uint64_t val;
                    iss >> label >> val;
                    mem_total_kb = val;
                } else if (line.compare(0, 13, "MemAvailable:") == 0) {
                    std::istringstream iss(line);
                    std::string label; uint64_t val;
                    iss >> label >> val;
                    mem_available_kb = val;
                }
            }
        }
    }

    uint64_t rx_bytes = 0, tx_bytes = 0;
    {
        std::ifstream f("/proc/net/dev");
        if (f.is_open()) {
            std::string line;
            while (std::getline(f, line)) {
                // Trim leading whitespace
                size_t start = line.find_first_not_of(" \t");
                if (start == std::string::npos) continue;
                std::string trimmed = line.substr(start);
                if (trimmed.compare(0, 6, "ens16:") == 0) {
                    std::istringstream iss(trimmed.substr(6));
                    uint64_t vals[10];
                    for (int i = 0; i < 10; i++) iss >> vals[i];
                    rx_bytes = vals[0];
                    tx_bytes = vals[8];
                }
            }
        }
    }

    auto now = std::chrono::steady_clock::now();
    double rx_mbps = 0.0, tx_mbps = 0.0;
    if (state.stats_cache.has_prev) {
        double elapsed = std::chrono::duration<double>(
            now - state.stats_cache.prev_sample_at).count();
        if (elapsed > 0.5) {
            double rx_delta = static_cast<double>(
                rx_bytes > state.stats_cache.prev_rx_bytes
                    ? rx_bytes - state.stats_cache.prev_rx_bytes : 0);
            double tx_delta = static_cast<double>(
                tx_bytes > state.stats_cache.prev_tx_bytes
                    ? tx_bytes - state.stats_cache.prev_tx_bytes : 0);
            rx_mbps = (rx_delta * 8.0) / (elapsed * 1000000.0);
            tx_mbps = (tx_delta * 8.0) / (elapsed * 1000000.0);
        } else {
            rx_mbps = state.stats_cache.rx_mbps;
            tx_mbps = state.stats_cache.tx_mbps;
        }
    }

    uint64_t mem_used_kb = (mem_total_kb > mem_available_kb)
        ? mem_total_kb - mem_available_kb : 0;

    auto round2 = [](double v) { return std::round(v * 100.0) / 100.0; };

    json resp = {
        {"mem_total_kb", mem_total_kb},
        {"mem_used_kb", mem_used_kb},
        {"rx_mbps", round2(rx_mbps)},
        {"tx_mbps", round2(tx_mbps)},
        {"bandwidth_cap_mbps", 950},  // = the CAKE shaper ceiling on this box (measured raw 1047), not the nominal port
        {"online_users", state.online_users()},
        // Delivery diagnostics (non-identifying counters; see DeliveryDiag).
        {"send_backpressure", state.diag.send_backpressure},
        {"send_dropped", state.diag.send_dropped},
        {"fwd_delivered", state.diag.fwd_delivered},
        {"fwd_buffered", state.diag.fwd_buffered},
        {"ghost_left_suppressed", state.diag.ghost_left_suppressed},
        // The circuit breaker's trips by kind (ws_handler.cpp); shadow mode counts the
        // trips enforcement would make.
        {"breaker", breaker_stats()},
        // Send-buffer pressure against the memory budget (send_budget.h): a healthy relay
        // sits at 0; sustained near 100 means slow or hostile readers.
        {"send_budget_used_pct", send_budget::used_pct(state.send_ledger.total(), state.send_ledger.limits.limit)},
        {"send_budget_bytes", state.send_ledger.limits.limit},
        {"fanout_tripped", state.diag.fanout_tripped},
        {"fanout_refused", state.diag.fanout_refused},
        {"fanout_evicted", state.diag.fanout_evicted},
        {"budget_refused", state.diag.budget_refused},
        {"budget_closed", state.diag.budget_closed}
    };

    server_stats::keep_public(resp, config.public_stats);
    state.stats_cache.cached_json = resp.dump();
    state.stats_cache.fetched_at = now;
    state.stats_cache.prev_rx_bytes = rx_bytes;
    state.stats_cache.prev_tx_bytes = tx_bytes;
    state.stats_cache.prev_sample_at = now;
    state.stats_cache.rx_mbps = rx_mbps;
    state.stats_cache.tx_mbps = tx_mbps;
    state.stats_cache.has_prev = true;

    res->end(state.stats_cache.cached_json);
}

static void handle_relay_status(HttpResponse* res, RelayState& state,
                                const Config& config) {
    cors_headers(res);
    json resp = {
        {"license_required", state.license.enabled},
        {"version", HOLLOW_RELAY_VERSION},
        {"turn", !config.turn_secret.empty()},
        {"forwarder", !config.forwarder_peer_id.empty()}
    };
    res->end(resp.dump());
}

void setup_http_handlers(uWS::SSLApp& app, RelayState& state,
                         const Config& config) {
    app.options("/*", [](HttpResponse* res, HttpRequest* /*req*/) {
        res->writeHeader("Access-Control-Allow-Origin", "*");
        res->writeHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
        res->writeHeader("Access-Control-Allow-Headers", "Content-Type");
        res->end();
    });

#ifdef HOLLOW_RELAY_MEASURE
    // The measuring build's anonymous counters (measure.h), for a test relay on loopback.
    app.get("/g2-measure", [](HttpResponse* res, HttpRequest* /*req*/) {
        cors_headers(res);
        res->end(measure_report());
    });
    app.get("/g2-measure-reset", [](HttpResponse* res, HttpRequest* /*req*/) {
        measure::reset();
        cors_headers(res);
        res->end(R"({"ok":true})");
    });
#endif
#ifdef HOLLOW_RELAY_TEST_LOOPBACK
    // One payer's breaker buckets, for the live tests; never in a relay that serves anyone.
    app.get("/breaker-test", [](HttpResponse* res, HttpRequest* req) {
        res->end(breaker_test_report(std::string(req->getQuery("peer"))));
    });
#endif
    app.get("/health", [](HttpResponse* res, HttpRequest* /*req*/) {
        handle_health(res);
    });

    app.get("/server-stats", [&state, &config](HttpResponse* res, HttpRequest* /*req*/) {
        handle_server_stats(res, state, config);
    });

    app.get("/relay-status", [&state, &config](HttpResponse* res, HttpRequest* /*req*/) {
        handle_relay_status(res, state, config);
    });
}
