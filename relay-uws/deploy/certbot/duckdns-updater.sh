#!/bin/sh
# Keep the DuckDNS name pointing at this machine. Sending an empty ip= makes
# DuckDNS record the address the request came from, which is the one clients
# will reach, so this survives a VPS address change without anyone editing .env.
# DUCKDNS_IP pins the record instead, for a machine people reach at an address
# other than the one it sends from (a LAN test box behind home NAT). The host
# setup runs it from a timer with DUCKDNS_ONCE=1.
set -eu

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

case "${RELAY_HOST:-}" in
*.duckdns.org) ;;
*)
    echo "RELAY_HOST is not a DuckDNS name, nothing to update."
    exit 0
    ;;
esac

if [ -z "${DUCKDNS_TOKEN:-}" ]; then
    echo "DUCKDNS_TOKEN is not set, nothing to update."
    exit 0
fi

name=${RELAY_HOST%.duckdns.org}
while :; do
    resp=$(http_get "https://www.duckdns.org/update?domains=$name&token=$DUCKDNS_TOKEN&ip=${DUCKDNS_IP:-}" || echo FAILED)
    case "$resp" in
    OK*) ok=1 ;;
    *) ok=0; echo "DuckDNS update failed. Check DUCKDNS_TOKEN and the subdomain name." >&2 ;;
    esac
    if [ "${DUCKDNS_ONCE:-}" = 1 ]; then
        [ "$ok" = 1 ]
        exit
    fi
    sleep 300
done
