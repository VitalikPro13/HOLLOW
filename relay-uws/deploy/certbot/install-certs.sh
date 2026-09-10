#!/bin/sh
# Copy the freshly issued pair out of certbot's lineage into the shared volume
# the relay reads. Also certbot's deploy hook, so a renewal lands the same way.
set -eu

. /hooks/lib.sh

LIVE=/etc/letsencrypt/live/relay
install_pair "$LIVE/fullchain.pem" "$LIVE/privkey.pem"
