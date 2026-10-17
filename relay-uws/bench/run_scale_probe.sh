#!/usr/bin/env bash
# One scale-probe run against a FRESH local relay on 127.0.0.1 (never production).
#
#   bash relay-uws/bench/run_scale_probe.sh <scenario> <N> [probe flags...]
#
# scenario: storm | joinone | churn | bcast | topic, or a comma list run on one room
#   (e.g. joinone,churn,bcast,topic), in that order
#   storm    N clients join one room at once (presence fan-out of a join storm)
#   joinone  room of N, then --extra M clients join one at a time (cost of one join)
#   churn    room of N, --churn-rates K1,K2 members/s, --churn rejoin,toggle, --churn-secs S
#   bcast    room of N, one sender at each of --rates R1,R2 msg/s (0x03), --payload B
#   topic    as bcast over a subscribed channel topic (0x07)
#   rejoin_all  every member re-joins the room it holds (door change, membership refresh)
# --fill hidden fills the room with inactive (hidden) members: no presence, same
# delivery, so a big room fills without the quadratic storm. Default: visible.
#
# Results: one JSON line per phase in $OUT (default .team/relay/results.jsonl) and on
# stdout as "RESULT {...}". The relay is built once by bench/macos/build.sh (macOS) and
# killed by pid when the run ends.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
wt=$(cd "$here/../.." && pwd)
scenario=${1:?scenario}
n=${2:?N}
shift 2
build=${RELAY_BUILD:-$wt/.team/relay/build}
out=${OUT:-$wt/.team/relay/results.jsonl}
case $out in /*) ;; *) out=$PWD/$out ;; esac
mkdir -p "$(dirname "$out")" "$build/run"
if [ ! -x "$build/hollow-relay" ]; then
    bash "$here/macos/build.sh" "$build"
fi
probe_target=${PROBE_TARGET:-$wt/.team/relay/target}
CARGO_TARGET_DIR=$probe_target cargo build --release --quiet --manifest-path "$here/scale_probe/Cargo.toml"
probe=$probe_target/release/relay_scale_probe

ulimit -n "$(sysctl -n kern.maxfilesperproc 2>/dev/null || echo 65536)" 2>/dev/null || ulimit -n 65536
port=$((20000 + RANDOM % 9000))
log=$build/run/relay_$port.log
cd "$build/run"
env -u NOTIFY_SOCKET -u LISTEN_PID -u LISTEN_FDS -u LISTEN_FDNAMES -u HOLLOW_PUSH_TOKEN \
    HOLLOW_CONN_RATE_EXEMPT=127.0.0.1 TURN_SECRET=bench \
    "$build/hollow-relay" --port "$port" --domain relay.bench.test \
    --cert-file "$build/cert.pem" --key-file "$build/key.pem" \
    --keys-file "$build/run/keys.json" --reports-file "$build/run/reports.json" > "$log" 2>&1 &
relay_pid=$!
# Relay CPU time, RSS and %cpu twice a second, read by the probe (it holds too many
# sockets to spawn ps reliably itself).
samples=$build/run/relay_$port.ps
(while kill -0 "$relay_pid" 2>/dev/null; do ps -o time=,rss=,%cpu= -p "$relay_pid" >> "$samples"; sleep 0.5; done) &
sampler_pid=$!
trap 'kill $relay_pid $sampler_pid 2>/dev/null || true; wait $relay_pid 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do
    grep -q "Listening on port" "$log" && break
    sleep 0.1
done
echo "relay pid $relay_pid port $port, scenario $scenario N=$n $*"
"$probe" --port "$port" --relay-pid "$relay_pid" --relay-stats "$samples" --scenario "$scenario" --n "$n" --out "$out" "$@"
# The relay's own delivery counters (send_dropped = sends uWS discarded past maxBackpressure).
stats=$(curl -sk --max-time 10 "https://127.0.0.1:$port/server-stats" || echo '{}')
echo "SERVER_STATS $stats"
echo "{\"phase\":\"server_stats\",\"n\":$n,\"scenario\":\"$scenario\",\"stats\":$stats}" >> "$out"
