# Running your own Hollow relay

This guide takes you from an empty server to a relay your group's apps connect
to. You don't need to have run a server before. The setup wizard asks a
few questions, shows you its plan and does the rest. Most people only need
[Your address](#your-address), [Prepare a server](#prepare-a-server) and
[Run the setup](#run-the-setup).

You never have to run a relay. The official one at `relay.anonlisten.com` is
free, open to everyone, and stays that way. People run their own for a network
nobody else is on.

## What a relay is

Every Hollow app connects to one relay. The relay passes encrypted traffic
between people and cannot read any of it. When someone is offline, the relay
holds the encrypted traffic meant for them in memory, for a limited time and
within a fixed size, and hands it over when their app connects again. Calls,
screen shares and files go directly between people where they can.

The relay keeps no message log, no accounts and no record of who talks to whom.
[What the relay holds](#what-the-relay-holds-and-never-writes) lists everything
it has in memory while it runs.

### The island rule

A relay is an island. Two people on different relays cannot see each other,
send each other messages or share a server, even when they know each other's
IDs. There is no bridging between relays, by design.

Invite links carry the address of the relay they were made on. When someone on
another relay opens one, the app shows **This server lives on another relay**
and asks whether to switch. It never switches on its own. If they agree, the app
restarts on your relay (a phone closes, and they open it again), and their
servers on the old relay go quiet until they switch back.

So everyone in your group points their app at your relay, and they reach only
each other there.

## Choose your setup

| Setup | Who it suits |
|---|---|
| **The setup wizard, full setup (recommended)** | Almost everyone. Each part of the relay runs as a system service under its own account and in its own sandbox, the way the official relay runs. Messages waiting for offline people survive a restart or an update of the relay. |
| **The setup wizard, Docker** | People who already run everything in Docker. Every restart or update of the relay container drops what the relay holds in memory, see below. |
| **By hand** | People who want to do each step themselves. [Path A](#path-a-docker-by-hand) covers Docker and [path B](#path-b-systemd-by-hand) covers systemd. |

With Docker, every time the relay container restarts, it loses the
messages waiting for offline people, the phones' push registrations and any
destroy orders waiting for an offline device. The apps fetch the messages they
missed from each other afterwards, but a waiting destroy order is gone for good.
A destroy order is how **Destroy my identity everywhere** reaches a device that
was offline when you pressed it. The full setup hands all of this across a
restart, memory to memory, without writing it to the disk.

## Your address

People type your relay's address into the app, and that address needs a
certificate from Let's Encrypt, because Hollow refuses self-signed ones. You have
three choices. The setup asks which one you want.

**A DuckDNS name (recommended).** Free, with nothing to buy. Go to
[duckdns.org](https://www.duckdns.org), sign in with any of the accounts it
offers and add a subdomain. You get a name like `myrelay.duckdns.org` and a
token, a long code at the top of the page. The setup keeps the name pointing at
your server, so if the server ever gets a new IP address, nobody has to type
anything new, and calls follow it too (see [A new address](#a-new-address)). The
certificate comes through DNS, so port 80 stays closed.

**The server's bare IP address.** Nothing to sign up for. Port 80 has to stay
open, because that is how Let's Encrypt checks an IP address. The certificate
lasts six days and renews on its own. A bare IP address only works if your
provider gives you a fixed address. If it changes, use DuckDNS or your own domain,
because every member would have to type the new address by hand.

**A domain you own.** Point the domain's A record at your server before you run
the setup. Port 80 has to stay open for the certificate. If your router or a
dynamic DNS service keeps the record current, calls follow a new address too.

The relay always listens on port 443, so the address never carries a port.

### A new address

TURN (for calls) and the media forwarder tell the apps the server's public
address. With a DuckDNS name or your own domain, the setup checks every five
minutes where the name points. It asks the server's own DNS servers, never
`/etc/hosts` and never a public resolver. When the name points somewhere new,
TURN and the forwarder move there once the new address proves to be this
server: the setup connects to it, and the far end has to answer with your
relay's own certificate key and with your TURN server's secret. A DNS answer
alone never moves them, so a forged one cannot send TURN traffic to someone
else's machine.

Some home routers can't connect from inside the network to their own public
address, so the check can't run from the server. Then the setup takes nothing
new. It stops using the old address, which someone else may have by then, only
when every check for half an hour agrees: the server no longer has the old
address, your relay no longer answers there, DNS keeps naming the same new
address, and for a DuckDNS name DuckDNS itself saw the server at that address.
From then on calls that need TURN fail until you confirm the new address: run
`sudo hollow-relay-setup`, choose **Change a setting**, then the address. The
setup's check names both addresses (see [Check it](#check-it)).

If your router or a Pi-hole answers your relay's name with a LAN address for
machines at home, the setup ignores those answers and changes nothing, even
after the public address changes. Then confirm a new address yourself the same
way.

The setup manages these addresses itself, in `turn.env`, `turn-port-lock.env`,
`forwarder.toml` and the Docker setup's `.env`, so it puts back any hand edit of
them within five minutes. To set an address, use **Change a setting**.

A relay only your home network uses, at a LAN address you typed, isn't
followed. Give that machine a fixed address in your router instead.

## Prepare a server

### Which system

The setup supports **Ubuntu 22.04 or newer** and **Debian 12 or newer**, on
x86_64 or ARM64 (aarch64), and systems built on them: Linux Mint 21 or newer,
LMDE 6, Pop!_OS 22.04, Zorin OS 17, elementary OS 7 and others that name their
Ubuntu or Debian release in `/etc/os-release`. It checks this first, says which
base it found ("Linux Mint 22, based on Ubuntu 24.04"), and stops on anything
else. On such a system Docker comes from the base's repository and the daily
security updates from the base's security archive, which one of the system's
software sources has to serve (the check says when none does). Removing the
relay takes that update setting back out.

We recommend Debian 12 or 13, because it is lighter. On the same small test
machine (1 CPU, 2 GB), a fresh Debian 13 used about 80 MB less memory than a
fresh Ubuntu Server 24.04 (212 MB against 291 MB), ran 11 background services
instead of 17, and took 1.3 GB of disk instead of 4.5 GB. Ubuntu Server works just
as well if that is what you know or what your provider offers. Either one leaves
plenty of room for the relay.

Not supported, and not tested: Rocky, Alma, Fedora and the rest of the Red Hat
family, Alpine, Arch, and any 32-bit system. Raspberry Pi OS 64-bit identifies
itself as Debian, so the setup accepts it, but we have not tried it on a Pi yet.
OpenVZ containers can't run the relay's sandbox, and the setup stops there. In an
LXC container some sandbox settings may not work, and the final check names
them.

### How big

| | Enough | Notes |
|---|---|---|
| Memory | 1 GB | The setup stops below 512 MB. With the full setup running (relay, TURN, push sender, forwarder and the hardening), our test machine used about 340 MB on Debian 13 and 400 MB on Ubuntu Server 24.04. The relay itself uses about 17 MB when idle and 13.4 KB for each connected person. |
| CPU | 1 vCPU | Plenty for the relay. Building the programs from source is slow on one core. |
| Disk | Whatever the provider gives | The ready-made programs are small. A build from source needs more room, and the setup tells you if your disk has unused space it can add. |
| Network | A public IPv4 address | Calls through TURN and screen shares through the media forwarder use the server's bandwidth. |

A VPS for 3 to 5 euros a month is enough for a group. You need root, or an
account that can use `sudo`, and SSH access.

### Cloud firewalls

Some providers (AWS, Google Cloud, Oracle and others) put their own firewall in
front of the server. The setup opens the right ports on the server itself, and
tells you at the end which ones to open in the provider's panel too. The list is
also under [Ports](#ports).

### A server at home

A machine at home works if your router can forward ports to it. The setup
notices that the machine's own address is private, tells you which ports to
forward and to which address, and carries on.

It cannot work behind carrier-grade NAT (CGNAT), where your internet provider
shares one public address between many customers, so nobody outside can reach
you. If the server's own address is in the range CGNAT uses, the setup stops.
Behind a home router it can't see that, so look at your router's status page. If
the WAN address there differs from the public address the setup reports, you are
behind CGNAT, and a small VPS is the way out.

## Run the setup

### Get the repository

Connect to your server over SSH from your own computer, where copy and paste
work. Then:

```bash
sudo apt install git
git clone --recurse-submodules https://github.com/VitalikPro13/HOLLOW.git
cd HOLLOW
git checkout v0.14.0-beta
git -c gpg.ssh.allowedSignersFile=.github/allowed_signers verify-tag v0.14.0-beta
git submodule update --init --recursive
sudo bash relay-uws/install.sh
```

Use the newest release tag in place of `v0.14.0-beta`. The newest is at the top
of the project's Releases page, and tags before 0.14.0 are not signed.
`verify-tag` should print a line that starts with `Good "git" signature` and
names the release key, `SHA256:S474PF7v/QSTHwpXexCX4EzKFsNfDajUtcfP71jO+R4`. If
it prints anything else, stop and tell us (see `SECURITY.md`).

There is no `curl ... | bash` one-liner, on purpose. The clone gives you a copy
you can read before you run it. The setup is `relay-uws/install.sh` plus the
files in `relay-uws/deploy/lib/`.

To see what it would do without changing anything:

```bash
bash relay-uws/install.sh --dry-run
```

If you started on the server's own console instead (a VirtualBox window or your
provider's web console), the setup says so and suggests stopping to connect over
SSH. Pasting rarely works on those consoles, and the DuckDNS token is long. If
you stay, it can read the token from a file instead.

### What it asks

The setup checks the machine first, then asks its questions one screen at a
time. Each screen says what the option does, what we recommend and what it costs.
Nothing changes until you accept the plan, and you can stop at any point before
that. Setting up takes about 5 to 10 minutes on a new server, longer if you build
the programs yourself.

1. **Can this machine host a relay?** The system, memory, disk, public address,
   whether you are behind a router, ports 443 and 80, and the clock. It ends in
   one of three verdicts: a relay works here, a relay works here with a step or
   two from you, or a relay cannot work here and why.
2. **How to run it.** The full setup (recommended) or Docker, as in
   [Choose your setup](#choose-your-setup).
3. **Ready-made programs or a build here.** Full setup only. The ready-made
   programs are built by the Hollow project. The setup checks the signature on
   the release list and the checksum of the download before it installs them,
   which takes about a minute. A build from source compiles both programs from
   your copy of the repository. The relay takes a few minutes, but the media
   forwarder is the whole Hollow core library and takes up to an hour or two on a
   small machine. If there are no ready-made programs for your machine, the
   setup says so and builds them instead. The Docker setup always builds from
   source.
4. **The address people reach.** Only behind a router. Press Enter to keep the
   public address the setup found, or type another, for example a LAN address
   for a relay only your home network uses.
5. **Your relay's address.** DuckDNS, the bare IP or your own domain. For
   DuckDNS it then asks for the name (`myrelay` or the whole
   `myrelay.duckdns.org`) and the token, which it checks with DuckDNS straight
   away. The token is kept in a file only root can read and never shown.
6. **TURN for calls**, recommended yes. See [TURN](#turn-for-calls).
7. **Push notifications for Android**, recommended yes. Full setup only; the
   Docker setup always runs it. See [Push](#push-notifications-on-phones).
8. **Media forwarder for screen shares**, recommended yes. See
   [The media forwarder](#the-media-forwarder).
9. **Sharing the upload fairly**, recommended on, and then the upload speed to
   share it under. See [Fair share of the upload](#fair-share-of-the-upload).
10. **Who may connect.** Open to anyone with the address (recommended), or
    members-only with keys. See [Members-only relay](#members-only-relay).
11. **The public stats page**, recommended on. See [Public stats](#public-stats).
12. **Waiting for dropped connections**, 120 seconds unless you change it. See
    [Dropped connections](#dropped-connections).
13. **Log in with a key instead of a password**, recommended yes. See
    [SSH keys](#ssh-keys).

For a domain you own, the setup checks that the name points at your server
before it asks Let's Encrypt for anything, because Let's Encrypt allows only a
few failed attempts. If it doesn't point there yet, you can fix the record and
check again, choose another address, or stop.

Then comes **Ready to set up**, the whole plan on one screen: the address, how
the relay runs, which parts run, the ports the firewall lets in and what the
setup changes on the machine. Say yes and it starts.

### What it changes on the machine

- **Firewall.** Turns on and lets in only SSH and the relay's ports. It keeps no
  log, since every line of one would name the address a packet came from.
- **Swap off and core dumps off**, now and after every reboot. Swap or a crash
  dump would let relay memory reach the disk.
- **The system journal** stays in memory only, for one hour, and relay lines
  never reach `/var/log`.
- **The clock** stays synchronised. Logins to the relay carry a signed timestamp
  with a 60 second window, so a wrong clock fails every login.
- **The TURN port lock**, when TURN is on. See [TURN](#turn-for-calls).
- **CAKE on the upload**, unless you turn it off. See
  [Fair share of the upload](#fair-share-of-the-upload).
- **fail2ban and automatic security updates** are installed and turned on. A
  fresh Debian installs the updater but never runs it, so the setup switches it
  on there.
- **Service accounts.** In the full setup each part runs as its own account that
  can't log in: `hollow-relay`, `hollow-turn`, `hollow-push`, `hollow-fwd` and
  `hollow-ddns`, and `hollow-build` if you build from source.

This is the same host setup the official relay runs. It lives in
`relay-uws/deploy/harden-host.sh`.

### SSH keys

Right now your server probably accepts SSH logins with a password, and bots try
passwords on every server on the internet all day. A key is safer. It is a file
on your computer that proves it is you, with nothing to guess. The setup can turn
password logins off for you, and it does that only after it has seen you log in
with a key, so you can't lock yourself out.

How it goes:

1. If you logged in to this session with a key, the setup shows that key's
   fingerprint and the address it came from and asks **Is that your key?** Say
   yes only if it is the key on the computer you will manage the server from.
2. Otherwise it shows **Make a key on your computer**. Run these on your own
   computer, not on the server:

   Windows (PowerShell):
   ```powershell
   ssh-keygen -t ed25519
   type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh you@myrelay.duckdns.org "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
   ```

   macOS or Linux (Terminal):
   ```bash
   ssh-keygen -t ed25519
   ssh-copy-id you@myrelay.duckdns.org
   ```

   `ssh-keygen` asks where to save the key (press Enter) and for a passphrase,
   which protects the key if someone copies it off your computer. **If it says
   the key already exists, answer `n`** and go on to the next command. The key
   you already have works. The setup shows the exact commands with your account
   and address filled in.
3. **Log in with your key.** Open a second window on your computer and log in
   with `ssh`. When the login arrives, the setup asks **Was that you?** and shows
   the key, the address and the time. Say no if you don't know that key or
   address. Logins with a password never count.
4. Password logins go off, and **One more login** asks you to log in once more
   from a second window, to prove you still can. If that login doesn't arrive,
   passwords come back on, and a timer turns them back on by itself after 10
   minutes in case your connection drops.

Root logins over SSH go off at the same time, unless root is the account you
log in with. The setup writes its SSH settings to
`/etc/ssh/sshd_config.d/10-hollow-relay.conf`.

Once passwords are off, the key file on your computer is your way in. Keep a
copy of it somewhere safe, such as a password manager. It is usually
`~/.ssh/id_ed25519`. To let a second computer in, run the setup again and choose
**Add another computer's SSH key**. If every key is lost, your provider's web
console, or a screen and keyboard on the machine itself, still gets you in.

### When it finishes

The setup gets the certificate, starts everything, checks that the relay
answers, runs the host checks and then shows a few summary screens:

- **Your relay is running**: the address to type into the app, and what runs.
- **Members-only keys**: the keys to hand out, if you chose members-only.
- **Ports to open**: the ports, for a provider's firewall or a router.
- **What to back up**: see [Backups](#backups).
- **SSH and checks**: what happened with SSH and whether every check passed.

Whiptail clears its screens when it's done, so the setup prints the summary once
more at the end, without the keys, where it stays in your terminal.

If something fails halfway, the setup stops and shows the command that failed
and its last lines. Fix the cause and run it again. Every step checks what is
already done and carries on from there. If a first install stopped before it
finished, the next run offers **Use the answers from last time?** The DuckDNS
token is never written down, so that one you type again.

### Running it again

The setup installs itself on the server, so later you only need:

```bash
sudo hollow-relay-setup
```

It shows **Hollow relay status** (the address, each service and whether it
runs, the relay's version, members-only, the certificate's expiry date and
whether an update is out), then **What next?**:

| Choice | What it does |
|---|---|
| **Update to version …** | Shown when a newer signed release is out. Downloads it, checks it, installs it and restarts the relay and the forwarder. If the new version doesn't start, the previous one goes back on by itself. |
| **Rebuild from this copy** / **Rebuild the containers from this copy** | Shown when you run the setup from your clone of the repository. For a build from source, only when the clone holds other code than the build running now. On a relay that runs programs from a signed release, it builds them from the clone instead, and the menu stops offering signed updates. If the clone holds an older version than the one running, it asks you first. |
| **Change a setting** | TURN, push, the forwarder, members-only, adding or removing a members-only key, the wait for dropped connections, or the address. On a relay with a certificate from the Let's Encrypt staging service, it also offers a trusted one, and on a relay built from source it offers to go back to signed releases. It shows that option's screen again, then applies the change. |
| **Show the members-only keys** | Lists the keys to hand out. |
| **Turn SSH password logins off** | Shown while passwords are still on. The same guided flow as above. |
| **Add another computer's SSH key** | Lets one more computer log in, with the same confirmed key login. It never turns passwords back on and never removes a key. |
| **Check the machine again** | Runs the host checks and asks the relay for its status. |
| **Remove the relay** | See [Removing the relay](#removing-the-relay). |
| **Leave everything as it is** | Changes nothing. |

### Without anyone at the keyboard

`sudo bash relay-uws/install.sh --answers FILE` takes every answer from a file,
for example from cloud-init. `relay-uws/test/installer/answers.example` lists
every key. A key you leave out takes the recommended choice, and an unknown key
stops the run, so a typo never passes silently. The DuckDNS token can come from
a file (`duckdns_token_file=`) that holds the token alone on its first line, or
on a `TOKEN=` or `DUCKDNS_TOKEN=` line. The SSH switch needs the fingerprint of your key
(`ssh_key_fingerprint=`, as `ssh-keygen -lf ~/.ssh/id_ed25519.pub` prints it),
so a login by any other key never turns passwords off. In this mode the
members-only keys go to `/root/hollow-relay-member-keys.txt`, which only root can
read, never to the screen. `--plain` asks the questions as plain prompts instead
of whiptail screens.

## Already running a relay?

If you set up a relay by hand from an older version of this guide, or with a
plain `docker compose up` in `relay-uws`, run the setup the same way:

```bash
cd HOLLOW
git pull --recurse-submodules
sudo bash relay-uws/install.sh
```

It finds the relay, changes nothing, and shows **A relay is already here** with
what it found: how it runs, the address, the certificate and how it renews,
TURN, push, the forwarder and its id, members-only keys and the report counts.
**Also worth knowing** lists anything odd, such as a relay and coturn with
different TURN secrets. Then you choose.

**Take it over (recommended).** The relay moves into the layout a new install
gets, and from then on `sudo hollow-relay-setup` shows its status, updates and
settings. The setup keeps the address, the certificate and its renewal, the
member keys, the report counts, the TURN secret, the push settings and the
forwarder's identity, so nobody in your group has to change anything. Before it
replaces a file it copies it to `/root/hollow-relay-adopt-<date>-<time>`, which
only root can read. If a step fails, it puts the old relay back as it was. If the
connection drops in the middle, the next run shows **A take over did not
finish** and offers to put the old relay back.

A relay set up by hand moves to the full setup, and the setup asks whether to
use the ready-made programs or build them. If its service is
`hollow-relay.service` with the restart handoff, as the old guide set it up,
messages waiting for offline people carry across the one restart at the end.
A Docker relay stays in Docker and moves to the setup's own copy in
`/opt/hollow-relay-docker`. The containers are built there first (with the
forwarder, that takes up to an hour or two), then the switch costs about half a
minute of downtime, and as on every container restart, waiting messages are
lost. The old containers stop, and their volumes are copied, never changed.

Taking over always applies the same hardening as a new install. Before anything
changes you see **How this machine is set up** (SSH, firewall, swap, journal,
core dumps, clock, fail2ban) and **What take over does**. The SSH key flow above
is offered too. Afterwards, **Taken over** lists what it left in place for you to
remove when you like, such as the old relay program, the old `hollow` account or
a DuckDNS line in a crontab.

**Leave it alone.** Nothing about the relay changes. The setup still shows how
the machine is set up and asks **Make this machine safer?** with three answers:
all of the changes, all but the firewall (recommended when the firewall would
close a port some other program on the machine uses), or none. It also offers
the SSH key flow. You can take the relay over later by running the setup again.

If the setup can't take the relay over safely, for example when two relays run
on the machine or the relay listens on a port other than 443, it says why under
**I cannot take it over** and goes on as if you had chosen to leave it alone.

## Setting it up by hand

The setup is the way we recommend and test. These two paths are for people who
want to do each step themselves. Both use the files in the repository, so they
end up close to what the setup builds.

### Path A: Docker by hand

Install Docker Engine with its compose plugin from Docker's own apt repository,
as [docs.docker.com/engine/install](https://docs.docker.com/engine/install/)
describes for Ubuntu and Debian. Debian 12's own packages lack the
`docker compose` plugin. Then add yourself to the `docker` group, log out and back in,
and check that `docker run --rm hello-world` works.

Harden the host. Pass `--http yes` instead of `no` for a bare IP or your own
domain, `--turn no` without TURN and `--forwarder yes` with the forwarder:

```bash
cd HOLLOW/relay-uws
sudo sh deploy/harden-host.sh --http no --turn yes --forwarder no --no-ssh
```

`--no-ssh` leaves SSH as it is. To turn password logins off, run
`sudo bash install.sh` in `HOLLOW/relay-uws` once the relay runs and choose
**Leave it alone**. It offers the [SSH key flow](#ssh-keys), which turns passwords off only
after it has seen you log in with your key. Add `--print` to see what
harden-host.sh would do first.

Fill in the settings:

```bash
cp .env.example .env
nano .env
```

| Field | What to put in it |
|---|---|
| `RELAY_HOST` | The address people type into the app. Your DuckDNS name, the server's IPv4 address or your own domain. No port. |
| `DUCKDNS_TOKEN` | Only for a DuckDNS name. The token from the DuckDNS page. |
| `DUCKDNS_IP` | Usually empty. Pins the DuckDNS name to another address, for example a test machine people reach only on your own network. |
| `TURN_SECRET` | Run `openssl rand -hex 32` and paste the result. Leave it empty without TURN. |
| `COMPOSE_PROFILES` | `turn` runs coturn. `turn,forwarder` adds the media forwarder. Empty runs neither. |
| `FORWARDER_PEER_ID` | The forwarder's id. See [the forwarder under Docker](#the-forwarder-under-docker). |
| `FWD_LICENSE_KEY` | Only for a members-only relay with the forwarder: a key from `keys/keys.json` that the forwarder connects with. |
| `PUBLIC_IP`, `PUBLIC_IPV6`, `LOCAL_IP` | Leave empty and they are found at start. Behind a router or a cloud provider's NAT, set `PUBLIC_IP` to the public address. Set `PUBLIC_IPV6` only if the machine has one. |
| `HOLLOW_MEM_LIMIT` | Optional. The machine's memory, like `2048m`. No container may use more, and none may swap. |
| `OWN_CERT_DIR` | Advanced. A directory holding a `fullchain.pem` and `privkey.pem` you obtain and renew yourself. Then certbot is not used at all. |
| `SESSION_GRACE_SECS` | Optional, 30 to 600. Empty means 120. See [Dropped connections](#dropped-connections). |
| `HOLLOW_CONN_RATE_EXEMPT` | Optional, best left empty. See [Connection limits](#connection-limits). |
| `CONN_LIMIT_IPV4` and the other limits | Optional, best left empty. See [Connection limits](#connection-limits). |
| `PUBLIC_STATS` | Optional. `off` hides the online count and the traffic figures. See [Public stats](#public-stats). |
| `HOLLOW_CAKE`, `HOLLOW_CAKE_MBIT` | `on` and the bandwidth of the host's CAKE queue, which the stats page shows. See [Fair share of the upload](#fair-share-of-the-upload). |
| `HOLLOW_SEND_BUDGET_BYTES` | Optional, best left empty. See [Send budget](#send-budget). |
| `CERTBOT_STAGING` | Troubleshooting. `1` uses the Let's Encrypt staging service, see [Troubleshooting](#troubleshooting). |

With TURN, add the TURN port lock before the first start (see
[TURN](#turn-for-calls)). Under Docker coturn runs as the account `65999`, which no account on the
machine itself uses:

```bash
sudo install -m 0755 deploy/turn-port-lock.sh /usr/local/sbin/hollow-turn-port-lock
sudo install -m 0644 deploy/hollow-turn-port-lock.service deploy/hollow-turn-port-lock-refresh.service deploy/hollow-turn-port-lock-refresh.timer /etc/systemd/system/
sudo install -D -m 0600 deploy/turn-port-lock.env.example /etc/hollow-relay/turn-port-lock.env
sudo nano /etc/hollow-relay/turn-port-lock.env    # TURN_USER=65999, TURN_PEERS=your public IPv4 (and IPv6), FORWARDER_PORTS= empty without the forwarder
sudo systemctl daemon-reload
sudo systemctl enable --now hollow-turn-port-lock hollow-turn-port-lock-refresh.timer
```

The lock starts before Docker does, and its timer loads it again every minute.

Start it:

```bash
docker compose up -d
```

The first run builds the relay and the push sender from source, which takes a
few minutes (the forwarder takes up to an hour or two). Then `certbot-init` gets
the certificate, and only then does the relay start. If the certificate fails,
the whole stack stops there and says why, instead of leaving a relay that cannot
serve.

Check it with `docker compose ps`. `certbot-init` has done its job and says
`Exited (0)`. `relay` says `Up ... (healthy)`, and `push`, `certbot-renew`,
`coturn` and `forwarder` (when you run them) say `Up`. `duckdns` says `Up` with a
DuckDNS name and has exited otherwise. A relay that says `Restarting`, or an
`Exited (1)` anywhere, means something went wrong;
[Troubleshooting](#troubleshooting) covers the usual causes.

The relay, push, coturn and forwarder containers run as unprivileged users with
no Linux capabilities and a read-only file system, so a bug in one of them stays
inside its container. The containers start again after a reboot on their own, so
you need no extra service for that.

#### The forwarder under Docker

With `COMPOSE_PROFILES=turn,forwarder`, start the stack once so the forwarder
makes its identity, then read its id:

```bash
docker compose up -d
docker compose run --rm --no-deps forwarder --print-peer-id
```

It prints a line starting with `12D3KooW`. If it prints an error instead, the
forwarder hasn't finished its first start yet; wait a few seconds and run it
again. Put the id in `.env` as `FORWARDER_PEER_ID`, then run
`docker compose up -d` again so the relay tells the apps about it.

#### Updating by hand under Docker

```bash
cd HOLLOW
git pull --recurse-submodules
cd relay-uws
docker compose build
docker compose up -d
```

This restarts the relay, which drops what it holds in memory, so pick a quiet
moment.

### Path B: systemd by hand

This is the layout the setup builds, done step by step. The repository's units
in `relay-uws/deploy/` are the official relay's own, and two of them call
scripts from `/usr/local/lib/hollow-relay/installer`, so the first step puts a
copy there. Run everything from your clone, as an account that can use `sudo`.

**1. Harden the host.** As in [path A](#path-a-docker-by-hand):

```bash
cd HOLLOW
sudo sh relay-uws/deploy/harden-host.sh --http no --turn yes --forwarder no --no-ssh
```

**2. Build and install the relay.**

```bash
sudo apt install build-essential cmake pkg-config libssl-dev libsodium-dev zlib1g-dev perl
cmake -S relay-uws -B relay-uws/build -DCMAKE_BUILD_TYPE=Release
cmake --build relay-uws/build -j"$(nproc)"
sudo install -m 0755 relay-uws/build/hollow-relay /usr/local/bin/hollow-relay
sudo install -d -m 0755 /usr/local/lib/hollow-relay/installer
sudo cp -R relay-uws/deploy /usr/local/lib/hollow-relay/installer/
```

**3. Accounts and settings.** Each service gets an account that can't log in.
Make the ones you need (`hollow-turn` for TURN, `hollow-push` for push,
`hollow-fwd` for the forwarder, `hollow-ddns` for DuckDNS) the same way:

```bash
sudo useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin hollow-relay
sudo install -d -m 0750 -o root -g hollow-relay /etc/hollow-relay
sudo install -m 0600 /dev/null /etc/hollow-relay/relay.env
sudo nano /etc/hollow-relay/relay.env
```

`relay.env` holds the relay's two secrets. Run `openssl rand -hex 32` once for
each:

```
TURN_SECRET=the-first-value
HOLLOW_PUSH_TOKEN=the-second-value
```

Leave a value empty for a part you don't run. The optional settings
`PUBLIC_STATS`, `HOLLOW_CONN_RATE_EXEMPT`, `HOLLOW_SEND_BUDGET_BYTES` and the
[connection limits](#connection-limits) go in this file too. systemd reads it as root when it starts the relay. Never move these values to an `Environment=` line,
because every account on the machine can read those with `systemctl show`.

**4. DuckDNS, for a DuckDNS name only.** The token goes in a file only root
reads. The timer keeps the name pointing at the server every five minutes:

```bash
sudo install -d -m 0700 /etc/hollow-duckdns
sudo install -m 0600 /dev/null /etc/hollow-duckdns/duckdns.env
sudo nano /etc/hollow-duckdns/duckdns.env    # DUCKDNS_TOKEN=..., RELAY_HOST=myrelay.duckdns.org, DUCKDNS_IP= (empty)
sudo cp relay-uws/deploy/hollow-duckdns.service relay-uws/deploy/hollow-duckdns.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hollow-duckdns.timer
```

**5. The certificate.** For a DuckDNS name or your own domain, the
distribution's certbot is enough (`sudo apt install certbot`). An IP address
needs certbot 5.3 or newer, which `sudo snap install --classic certbot` gives you
where snap is available. The deploy hook hands each renewed certificate to the relay and to
coturn:

```bash
sudo install -D -m 0755 relay-uws/deploy/certbot/host-deploy-hook.sh /etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh
sudo env RELAY_HOST=myrelay.duckdns.org CERT_INSTALL_HOOK=/etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh \
    sh /usr/local/lib/hollow-relay/installer/deploy/certbot/issue.sh
```

`issue.sh` picks the method from the address. A DuckDNS name goes through DNS
with the token from step 4, so port 80 stays closed. An IP address or a domain
is checked over port 80. Run it from the copy in `/usr/local/lib`, because
certbot's renewals call the DuckDNS hooks from the same place. certbot's own
timer renews the certificate, and the relay picks up a renewed one within a
minute without restarting.

**6. The relay service.**

```bash
sudo cp relay-uws/deploy/hollow-relay.service /etc/systemd/system/
sudo nano /etc/systemd/system/hollow-relay.service
```

On the `ExecStart` lines, change `--domain relay.anonlisten.com` to your
address, and either put your forwarder's id after `--forwarder-peer-id` or delete
that line (and the `\` at the end of the line above it). To change the wait for
dropped connections, add `--session-grace-secs` and a number. Keep every other
line. `NotifyAccess` and `FileDescriptorStoreMax` carry the offline messages
across a restart, `LimitCORE=0` keeps a crash from writing them to the disk, and
the block below them is the relay's sandbox. Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now hollow-relay
```

For a members-only relay, `/etc/hollow-relay/keys.json` is owned by root with the
group `hollow-relay` and mode `0640`. See
[Members-only relay](#members-only-relay).

**7. TURN.** Install coturn, and switch off the service the package ships with,
which would take the ports and run without a sandbox:

```bash
sudo apt install coturn
sudo systemctl disable --now coturn
sudo systemctl mask coturn
sudo install -d -m 0750 -o root -g hollow-turn /etc/hollow-turn
sudo install -m 0600 /dev/null /etc/hollow-turn/turn.env
sudo nano /etc/hollow-turn/turn.env    # TURN_SECRET= (the same value), PUBLIC_IP=, PUBLIC_IPV6=, LOCAL_IP=
sudo /etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh
sudo install -m 0755 relay-uws/deploy/turn-port-lock.sh /usr/local/sbin/hollow-turn-port-lock
sudo install -m 0644 relay-uws/deploy/hollow-turn-port-lock.service relay-uws/deploy/hollow-turn-port-lock-refresh.service relay-uws/deploy/hollow-turn-port-lock-refresh.timer /etc/systemd/system/
sudo install -D -m 0600 relay-uws/deploy/turn-port-lock.env.example /etc/hollow-relay/turn-port-lock.env
sudo nano /etc/hollow-relay/turn-port-lock.env    # TURN_USER=hollow-turn, TURN_PEERS=, FORWARDER_PORTS=
sudo cp relay-uws/deploy/hollow-coturn.service /etc/systemd/system/
sudo install -D -m 0644 relay-uws/deploy/coturn-port-lock.conf /etc/systemd/system/hollow-coturn.service.d/hollow-port-lock.conf
sudo systemctl daemon-reload
sudo systemctl enable --now hollow-turn-port-lock hollow-turn-port-lock-refresh.timer
sudo systemctl enable --now hollow-coturn
```

Set `PUBLIC_IP` to the server's public IPv4. Behind a router, also set
`LOCAL_IP` to the machine's own address, because coturn's sandbox can't look it
up. Running the deploy hook once gives coturn its copy of the certificate.

In `turn-port-lock.env`, `TURN_PEERS` takes the same public IPv4, the
machine's own address too when it sits behind a router, and the IPv6 if it has
one. `FORWARDER_PORTS` stays empty until you add the forwarder in step 9, then
`40000-40199`. The file `coturn-port-lock.conf` keeps
coturn from starting without the lock. After you change an address or a range,
run `sudo systemctl restart hollow-turn-port-lock`.

Addresses set by hand stay as you set them. If the server's public address
changes, edit `turn.env`, `turn-port-lock.env` and `forwarder.toml` again and
restart coturn, the lock and the forwarder. The setup can take over a relay set
up by hand (see [Already running a relay?](#already-running-a-relay)), and then
it follows a new address for you.

**8. Push for Android.** The push sender needs Node.js 22 or newer, from
[NodeSource](https://github.com/nodesource/distributions) or
[nodejs.org](https://nodejs.org), since the distribution packages are usually
older. Copy it into place and give it the push token, under the name
`PUSH_TOKEN`:

```bash
sudo install -d -m 0755 /opt/hollow-push
sudo cp push-sidecar/index.js push-sidecar/fcm.js push-sidecar/unifiedpush.js push-sidecar/package.json push-sidecar/package-lock.json /opt/hollow-push/
cd /opt/hollow-push && sudo npm ci --omit=optional --omit=dev --ignore-scripts --no-audit --no-fund && cd -
sudo install -d -m 0700 /etc/hollow-push
sudo install -m 0600 /dev/null /etc/hollow-push/push.env
sudo nano /etc/hollow-push/push.env    # PUSH_TOKEN=the-second-value
sudo cp push-sidecar/hollow-push.service /etc/systemd/system/
sudo nano /etc/systemd/system/hollow-push.service
```

In the unit, delete the `LoadCredential=` line and the
`Environment=FIREBASE_KEY_PATH=` line. Those load Google's credential, which
only the official relay holds. The unit blocks private addresses, so if
`/etc/resolv.conf` names a private nameserver (common on Debian and at cloud
providers), add a line like `IPAddressAllow=10.0.0.2/32` with that address under
the existing one. Then `sudo systemctl daemon-reload` and
`sudo systemctl enable --now hollow-push`. The relay reaches the sender on
`127.0.0.1:3001`, so no port opens to the outside.

**9. The media forwarder.** Build it with Rust ([rustup.rs](https://rustup.rs)).
This takes up to an hour or two on a small machine:

```bash
cargo build --release --locked --features forwarder --bin hollow-forwarder --manifest-path rust/hollow_core/Cargo.toml
sudo install -m 0755 rust/hollow_core/target/release/hollow-forwarder /usr/local/bin/hollow-forwarder
sudo install -d -m 0750 -o root -g hollow-fwd /etc/hollow-forwarder
sudo install -m 0640 -o root -g hollow-fwd relay-uws/deploy/forwarder.toml.example /etc/hollow-forwarder/forwarder.toml
sudo nano /etc/hollow-forwarder/forwarder.toml    # relay_domain and public_ip
sudo cp relay-uws/deploy/hollow-forwarder.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hollow-forwarder
sudo runuser -u hollow-fwd -- /usr/local/bin/hollow-forwarder --config /etc/hollow-forwarder/forwarder.toml --print-peer-id
```

If it prints an error, the forwarder hasn't finished its first start; wait a
few seconds and run it again. Put the printed id after `--forwarder-peer-id` in
the relay's unit (step 6), then `sudo systemctl daemon-reload && sudo systemctl restart hollow-relay`. Open
the forwarder's UDP ports with `--forwarder yes` in step 1. On a members-only
relay, the forwarder needs a key of its own. Add one to `keys.json` and put it in
`/etc/hollow-forwarder/forwarder.env` (root, `0600`) as
`HOLLOW_FWD_LICENSE_KEY=...`.

**10. Check it** with `sudo bash relay-uws/deploy/check-host.sh`, as in
[Check it](#check-it).

**Updating by hand.** Pull the repository, build again, install the new program
and the scripts, and restart:

```bash
cd HOLLOW
git pull --recurse-submodules
cmake --build relay-uws/build -j"$(nproc)"
sudo install -m 0755 relay-uws/build/hollow-relay /usr/local/bin/hollow-relay
sudo cp -R relay-uws/deploy /usr/local/lib/hollow-relay/installer/
sudo systemctl restart hollow-relay
```

Messages waiting for offline people survive this restart, and connected apps
pick up where they were within about 10 seconds. If `push-sidecar` changed, copy
its files again, run the `npm ci` line again and restart `hollow-push`.

## Optional parts

### TURN for calls

TURN gets a call through when both people are behind strict networks and no
direct route exists, which happens with some mobile carriers and office
networks. The call's audio and video then flow through your server, so those
calls cost its bandwidth. It opens TCP and UDP ports 3478 and 5349, and UDP ports
49152 to 65535.

Without TURN, calls need a direct route between the two people, which works
most of the time. When a call fails for that reason, the app says so, and
Settings > Network marks the relay with **No TURN server**. Someone who turned
on **Always relay calls** (Settings > Security) can't call at all on a relay
without TURN, and the app tells them before the call starts. Hollow Share never
used TURN, so it is unaffected.

TURN may relay only to this machine's own address, but coturn has no setting
for which ports on it a call may reach. So whenever TURN is on, the setup adds
the TURN port lock, `deploy/turn-port-lock.sh`. It adds a firewall rule that
keeps TURN to coturn's relay ports and the forwarder's, and reserves those ports
from the moment the machine starts, so no other program's connections land in
them. Ports you reserved yourself stay reserved. coturn doesn't start without the lock, and a timer loads it again every
minute in case anything clears the firewall. Keep other services out of ports
49152 to 65535. A program that was already running when you turned TURN on can
still hold a port there. Desktop systems such as Linux Mint run avahi-daemon,
which finds devices on the local network, and the setup restarts it so it picks
another port. For anything else, the host checks name the program and its process
number, and for a system service the command that restarts it. With the lock in
place, a Hollow app running on the relay machine itself can't use TURN, because
coturn's replies to it are dropped, though its direct connections still work.
The host checks look for the lock.

The relay tells the apps it has TURN when `TURN_SECRET` is set. A secret with no
coturn running is the one combination to avoid, because the app would then hand
out credentials for a server that isn't there. The setup always keeps the two
together.

### Fair share of the upload

When the server's upload is full, one person pulling a large file or watching a
busy screen share can slow everyone else down. So the setup puts CAKE, a queue
built into the Linux kernel, on the network card the default route leaves
through. Once the upload is full, CAKE gives every address the relay sends to an
equal share. While the line has room, it holds nobody back.

CAKE can only share when it is the slowest point on the way out, so it runs a
little under the line's real speed. The setup suggests 90 percent of the speed
the card reports, or 900 Mbit/s when the card reports none, which is common on
virtual servers. If you measured your upload, or your provider sells you less,
use 90 percent of that figure; behind a home router, the figure is your
internet upload speed. Too high a number does no harm, but then CAKE never
shares anything. Too low a number slows the relay down for everyone.

Turn it off only when something in front of the server already shares the line
fairly, such as your provider or a router of your own. The host checks then
report it as off by your choice.

Some cloud kernels leave CAKE out. The setup says so and carries on without it,
and the host checks fail until it is there. On Ubuntu,
`sudo apt install linux-modules-extra-$(uname -r)` adds it. Then run
`sudo hollow-relay-setup` again.

By hand, the settings go in `/etc/hollow-relay/cake.env`, a file only root
reads, and the top of `deploy/hollow-cake.service` shows how to install it. The
relay reads the same file and shows the number on its stats page as
`bandwidth_cap_mbps`. Under Docker, CAKE still sits on the host, never in a
container. Install the unit on the host, then put `HOLLOW_CAKE=on` and the same
number in `HOLLOW_CAKE_MBIT` in `.env`.

### Push notifications on phones

A phone that is asleep has to be woken when a message arrives. The wake-up
carries no message content, only a note that something is waiting, and the app
then collects the message from the relay itself.

**Android.** Your relay sends wake-ups through UnifiedPush, which needs no
accounts or keys. You don't need an ntfy server of your own. The ntfy app uses
the public server at ntfy.sh by default. Each person with an Android phone does
this once:

1. Install [ntfy](https://ntfy.sh) from the Play Store or F-Droid, and open it
   once.
2. In Hollow on the phone, go to Settings > Notifications > Push delivery >
   Wake-up service and tap **ntfy**. This section is only in the Android app.

The wake-up is encrypted to that phone before it leaves your relay, so the ntfy
server only sees that some app got a push. People who leave Wake-up service on
Google get no wake-ups on your relay, because only the official relay holds
Hollow's Google credentials. For the same reason, **Fall back to Google** can't
wake a phone on your relay when ntfy stops working.

Running your own ntfy server is optional, and ntfy's own guide covers it at
[docs.ntfy.sh/install](https://docs.ntfy.sh/install/). The push sender only
sends to public addresses. If your ntfy server sits on the same private network
as the relay, the Docker setup can allow it with `UNIFIEDPUSH_ALLOW_PRIVATE=1`
in the `push` service's environment.

**iPhone.** iPhone notifications don't work on a self-hosted relay. Apple only
delivers notifications signed with the key from Hollow's Apple Developer
account. That key stays on the official relay, because anyone who has it could
send notifications pretending to be Hollow. iPhones still get new messages while
Hollow is open.

### The media forwarder

When someone shares their screen with several viewers, the forwarder takes one
copy of the stream and sends it on to each viewer, so the person sharing uploads
it only once. It carries only encrypted media and holds no keys, so it cannot see
the screen.

It costs your server upload for every viewer, roughly 1 to 3 Mbit/s each, and
opens UDP ports 40000 to 40199. We recommend it if the server has a fast
connection and your group shares screens. Without it, screen shares still work:
a viewer's own app can pass the stream on, or the person sharing sends a copy to
each viewer.

The forwarder has an identity of its own, kept in `forwarder.key` and
`forwarder.db`. Viewers' apps learn it, so keep it across reinstalls (see
[Backups](#backups)). A new identity means every viewer's app has to learn it
again.

### Members-only relay

By default anyone who knows your address can connect, the same as on the
official relay. Since only the people you give the address to will find your
relay, most groups leave it that way. A members-only relay asks for an access
key the first time someone connects, on a screen titled **This relay needs an
access key**.

The setup makes the keys for you and shows them at the end. Run it again to see
them, add one or remove one. One key admits up to 5 devices at a time, so a
person's phone and desktop share one key. Removing a key disconnects whoever uses
it within 30 seconds.

By hand, the keys live in `keys.json` (`relay-uws/keys/keys.json` under Docker,
`/etc/hollow-relay/keys.json` under systemd):

```json
{
  "enabled": true,
  "keys": ["AB12-CD32-BA30-LJ50", "QQ44-RT19-ZZ08-MN71"]
}
```

A key is four groups of four characters, each `A-Z` or `0-9`, with hyphens
between them. The relay reads the file every 30 seconds, so changes need no
restart. Under Docker the file is mounted read-only and is gitignored, so you
can't commit it by accident.

### Public stats

Your relay serves a small stats page at `/server-stats`, open to anyone who
knows the address. It shows how many people are online, how much traffic the
relay carries and how much memory it uses, and the app's relay card shows the
same figures.

Turned off, the page leaves out the online count and the traffic, rounds the
memory to whole percent, and the relay card shows only memory. On a relay for a
small group, the online count can tell an outsider when your friends are around,
so turn it off if that matters to you. The setup asks. By hand, it is
`PUBLIC_STATS=off` in `.env` under Docker or in `/etc/hollow-relay/relay.env`
under systemd. Empty means on, and any value the relay doesn't know counts as
off.

### Dropped connections

Phones lose signal, laptops go to sleep and Wi-Fi hands over to mobile data. When
someone's connection drops, the relay keeps their place for a while: the rooms
they were in, and everything sent to them since. When their app comes back in
time, it picks up where it left off and misses nothing. Their friends see them go
offline as soon as the connection is gone, as before.

The wait is 120 seconds unless you change it, anything from 30 to 600. A longer
wait covers longer gaps, like a train tunnel, but holds more memory while people
are away. Each dropped connection keeps at most 8 MB, and everything the relay
holds for absent people shares one 512 MB limit.

When you restart or update the relay, it first tells every connected app to come
back 2 to 10 seconds later, each at a different moment, so they don't all
reconnect at once.

### Blocking a server, an identity or an address

A relay can refuse three things and nothing finer: a server or a meeting, by its
id; a person's identity, with its devices; and a network address. You list them
in one file. The relay reads it again within a couple of seconds of a change, with
no restart, and it deletes nothing on anyone's device.

The file is `/etc/hollow-relay/denylist.json` under systemd and
`relay-uws/keys/denylist.json` under Docker. The setup writes an empty one:

```json
{
  "version": 1,
  "servers": [],
  "identities": [],
  "networks": []
}
```

The setup changes it for you. It checks the result the way the relay reads it,
then writes the whole file in one step and keeps its owner and permissions:

```bash
sudo hollow-relay-setup --deny add server 3f2a0b1c2d3e4f5061728394a5b6c7d8e9f00112 N-2026-014
sudo hollow-relay-setup --deny add identity 12D3KooWAx1yGq5n7mCgS2kS8wYk7c2XQGtB4V3pX8XnZfnwq7mD
sudo hollow-relay-setup --deny add network 203.0.113.7
sudo hollow-relay-setup --deny remove server 3f2a0b1c2d3e4f5061728394a5b6c7d8e9f00112
sudo hollow-relay-setup --deny check
```

What each list takes:

- **servers**: a server's id, the 40 (or, for older servers, 32) hexadecimal
  characters from its invite link. A meeting is `conf:` followed by its id. To the
  relay, an older server's 32-character id looks the same as the code of a direct
  message between two people or of one person's own devices. Such an entry blocks
  whatever room has that code, so list one only when you are sure it names the
  server. The check warns about each one.
- **identities**: a person's identity id, which starts with `12D3KooW`. The relay
  refuses that key at once, and each of the identity's devices once any of them
  has shown the relay its device list, which the app does every time it connects.
  A device stays refused until you remove the identity, even if a later list
  leaves it out.
- **networks**: an IPv4 address, or an IPv6 address, which stands for its whole
  `/64` (write any address in it, or the block as `2001:db8:1:2::/64`). Nothing
  wider.

By hand, an entry is either the bare text or an object with `id` (`ip` for a
network). An object may carry `ref`, a pointer into your own record of the notice
you acted on; the relay reads past it and never keeps it. Keep reasons, names and
evidence off the server, which can be seized or broken into. Before you save, check
the file the way the relay reads it:

```bash
hollow-relay --check-denylist /etc/hollow-relay/denylist.json
```

One entry the relay can't read makes it ignore the whole file and keep the list
it already has, so a typo never lifts a block quietly. The same goes for a file
that is missing, even across a restart: the relay keeps the list it held and says
so in its log, and the host check fails until the file is back. To lift every
block, write the empty file above.

What people see:

- The members of a blocked server or meeting see that it is not available on this
  relay. Their messages, files and the server itself stay on their devices, and
  their direct messages and other servers keep working.
- A blocked identity's app, on every one of its devices, says this relay does not
  accept the account.
- People behind a blocked address are told that this relay does not accept
  connections from their network.

The apps ask again on their own every few hours, and when someone chooses to try
again, so lifting a block needs nothing from them.

The relay logs no refusal and no entry, only the counts each time it loads the
list. It keeps the list in memory and hands it to the next process across a
restart, like the rest of what it holds. `/server-stats` shows how many entries of
each kind there are only if you set `PUBLIC_DENY_COUNTS=on` beside `PUBLIC_STATS`;
it is off by default.

What a block does not stop:

- Anything already on the members' devices.
- Members moving to another relay, such as one of their own.
- What is already connected directly between devices: calls and voice rooms in
  progress and file transfers under way. TURN credentials already handed out last
  up to an hour.
- A server founded again under a new id, or a person who makes a new identity.
- A device of a blocked identity that the relay has not seen yet, until its first
  connection shows its device list. A modified app that never shows it is never
  recognised.
- A device of a blocked identity that has left its device list, once that
  identity has shown the relay more than 512 newer devices. The relay remembers
  that many per identity and lets the oldest go first.
- A modified app passing a blocked server's encrypted traffic through other rooms,
  such as direct messages, which the relay cannot tell apart. The Hollow app stops
  sending it.
- A VPN or a new address. One address can also stand for many people, on a mobile
  network or in an office, and blocking it refuses everyone behind it.
- Pages a guest already loaded in a browser, and other relays.

Anyone who has a server's id can find out that your relay blocks it, because a
join is answered with "not available". The relay never scans or matches content:
it acts only on the ids you write down.

## Connect the app

On desktop, open Settings, then Network. Under Relay, choose **Change**, then
**Add a relay**, type your relay's address and choose **Add**. Then choose
**Switch and restart**. The app comes back connected to your relay.

On a phone it is the same, except the button says **Switch and close**. Open
Hollow again and it connects to your relay.

On a fresh install, before an identity exists, the welcome screen has a button
showing the relay's address (`relay.anonlisten.com`). It opens a **Relay
address** field. Anyone joining your network can type your address there and
never touch the official relay at all.

Invites made on your relay carry its address, so people already on another
relay get the switch question described under [The island rule](#the-island-rule).

## Check it

From your own computer, not the server:

```bash
curl https://myrelay.duckdns.org/health
curl https://myrelay.duckdns.org/relay-status
```

`/health` answers `{"status":"ok","service":"hollow-signaling"}`. `/relay-status`
tells the app what this relay offers:

- `license_required`: whether members need an access key.
- `version`: the relay's version.
- `turn`: whether the relay can hand out TURN credentials for calls.
- `forwarder`: whether a media forwarder is set up.

If both answer without a certificate warning, your relay is live.

On the server, the host checks look at each service's account, who can read its
secrets, how tight its sandbox is, whether anything could reach the disk, whether
TURN and the forwarder use the address your relay's name points at, and SSH. They change nothing. The setup runs them at the end and from
**Check the machine again**. To run them yourself:

```bash
sudo bash /usr/local/lib/hollow-relay/installer/deploy/check-host.sh
```

(or `sudo bash relay-uws/deploy/check-host.sh` from your clone). Every line
should say `ok`. SSH password logins that are still on show as a `FAIL`. Linux
Mint lets every account run a few of its own maintenance tools with `sudo`. The
checks accept exactly those, and only for a service whose sandbox keeps it from
using `sudo` at all, while no `sudo` setting changes what those tools run. Any other `sudo` rule fails, and the line names it and the
file it comes from. On a
Docker setup the services aren't under systemd, so the checks cover the machine
itself, and the containers' limits come from the compose file.

## Day to day

### Updates

With the ready-made programs, `sudo hollow-relay-setup` tells you on its status
screen when a newer signed release is out, and **Update to version …** installs
it. The relay restarts once, and messages waiting for offline people carry across
the restart. If the new version doesn't start, the previous one goes back on by
itself.

With a build from source or Docker, pull your copy of the repository and run the
setup from it:

```bash
cd HOLLOW
git pull --recurse-submodules
sudo bash relay-uws/install.sh
```

The status screen then offers the rebuild. A Docker rebuild restarts the relay
container, which drops what it holds in memory.

System packages update themselves through the automatic security updates the
setup turned on. A kernel update still needs a reboot now and then, and a reboot
empties everything the relay holds in memory, since none of it is ever written
to the disk.

### Backups

The relay keeps almost nothing worth backing up, and that is the point. Copy
these somewhere safe, off the server:

| What | Full setup | Docker |
|---|---|---|
| The report counts | `/var/lib/hollow-relay/reports.json` | the `hollow-relay_data` volume |
| The forwarder's identity | `/var/lib/hollow-forwarder/forwarder.key` and `forwarder.db` | the `hollow-relay_fwd-data` volume |
| Your SSH key | `~/.ssh/id_ed25519` on your own computer | the same |

A Docker stack you started by hand names its volumes after its folder instead,
`relay-uws_data` and `relay-uws_fwd-data`. The members-only keys can always be
shown again by the setup. The certificate can always be asked for again, and the
address stays the same as long as you keep your DuckDNS account or domain.

### Removing the relay

`sudo hollow-relay-setup`, then **Remove the relay**. It removes the relay and
every service the setup added, with their accounts, settings and secrets, the
programs and the firewall rules for the relay's ports. It keeps the hardening,
the packages it installed and your copy of the repository. It asks whether to
keep the forwarder's identity and the report counts, and we recommend yes. Messages
waiting for offline people are lost.

In the full setup the kept files go to `/root/hollow-relay-backup`, and a later
install picks them up again. The certificate stays in `/etc/letsencrypt` with its
renewal turned off, and `sudo certbot delete --cert-name relay` removes it. The
Docker setup keeps its volumes instead, the certificate's included.

## Troubleshooting

**The setup stopped.** It shows the command that failed and its last lines.
Every step checks what is already done, so after fixing the cause, run it again.
If the system's automatic updates hold the package lock on a new server, the
setup waits for them for up to 15 minutes and says so.

**The certificate failed.** The setup shows certbot's own lines. The usual
causes are DNS that doesn't point at this server yet, port 80 blocked by a
provider firewall or a router when you use an IP address or your own domain, or
a DuckDNS token pasted with a character missing. Let's Encrypt also limits how
often you may ask for the same certificate. While you work out a problem, use its
staging service: `staging=yes` in an [answer file](#without-anyone-at-the-keyboard),
or under Docker `CERTBOT_STAGING=1` in `.env` and
`docker compose up -d --force-recreate certbot-init`. The app doesn't trust
staging certificates, so switch back once the rest works. If the setup installed
the relay, run it again and choose **Change a setting**, then the certificate. If
you run Docker by hand, remove `CERTBOT_STAGING` from `.env` and run
`docker compose up -d --force-recreate certbot-init`. Under Docker,
`docker compose logs certbot-init` shows what went wrong.

**The relay doesn't start or says unhealthy.** Read its log. The full setup:

```bash
sudo journalctl -u hollow-relay -e
```

For the setup's Docker stack, run `sudo docker compose -p hollow-relay logs relay`,
and for one you started by hand, `docker compose logs relay`. A relay that can't read its
certificate stops at once and says so. Under Docker, check that `certbot-init`
exited 0 and that `docker compose exec relay ls -l /certs` shows both files owned
by `999`. Under systemd, check that `/etc/hollow-relay/` holds both files, owned
by root with the group `hollow-relay`.

The journal lives in memory for one hour, so read it soon after the problem.

**The app says Offline.** Try `curl https://YOUR_ADDRESS/health` from somewhere
other than the server. If that fails, it is the firewall, the router or the
address. If it works and the app still won't connect, check the clock on the
server with `timedatectl`. Logins carry a signed timestamp with a 60 second
window, so a clock that is minutes out turns away every login while everything
else looks fine.

**Some members connect and others can't.** The app signs the exact address it
connected to, and the relay accepts only its own address (`RELAY_HOST`, or
`--domain` under systemd). Everyone has to type that address. A second name that
points at the same server won't sign in.

**The app says the relay has no TURN server.** TURN is off, or coturn isn't
running. Check `systemctl status hollow-coturn`, or `docker compose ps` and
`COMPOSE_PROFILES=turn` in `.env`. coturn keeps no log at all, because a TURN log
records who called and from which address. A coturn problem therefore shows up
as a service that keeps restarting rather than as a message. To see what it
complains about, remove the `--no-stdout-log` line from
`deploy/coturn/coturn-start.sh` (under the full setup, the copy in
`/usr/local/lib/hollow-relay/installer`), restart coturn, read its log, and put
the line back.

**Calls fail after the server's public address changed.** With a DuckDNS name or
your own domain, TURN and the forwarder follow a new address within minutes, once
it proves to be this server (see [A new address](#a-new-address)). If they don't,
run `sudo bash /usr/local/lib/hollow-relay/installer/deploy/check-host.sh` and
read its **Public address** lines, which name the address TURN uses and where
your name points. `sudo journalctl -u hollow-address-follow` says why a new
address wasn't taken. The usual reasons: a router that can't connect to its own
public address from inside, a router or Pi-hole that answers your name with a
LAN address, or a name that points at a proxy in front of the server rather than
at the server itself. Then run `sudo hollow-relay-setup`, choose
**Change a setting**, then the address. With a bare IP address nothing follows,
so members have to type the new address. If you set up Docker by hand, put the
new address in `PUBLIC_IP` in `.env` and run `docker compose up -d`.

**SSH password logins stayed on.** The setup turns them off only after a key
login you confirmed, and the summary says which step didn't happen. Run
`sudo hollow-relay-setup` and choose **Turn SSH password logins off** to try
again.

## Reference

### Ports

| Port | Protocol | Needed by | When |
|---|---|---|---|
| 22 (or your SSH port) | TCP | You, over SSH | Always |
| 443 | TCP | Every member's app | Always |
| 80 | TCP | Let's Encrypt | Only for a bare IP address or your own domain. Not with DuckDNS. |
| 3478 | TCP and UDP | Calls through TURN | Only with TURN |
| 5349 | TCP and UDP | Calls through TURN over TLS | Only with TURN |
| 49152 to 65535 | UDP | Call media through TURN | Only with TURN |
| 40000 to 40199 | UDP | Screen shares through the forwarder | Only with the forwarder |

The setup opens exactly these and finds the port your SSH server really listens
on, so the firewall never shuts you out. If your provider or your router has its
own firewall in front of the server, open them there too.

### Where things live in the full setup

| What | Where |
|---|---|
| The programs | `/usr/local/bin/hollow-relay`, `/usr/local/bin/hollow-forwarder` |
| The setup's own copy | `/usr/local/lib/hollow-relay/installer`, run as `sudo hollow-relay-setup` |
| Your answers, no secrets | `/etc/hollow-relay/install.conf` |
| Relay settings, keys, the denylist and secrets | `/etc/hollow-relay/` |
| TURN, push, forwarder, DuckDNS settings | `/etc/hollow-turn/`, `/etc/hollow-push/`, `/etc/hollow-forwarder/`, `/etc/hollow-duckdns/` |
| Report counts and their key | `/var/lib/hollow-relay/` |
| The forwarder's identity | `/var/lib/hollow-forwarder/` |
| The push sender | `/opt/hollow-push/` |
| Services | `hollow-relay`, `hollow-coturn`, `hollow-push`, `hollow-forwarder`, `hollow-duckdns.timer`, `hollow-address-follow.timer` |
| The Docker setup | `/opt/hollow-relay-docker`, compose project `hollow-relay` |

Every file that holds a secret can be read by root alone, or by root and the one
service that needs it.

### Connection limits

The relay limits how many connections each address may hold and open, so a flood
from a few machines cannot fill it. The defaults suit almost every relay. That
includes one that many people reach through a single shared address, like a
mobile network or a school, where hundreds of phones can reconnect at the same
moment. To change a limit, run the setup again and choose **Change a setting**,
then **Advanced: connection limits**. You can also set it in `.env` (Docker) or
in `/etc/hollow-relay/relay.env` (systemd) and restart the relay. An empty
setting means the default.

| Setting | Default | Range | What it limits |
|---|---|---|---|
| `CONN_LIMIT_IPV4` | 512 | 8 to 65,536 | Open connections from one IPv4 address |
| `CONN_LIMIT_IPV6` | 128 | 8 to 65,536 | Open connections from one IPv6 /64 |
| `CONN_RATE_IPV4` | 120 | 6 to 6,000 | New connections a minute from one IPv4 address, after a first burst as large as its open limit |
| `CONN_RATE_IPV6` | 30 | 6 to 6,000 | New connections a minute from one IPv6 /64, after a first burst as large as its open limit |
| `LOGIN_WINDOW_PER_BLOCK` | 256 | 16 to 65,536 | Logins in progress from one IPv4 /24 or IPv6 /48 |
| `LOGIN_WINDOW_TOTAL` | 10,000 | 256 to 1,000,000 | Logins in progress on the whole relay |
| `CONNECTED_LIMIT` | Set from memory | 1,024 to 4,194,304 | Connections on the whole relay |
| `BREAKER_MODE` | `enforce` | `enforce` or `shadow` | See [Circuit breaker](#circuit-breaker) |

When too many logins are in progress, the relay first closes the ones that have
not moved for five seconds, from the address with the most of them. A burst of
real logins keeps moving, so it gets through. Past `CONNECTED_LIMIT`, the relay
closes connections from the address that holds the most. That default is a
quarter of the machine's memory at 32 KB a connection, about 65,000 on an 8 GB
machine. An app the relay turns away waits before it tries again.

A value that is not a number counts as the default, and one outside its range
counts as the nearer end. The relay names each such value in its log when it
starts. `hollow-relay --check-limits` prints the limits in force and fails when a
value was out of range. The host checks run it for you.

To lift the new-connection limit alone for your own machines, for example while
you test with many copies of the app at once, list their public addresses,
separated by commas, as `HOLLOW_CONN_RATE_EXEMPT` in `.env` (Docker) or in
`/etc/hollow-relay/relay.env` (systemd). An IPv6 address covers its whole /64.
Every other limit still applies to them. The relay skips local, broadcast and
multicast addresses on the list, such as 127.0.0.1 or ::1, since no outside
machine connects from them.

### Send budget

The relay holds data for each connection: what it still has to send to an app
that reads slowly, and large incoming messages that arrive in pieces. All of it
together has one limit, by default a quarter of the machine's memory and never
less than 512 MB, or a third of the memory on a small machine. Past the limit,
the relay closes a connection from the address that holds the most, the one
stuck the longest first, and that app picks up where it left off when it
reconnects. This keeps a few stuck connections from using up the memory and
getting the relay killed. To change the limit, set `HOLLOW_SEND_BUDGET_BYTES` to a number of bytes in `.env` (Docker) or in
`/etc/hollow-relay/relay.env` (systemd). A value below the floor counts as the
floor. Most relays never need it.

### Circuit breaker

The relay also counts how much work each session causes it: messages, the
deliveries they lead to, and signature checks. When a device causes far more
work than anyone normally does, the relay pauses it, for longer each time it
keeps it up, and then lets it back in. The app waits and picks up where it left off. The limits
are built in, not settings, so an operator cannot lower them. With
`BREAKER_MODE=shadow` the relay only counts and pauses nobody, which helps when
you look into a problem. The setup offers it as **Overload protection** under
**Advanced: connection limits**. While `PUBLIC_STATS` is on, `/server-stats`
shows anonymous totals, under `breaker`, of how often a session was paused, and
whether the relay pauses at all.

### What the relay holds and never writes

While it runs, the relay holds:

- which connections are in which rooms, and which channels each one follows
- encrypted traffic waiting for people who are offline, deleted on delivery or
  when it expires
- each identity's signed list of its devices, so only that person's devices can
  collect what waits for them
- for each server, the public keys that guard who joins it, which also name its
  owner
- destroy orders waiting for a device that is offline
- for each phone, where to send its wake-ups and its notification settings,
  muted servers and conversations included
- temporary nicknames and one-time device link codes
- for each connection that dropped in the last few minutes, the rooms it was in
  and the encrypted traffic sent to it since, until it comes back or the wait
  runs out

It can't decrypt any of it, and nothing on the list is message content.

None of it is written to the disk. That promise depends on the host, which is why
the setup turns swap and core dumps off and keeps the journal in memory. Swap
would let the kernel page that memory onto the disk, a core dump would write all
of it at once, and a journal on disk would outlive the traffic it mentions. When
the relay restarts under the full setup, it hands everything to the next relay
process, memory to memory. A reboot or a power cut ends all of it.

The one thing the relay does write is a count of user reports, in
`reports.json`, so you can see which peers have been reported and act on it. It
records the reported peer and the category. To stop one person's report counting
twice, it also keeps a one-way fingerprint of each report, made with a random key
that exists only in the relay's memory and never reaches the disk, so the reports
file can't confirm who reported whom. The full setup carries the key across a
restart the same way as the waiting messages. A reboot, or any restart under
Docker, gives the relay a new key. It then drops the old fingerprints and keeps
the counts, so a repeat of an old report counts once more. Relays before 0.13
kept the key in `reports.json.key`, and the first start of a newer relay
overwrites that file with zeros and deletes it.

## Operator changelog

Notes for people who already run a relay, newest first.

### 0.14

- The connection limits are settings now, with new defaults. Each IPv4 address
  may hold 512 connections and open 120 new ones a minute, up from 34 and 10, so
  everyone behind one mobile network or school address can reconnect at once.
  Logins in progress and connections in total have limits of their own. A limit
  you already set by hand stays. See [Connection limits](#connection-limits).
- The circuit breaker now pauses a device that causes far more work than anyone
  normally does. In 0.13 it only counted. `BREAKER_MODE=shadow` makes it count
  only again. See [Circuit breaker](#circuit-breaker).
- The relay reads a denylist, `/etc/hollow-relay/denylist.json` (Docker:
  `keys/denylist.json`), to refuse a server, an identity or an address. The setup
  writes an empty one and the `--denylist-file` flag when you update; a relay you
  run by hand needs both, or it looks for `denylist.json` in its working directory
  and blocks nothing. See [Blocking a server, an identity or an
  address](#blocking-a-server-an-identity-or-an-address).
- A 0.14 relay hands its memory to the next process in a newer form. Going back to
  a 0.13 relay after that loses, on that one restart, the messages waiting for
  offline people, the channel history it held and the phones' push registrations.
- The setup puts CAKE on the server's upload, so a full line is shared fairly
  between the addresses the relay sends to. On a relay the setup put up before,
  choose it under **Change a setting**. Until then the host checks fail.
  See [Fair share of the upload](#fair-share-of-the-upload).
- Ask the people who use your relay to update their apps to 0.14 when you update
  the relay. A 0.14 relay passes a request to join a locked server to only three
  members, and the 0.13 app often leaves it unanswered, so joins stay slow until
  the members have 0.14.

### 0.13

- The setup wizard, `relay-uws/install.sh`, sets up, updates and removes a relay, and takes over a
  relay set up by hand or with a plain `docker compose up`. See
  [Already running a relay?](#already-running-a-relay).
- Relays can run their own media forwarder, under systemd or with
  `COMPOSE_PROFILES=turn,forwarder`.
- The full setup can install ready-made relay and forwarder programs for x86_64
  and ARM64, from a release list signed with the same key as Hollow's app
  updates.
- Without Docker, a DuckDNS certificate now comes through DNS, so port 80 can
  stay closed.
- The Docker stack no longer needs a service to start on boot.
- With TURN on, the TURN port lock keeps TURN to coturn's relay ports and the
  forwarder's. A relay set up by hand adds it as in
  [path A](#path-a-docker-by-hand) or [path B](#path-b-systemd-by-hand), and
  `check-host.sh` now fails without it.
- `PUBLIC_STATS=off` hides the online count and the traffic figures from the
  public stats page. See [Public stats](#public-stats).
- The report key lives only in memory. The relay overwrites an old
  `reports.json.key` with zeros and deletes it on its first start, and
  `check-host.sh` fails while one is on the disk.
- `HOLLOW_SEND_BUDGET_BYTES` is a new optional setting. See
  [Send budget](#send-budget).
- `CERTBOT_EMAIL` is gone from `.env`. Let's Encrypt no longer keeps an email on
  an account, and an old `.env` that still sets it keeps working.

### 0.12.2

Apps from 0.12.1 and 0.12.2 both work on either relay. Update the relay so
offline messages keep working in servers and channels created after the update.
From 0.12.2 the app signs your relay's address into those requests, and an older
relay can't check that. Nothing in `.env` changes, and no new ports open.

### 0.12

The app signs the exact address it connects to, and the relay accepts only its
own `RELAY_HOST` (`--domain` under systemd). Invite links made before 0.12 no
longer work, so send new ones once everyone has updated.
