#!/bin/sh
# Start coturn with flags only, so the whole TURN configuration lives in the
# compose file and this script, and a self-hoster never edits a second config.
set -eu

if [ -z "${TURN_SECRET:-}" ]; then
    echo "TURN_SECRET is not set. Put the same value in .env that the relay gets, or set COMPOSE_PROFILES= to run without TURN." >&2
    exit 1
fi

# The container mounts the certificate at /certs; a host install points this at
# its own copy.
cert_dir=${CERT_DIR:-/certs}

ip=${PUBLIC_IP:-}
if [ -z "$ip" ]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n 1 || true)
fi
if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -m 1 '^[0-9][0-9.]*$' || true)
fi
if [ -z "$ip" ]; then
    echo "Could not work out this machine's public IPv4. Set PUBLIC_IP in .env." >&2
    exit 1
fi

# --simple-log keeps the log file name exactly as given. Without it coturn
# appends a date and rotates, so /dev/null becomes a real
# /dev/null_<date>.log and every TURN session lands on the disk.
#
# The peer lock: deny every address, then allow this host back. TURN may relay
# only to another allocation on this same server, so it carries Hollow calls
# and cannot be used as an open proxy to anywhere else on the internet. An
# address on both lists is allowed, which is why the broad denies stay.
set -- \
    --listening-port=3478 \
    --tls-listening-port=5349 \
    --realm=hollow \
    --use-auth-secret \
    --static-auth-secret="$TURN_SECRET" \
    --no-cli \
    --no-multicast-peers \
    --no-tcp-relay \
    --min-port=49152 \
    --max-port=65535 \
    --cert="$cert_dir/fullchain.pem" \
    --pkey="$cert_dir/privkey.pem" \
    --no-stdout-log \
    --simple-log \
    --log-file=/dev/null \
    --denied-peer-ip=10.0.0.0-10.255.255.255 \
    --denied-peer-ip=172.16.0.0-172.31.255.255 \
    --denied-peer-ip=192.168.0.0-192.168.255.255 \
    --denied-peer-ip=0.0.0.0-255.255.255.255 \
    --denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff \
    --allowed-peer-ip="$ip"

if [ -n "${PUBLIC_IPV6:-}" ]; then
    set -- "$@" --allowed-peer-ip="$PUBLIC_IPV6"
fi

echo "Starting coturn, relaying only to $ip${PUBLIC_IPV6:+ and $PUBLIC_IPV6}."
exec turnserver "$@"
