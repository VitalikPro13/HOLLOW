#!/bin/sh
# Shared by the certbot hooks. Sourced, never executed.

# The relay runs as uid 999 and reads the certificate out of the shared volume,
# so every copy has to change hands.
CERT_UID=999
CERT_GID=999

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
# check never reads a half-written certificate.
install_pair() {
    cp "$1" /etc/letsencrypt/fullchain.pem.new
    cp "$2" /etc/letsencrypt/privkey.pem.new
    chown "$CERT_UID:$CERT_GID" /etc/letsencrypt/fullchain.pem.new /etc/letsencrypt/privkey.pem.new
    chmod 644 /etc/letsencrypt/fullchain.pem.new
    chmod 600 /etc/letsencrypt/privkey.pem.new
    mv /etc/letsencrypt/privkey.pem.new /etc/letsencrypt/privkey.pem
    mv /etc/letsencrypt/fullchain.pem.new /etc/letsencrypt/fullchain.pem
}

http_get() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS "$1"
    else
        wget -qO- "$1"
    fi
}
