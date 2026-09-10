#!/bin/sh
# certbot's DNS-01 cleanup hook. A failure here must not fail the issuance that
# already succeeded, so it only reports.
set -u

. /hooks/lib.sh

name=${CERTBOT_DOMAIN%.duckdns.org}
resp=$(http_get "https://www.duckdns.org/update?domains=$name&token=$DUCKDNS_TOKEN&txt=&clear=true" || echo FAILED)
case "$resp" in
OK*) ;;
*) echo "Could not clear the DuckDNS TXT record. It expires on its own." >&2 ;;
esac
exit 0
