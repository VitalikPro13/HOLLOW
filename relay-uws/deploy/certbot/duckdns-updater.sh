#!/bin/sh
# Keep the DuckDNS name pointing at this machine. Sending an empty ip= makes
# DuckDNS record the address the request came from, which is the one clients
# will reach, so this survives a VPS address change without anyone editing .env.
set -eu

. /hooks/lib.sh

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
    resp=$(http_get "https://www.duckdns.org/update?domains=$name&token=$DUCKDNS_TOKEN&ip=" || echo FAILED)
    case "$resp" in
    OK*) ;;
    *) echo "DuckDNS update failed. Check DUCKDNS_TOKEN and the subdomain name." >&2 ;;
    esac
    sleep 300
done
