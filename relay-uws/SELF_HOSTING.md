# Self-hosting a Hollow relay

## What you get and what you need

A relay is the only piece of shared infrastructure Hollow uses. It passes
encrypted blobs between people and holds messages for members who are offline.
It cannot read anything it carries.

Running your own gives you a private network. Only people who point their app
at your relay can reach each other, and nothing about your group touches the
official relay.

You need a VPS with a public IPv4 address, running Ubuntu 22.04 or newer or
Debian 12 or newer, and root access over SSH. One vCPU and 1 GB of memory is
plenty; a relay uses around 17 MB when idle and 13.4 KB per connected person.
Budget about twenty minutes.

You do not need to know Docker. Every command below is written out. If you
would rather not run Docker at all, [Without Docker](#without-docker) sets up
the same relay directly on the host.

## Pick your address

Your relay needs an address people can type into the app, and that address needs
a TLS certificate that is trusted publicly. Hollow refuses self-signed
certificates, so this part is not optional. There are three ways to get one.

**A DuckDNS name, recommended.** Go to [duckdns.org](https://www.duckdns.org),
sign in with any of the accounts it offers, add a subdomain, and copy the token
it shows you. You get a name like `myrelay.duckdns.org` for free. The stack
keeps that name pointing at your VPS, and it gets the certificate through DNS
validation, so nothing has to listen on port 80. If your VPS ever changes
address, the name follows it and nobody has to re-enter anything.

**The bare IP address of your VPS.** Nothing to sign up for. Let's Encrypt has
issued certificates for IP addresses since January 2026, so this works, with two
things to know. Port 80 has to reach your VPS, because that is how the address is
validated. And IP certificates last six days, so the stack renews them roughly
every four days on its own. The real cost is that if your VPS ever changes
address, every member has to type the new one in by hand.

**A domain you own.** Point an A record at the VPS and put the name in
`RELAY_HOST`. Port 80 has to reach the VPS for validation.

Whichever you pick, the relay listens on 443 and the address carries no port.

## Prepare the host

SSH into the VPS as a user with sudo, and get the repository:

```bash
git clone --recurse-submodules https://github.com/VitalikPro13/HOLLOW.git
cd HOLLOW/relay-uws
```

The rest of this guide runs from that directory.

### Harden it

The same host setup the official relay runs is in the repository:

```bash
sudo sh deploy/harden-host.sh
```

Add `--print` to see what it would do without changing anything. What it does,
and why:

- Installs and enables a firewall that denies everything inbound except SSH,
  ports 80 and 443, and the TURN ports. A relay needs a handful of ports, so
  everything else stays shut. The firewall keeps no log, since every line of one
  would name the address a packet came from.
- Keeps the system journal in memory only, for one hour, capped at 50 MB, and
  stops rsyslog from copying relay, push and TURN lines into `/var/log`. The
  relay carries ciphertext and network addresses. Logs that survive a reboot
  undo that.
- Turns core dumps off. A crash would otherwise write the relay's entire memory,
  buffered messages included, to the disk.
- Turns swap off, now and after a reboot. Swap lets the kernel write relay
  memory to the disk, which is the one thing the relay promises never happens.
- Turns on clock synchronisation. Hollow logins carry a signed timestamp with a
  60 second window, so a wrong clock fails every login.
- Installs fail2ban and unattended security updates.
- Turns off SSH password logins, but only if your user already has an SSH key
  set up. If you have no key, it says so and leaves passwords on rather than
  lock you out. With a key in place it also keeps root out of SSH, unless root
  is the account you logged in with.

Once the relay is running, check the whole setup:

```bash
sudo bash deploy/check-host.sh
```

It changes nothing. For each relay service it checks the account it runs as,
who can read its secrets and how tight its sandbox is, then whether anything
could reach the disk. Every line should say `ok`.

### Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

Log out and back in, so your shell picks up the new group. Check it:

```bash
docker run --rm hello-world
```

## Configure

```bash
cp .env.example .env
nano .env
```

The fields:

| Field | What to put in it |
|---|---|
| `RELAY_HOST` | The address people type into the app. Your DuckDNS name, your VPS IPv4, or your own domain. No port. |
| `DUCKDNS_TOKEN` | Only for a DuckDNS name. The token from the DuckDNS dashboard. |
| `TURN_SECRET` | Run `openssl rand -hex 32` and paste the result. Leave it empty if you are running without TURN. |
| `CERTBOT_EMAIL` | Where Let's Encrypt sends expiry notices. |
| `COMPOSE_PROFILES` | Leave it as `turn`. Set it empty to run without a TURN server. |
| `PUBLIC_IP`, `PUBLIC_IPV6` | Leave empty. The IPv4 is detected at start. Fill the v6 in only if the machine has one. |
| `OWN_CERT_DIR` | Advanced. A directory holding a `fullchain.pem` and `privkey.pem` you manage yourself. Set it and certbot is not used at all. |
| `SESSION_GRACE_SECS` | Optional. How many seconds the relay waits for someone whose connection dropped, from 30 to 600. Leave it empty for 120. See [Dropped connections](#dropped-connections). |
| `CERTBOT_STAGING` | Troubleshooting. Set to `1` to use the Let's Encrypt staging service while you get the setup right. |

## Start

```bash
docker compose up -d
```

The first run builds the relay from source, which takes a few minutes. Then it
gets the certificate, and only then does the relay start. If the certificate
fails, the whole thing stops there and tells you why, rather than leaving a
relay that cannot serve.

The relay, push and coturn containers run as unprivileged users with no Linux
capabilities and a read-only file system, so a bug in one of them stays inside
its container.

Check it:

```bash
docker compose ps
```

Read the STATUS column. `certbot-init` has done its job and says
`Exited (0)`, `certbot-renew`, `coturn` and `duckdns` say `Up`, and `relay`
says `Up ... (healthy)`. A relay that says `Restarting` or an `Exited (1)`
anywhere means something went wrong; the troubleshooting section below covers
the usual causes.

Then, from your own machine:

```bash
curl https://myrelay.duckdns.org/health
curl https://myrelay.duckdns.org/relay-status
```

`/health` answers `{"status":"ok","service":"hollow-signaling"}`.
`/relay-status` tells the app what this relay offers:

- `license_required`: whether members need an access key to connect. See
  [Members-only relay](#members-only-relay).
- `version`: the relay's version.
- `turn`: whether the relay can hand out TURN credentials for calls.
- `forwarder`: whether a media forwarder is configured. On a self-hosted relay
  this is always false.

If both of those answer without a certificate warning, your relay is live.

## Connect the app

On desktop, open Settings, then Network, then Add relay. Type your relay
address, apply it, and let the app restart. It comes back connected to your
relay.

On mobile the same setting is under Settings, then Network. Applying it closes
the app. Reopen it and it connects to your relay.

On a fresh install, before an identity exists, the welcome screen has an
Advanced field for the relay address. Anyone joining your network can enter it
there and never touch the official relay at all.

## Invites and the island rule

A relay is an island. Two people on different relays cannot see each other, send
messages to each other, or share a server, even if they know each other's IDs.
There is no bridging between relays, by design.

Invite links carry the relay address. When someone on another relay opens one,
the app asks whether they want to switch. If they say yes, the app restarts on
your relay, and their servers on the old relay go quiet until they switch back.
Links made before 0.12 no longer work, so send new ones once everyone has
updated.

## Push notifications on phones

A phone that is asleep has to be woken when a message arrives. The wake-up
carries no message content, only a note that something is waiting, and the app
then collects the message from the relay itself.

**Android.** Your relay can do this through UnifiedPush. The `push` container in
the compose file sends the wake-ups and needs no accounts or keys. Each person
installs a UnifiedPush app on their phone, [ntfy](https://ntfy.sh) being the
common one, then picks it in Hollow under Settings > Notifications > Push
Delivery. The wake-up is encrypted to that phone before it leaves your relay,
so the ntfy server only sees that some app got a push. People who leave the
setting on Google get no wake-ups on your relay, because only the official
relay holds Hollow's Google credentials.

The container only sends to public addresses. If your ntfy server sits on the
same private network as the relay, add `UNIFIEDPUSH_ALLOW_PRIVATE=1` to the
`push` service's environment.

**iOS.** Apple wakes an iPhone only for pushes signed with the app's own
credentials, which only the official relay holds. On your relay, iPhones get
messages when Hollow is open.

## What a self-hosted relay does not have

**The media forwarder** runs only on the official relay. Large screen shares to
several viewers at once are carried by a separate blind forwarder on the
official infrastructure. Without it, a share goes peer to peer to each viewer,
which works and costs the sender more upload.

**Restart persistence** needs the relay to run without Docker. On the official
relay, offline message buffers survive a restart through a systemd handoff.
Under Docker there is no such handoff, so buffers, channel history rings, push
registrations, destroy orders and the places it keeps for
[dropped connections](#dropped-connections) end when the container stops, and
upgrading the relay empties them. Apps then reconnect from scratch and fetch what
they missed from each other. A destroy order is how Destroy my identity everywhere
reaches a device that is offline when you press it. If the container restarts
before that device comes back, the order is gone and the device keeps its data.
Certificate renewals no longer restart anything, so those cost nothing. A
relay set up as in [Without Docker](#without-docker) gets the handoff too.

Everything else is the same relay. The GIF, emote and game cover services are
features of the app rather than the relay, so they keep working.

## Dropped connections

Phones lose signal, laptops go to sleep and Wi-Fi hands over to mobile data. When
someone's connection drops, the relay keeps their place for a while: which rooms
they were in, and everything sent to them since. When their app comes back within
that time, it picks up where it left off and nothing is lost. Their friends see
them go offline as soon as the connection is gone, as before.

The wait is two minutes unless you change it. Set `SESSION_GRACE_SECS` in `.env`
to any number of seconds from 30 to 600, then `docker compose up -d`. A longer wait
covers longer gaps but holds more memory while people are away. Each dropped
connection keeps at most 8 MB, and everything the relay holds for absent people
shares one 512 MB limit. Without Docker, add `--session-grace-secs` and the number
to the relay's `ExecStart` line.

When you restart or update the relay, it first tells every connected app to come
back 2 to 10 seconds later, each at a different moment, so they do not all
reconnect at once.

## Running without TURN

TURN is what gets a call through when both people are behind a strict NAT and no
direct route exists. It costs bandwidth on your VPS, because the call's audio
and video flow through it.

To run without it, set `COMPOSE_PROFILES=` and leave `TURN_SECRET` empty in
`.env`, then `docker compose up -d`. The relay reports TURN from the secret, so
an empty secret is what tells the app there is no TURN server. Leaving the
secret set while coturn is not running is the one combination to avoid: the app
would hand out credentials for a server that is not there.

Calls then need a direct route between the two people, which is most of the
time. When one fails for this reason the app says so. Hollow Share never used TURN, so it's unaffected.

## Members-only relay

By default anyone who knows your address can connect. To limit it to people you
give a key to, create `keys/keys.json`:

```json
{
  "enabled": true,
  "keys": ["AB12-CD32-BA30-LJ50", "QQ44-RT19-ZZ08-MN71"]
}
```

Keys are four groups of four characters, each `A-Z` or `0-9`, separated by
hyphens. Make them up. The relay reads the file every 30 seconds, so adding a
key takes effect without a restart, and removing one disconnects whoever is
using it. One key admits up to 5 devices at a time, so a person's phone and
desktop share one key. The app asks for a key when it connects to a relay that
requires one.

The file is mounted read-only into the container and is gitignored, so you
cannot commit it by accident.

## Updating

```bash
cd HOLLOW
git pull
cd relay-uws
docker compose build relay push
docker compose up -d
```

This restarts the relay, which empties the offline buffers. Anything waiting for
a member who is offline is lost, so pick a quiet moment.

### Moving to 0.12

0.12 can't talk to 0.11, and the two can't share a relay either. The 0.12 app
can't sign in to an older relay, and a 0.11 app can't sign in to an updated one.
So update the relay first, then everyone's app, in one go:

1. Update the relay as above, or as in [Without Docker](#without-docker) if you
   run it that way.
2. Run `sudo sh deploy/harden-host.sh` again. Since 0.11.1 it also turns the
   firewall's log off, keeps relay lines out of `/var/log`, turns kdump off and
   tightens SSH. It changes only what isn't set yet.
3. Run `sudo bash deploy/check-host.sh`. Every check should say `ok`.
4. Then everyone on your relay updates the app. Until they do, they can't
   connect. Invite links made before 0.12 stop working, so send new ones.

Nothing in `.env` changes, and no new ports open.

## Ports

| Port | Protocol | Needed by | When |
|---|---|---|---|
| 22 | TCP | You, over SSH | Always |
| 443 | TCP | Every member's app | Always |
| 80 | TCP | Let's Encrypt validation | Only for an IP address or your own domain. Not needed with DuckDNS. |
| 3478 | TCP and UDP | Calls through TURN | Only with TURN |
| 5349 | TCP and UDP | Calls through TURN over TLS | Only with TURN |
| 49152 to 65535 | UDP | Call media through TURN | Only with TURN |

`harden-host.sh` opens exactly these. If your provider has its own firewall in
front of the VPS, open them there too.

## Troubleshooting

**`certbot-init` failed.** Read what it said:

```bash
docker compose logs certbot-init
```

The usual causes are DNS that does not point at this machine yet, port 80
blocked by a provider firewall when you are using an IP address or your own
domain, or a DuckDNS token that was pasted with a character missing. Let's
Encrypt also limits how often you may ask for the same certificate, so while you
are working out a problem, set `CERTBOT_STAGING=1` in `.env` and run
`docker compose up -d --force-recreate certbot-init`. Staging certificates are
not trusted and the app will not connect with one, but you can see the whole
flow succeed. Clear the setting when it does.

**The relay says unhealthy.**

```bash
docker compose logs relay
```

A relay that cannot read its certificate exits immediately. Check that
`certbot-init` exited 0 and that `docker compose exec relay ls -l /certs` shows
both files owned by `999`.

**The app says Offline.** Check `curl https://YOUR_RELAY_HOST/health` from
somewhere other than the VPS. If that fails, it is the firewall or the address.
If it works and the app still will not connect, check the clock on the VPS:

```bash
timedatectl
```

Logins carry a signed timestamp with a 60 second window, so a clock that is
minutes out rejects every login while everything else looks fine.

**Nobody can connect after updating the app to 0.12.** The relay is older than
0.12 and can't answer the new sign-in. Update the relay, as in
[Moving to 0.12](#moving-to-012).

**Some members connect and others can't.** From 0.12 the app signs the exact
address it connected to, and the relay only accepts its own `RELAY_HOST`
(`--domain` without Docker). Everyone has to type that address. A second name
pointing at the same VPS won't sign in.

**The app says the relay has no TURN server.** `TURN_SECRET` is empty, or coturn
is not running. Check `docker compose ps` for coturn, and that
`COMPOSE_PROFILES=turn` is set in `.env`.

coturn is set up to keep no log at all, because a TURN log records who called
and from which address. So a coturn problem shows up as a container that keeps
restarting rather than as a message. To see what it is complaining about,
remove the `--no-stdout-log` line from `deploy/coturn/coturn-start.sh`, run
`docker compose up -d coturn`, read `docker compose logs coturn`, and put the
line back.

## What the relay holds and never writes

The relay keeps no message log, no account, and no record of who talks to whom.
While it runs, it holds:

- which connections are in which rooms, and which channels each one follows
- ciphertext waiting for people who are offline, deleted on delivery or after
  its expiry
- each identity's signed list of its devices, so only that person's devices can
  collect what is waiting for them
- for each server, the public keys that guard who joins it, which also name its
  owner
- destroy orders waiting for a device that is offline
- for each phone, where to send its wake-ups and its notification settings,
  muted servers and conversations included
- temporary nicknames and one-time device link codes
- for each connection that dropped in the last few minutes, the rooms it was in
  and the ciphertext sent to it since, until it comes back or the wait runs out

It cannot decrypt the ciphertext, and nothing on the list is message content.

None of that is written to the disk. That promise depends on the host, which is
why `harden-host.sh` turns swap off and keeps the journal in memory. Swap would
let the kernel page ciphertext onto the SSD, a core dump would write the whole
lot at once, and a persistent journal would outlive the messages it mentions.

The one thing the relay does write is a count of user reports, in
`/data/reports.json` inside its volume, so you can see which peers have been
reported and act on it. It records the reported peer and the category. To stop
one person's report counting twice it also keeps a one-way fingerprint of each
report, made with a random key the relay creates on its first start in
`reports.json.key` beside it. Without that key the reports file can't confirm
who reported whom, so leave the key out of any copy you share. A reports file
from before the key loses its fingerprints on the next start and keeps its
counts.

## Starting on boot

`docker compose up -d` does not survive a reboot on its own. The repository has
a systemd unit for it:

```bash
sudo cp deploy/hollow-relay-docker-compose.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hollow-relay-docker-compose
```

It assumes the repository is at `/opt/HOLLOW` and that a user named `hollow`
owns it and is in the docker group. Edit the `User` and `WorkingDirectory` lines
if yours differs.

## Without Docker

The relay is a single program, and the official relay runs it directly under
systemd rather than in a container. Setting it up that way takes a few more
steps than Docker, and gets you one thing Docker cannot: offline messages
survive a relay restart, updates included.

Everything above about [picking an address](#pick-your-address), hardening the
host, [connecting the app](#connect-the-app), members-only keys and
[ports](#ports) still applies. Skip Install Docker, Configure and Start, and do
this instead. The commands assume the repository lives at `/opt/HOLLOW`.

### Build the relay

Move the repository you cloned earlier into place, then build:

```bash
sudo mv ~/HOLLOW /opt/HOLLOW
sudo apt install cmake g++ libssl-dev libsodium-dev zlib1g-dev
cd /opt/HOLLOW/relay-uws
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
```

The result is one file, `build/hollow-relay`. It runs as its own system user,
which can't use sudo and can read nothing but its certificate, its keys file
and its report count. The push sender gets a user of its own:

```bash
sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin hollow
sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin hollow-push
sudo install -d -o root -g hollow -m 0750 /etc/hollow-relay
```

### Get the certificate

Install certbot from snap. The distribution packages are too old for IP address
certificates.

```bash
sudo snap install --classic certbot
```

Port 80 has to reach the machine here, whichever address you picked, because
this setup validates over HTTP. For a DuckDNS name or a domain you own:

```bash
sudo certbot certonly --standalone --cert-name relay -d myrelay.duckdns.org
```

For the bare IP address:

```bash
sudo certbot certonly --standalone --cert-name relay --ip-address 203.0.113.7 --preferred-profile shortlived
```

Certbot keeps the files where only root can read them, so a small hook hands a
copy to the relay every time they renew. Create
`/etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh`:

```sh
#!/bin/sh
set -eu
live=/etc/letsencrypt/live/relay
install -o root -g hollow -m 0644 "$live/fullchain.pem" /etc/hollow-relay/fullchain.pem
install -o root -g hollow -m 0640 "$live/privkey.pem" /etc/hollow-relay/privkey.pem
# coturn reads its certificate once, at start. The relay needs no restart: it
# picks up the new files within a minute.
systemctl try-restart hollow-coturn || true
```

Make it executable and run it once, since certbot only calls it on renewals:

```bash
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh
sudo /etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh
```

The snap renews on its own timer. With a DuckDNS name, also keep the name
pointing at this machine, which the Docker setup does for you. Add this line
with `crontab -e`, using your own subdomain and token:

```
*/5 * * * * curl -fsS "https://www.duckdns.org/update?domains=myrelay&token=YOUR_TOKEN&ip=" >/dev/null
```

### Run it as a service

The relay's two secrets go in a file only root can read. systemd reads it as
root when it starts the relay. Never put them in an `Environment=` line, because
every account on the machine can read those with `systemctl show`. Run
`openssl rand -hex 32` twice, once for each value:

```bash
sudo install -m 0600 /dev/null /etc/hollow-relay/relay.env
sudo nano /etc/hollow-relay/relay.env
```

```
TURN_SECRET=the-first-value
HOLLOW_PUSH_TOKEN=the-second-value
```

Leave `TURN_SECRET=` empty to run without TURN. `HOLLOW_PUSH_TOKEN` is what the
push sender below checks, so no other program on the machine can send pushes
through it.

Then the service. Replace the domain with your relay address:

```bash
sudo tee /etc/systemd/system/hollow-relay.service >/dev/null <<'EOF'
[Unit]
Description=Hollow relay
After=network-online.target
Wants=network-online.target

[Service]
User=hollow
Group=hollow
ExecStart=/opt/HOLLOW/relay-uws/build/hollow-relay \
    --port 443 \
    --domain myrelay.duckdns.org \
    --keys-file /etc/hollow-relay/keys.json \
    --reports-file /var/lib/hollow-relay/reports.json \
    --cert-file /etc/hollow-relay/fullchain.pem \
    --key-file /etc/hollow-relay/privkey.pem
EnvironmentFile=/etc/hollow-relay/relay.env
StateDirectory=hollow-relay
StateDirectoryMode=0700
WorkingDirectory=/var/lib/hollow-relay
Restart=always
RestartSec=3
LimitNOFILE=1048576
NotifyAccess=main
FileDescriptorStoreMax=1
LimitCORE=0

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
PrivateIPC=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallErrorNumber=EPERM
RemoveIPC=yes
UMask=0077
InaccessiblePaths=-/etc/letsencrypt -/etc/hollow-push

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now hollow-relay
```

`AmbientCapabilities` lets the relay listen on 443 without running as root.
Keep `NotifyAccess` and `FileDescriptorStoreMax`, which carry the offline
messages across a restart. `LimitCORE=0` stops a crash from writing them to the
disk.

The block from `CapabilityBoundingSet` down is the relay's sandbox. The relay
sees the whole file system read-only apart from its own report directory, and
never sees `/home`, other programs, the certbot files or the push sender's
settings. It can't gain privileges, and the kernel refuses it every system call a
network server has no use for. A bug
in the relay then stays in the relay. It is the same sandbox the official relay
runs, and `systemd-analyze security hollow-relay` rates it about 1.4 out of 10,
where lower is safer.

Check it with the same `curl .../health` as above.

For a members-only relay, put `keys.json` in `/etc/hollow-relay/` instead of
`keys/`, owned by root and readable by the `hollow` group
(`sudo chgrp hollow keys.json && sudo chmod 0640 keys.json`).

### TURN

Install coturn and turn off the service the package ships with:

```bash
sudo apt install coturn
sudo systemctl disable --now coturn
```

Run it through the repository's start script instead, which uses the exact
settings of the Docker setup and reads the same `TURN_SECRET` from the relay's
secrets file. The script hands the secret to coturn in a file under
`/run/hollow-coturn`, never on its command line, where any account could read it
with `ps`.

```bash
sudo tee /etc/systemd/system/hollow-coturn.service >/dev/null <<'EOF'
[Unit]
Description=coturn for the Hollow relay
After=network-online.target
Wants=network-online.target

[Service]
User=hollow
Group=hollow
EnvironmentFile=/etc/hollow-relay/relay.env
Environment=CERT_DIR=/etc/hollow-relay
RuntimeDirectory=hollow-coturn
RuntimeDirectoryMode=0700
ExecStart=/bin/sh /opt/HOLLOW/relay-uws/deploy/coturn/coturn-start.sh
Restart=always
RestartSec=3
LimitCORE=0

CapabilityBoundingSet=
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
PrivateIPC=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged
SystemCallErrorNumber=EPERM
RemoveIPC=yes
UMask=0077
InaccessiblePaths=-/etc/letsencrypt -/etc/hollow-push

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now hollow-coturn
```

The script works out the machine's public IPv4 on its own. If it gets it wrong,
or the machine has an IPv6 you want calls to use, add
`Environment=PUBLIC_IP=...` or `Environment=PUBLIC_IPV6=...` lines.

### Push for Android phones

The UnifiedPush sender described in
[Push notifications on phones](#push-notifications-on-phones) needs Node.js 22.
Install it from [nodejs.org](https://nodejs.org) or NodeSource, because the
distribution packages are usually older. Its token file holds the same value as
`HOLLOW_PUSH_TOKEN` in the relay's secrets file, under the name `PUSH_TOKEN`:

```bash
cd /opt/HOLLOW/push-sidecar
npm install --omit=optional --omit=dev
sudo install -d -m 0700 /etc/hollow-push
sudo install -m 0600 /dev/null /etc/hollow-push/push.env
sudo nano /etc/hollow-push/push.env
```

```
PUSH_TOKEN=the-second-value
```

```bash
sudo tee /etc/systemd/system/hollow-push.service >/dev/null <<'EOF'
[Unit]
Description=Hollow push sender
After=network-online.target hollow-relay.service

[Service]
User=hollow-push
Group=hollow-push
WorkingDirectory=/opt/HOLLOW/push-sidecar
ExecStart=/usr/bin/node /opt/HOLLOW/push-sidecar/index.js
SyslogIdentifier=hollow-push
Environment=PUSH_PORT=3001
EnvironmentFile=/etc/hollow-push/push.env
Restart=always
RestartSec=3
LimitCORE=0

CapabilityBoundingSet=
NoNewPrivileges=yes
PrivateUsers=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
PrivateIPC=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged
SystemCallErrorNumber=EPERM
RemoveIPC=yes
UMask=0077
InaccessiblePaths=-/etc/letsencrypt -/etc/hollow-relay

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now hollow-push
```

The relay reaches it on `127.0.0.1:3001`, so that port stays closed to the
outside. Its sandbox is the relay's, less the line that would stop Node.js from
compiling JavaScript as it runs.

### Updating

```bash
cd /opt/HOLLOW
git pull --recurse-submodules
cmake --build relay-uws/build -j"$(nproc)"
sudo systemctl restart hollow-relay
```

Offline messages survive this restart, and apps that were connected resume their
place within about 10 seconds, missing nothing. If `push-sidecar` changed, run
`npm install --omit=optional --omit=dev` in it and
`sudo systemctl restart hollow-push` as well.

For the move to 0.12, [Moving to 0.12](#moving-to-012) applies here too: the
relay first, then the host script and the check, then the apps.

### When something is wrong

The relay, coturn and the push sender log to the journal, which
`harden-host.sh` keeps in memory for an hour:

```bash
journalctl -u hollow-relay -e
```

A relay that cannot read its certificate stops right away and says so. Check
that `/etc/hollow-relay/` holds both files, owned by root with the group
`hollow`. `sudo bash deploy/check-host.sh` names anything else that is off.
