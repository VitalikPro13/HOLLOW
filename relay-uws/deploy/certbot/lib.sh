#!/bin/sh
# Shared by the certbot hooks. Sourced, never executed.

# The relay runs as uid 999 and reads the certificate out of the shared volume,
# so every copy has to change hands.
CERT_UID=999
CERT_GID=999

# coturn's container runs as this uid, the one place it is set (docker-compose.yml's
# coturn user and the installer's TURN port lock follow it). The lock holds every
# process with coturn's uid, so no host account may have it: above 65535 (system
# and user accounts, systemd's dynamic users, nobody) and below 100000, the first
# subordinate uid useradd hands out for rootless containers.
TURN_UID=65999
TURN_GID=65999

die() {
    echo "$1" >&2
    exit 1
}

require_env() {
    eval "value=\${$1:-}"
    [ -n "$value" ] || die "$1 is not set. Fill it in relay-uws/.env and start again."
}

# RELAY_HOST is the address the app connects to, which may carry a port. A
# certificate is issued for a name or an address and never for a port, and a
# self-hosted relay on a port other than 443 has no way to be validated, so
# refuse it here rather than fail deep inside certbot.
reject_port_in_relay_host() {
    case "$RELAY_HOST" in
    \[*\]) ;;
    \[*) die "RELAY_HOST carries a port. Keep the relay on 443 and set RELAY_HOST to the host alone." ;;
    *:*:*) ;;
    *:*) die "RELAY_HOST carries a port. Keep the relay on 443 and set RELAY_HOST to the host alone." ;;
    esac
}

# Where certbot keeps its certificates; a test points it elsewhere.
LE_DIR=${HOLLOW_LE_DIR:-/etc/letsencrypt}

# ip, duckdns or name.
cert_mode() {
    case "$RELAY_HOST" in
    *.duckdns.org)
        if [ -n "${DUCKDNS_TOKEN:-}" ]; then echo duckdns; else echo name; fi
        return
        ;;
    esac
    case "$RELAY_HOST" in
    *[!0-9.]*) ;;
    *) echo ip; return ;;
    esac
    case "$RELAY_HOST" in
    *:*) echo ip; return ;;
    esac
    echo name
}

# The names and addresses the current certificate covers.
cert_names() {
    if command -v openssl >/dev/null 2>&1 && [ -r "$LE_DIR/live/relay/cert.pem" ]; then
        openssl x509 -in "$LE_DIR/live/relay/cert.pem" -noout -ext subjectAltName 2>/dev/null
    else
        certbot certificates --cert-name relay 2>/dev/null
    fi
}

# renew_way_changed <mode>: certbot's lineage renews another way than <mode>
# needs, or through hooks of another copy of these scripts.
renew_way_changed() {
    rwc_auth=$(sed -n 's/^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*//p' "$LE_DIR/renewal/relay.conf" | tail -n 1)
    rwc_hook=$(sed -n 's/^[[:space:]]*manual_auth_hook[[:space:]]*=[[:space:]]*//p' "$LE_DIR/renewal/relay.conf" | tail -n 1)
    if [ "$1" = duckdns ]; then
        [ "$rwc_auth" != manual ] || [ "$rwc_hook" != "$HOOKS/duckdns-auth.sh" ]
    else
        [ "$rwc_auth" != standalone ]
    fi
}

# certbot reconfigure came with 2.3. An older certbot answers reconfigure --help
# with its general help and exit 0, so only its version tells.
certbot_has_reconfigure() {
    chr_v=$(certbot --version 2>&1 | sed -n 's/^certbot \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' | head -n 1)
    [ -n "$chr_v" ] || return 1
    # shellcheck disable=SC2086 # major and minor
    set -- $chr_v
    [ "$1" -gt 2 ] || { [ "$1" = 2 ] && [ "$2" -ge 3 ]; }
}

# with_account <certbot command...>: with the Let's Encrypt account's terms
# appended, and never an email (Let's Encrypt keeps none).
with_account() {
    "$@" --agree-tos --register-unsafely-without-email
}

# RELAY_HOST without the IPv6 brackets, which certbot does not take.
bare_host() {
    host=$RELAY_HOST
    host=${host#"["}
    host=${host%"]"}
    echo "$host"
}

install_own_certs() {
    [ -r /own-certs/fullchain.pem ] || die "OWN_CERT_DIR has no readable fullchain.pem."
    [ -r /own-certs/privkey.pem ] || die "OWN_CERT_DIR has no readable privkey.pem."
    install_pair /own-certs/fullchain.pem /own-certs/privkey.pem
}

# Each file lands under its final name in one rename, so the relay's reload
# check never reads a half-written certificate. coturn gets a copy of its own in
# turn/, so each key stays 0600 and readable by one uid alone.
install_pair() {
    copy_pair_to "$LE_DIR" "$CERT_UID:$CERT_GID" "$1" "$2"
    mkdir -p "$LE_DIR/turn"
    chown "$TURN_UID:$TURN_GID" "$LE_DIR/turn"
    chmod 700 "$LE_DIR/turn"
    copy_pair_to "$LE_DIR/turn" "$TURN_UID:$TURN_GID" "$1" "$2"
}

# copy_pair_to <dir> <uid:gid> <fullchain> <privkey>: the key is never readable
# by another uid, not even between its copy and its chmod.
copy_pair_to() {
    (umask 077 && cp "$3" "$1/fullchain.pem.new" && cp "$4" "$1/privkey.pem.new")
    chown "$2" "$1/fullchain.pem.new" "$1/privkey.pem.new"
    chmod 644 "$1/fullchain.pem.new"
    chmod 600 "$1/privkey.pem.new"
    mv "$1/privkey.pem.new" "$1/privkey.pem"
    mv "$1/fullchain.pem.new" "$1/fullchain.pem"
}

# The URL goes to curl on stdin: on its command line, every local account would
# read the DuckDNS token in ps.
http_get() {
    if command -v curl >/dev/null 2>&1; then
        printf 'url = "%s"\n' "$1" | curl -fsS --max-time 30 -K -
    else
        wget -qO- "$1"
    fi
}

# On the host the token lives in a root-only file, since certbot's renewal
# timer calls the hooks without the installer's environment.
load_duckdns_token() {
    if [ -z "${DUCKDNS_TOKEN:-}" ] && [ -r /etc/hollow-duckdns/duckdns.env ]; then
        DUCKDNS_TOKEN=$(sed -n 's/^DUCKDNS_TOKEN=//p' /etc/hollow-duckdns/duckdns.env | tail -n 1)
    fi
}
