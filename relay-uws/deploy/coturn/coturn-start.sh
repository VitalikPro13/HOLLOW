#!/bin/sh
# Start coturn with flags only, so the whole TURN configuration lives in the
# compose file and this script, and a self-hoster never edits a second config.
set -eu

if [ -z "${TURN_SECRET:-}" ]; then
    echo "TURN_SECRET is not set. Put the same value in .env that the relay gets, or set COMPOSE_PROFILES= to run without TURN." >&2
    exit 1
fi

# The secret goes into a file only this process can read. On the command line
# every local account, a Docker host's included, would see it in ps.
conf_dir=${RUNTIME_DIRECTORY:-$(mktemp -d)}
conf="$conf_dir/turnserver.conf"
(umask 077 && printf 'static-auth-secret=%s\n' "$TURN_SECRET" > "$conf")
unset TURN_SECRET

# The container mounts the certificate at /certs; a host install points this at
# its own copy.
cert_dir=${CERT_DIR:-/certs}

# Each lands in an --allowed-peer-ip flag, where a range would open the peer
# lock to the internet.
for v in "${PUBLIC_IP:-}" "${LOCAL_IP:-}"; do
    case "$v" in *[!0-9.]*) echo "PUBLIC_IP and LOCAL_IP take one IPv4 address each, not $v." >&2; exit 1 ;; esac
done
case "${PUBLIC_IPV6:-}" in *[!0-9A-Fa-f:]*) echo "PUBLIC_IPV6 takes one IPv6 address, not $PUBLIC_IPV6." >&2; exit 1 ;; esac
case "${CERT_WATCH_SECS:-}" in
'') ;;
*[!0-9]* | 0*) echo "CERT_WATCH_SECS takes a number of seconds, not $CERT_WATCH_SECS." >&2; exit 1 ;;
esac

# The address this machine sends from. LOCAL_IP comes from install.sh, because
# under the host unit's sandbox ip(8) fails; it counts only while this machine
# still has it.
own=" $(hostname -I 2>/dev/null || true) "
local_ip=""
if [ -n "${LOCAL_IP:-}" ]; then
    case "$own" in
    "  " | *" $LOCAL_IP "*) local_ip=$LOCAL_IP ;;
    *) echo "LOCAL_IP $LOCAL_IP is no longer an address of this machine. Run the setup again to update it." >&2 ;;
    esac
fi
[ -n "$local_ip" ] || local_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n 1 || true)
ip=${PUBLIC_IP:-$local_ip}
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

# Behind 1:1 NAT (most clouds, or a home router forwarding the ports) the
# sockets sit on the private address while clients reach the public one.
if [ -n "$local_ip" ] && [ "$ip" != "$local_ip" ]; then
    set -- "$@" --external-ip="$ip/$local_ip" --allowed-peer-ip="$local_ip"
fi

if [ -n "${PUBLIC_IPV6:-}" ]; then
    set -- "$@" --allowed-peer-ip="$PUBLIC_IPV6"
fi

echo "Starting coturn, relaying only to $ip${PUBLIC_IPV6:+ and $PUBLIC_IPV6}."

# coturn reads its pair only at start. A host's certbot hook restarts the unit;
# under Docker only the Docker socket could restart the container, and that is
# root on the host. So with CERT_WATCH_SECS this script stays coturn's parent
# and has it reload a renewed pair with SIGUSR2, which keeps every call up.
if [ -z "${CERT_WATCH_SECS:-}" ]; then
    exec turnserver -c "$conf" "$@"
fi

# Empty while either file is missing.
pair_sum() {
    s=$(sha256sum "$cert_dir/fullchain.pem" "$cert_dir/privkey.pem" 2>/dev/null) || s=""
    printf '%s' "$s"
}

# A pair counts once two looks in a row agree, so the moment between
# install_pair's two renames, a new key beside the old chain, never does.
watch_pair() {
    applied=$(pair_sum)
    seen=$applied
    while kill -0 "$1" 2>/dev/null; do
        sleep "$CERT_WATCH_SECS"
        now=$(pair_sum)
        if [ -n "$now" ] && [ "$now" = "$seen" ] && [ "$now" != "$applied" ]; then
            kill -s USR2 "$1" 2>/dev/null || true
            applied=$now
        fi
        seen=$now
    done
}

# As the container's first process this shell gets docker stop's TERM, and the
# signals coturn itself acts on.
turn=""
trap 'kill -s TERM "$turn" 2>/dev/null || true' TERM
trap 'kill -s INT "$turn" 2>/dev/null || true' INT
trap 'kill -s USR1 "$turn" 2>/dev/null || true' USR1
trap 'kill -s USR2 "$turn" 2>/dev/null || true' USR2
turnserver -c "$conf" "$@" &
turn=$!
watch_pair "$turn" &
watcher=$!
# A trapped signal ends a wait early; coturn has ended once it can be reaped.
while :; do
    rc=0
    wait "$turn" || rc=$?
    kill -0 "$turn" 2>/dev/null || break
done
kill "$watcher" 2>/dev/null || true
exit "$rc"
