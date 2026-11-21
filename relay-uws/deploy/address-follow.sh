#!/bin/bash
# Keeps the public address in coturn's settings, the TURN port lock's and the media
# forwarder's on the address the relay's own name points at (HOL-SEC-214), for a relay
# set up by install.sh with a DuckDNS name or a domain of its own.
#
# The name is looked up through this machine's DNS servers, asked as DNS
# (address-probe.py dns): never /etc/hosts, a synthesized record or a third party's
# resolver, and an answer naming any private address counts for nothing. A new address
# counts only once it is proven to be this machine: an address this machine holds, or
# one where a TLS handshake for the relay's name completes with the key the relay
# serves (curl --pinnedpubkey) AND coturn answers an authenticated Allocate signed with
# this relay's TURN secret (address-probe.py turn). A relay without TURN has nothing
# there but the TLS key, which a passthrough for 443 also shows, so it takes only an
# address this machine holds. A DNS answer
# alone never moves TURN, so a forged one cannot point coturn's peer lock at someone
# else's machine.
#
# A router without NAT loopback leaves a new address unproven from in here. Then the
# old address is dropped for this machine's own LAN address, but only when every look
# over DROP_SECS and DROP_LOOKS in a row agrees: the old address is on no interface, a
# pinned handshake there fails, DNS names the same public set without it, the LAN
# address differs, and evidence beyond DNS says it is gone: for a DuckDNS name DuckDNS
# itself (over HTTPS, by the updater) saw this machine at one of those addresses; for a
# domain a pinned handshake to the current address worked before (LOOP4), since behind
# a router without loopback it always fails. Dropping an allowed peer opens nothing.
#
# A restart or reload a rewritten file still owes is noted in RAM (PENDING) before the
# rename and cleared once it worked, so a failed or cut-short look is retried, and the
# port lock keeps every old peer until coturn runs with the new ones.
#
# What the follower decides lives in install.conf's turn_public_ip/turn_public_ipv6;
# public_ip stays the setup's answer, which DuckDNS and every later setup run use.
#
# Root, from hollow-address-follow.service (its timer runs it every five minutes); the
# lookups and the handshakes run as hollow-addr through setpriv.
#   address-follow.sh run      one look; writes and restarts only what changed
#   address-follow.sh check    ok/FAIL/skip lines for check-host.sh, then "done"; changes nothing
#   address-follow.sh wanted <address> <turn> <forwarder> <public_ip> <public_ip_fixed>
#                              exit 0 when the setup's answers call for the follower
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/preflight.sh
. "$HERE/lib/preflight.sh"

CONF=/etc/hollow-relay/install.conf
TURN_ENV=/etc/hollow-turn/turn.env
LOCK_ENV=/etc/hollow-relay/turn-port-lock.env
FWD_TOML=/etc/hollow-forwarder/forwarder.toml
STACK_DIR=/opt/hollow-relay-docker/relay-uws
SETUP_LOCK=/var/lib/hollow-installer/setup.lock
SEEN_FILE=/run/hollow-duckdns/seen
LOCK_UNIT=hollow-turn-port-lock.service
FOLLOW_UNIT=hollow-address-follow.service
FOLLOW_TIMER=hollow-address-follow.timer
STATE=${RUNTIME_DIRECTORY:-/run/hollow-address}/state
PENDING=${STATE%/*}/pending
PROBE=$HERE/address-probe.py
PROBE_USER=hollow-addr
# Seconds between two address changes, so a name that flaps restarts coturn at most
# this often; how long and how many looks in a row an old address has to look stale
# before it goes; how old DuckDNS's answer may be.
MIN_GAP=600
DROP_SECS=1800
DROP_LOOKS=6
SEEN_FRESH=900
PROBE_SECS=8
MAX_CANDIDATES=4

say() { printf '%s\n' "$*"; }

# wanted <address> <turn> <forwarder> <public_ip> <public_ip_fixed>: a bare IP has no name
# to follow; a LAN address typed in for a relay only the home network uses has none either.
wanted() {
    [ "$1" = duckdns ] || [ "$1" = domain ] || return 1
    [ "$2" = yes ] || [ "$3" = yes ] || return 1
    [ "$5" != yes ] || [ "$(ip4_class "$4")" = public ]
}

# key_get <file> <key>: a KEY=value line's value, without quotes.
key_get() {
    local v
    v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1)
    v=${v#\"}
    v=${v%\"}
    printf '%s' "$v"
}
toml_ip() { sed -n 's/^public_ip[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | tail -n 1; }

valid_name() {
    local d=${1,,}
    [ "${#d}" -le 253 ] && [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}
is_v4() { [ "$(ip4_class "$1")" != invalid ]; }
is_v6() { [ "$(ip6_class "$1")" != invalid ]; }

in_list() {
    local x=$1 y
    shift
    for y; do [ "$x" = "$y" ] && return 0; done
    return 1
}

# Lookups and handshakes with other machines run as an account that can write nothing.
as_probe() {
    local who=$PROBE_USER uid gid
    [ "$(id -u)" = 0 ] || { "$@"; return; }
    getent passwd "$who" >/dev/null || who=nobody
    uid=$(id -u "$who") && gid=$(id -g "$who") || return 1
    setpriv --reuid="$uid" --regid="$gid" --clear-groups --no-new-privs -- "$@"
}

# resolve <A|AAAA>: NAMES = the name's addresses of that family; DNS_STATE = ok (at
# least one, all public), private (any address that is not public: a router's or a
# Pi-hole's local answer, which counts for nothing) or none (no answer, an error or
# no such name).
resolve() {
    local t=$1 out a bad=0
    NAMES=()
    DNS_STATE=none
    out=$(as_probe timeout 12 python3 -I "$PROBE" dns "$HOST" "$t" 2>/dev/null) || return 0
    [ "$(head -n 1 <<<"$out")" = rcode=0 ] || return 0
    while read -r a; do
        a=${a,,}
        if [ "$t" = A ]; then [ "$(ip4_class "$a")" = public ] || bad=1
        else [ "$(ip6_class "$a")" = global ] || bad=1; fi
        [ "$bad" = 0 ] || break
        in_list "$a" "${NAMES[@]}" || NAMES+=("$a")
    done < <(tail -n +2 <<<"$out" | head -n 64)
    if [ "$bad" = 1 ]; then
        NAMES=()
        DNS_STATE=private
    elif [ ${#NAMES[@]} -gt 0 ]; then
        DNS_STATE=ok
    fi
    return 0
}

own_addrs() { ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr 'A-F' 'a-f'; }

# The SHA-256 of the public key this machine's relay serves for its name, as curl pins it.
local_pin() {
    local pem pin
    pem=$(as_probe timeout "$PROBE_SECS" openssl s_client -connect 127.0.0.1:443 -servername "$HOST" </dev/null 2>/dev/null) || return 1
    pin=$(openssl x509 -pubkey -noout <<<"$pem" 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null |
        openssl dgst -sha256 -binary | base64)
    [[ "$pin" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
    printf '%s' "$pin"
}

# pin_proves <address>: 0 when the handshake for the relay's name at <address>:443
# completes with the relay's own key, 1 when it does not, 2 when this machine's relay
# does not answer, so nothing can be judged. Certificate checks are off (a staging
# certificate is fine); the pin is the proof.
PIN=""
PIN_STATE=""
pin_load() {
    [ -z "$PIN_STATE" ] || return 0
    if PIN=$(local_pin); then PIN_STATE=ok; else PIN="" PIN_STATE=none; fi
}
pin_proves() {
    local a=$1 r=$1
    [[ "$a" == *:* ]] && r="[$a]"
    pin_load
    [ "$PIN_STATE" = ok ] || return 2
    as_probe timeout "$PROBE_SECS" curl -q -s -o /dev/null -k --proto =https --noproxy '*' --max-time "$PROBE_SECS" \
        --max-filesize 65536 --pinnedpubkey "sha256//$PIN" --resolve "$HOST:443:$r" "https://$HOST/health" || return 1
}

# turn_proves <address>: coturn at <address>:3478 answers an authenticated Allocate
# signed with this relay's TURN secret. A passthrough proxy for port 443 alone, which
# the pin cannot tell from this machine, fails here. Root derives a five-minute
# credential; the probe account never sees the secret.
turn_proves() {
    local a=$1 cred file=$TURN_ENV TURN_USER TURN_PASS
    [ "$MODE" = docker ] && file=$STACK_DIR/.env
    cred=$(timeout 5 python3 -I "$PROBE" turn-cred "$file" 2>/dev/null) || return 1
    TURN_USER=${cred%%$'\n'*} TURN_PASS=${cred#*$'\n'}
    [ -n "$TURN_USER" ] && [ -n "$TURN_PASS" ] && [ "$TURN_USER" != "$TURN_PASS" ] || return 1
    (
        export TURN_USER TURN_PASS
        as_probe timeout "$PROBE_SECS" python3 -I "$PROBE" turn "$a" 3478
    ) >/dev/null 2>&1
}

# proven <address>: prints how the address proved to be this machine; fails when it did not.
proven() {
    if in_list "$1" "${OWN[@]}"; then
        echo "an address of this machine"
        return 0
    fi
    [ "$TURN" = yes ] || return 1
    pin_proves "$1" || return 1
    turn_proves "$1" || return 1
    echo "and both this relay's TLS key and its TURN secret answered there"
}

# not_taken <address>: why a candidate that did not prove stays out.
not_taken() {
    if [ "$TURN" = yes ]; then
        say "$HOST points at $1, which did not prove to be this machine, so TURN does not take it"
    else
        say "$HOST points at $1, which this machine does not hold, so the forwarder does not take it (a relay without TURN takes only an address this machine holds)"
    fi
}

# duckdns_agrees: for a DuckDNS name that follows this machine, DuckDNS's own answer
# over HTTPS (the address its last update came from, which hollow-duckdns keeps in RAM)
# is one of the addresses the name names, which stale_look reaches only when all are
# public and none is the current one. Other names pass.
duckdns_follows() { [ "$ADDRESS" = duckdns ] && [ "$FIXED" != yes ]; }
duckdns_agrees() {
    local seen stamp
    duckdns_follows || return 0
    [ -f "$SEEN_FILE" ] && [ ! -L "$SEEN_FILE" ] || return 1
    stamp=$(stat -c %Y "$SEEN_FILE" 2>/dev/null) || return 1
    [ $((NOW - stamp)) -ge 0 ] && [ $((NOW - stamp)) -le "$SEEN_FRESH" ] || return 1
    seen=$(head -c 64 "$SEEN_FILE" | head -n 1)
    in_list "$seen" "${NAMES[@]}"
}

state_get() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -n 1; }
state_save() {
    install -d -m 0700 "${STATE%/*}" &&
        printf 'last_change=%s\nloop4=%s\nw4_start=%s\nw4_looks=%s\nw4_set=%s\nw4_cur=%s\nw6_start=%s\nw6_looks=%s\nw6_cur=%s\n' \
            "$LAST_CHANGE" "$LOOP4" "$W4_START" "$W4_LOOKS" "$W4_SET" "$W4_CUR" "$W6_START" "$W6_LOOKS" "$W6_CUR" >"$STATE"
}
state_load() {
    LAST_CHANGE=$(state_get last_change)
    LOOP4=$(state_get loop4)
    [ "$LOOP4" = yes ] || LOOP4=""
    W4_START=$(state_get w4_start) W4_LOOKS=$(state_get w4_looks) W4_SET=$(state_get w4_set) W4_CUR=$(state_get w4_cur)
    W6_START=$(state_get w6_start) W6_LOOKS=$(state_get w6_looks) W6_CUR=$(state_get w6_cur)
    [[ "$LAST_CHANGE" =~ ^[0-9]+$ ]] || LAST_CHANGE=0
    if ! [[ "$W4_START" =~ ^[0-9]+$ && "$W4_LOOKS" =~ ^[0-9]+$ && "$W4_SET" =~ ^[0-9.\ ]+$ ]] || ! is_v4 "$W4_CUR"; then w4_reset; fi
    if ! [[ "$W6_START" =~ ^[0-9]+$ && "$W6_LOOKS" =~ ^[0-9]+$ ]] || ! is_v6 "$W6_CUR"; then w6_reset; fi
}
w4_reset() { W4_START="" W4_LOOKS="" W4_SET="" W4_CUR=""; }
w6_reset() { W6_START="" W6_LOOKS="" W6_CUR=""; }

# stale_look: this look's part in dropping the current IPv4. Every look of the window
# has to agree, or it starts again.
stale_look() {
    local set why="" rc
    set=$(printf '%s\n' "${NAMES[@]}" | sort | tr '\n' ' ')
    set=${set% }
    if [ "$CUR_IP" = "$LOCAL_IP" ]; then
        w4_reset
        return 0
    fi
    if in_list "$CUR_IP" "${OWN[@]}"; then
        why="it is still an address of this machine"
    elif [ -z "$LOCAL_IP" ] || ! in_list "$LOCAL_IP" "${OWN[@]}"; then
        why="this machine has no address of its own to fall back on"
    else
        pin_proves "$CUR_IP"
        rc=$?
        if [ "$rc" = 0 ]; then
            LOOP4=yes
            why="this relay's key still answers there"
        elif [ "$rc" = 2 ]; then why="this machine's relay does not answer on 127.0.0.1:443, so nothing can be judged"
        elif ! duckdns_follows && [ "$LOOP4" != yes ]; then
            why="no handshake from here to its own public address has worked since this machine started (a router without NAT loopback), so a failed one says nothing"
        elif ! duckdns_agrees; then why="DuckDNS has not seen this machine at an address $HOST names"
        fi
    fi
    if [ -n "$why" ]; then
        w4_reset
        say "$HOST no longer names $CUR_IP, but $why, so TURN keeps it"
        return 0
    fi
    if [ -z "$W4_START" ] || [ "$W4_CUR" != "$CUR_IP" ] || [ "$W4_SET" != "$set" ]; then
        W4_START=$NOW W4_LOOKS=0 W4_SET=$set W4_CUR=$CUR_IP
    fi
    W4_LOOKS=$((W4_LOOKS + 1))
    if [ "$W4_LOOKS" -ge "$DROP_LOOKS" ] && [ $((NOW - W4_START)) -ge "$DROP_SECS" ]; then
        NEW_IP=$LOCAL_IP
        say "$HOST has named only $set for $(((NOW - W4_START) / 60)) minutes and $W4_LOOKS looks, never $CUR_IP, which no longer answers here, so TURN drops it for this machine's own $LOCAL_IP"
    else
        say "$HOST names $set, not $CUR_IP, look $W4_LOOKS: TURN drops it after $DROP_LOOKS looks in a row over $((DROP_SECS / 60)) minutes"
    fi
}

# Sets NEW_IP: the address the name points at once proven, else the current one, or
# this machine's own LAN address once the current one is stale (stale_look).
decide_v4() {
    local c n=0 why
    NEW_IP=$CUR_IP
    resolve A
    case "$DNS_STATE" in
    none) w4_reset; say "no answer from DNS for $HOST, so nothing changes"; return 0 ;;
    private) w4_reset; say "DNS gives $HOST a private address, which counts for nothing, so nothing changes"; return 0 ;;
    esac
    if in_list "$CUR_IP" "${NAMES[@]}"; then
        w4_reset
        # Until one works: whether a pinned handshake to its own address can work from here.
        if [ "$LOOP4" != yes ] && pin_proves "$CUR_IP"; then LOOP4=yes; fi
        return 0
    fi
    for c in "${NAMES[@]}"; do
        n=$((n + 1))
        [ "$n" -le "$MAX_CANDIDATES" ] || break
        if why=$(proven "$c"); then
            NEW_IP=$c
            in_list "$c" "${OWN[@]}" || LOOP4=yes
            w4_reset
            say "$HOST points at $c, $why"
            return 0
        fi
        not_taken "$c"
    done
    stale_look
}

# Sets NEW_IP6: kept while this machine holds it, else the name's proven one, else none
# once it has been gone from this machine and silent for the whole window.
decide_v6() {
    local c n=0 why rc
    NEW_IP6=$CUR_IP6
    [ -n "$CUR_IP6" ] || { w6_reset; return 0; }
    if in_list "$CUR_IP6" "${OWN[@]}"; then w6_reset; return 0; fi
    resolve AAAA
    if [ "$DNS_STATE" = ok ]; then
        for c in "${NAMES[@]}"; do
            [ "$c" != "$CUR_IP6" ] || continue
            n=$((n + 1))
            [ "$n" -le "$MAX_CANDIDATES" ] || break
            if why=$(proven "$c"); then
                NEW_IP6=$c
                w6_reset
                say "$HOST points at $c, $why"
                return 0
            fi
        done
    fi
    pin_proves "$CUR_IP6"
    rc=$?
    if [ "$rc" != 1 ]; then
        w6_reset
        say "this machine no longer holds $CUR_IP6, but it cannot be judged stale yet, so TURN keeps it"
        return 0
    fi
    if [ -z "$W6_START" ] || [ "$W6_CUR" != "$CUR_IP6" ]; then W6_START=$NOW W6_LOOKS=0 W6_CUR=$CUR_IP6; fi
    W6_LOOKS=$((W6_LOOKS + 1))
    if [ "$W6_LOOKS" -ge "$DROP_LOOKS" ] && [ $((NOW - W6_START)) -ge "$DROP_SECS" ]; then
        NEW_IP6=""
        say "this machine has not held $CUR_IP6 for $(((NOW - W6_START) / 60)) minutes, so TURN drops it"
    fi
}

# What a rewritten file still owes, one word a line: coturn, forwarder, compose (the
# Docker setup's containers) or lock (the TURN port lock's reload).
pending_has() { grep -qx -- "$1" "$PENDING" 2>/dev/null; }
pending_add() {
    pending_has "$1" && return 0
    install -d -m 0700 "${PENDING%/*}" && printf '%s\n' "$1" >>"$PENDING"
}
pending_del() {
    local rest
    [ -f "$PENDING" ] || return 0
    rest=$(grep -vx -- "$1" "$PENDING")
    if [ -n "$rest" ]; then printf '%s\n' "$rest" >"$PENDING"; else rm -f "$PENDING"; fi
}

# rewrite <file> <awk program> [awk options]: the file as the program prints it, in one
# rename, with its mode and owner kept. With OWES set, that restart is noted as owed
# before the rename, or nothing is renamed.
TMP_FILE=""
OWES=""
rewrite() {
    local f=$1 prog=$2
    shift 2
    if [ ! -f "$f" ] || [ -L "$f" ]; then
        say "$f is missing or not a plain file, so I left it"
        return 1
    fi
    TMP_FILE=$(mktemp "$f.follow.XXXXXX") || { TMP_FILE=""; return 1; }
    if ! awk "$@" "$prog" "$f" >"$TMP_FILE"; then drop_tmp; return 1; fi
    if cmp -s "$TMP_FILE" "$f"; then drop_tmp; return 0; fi
    if ! chown --reference="$f" "$TMP_FILE" || ! chmod --reference="$f" "$TMP_FILE"; then
        drop_tmp
        return 1
    fi
    if [ -n "$OWES" ] && ! pending_add "$OWES"; then
        say "could not note in ${PENDING%/*} that $OWES needs a restart, so $f stays as it was"
        drop_tmp
        return 1
    fi
    if ! mv -f "$TMP_FILE" "$f"; then
        drop_tmp
        return 1
    fi
    TMP_FILE=""
}
drop_tmp() {
    [ -z "$TMP_FILE" ] || rm -f "$TMP_FILE"
    TMP_FILE=""
}

# A run killed between mktemp and its rename leaves a temporary beside the file.
sweep_temps() {
    find /etc/hollow-relay /etc/hollow-turn /etc/hollow-forwarder "$STACK_DIR" -maxdepth 1 -type f \
        -name '*.follow.??????' -delete 2>/dev/null
    return 0
}

# set_keys <file> <KEY=value>...: each KEY's line takes the value; a missing one is added.
# Values are addresses or a quoted list of them, never anything with a | in it.
set_keys() {
    local f=$1 keys="" vals="" kv
    shift
    for kv; do keys="$keys${keys:+|}${kv%%=*}" vals="$vals${vals:+|}${kv#*=}"; done
    # shellcheck disable=SC2016 # an awk program
    rewrite "$f" 'BEGIN { n = split(keys, k, "|"); split(vals, v, "|"); for (i = 1; i <= n; i++) want[k[i]] = v[i] }
        { p = index($0, "="); key = substr($0, 1, p - 1) }
        p > 0 && (key in want) { print key "=" want[key]; seen[key] = 1; next }
        { print }
        END { for (i = 1; i <= n; i++) if (!(k[i] in seen)) print k[i] "=" v[i] }' -v keys="$keys" -v vals="$vals"
}

set_toml_ip() {
    # shellcheck disable=SC2016 # an awk program
    rewrite "$1" '/^public_ip[[:space:]]*=/ { print "public_ip = \"" ip "\""; next } { print }' -v ip="$2"
}

# The --allowed-peer-ip values coturn-start.sh passes for these addresses, in its order
# (turn_lock_peers in lib/native.sh): check-host compares the two.
peers_for() {
    local ip=$1 own=$2 v6=$3 out
    out=$ip
    if [ -n "$own" ] && [ "$own" != "$ip" ]; then out="$out $own"; fi
    if [ -n "$v6" ]; then out="$out $v6"; fi
    printf '%s' "$out"
}

lock_reload() {
    systemctl try-reload-or-restart "$LOCK_UNIT" && return 0
    say "the TURN port lock did not load again (journalctl -u $LOCK_UNIT)"
    return 1
}

compose() {
    DOCKER_CONFIG=${STATE%/*}/docker docker compose --project-name hollow-relay --project-directory "$STACK_DIR" \
        -f "$STACK_DIR/docker-compose.yml" "$@"
}

# restart_owed <unit>: restarts a unit a rewritten file still owes a restart. One a
# restart of ours left failed starts again; one stopped by hand stays stopped.
restart_owed() {
    if systemctl is-failed --quiet "$1"; then systemctl restart "$1"; else systemctl try-restart "$1"; fi
}

# Writes NEW_IP, NEW_IP6 and LOCAL_IP wherever they differ and restarts only what read a
# changed file or still owes a restart from an earlier look. install.conf first, so a
# run cut short converges on the next look. The port lock takes the new peers beside
# the old ones before coturn's settings change, and loses the old ones only once every
# write, restart and reload worked: coturn never runs with a peer the loaded rule does
# not cover.
apply_files() {
    local old_peers new_peers union a l=$LOCAL_IP failed=0 grown=1 svcs=()
    # A restart owed to a service this relay no longer runs is owed no more.
    [ "$TURN" = yes ] || { pending_del coturn; pending_del lock; }
    [ "$FORWARDER" = yes ] || pending_del forwarder
    if [ "$MODE" = docker ]; then pending_del coturn; pending_del forwarder; else pending_del compose; fi
    if [ "$NEW_IP" = "$SETUP_IP" ] && [ "$NEW_IP6" = "$SETUP_IP6" ]; then
        set_keys "$CONF" "turn_public_ip=" "turn_public_ipv6=" || failed=1
    else
        set_keys "$CONF" "turn_public_ip=$NEW_IP" "turn_public_ipv6=$NEW_IP6" || failed=1
    fi
    if [ -z "$l" ] && [ "$MODE" = docker ]; then l=$(key_get "$STACK_DIR/.env" LOCAL_IP)
    elif [ -z "$l" ]; then l=$(key_get "$TURN_ENV" LOCAL_IP); fi
    new_peers=$(peers_for "$NEW_IP" "$l" "$NEW_IP6")
    if [ "$TURN" = yes ] && [ -f "$LOCK_ENV" ]; then
        old_peers=$(key_get "$LOCK_ENV" TURN_PEERS)
        union=$new_peers
        # shellcheck disable=SC2086 # one word per address
        for a in $old_peers; do in_list "$a" $union || union="$union $a"; done
        if [ "$union" != "$old_peers" ]; then
            OWES=lock set_keys "$LOCK_ENV" "TURN_PEERS=\"$union\"" || { failed=1; grown=0; }
        fi
        if [ "$grown" = 1 ] && pending_has lock; then
            if lock_reload; then pending_del lock; else failed=1; grown=0; fi
        fi
        # coturn's settings wait for a lock that holds their peers.
        [ "$grown" = 1 ] || say "the TURN port lock does not hold the new peers yet, so coturn keeps its address until a later look"
    fi
    if [ "$MODE" = docker ]; then
        [ "$TURN" = yes ] && svcs+=(coturn)
        [ "$FORWARDER" = yes ] && svcs+=(forwarder)
        if [ "$grown" = 1 ] && [ ${#svcs[@]} -gt 0 ]; then
            OWES=compose set_keys "$STACK_DIR/.env" "PUBLIC_IP=$NEW_IP" "PUBLIC_IPV6=$NEW_IP6" ${LOCAL_IP:+"LOCAL_IP=$LOCAL_IP"} || failed=1
            if pending_has compose; then
                if compose up -d --no-deps --no-build "${svcs[@]}"; then pending_del compose
                else say "the containers did not start again with the new address, so a later look tries again"; failed=1; fi
            fi
        fi
    else
        if [ "$TURN" = yes ] && [ "$grown" = 1 ]; then
            OWES=coturn set_keys "$TURN_ENV" "PUBLIC_IP=$NEW_IP" "PUBLIC_IPV6=$NEW_IP6" ${LOCAL_IP:+"LOCAL_IP=$LOCAL_IP"} || failed=1
            if pending_has coturn; then
                if restart_owed hollow-coturn; then pending_del coturn
                else say "coturn did not restart with the new address (journalctl -u hollow-coturn), so a later look tries again"; failed=1; fi
            fi
        fi
        if [ "$FORWARDER" = yes ]; then
            OWES=forwarder set_toml_ip "$FWD_TOML" "$NEW_IP" || failed=1
            if pending_has forwarder; then
                if restart_owed hollow-forwarder; then pending_del forwarder
                else say "the forwarder did not restart with the new address (journalctl -u hollow-forwarder), so a later look tries again"; failed=1; fi
            fi
        fi
    fi
    # The old peers go only once everything above worked and nothing is owed.
    if [ "$TURN" = yes ] && [ -f "$LOCK_ENV" ] && [ "$failed" = 0 ] && [ ! -s "$PENDING" ] &&
        [ "$(key_get "$LOCK_ENV" TURN_PEERS)" != "$new_peers" ]; then
        OWES=lock set_keys "$LOCK_ENV" "TURN_PEERS=\"$new_peers\"" || failed=1
        if pending_has lock; then
            if lock_reload; then pending_del lock; else failed=1; fi
        fi
    fi
    return "$failed"
}

# CUR_IP/CUR_IP6 = what TURN and the forwarder use: the follower's own once it moved
# them, else the setup's answer (SETUP_IP/SETUP_IP6).
load_conf() {
    local t4 t6
    MODE=$(key_get "$CONF" mode)
    ADDRESS=$(key_get "$CONF" address)
    HOST=$(key_get "$CONF" host)
    HOST=${HOST,,}
    TURN=$(key_get "$CONF" turn)
    FORWARDER=$(key_get "$CONF" forwarder)
    SETUP_IP=$(key_get "$CONF" public_ip)
    SETUP_IP6=$(key_get "$CONF" public_ipv6)
    SETUP_IP6=${SETUP_IP6,,}
    [ -z "$SETUP_IP6" ] || is_v6 "$SETUP_IP6" || SETUP_IP6=""
    FIXED=$(key_get "$CONF" public_ip_fixed)
    t4=$(key_get "$CONF" turn_public_ip)
    t6=$(key_get "$CONF" turn_public_ipv6)
    t6=${t6,,}
    [ -z "$t6" ] || is_v6 "$t6" || t6=""
    if is_v4 "$t4"; then CUR_IP=$t4 CUR_IP6=$t6
    else CUR_IP=$SETUP_IP CUR_IP6=$SETUP_IP6; fi
}

# Never beside a run of the setup, which writes the same files: held only while
# writing, on a descriptor that stays open to the end.
setup_lock() {
    [ -e "$SETUP_LOCK" ] || return 0
    exec 8<"$SETUP_LOCK" || return 1
    flock -n 8
}

main_run() {
    local conf_sum prev_change rc=0
    [ "$(id -u)" = 0 ] || { say "run it as root"; exit 2; }
    [ -r "$CONF" ] || { say "no relay set up here"; exit 0; }
    trap drop_tmp EXIT
    trap 'exit 1' HUP INT TERM
    conf_sum=$(sha256sum <"$CONF")
    load_conf
    wanted "$ADDRESS" "$TURN" "$FORWARDER" "$SETUP_IP" "$FIXED" || { say "this relay has no name to follow"; exit 0; }
    valid_name "$HOST" || { say "the relay's name in $CONF is not a host name"; exit 1; }
    is_v4 "$CUR_IP" || { say "public_ip in $CONF is not an IPv4 address"; exit 1; }
    getent passwd "$PROBE_USER" >/dev/null || { say "the account $PROBE_USER is missing; run the setup again"; exit 1; }
    NOW=$(date +%s)
    state_load
    prev_change=$LAST_CHANGE
    LOCAL_IP=$(local_ipv4)
    is_v4 "$LOCAL_IP" || LOCAL_IP=""
    mapfile -t OWN < <(own_addrs)
    # Once per look, outside the subshells that use it.
    pin_load
    decide_v4
    decide_v6
    if [ "$NEW_IP" != "$CUR_IP" ] || [ "$NEW_IP6" != "$CUR_IP6" ]; then
        if [ $((NOW - LAST_CHANGE)) -lt "$MIN_GAP" ]; then
            say "the address changed less than $((MIN_GAP / 60)) minutes ago, so $NEW_IP waits for a later look"
            NEW_IP=$CUR_IP NEW_IP6=$CUR_IP6
        else
            say "TURN and the forwarder move from $CUR_IP${CUR_IP6:+ and $CUR_IP6} to $NEW_IP${NEW_IP6:+ and $NEW_IP6}"
            LAST_CHANGE=$NOW
        fi
    fi
    if ! setup_lock; then
        say "the setup is running, so this look writes nothing"
        LAST_CHANGE=$prev_change
        state_save
        exit 0
    fi
    if [ "$(sha256sum <"$CONF")" != "$conf_sum" ]; then
        say "the setup changed $CONF during this look, so it writes nothing"
        LAST_CHANGE=$prev_change
        w4_reset
        w6_reset
        state_save
        exit 0
    fi
    sweep_temps
    apply_files || rc=1
    state_save || say "could not keep the follower's stamps in ${STATE%/*}"
    exit "$rc"
}

# ---------------------------------------------------------------- check

ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; }
skip() { echo "  skip  $1"; }

check_sandbox() {
    local p good=1 c
    for p in NoNewPrivileges=yes ProtectSystem=strict ProtectHome=yes PrivateTmp=yes PrivateDevices=yes \
        RestrictSUIDSGID=yes RestrictNamespaces=yes LimitCORE=0; do
        if [ "$(systemctl show -p "${p%%=*}" --value "$FOLLOW_UNIT")" != "${p#*=}" ]; then
            bad "${FOLLOW_UNIT%.service} runs as root without $p"
            good=0
        fi
    done
    for c in $(systemctl show -p CapabilityBoundingSet --value "$FOLLOW_UNIT"); do
        case "$c" in
        cap_chown | cap_setuid | cap_setgid) ;;
        *) bad "${FOLLOW_UNIT%.service} keeps $c, which it does not need"; good=0 ;;
        esac
    done
    [ "$good" = 1 ] && ok "${FOLLOW_UNIT%.service} runs as root in a sandbox, its lookups as $PROBE_USER"
}

# check_one <what> <give|gives> <address>: the address a file gives against where the
# name points.
check_one() {
    [ -n "$3" ] || return 0
    if in_list "${3,,}" "${NAMES[@]}"; then
        ok "$1 $2 $3, the address $HOST points at"
    else
        if [ "$TURN" = yes ]; then
            bad "$1 $2 $3, but $HOST points at ${NAMES[*]}. The follower takes a new address once it proves to be this machine; to set one now, run sudo hollow-relay-setup and choose Change a setting, then the address"
        else
            bad "$1 $2 $3, but $HOST points at ${NAMES[*]}. A relay without TURN moves the forwarder only to an address this machine holds; to set one now, run sudo hollow-relay-setup and choose Change a setting, then the address"
        fi
    fi
}

# check_owed: a restart or reload the follower still owes, which keeps the old peers in
# the TURN port lock until it works.
check_owed() {
    local w
    [ -f "$PENDING" ] || return 0
    while read -r w; do
        case "$w" in
        coturn) bad "coturn has not restarted with the follower's new address yet, so the TURN port lock keeps the old one too. The follower tries again every five minutes (sudo journalctl -u ${FOLLOW_UNIT%.service} says why)" ;;
        compose) bad "the Docker setup's containers have not restarted with the follower's new address yet, so the TURN port lock keeps the old one too. The follower tries again every five minutes (sudo journalctl -u ${FOLLOW_UNIT%.service} says why)" ;;
        forwarder) bad "the forwarder has not restarted with the follower's new address yet. The follower tries again every five minutes (sudo journalctl -u ${FOLLOW_UNIT%.service} says why)" ;;
        lock) bad "the TURN port lock has not loaded its new peers yet. The follower tries again every five minutes (sudo journalctl -u ${FOLLOW_UNIT%.service} says why)" ;;
        esac
    done <"$PENDING"
}

main_check() {
    local peers what="your answers ($CONF)" verb=give follows=0
    [ -r "$CONF" ] || { echo "done"; return 0; }
    load_conf
    if [ "$CUR_IP" != "$SETUP_IP" ]; then
        what="the follower's address in $CONF (your answer is $SETUP_IP)"
        verb=gives
    fi
    wanted "$ADDRESS" "$TURN" "$FORWARDER" "$SETUP_IP" "$FIXED" && follows=1
    DNS_STATE=ok
    if [ "$ADDRESS" = ip ]; then
        NAMES=("$HOST")
    elif valid_name "$HOST"; then
        resolve A
    else
        NAMES=() DNS_STATE=none
    fi
    if [ "$DNS_STATE" = none ]; then
        skip "no answer from this machine's DNS for where $HOST points"
    elif [ "$DNS_STATE" = private ] && [ "$follows" = 1 ]; then
        skip "this network's DNS answers $HOST with a LAN address, so the follower can't follow a new public address on this network"
    elif [ "$DNS_STATE" = private ]; then
        skip "this network's DNS answers $HOST with a LAN address, so where it points on the internet can't be checked from here"
    else
        check_one "$what" "$verb" "$CUR_IP"
        if [ "$MODE" = docker ]; then
            [ -f "$STACK_DIR/.env" ] && check_one "the Docker setup's settings ($STACK_DIR/.env)" give "$(key_get "$STACK_DIR/.env" PUBLIC_IP)"
        else
            [ "$TURN" = yes ] && [ -f "$TURN_ENV" ] && check_one "coturn's settings ($TURN_ENV)" give "$(key_get "$TURN_ENV" PUBLIC_IP)"
            [ "$FORWARDER" = yes ] && [ -f "$FWD_TOML" ] && check_one "the forwarder's settings ($FWD_TOML)" give "$(toml_ip "$FWD_TOML")"
        fi
        if [ "$TURN" = yes ] && [ -f "$LOCK_ENV" ]; then
            peers=$(key_get "$LOCK_ENV" TURN_PEERS)
            check_one "the TURN port lock's peers ($LOCK_ENV)" give "${peers%% *}"
        fi
    fi
    [ "$follows" = 1 ] && check_owed
    if [ "$(systemctl show -p LoadState --value "$FOLLOW_UNIT" 2>/dev/null)" = loaded ]; then
        check_sandbox
    fi
    if [ "$follows" = 1 ]; then
        if [ "$(systemctl is-active "$FOLLOW_TIMER" 2>/dev/null)" != active ]; then
            bad "$FOLLOW_TIMER is not running, so TURN and the forwarder keep an old address after a change (sudo hollow-relay-setup puts it back)"
        elif [ "$DNS_STATE" != private ]; then
            ok "TURN and the forwarder follow a new address of $HOST ($FOLLOW_TIMER)"
        fi
    fi
    echo "done"
}

case "${1:-}" in
run) main_run ;;
check) main_check ;;
wanted) shift; wanted "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
*) echo "usage: address-follow.sh run|check|wanted <address> <turn> <forwarder> <public_ip> <public_ip_fixed>" >&2; exit 2 ;;
esac
