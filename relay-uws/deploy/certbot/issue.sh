#!/bin/sh
# Obtain the relay's TLS certificate once, at stack start. Runs to completion
# and must exit non-zero on failure: the relay waits on this container, so a
# failed issuance stops the stack instead of leaving the relay to crash-loop on
# missing certificates while the certbot container looks healthy.
set -eu

HOOKS=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HOOKS/lib.sh"

if [ -n "${OWN_CERT_DIR:-}" ]; then
    install_own_certs
    echo "Using your own certificate from OWN_CERT_DIR."
    exit 0
fi

require_env RELAY_HOST
reject_port_in_relay_host
load_duckdns_token

# Let's Encrypt keeps no account email any more, so an email an older .env
# still names is ignored.
set -- certonly --non-interactive --agree-tos --register-unsafely-without-email
keep=--keep-until-expiring

# --keep-until-expiring would otherwise keep a still-valid staging certificate
# when the operator clears CERTBOT_STAGING, so the relay would come back up
# serving a certificate no client trusts.
RENEWAL=$LE_DIR/renewal/relay.conf
if [ -f "$RENEWAL" ]; then
    if grep -q acme-staging "$RENEWAL"; then have_staging=1; else have_staging=0; fi
    if [ "${CERTBOT_STAGING:-}" = "1" ]; then want_staging=1; else want_staging=0; fi
    if [ "$have_staging" != "$want_staging" ]; then
        echo "Switching between the staging and live services, discarding the old certificate."
        certbot delete --cert-name relay --non-interactive
    elif ! cert_names | grep -qwF -- "$(bare_host)"; then
        echo "The relay's address changed, discarding the certificate for the old one."
        certbot delete --cert-name relay --non-interactive
    fi
fi

# It would also keep the way certbot renews it, while a changed address mode
# needs another: DuckDNS mode closes port 80, so a renewal over it fails.
mode=$(cert_mode)
if [ -f "$RENEWAL" ] && renew_way_changed "$mode"; then
    echo "The certificate stays, but certbot renews it another way now, to match the relay's address."
    if certbot_has_reconfigure; then
        # reconfigure tries the new way against the staging service first and
        # saves it only once that works.
        if [ "$mode" = duckdns ]; then
            with_account certbot reconfigure --cert-name relay --non-interactive --manual --preferred-challenges dns \
                --manual-auth-hook "$HOOKS/duckdns-auth.sh" --manual-cleanup-hook "$HOOKS/duckdns-cleanup.sh"
        else
            with_account certbot reconfigure --cert-name relay --non-interactive --standalone --preferred-challenges http
        fi
    else
        # A certbot older than 2.3 saves a new way only with a new certificate.
        keep=--force-renewal
    fi
fi
set -- "$@" "$keep" --cert-name relay
if [ "${CERTBOT_STAGING:-}" = "1" ]; then
    set -- "$@" --staging
    echo "CERTBOT_STAGING=1, so this certificate will not be trusted by browsers or by Hollow."
fi

case "$mode" in
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
        --manual-auth-hook "$HOOKS/duckdns-auth.sh" \
        --manual-cleanup-hook "$HOOKS/duckdns-cleanup.sh" \
        -d "$RELAY_HOST"
    ;;
*)
    echo "Getting a certificate for $RELAY_HOST. Port 80 must reach this host."
    set -- "$@" --standalone -d "$RELAY_HOST"
    ;;
esac

certbot "$@"
# The host setup hands the pair to its services with its own deploy hook.
"${CERT_INSTALL_HOOK:-$HOOKS/install-certs.sh}"
echo "Certificate ready."
