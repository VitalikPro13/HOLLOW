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

You do not need to know Docker. Every command below is written out.

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
  everything else stays shut.
- Keeps the system journal in memory only, for one hour, capped at 50 MB. The
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
  lock you out.

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
| `CERTBOT_STAGING` | Troubleshooting. Set to `1` to use the Let's Encrypt staging service while you get the setup right. |

## Start

```bash
docker compose up -d
```

The first run builds the relay from source, which takes a few minutes. Then it
gets the certificate, and only then does the relay start. If the certificate
fails, the whole thing stops there and tells you why, rather than leaving a
relay that cannot serve.

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

Invite links made in version 0.11.1 and later carry the relay address. When
someone on another relay opens one, the app asks whether they want to switch. If
they say yes, the app restarts on your relay, and their servers on the old relay
go quiet until they switch back. Older links do not carry the address, so tell
people your relay address alongside the link.

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

Two things run only on the official relay.

**The media forwarder.** Large screen shares to several viewers at once are
carried by a separate blind forwarder on the official infrastructure. Without
it, a share goes peer to peer to each viewer, which works and costs the sender
more upload.

**Restart persistence.** On the official relay, offline message buffers survive
a restart through a systemd handoff. Under Docker there is no such handoff, so
buffers, channel history rings and push registrations end when the container stops.
Upgrading the relay empties them. Certificate renewals no longer restart
anything, so those cost nothing.

Everything else is the same relay. The GIF, emote and game cover services are
features of the app rather than the relay, so they keep working.

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
What it holds while it runs is a list of which connections are in which rooms,
and ciphertext waiting for people who are offline, which is deleted on delivery
or after its expiry. It cannot decrypt any of it.

None of that is written to the disk. That promise depends on the host, which is
why `harden-host.sh` turns swap off and keeps the journal in memory. Swap would
let the kernel page ciphertext onto the SSD, a core dump would write the whole
lot at once, and a persistent journal would outlive the messages it mentions.

The one thing the relay does write is a count of user reports, in
`/data/reports.json` inside its volume, so you can see which peers have been
reported and act on it. It records the reported peer and the category, never who
reported it.

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
