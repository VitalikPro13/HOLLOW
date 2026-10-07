#!/bin/bash
# The relay across a restart (test_relay_live.cpp, hs_restart): fdstore_restart.py plays
# systemd's fd store, so the snapshot really leaves one relay process and enters the next.
# Uses the relay and client run_live.sh built in [dir]/live; run_tests.sh calls it after
# run_live.sh with the same scratch directory. Skips, saying why, without them.
#   bash run_restart.sh <dir>
#   RELAY_LIVE_PORTS=lo-hi    pick the relays' ports in this range
cd "$(dirname "$0")" || exit 1
live=${1:?usage: run_restart.sh <dir>}/live
relay=$live/relay_off
[ -x "$relay" ] || relay=$live/relay_on
if [ ! -x "$relay" ] || [ ! -x "$live/client" ]; then
    echo "skip test_relay_restart (no relay or client from run_live.sh in $live)"
    exit 0
fi
command -v python3 > /dev/null || {
    echo "skip test_relay_restart (no python3)"
    exit 0
}
timeout 150 python3 -I fdstore_restart.py "$relay" "$live/client" "$live" "${RELAY_LIVE_PORTS:-}"
