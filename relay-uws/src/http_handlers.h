#pragma once
#include <App.h>
#include "state.h"
#include "config.h"

void setup_http_handlers(uWS::SSLApp& app, RelayState& state, const Config& config);
