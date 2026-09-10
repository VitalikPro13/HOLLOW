#!/bin/sh
# Obtain the relay's TLS certificate once, at stack start. Runs to completion
# and must exit non-zero on failure: the relay waits on this container, so a
# failed issuance stops the stack instead of leaving the relay to crash-loop on
# missing certificates while the certbot container looks healthy.
set -eu

. /hooks/lib.sh

if [ -n "${OWN_CERT_DIR:-}" ]; then
    install_own_certs
    echo "Using your own certificate from OWN_CERT_DIR."
    exit 0
fi

require_env RELAY_HOST
require_env CERTBOT_EMAIL
reject_port_in_relay_host

set -- certonly --non-interactive --agree-tos \
    --email "$CERTBOT_EMAIL" --keep-until-expiring --cert-name relay
if [ "${CERTBOT_STAGING:-}" = "1" ]; then
    set -- "$@" --staging
    echo "CERTBOT_STAGING=1, so this certificate will not be trusted by browsers or by Hollow."
fi

# --keep-until-expiring would otherwise keep a still-valid staging certificate
# when the operator clears CERTBOT_STAGING, so the relay would come back up
# serving a certificate no client trusts.
RENEWAL=/etc/letsencrypt/renewal/relay.conf
if [ -f "$RENEWAL" ]; then
    if grep -q acme-staging "$RENEWAL"; then have_staging=1; else have_staging=0; fi
    if [ "${CERTBOT_STAGING:-}" = "1" ]; then want_staging=1; else want_staging=0; fi
    if [ "$have_staging" != "$want_staging" ]; then
        echo "Switching between the staging and live services, discarding the old certificate."
        certbot delete --cert-name relay --non-interactive
    fi
fi

case "$(cert_mode)" in
ip)
    # Let's Encrypt issues IP certificates only under the shortlived profile,
    # and validates them by http-01, so port 80 has to reach this host.
    echo "Getting a certificate for the IP address $RELAY_HOST."
    set -- "$@" --standalone --ip-address "$(bare_host)" --preferred-profile shortlived
    ;;
duckdns)
    # DNS validation, so nothing has to listen on port 80. This is the only
    # path that works on a host behind NAT.
    echo "Getting a certificate for $RELAY_HOST through DuckDNS DNS validation."
    set -- "$@" --manual --preferred-challenges dns \
        --manual-auth-hook /hooks/duckdns-auth.sh \
        --manual-cleanup-hook /hooks/duckdns-cleanup.sh \
        -d "$RELAY_HOST"
    ;;
*)
    echo "Getting a certificate for $RELAY_HOST. Port 80 must reach this host."
    set -- "$@" --standalone -d "$RELAY_HOST"
    ;;
esac

certbot "$@"
/hooks/install-certs.sh
echo "Certificate ready."
