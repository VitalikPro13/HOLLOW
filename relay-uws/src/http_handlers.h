#pragma once
#include <App.h>
#include "state.h"
#include "config.h"

void setup_http_handlers(uWS::SSLApp& app, RelayState& state, const Config& config);

#ifdef HOLLOW_RELAY_MEASURE
// The measuring build's report (ws_handler.cpp, measure.h).
std::string measure_report();
#endif
