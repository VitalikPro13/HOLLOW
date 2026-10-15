#!/bin/bash
# One ssh connection's end of a fleet agent (fleet_remote.ps1). The agent itself is a
# DETACHED server (fleet_remote_agent.ps1 -Serve) that outlives the connection, so a
# dropped ssh session loses no device, process or probe state; the driver reconnects
# and sends the same request again.
#
#   fleet_agent_attach.sh <agent> <session>
#
# Requests: one line each, "<key> <json>", key = <session>-<n>. A request runs at most
# once: its file moves req/ -> run/ -> ans/ and a key already in any of them is only
# waited for. Answers: "@@FLEET@@ <json>". Run from the tree's root; the environment
# (FLEET_BACKEND, FLEET_ANDROID_PEERS, ...) reaches a server this script starts.
# "<key> quit" stops the server. Not meant to be run by hand.
set -u
agent=${1:?agent}
session=${2:?session}
[[ "$agent" =~ ^[a-z-]+$ && "$session" =~ ^[A-Za-z0-9]+$ ]] || { echo "bad agent or session"; exit 2; }
dir=".team/agent-$agent"
mkdir -p "$dir"

alive() { [ -f "$dir/pid" ] && kill -0 "$(cat "$dir/pid" 2> /dev/null)" 2> /dev/null; }
proto() { printf '@@FLEET@@ %s\n' "$1"; }
fail() { proto "{\"id\":\"$1\",\"ok\":false,\"error\":\"$2 (see .team/agent-$agent.log on $(hostname))\"}"; }

# Another driver's server: a new driver starts clean, as a fresh agent always did.
if alive && [ "$(cat "$dir/session" 2> /dev/null)" != "$session" ]; then
    touch "$dir/quit"
    for _ in $(seq 1 100); do alive || break; sleep 0.1; done
    alive && kill "$(cat "$dir/pid")" 2> /dev/null
    sleep 0.3
fi
if ! alive; then
    rm -rf "$dir/req" "$dir/run" "$dir/ans" "$dir/quit" "$dir/hello.json"
    mkdir -p "$dir/req" "$dir/run" "$dir/ans"
    echo "$session" > "$dir/session"
    # macOS has no setsid; nohup alone keeps the server past the session there.
    if command -v setsid > /dev/null; then
        nohup setsid pwsh -NoProfile -File scripts/fleet_remote_agent.ps1 -Serve "$dir" \
            >> ".team/agent-$agent.log" 2>&1 < /dev/null &
    else
        nohup pwsh -NoProfile -File scripts/fleet_remote_agent.ps1 -Serve "$dir" \
            >> ".team/agent-$agent.log" 2>&1 < /dev/null &
    fi
    echo $! > "$dir/pid"
fi

for _ in $(seq 1 1200); do
    [ -f "$dir/hello.json" ] && break
    alive || break
    sleep 0.1
done
[ -f "$dir/hello.json" ] || { fail 0 "agent server did not start"; exit 1; }
proto "$(cat "$dir/hello.json")"

while IFS= read -r line; do
    # Windows PowerShell's pipe opens with a UTF-8 BOM.
    line=${line#$'\xef\xbb\xbf'}
    line=${line%$'\r'}
    key=${line%% *}
    json=${line#* }
    [[ "$key" =~ ^[A-Za-z0-9]+-[0-9]+$ ]] || { fail -1 "bad request key"; continue; }
    if [ "$json" = quit ]; then
        touch "$dir/quit"
        exit 0
    fi
    if [ ! -f "$dir/ans/$key.json" ] && [ ! -f "$dir/run/$key.json" ] && [ ! -f "$dir/req/$key.json" ]; then
        printf '%s\n' "$json" > "$dir/req/.$key.tmp" && mv "$dir/req/.$key.tmp" "$dir/req/$key.json"
    fi
    while [ ! -f "$dir/ans/$key.json" ]; do
        alive || { fail "$key" "agent server ended"; exit 1; }
        sleep 0.1
    done
    proto "$(cat "$dir/ans/$key.json")"
done
