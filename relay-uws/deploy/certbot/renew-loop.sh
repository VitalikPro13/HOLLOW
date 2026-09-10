#!/bin/sh
# Renewal, forever. certbot stores the challenge method with the lineage, so a
# DuckDNS or IP certificate renews the way it was issued and needs no flags
# here. The relay picks the new files up on its own within a minute, so nothing
# in this stack restarts on a renewal.
set -eu

. /hooks/lib.sh

while :; do
    sleep 43200  # 12 hours, in seconds, because busybox sleep may not take suffixes
    if [ -n "${OWN_CERT_DIR:-}" ]; then
        # A subshell, because the copy helper exits on a missing file and
        # this loop has to survive that.
        (install_own_certs) || echo "Could not re-copy the certificate from OWN_CERT_DIR." >&2
    else
        certbot renew --quiet --deploy-hook /hooks/install-certs.sh \
            || echo "Renewal attempt failed, will try again in 12 hours." >&2
    fi
done
