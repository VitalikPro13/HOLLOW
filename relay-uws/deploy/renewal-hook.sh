#!/bin/sh
# Certbot deploy hook on the official relay:
#   /etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh
# The relay reads a root-owned copy it can see through its group and reloads
# it within a minute on its own. coturn (the packaged unit, user turnserver in
# ssl-cert) reads the key in place. Nobody else can read a private key.
set -eu
name=relay.anonlisten.com
live=/etc/letsencrypt/live/$name
install -o root -g hollow-relay -m 0644 "$live/fullchain.pem" /etc/hollow-relay/fullchain.pem
install -o root -g hollow-relay -m 0640 "$live/privkey.pem" /etc/hollow-relay/privkey.pem
chgrp ssl-cert /etc/letsencrypt/archive/$name/privkey*.pem
chmod 0640 /etc/letsencrypt/archive/$name/privkey*.pem
# coturn reads its certificate only at start.
systemctl try-restart coturn || true
