#pragma once
#include <App.h>
#include "state.h"
#include "config.h"

void setup_ws_handler(uWS::SSLApp& app, RelayState& state, const Config& config);

// Evict offline-buffer entries older than OFFLINE_BUFFER_TTL_SECS. Called
// periodically from main's timer loop.
void sweep_offline_buffer(RelayState& state);

// Oldest-first eviction down to MAX_BUFFER_TOTAL_BYTES. Every deposit path
// runs it; a restored snapshot runs it once in case the budget shrank.
void enforce_buffer_budget(RelayState& state);

// Drop parked destroy signals nobody ever came back for. Called from main's
// timer loop.
void sweep_kill_list(RelayState& state);

// Release multi-device link codes whose 5-minute TTL has elapsed (server-side
// backstop; the live countdown is client-side). Called from main's timer loop.
void sweep_link_codes(RelayState& state);

// Drop per-IP link-code guess records that have gone quiet for
// LINK_GUESS_EXPIRE_SECS. Called from main's timer loop.
void sweep_link_guesses(RelayState& state);
