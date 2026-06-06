#pragma once
#include <App.h>
#include "state.h"

void setup_ws_handler(uWS::SSLApp& app, RelayState& state);

// Evict offline-buffer entries older than OFFLINE_BUFFER_TTL_SECS. Called
// periodically from main's timer loop.
void sweep_offline_buffer(RelayState& state);
