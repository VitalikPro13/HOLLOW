#!/bin/sh
# Start the forwarder in its container from environment variables, so the
# compose file and .env hold all of its settings. Extra arguments go to
# hollow-forwarder (install.sh passes --print-peer-id).
set -eu

if [ -z "${RELAY_HOST:-}" ]; then
    echo "RELAY_HOST is not set. Fill it in relay-uws/.env." >&2
    exit 1
fi
ip=${PUBLIC_IP:-}
if [ -z "$ip" ]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n 1 || true)
fi
if [ -z "$ip" ]; then
    echo "Could not work out this machine's public IPv4. Set PUBLIC_IP in .env." >&2
    exit 1
fi

conf=/tmp/forwarder.toml
cat > "$conf" <<EOF
relay_domain = "$RELAY_HOST"
data_dir = "/data"
public_ip = "$ip"
udp_port_min = 40000
udp_port_max = 40199
EOF

exec hollow-forwarder --config "$conf" "$@"
