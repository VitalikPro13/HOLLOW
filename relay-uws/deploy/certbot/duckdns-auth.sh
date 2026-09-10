#!/bin/sh
# certbot's DNS-01 auth hook: publish the challenge as the DuckDNS TXT record.
set -eu

. /hooks/lib.sh

name=${CERTBOT_DOMAIN%.duckdns.org}
resp=$(http_get "https://www.duckdns.org/update?domains=$name&token=$DUCKDNS_TOKEN&txt=$CERTBOT_VALIDATION" || echo FAILED)
case "$resp" in
OK*) ;;
*) die "DuckDNS refused the TXT update. Check DUCKDNS_TOKEN and the subdomain name." ;;
esac

# DuckDNS serves its own zone, but Let's Encrypt reads it through resolvers that
# have already cached the old answer.
sleep 45
