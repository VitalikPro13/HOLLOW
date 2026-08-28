#pragma once
#include <App.h>
#include "state.h"
#include "config.h"

void setup_ws_handler(uWS::SSLApp& app, RelayState& state, const Config& config);

// Evict offline-buffer entries older than OFFLINE_BUFFER_TTL_SECS. Called
// periodically from main's timer loop.
void sweep_offline_buffer(RelayState& state);

// Release multi-device link codes whose 5-minute TTL has elapsed (server-side
// backstop; the live countdown is client-side). Called from main's timer loop.
void sweep_link_codes(RelayState& state);
