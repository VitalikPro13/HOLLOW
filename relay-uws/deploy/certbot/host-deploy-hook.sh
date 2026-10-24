#!/bin/sh
# certbot's deploy hook on a host set up by install.sh, installed as
# /etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh. Each service gets a
# root-owned copy it reads through its group, so no account reads another's key
# and nobody else reads any. The relay picks a new pair up within a minute on
# its own; coturn reads its pair only at start.
set -eu

live=/etc/letsencrypt/live/relay

# copy_pair <dir> <group>: each file lands under its final name in one rename.
copy_pair() {
    install -o root -g "$2" -m 0640 "$live/fullchain.pem" "$1/fullchain.pem.new"
    install -o root -g "$2" -m 0640 "$live/privkey.pem" "$1/privkey.pem.new"
    mv -f "$1/privkey.pem.new" "$1/privkey.pem"
    mv -f "$1/fullchain.pem.new" "$1/fullchain.pem"
}

copy_pair /etc/hollow-relay hollow-relay
if [ -d /etc/hollow-turn ] && getent group hollow-turn >/dev/null; then
    copy_pair /etc/hollow-turn hollow-turn
    systemctl try-restart hollow-coturn >/dev/null 2>&1 || true
fi
