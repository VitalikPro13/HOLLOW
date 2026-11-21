#pragma once
#include <App.h>
#include "state.h"
#include "config.h"
#include "json.hpp"

void setup_ws_handler(uWS::SSLApp& app, RelayState& state, const Config& config);

// Evict offline-buffer entries older than OFFLINE_BUFFER_TTL_SECS. Called
// periodically from main's timer loop.
void sweep_offline_buffer(RelayState& state);

// Evict down to MAX_BUFFER_TOTAL_BYTES, the heaviest address share first. Every
// deposit path runs it; a restored snapshot runs it once in case the budget shrank.
void enforce_buffer_budget(RelayState& state);

// Charge a restored identity's registrations (push token, prefs, opt-in) to `share`.
void restore_registration(RelayState& state, const std::string& peer, uint64_t share);

// Drop parked destroy signals nobody ever came back for. Called from main's
// timer loop.
void sweep_kill_list(RelayState& state);

// End the grace of every door-locked room's provers who did not prove the new door
// in time (door_room.h): the others see them leave. Called from main's timer loop.
void sweep_door_grace(RelayState& state);

// Release multi-device link codes whose 5-minute TTL has elapsed (server-side
// backstop; the live countdown is client-side). Called from main's timer loop.
void sweep_link_codes(RelayState& state);

// Drop per-IP link-code guess records that have gone quiet for
// LINK_GUESS_EXPIRE_SECS. Called from main's timer loop.
void sweep_link_guesses(RelayState& state);

// The operator denylist (deny_list.h). deny_start reads the file once, after the restart
// snapshot is back and before the relay listens; deny_tick re-reads it on every change
// (main.cpp, every 2 s); deny_settle finishes devices learned on a show, after a loop
// iteration. None of them throws.
void deny_start(RelayState& state, const std::string& path);
void deny_tick(RelayState& state, const std::string& path);
void deny_settle(RelayState& state);

// After keys.json reloaded: every session in grace whose last login the file no longer
// admits ends as on expiry (its socket's close already gave its seat back). Called from
// main's license timer.
void end_unlicensed_grace(RelayState& state);

// The breaker's anonymous trip counts (breaker.h): by kind, never ids. In shadow mode,
// the trips enforcement would have made.
nlohmann::json breaker_stats();

#ifdef HOLLOW_RELAY_TEST_LOOPBACK
// One payer's buckets, for the live tests (test builds only).
std::string breaker_test_report(const std::string& peer);
// What the relay still holds of a peer and a room after a denial (test builds only).
std::string deny_test_report(const std::string& peer, const std::string& room, const std::string& net);
// The presence tables a stranger fills, in all and for one subject (test builds only).
std::string presence_test_report(const std::string& peer);
#endif
