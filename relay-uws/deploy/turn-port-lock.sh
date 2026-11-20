#!/bin/bash
# Keeps TURN relaying to coturn's own relay ports and the media forwarder's on this
# machine's own address, and nothing else there (AR-32). coturn's peer lock
# (coturn-start.sh, or /etc/turnserver.conf) allows this host's public address back,
# but coturn's peer lists take addresses, never ports: without this rule a TURN
# allocation could reach any UDP service listening on that address.
#
# Run as root:
#   turn-port-lock.sh apply     load the rule (replaces an older copy in one step)
#   turn-port-lock.sh refresh   the same, saying something only when it changed anything
#   turn-port-lock.sh remove    drop it
#   turn-port-lock.sh check     print ok/BAD lines, exit 1 on any BAD
# Settings, from the environment (hollow-turn-port-lock.service reads
# /etc/hollow-relay/turn-port-lock.env; none of them is a secret):
#   TURN_USER        the account coturn runs as: turnserver for the distribution's
#                    package, hollow-turn for the setup's hollow-coturn.service, 65999 under Docker
#   TURN_PEERS       the addresses coturn allows back (its allowed-peer-ip values),
#                    space separated: this machine's public IPv4 and IPv6
#   TURN_PORTS       coturn's relay ports, its --min-port to --max-port (default 49152-65535)
#   FORWARDER_PORTS  the forwarder's udp_port_min to udp_port_max (default none)
#   FORWARDER_USER   the account the forwarder runs as (check only, default hollow-fwd)
#
# The rules sit on the output hook and match coturn's socket owner: one per family for
# every local address but loopback (coturn refuses loopback peers, and a resolver may
# listen there), and one per family for the addresses coturn allows back, which behind
# a NAT that hairpins are not local at all. The chain runs at raw priority, before any
# nat output rule (Docker's DNAT of published ports) can rewrite where a datagram goes.
# Every process of coturn's account is held, so that account is coturn's alone.
# Both port ranges are also reserved (net.ipv4.ip_local_reserved_ports, which covers
# both families), so no other program's ephemeral UDP socket lands where TURN reaches,
# and from boot on (SYSCTL_FILE): a service that starts before this unit, such as
# avahi-daemon, would otherwise take a random port inside them on some boots.
set -euo pipefail

TABLE=hollow_turn
# Last in systemd-sysctl's order, so its value is the one boot keeps. That value is ours
# joined with what every other file gives the key, so an operator's own reservation (a
# sysctl.d file, or /etc/sysctl.conf through 99-sysctl.conf) survives; refresh keeps it so.
SYSCTL_FILE=${TURN_LOCK_SYSCTL_FILE:-/etc/sysctl.d/zz-hollow-turn-ports.conf}
# Where systemd-sysctl reads, highest priority first. Both are set only by the tests.
SYSCTL_DIRS=${TURN_LOCK_SYSCTL_DIRS:-/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d}
TURN_PORTS=${TURN_PORTS:-49152-65535}
FORWARDER_PORTS=${FORWARDER_PORTS:-}
FORWARDER_USER=${FORWARDER_USER:-hollow-fwd}

die() {
    echo "turn-port-lock: $*" >&2
    exit 2
}

# A user name or a numeric uid, as a uid.
uid_of() {
    local who=$1
    if [[ $who =~ ^[0-9]+$ ]]; then
        echo "$who"
    else
        id -u -- "$who" 2> /dev/null || die "no account named $who"
    fi
}

# "lo-hi" with 1 <= lo <= hi <= 65535.
valid_range() {
    local r=$1
    [[ $r =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
    local lo=$((10#${BASH_REMATCH[1]})) hi=$((10#${BASH_REMATCH[2]}))
    ((lo >= 1 && lo <= hi && hi <= 65535))
}

our_ranges() {
    local r=$TURN_PORTS
    if [ -n "$FORWARDER_PORTS" ]; then r="$r,$FORWARDER_PORTS"; fi
    echo "$r"
}

# TURN_PEERS of one family ("ip" or "ip6"), comma separated.
peers_of_family() {
    local fam=$1 out="" a
    for a in ${TURN_PEERS:-}; do
        if [ "$fam" = ip6 ] && [[ $a == *:* ]]; then
            out="$out${out:+,}$a"
        elif [ "$fam" = ip ] && [[ $a =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            out="$out${out:+,}$a"
        fi
    done
    echo "$out"
}

# The reserved-port list with `add` in it and without `drop`, keeping anyone else's.
reserved_with() {
    local add=$1 drop=$2 cur item out=""
    cur=$(sysctl -n net.ipv4.ip_local_reserved_ports 2> /dev/null || true)
    for item in ${cur//,/ } ${add//,/ }; do
        [ -z "$item" ] && continue
        [[ ",$drop," == *",$item,"* ]] && continue
        [[ ",$out," == *",$item,"* ]] && continue
        out="$out${out:+,}$item"
    done
    echo "$out"
}

settings_valid() {
    [ -n "${TURN_USER:-}" ] || die "TURN_USER is not set"
    [ -n "${TURN_PEERS:-}" ] || die "TURN_PEERS is not set (coturn's allowed-peer-ip addresses)"
    local a
    for a in $TURN_PEERS; do
        [[ $a =~ ^[0-9a-fA-F:.]+$ ]] || die "TURN_PEERS holds '$a', not an address"
    done
    valid_range "$TURN_PORTS" || die "TURN_PORTS must be lo-hi, got '$TURN_PORTS'"
    if [ -n "$FORWARDER_PORTS" ]; then
        valid_range "$FORWARDER_PORTS" || die "FORWARDER_PORTS must be lo-hi or empty, got '$FORWARDER_PORTS'"
    fi
}

apply() {
    settings_valid
    local uid ports v4 v6 rules=""
    uid=$(uid_of "$TURN_USER")
    ports="{ $(our_ranges | sed 's/,/, /g') }"
    v4=$(peers_of_family ip)
    v6=$(peers_of_family ip6)
    # One rule per family: a rule naming both an ip and an ip6 address matches nothing.
    rules="$rules
        meta skuid $uid fib daddr type local ip daddr != 127.0.0.0/8 udp dport != $ports counter drop
        meta skuid $uid fib daddr type local ip6 daddr != ::1 udp dport != $ports counter drop"
    if [ -n "$v4" ]; then
        rules="$rules
        meta skuid $uid ip daddr { ${v4//,/, } } udp dport != $ports counter drop"
    fi
    if [ -n "$v6" ]; then
        rules="$rules
        meta skuid $uid ip6 daddr { ${v6//,/, } } udp dport != $ports counter drop"
    fi
    # Declaring the table before deleting it makes the swap one transaction that works
    # whether or not an older copy is loaded.
    printf '%s\n' \
        "table inet $TABLE" \
        "delete table inet $TABLE" \
        "table inet $TABLE {" \
        "    chain out {" \
        "        type filter hook output priority raw; policy accept;$rules" \
        "    }" \
        "}" | nft -f -
    sysctl -q -w net.ipv4.ip_local_reserved_ports="$(reserved_with "$(our_ranges)" "")"
    persist_reservation
    echo "TURN may relay to this machine's own address only on ports $(our_ranges)."
}

# The reservation for the next boot, written only when it changed (refresh runs every minute).
# remove leaves it: it runs at every shutdown, and the setup deletes the file with the lock.
persist_reservation() {
    local want others
    others=$(boot_setting "$SYSCTL_FILE" | cut -f2)
    want="# Written by hollow-turn-port-lock: keeps the TURN and forwarder ports free of other
# programs' ephemeral sockets from boot on, with what the other sysctl.d files reserve.
# Removing the relay's TURN removes this file.
net.ipv4.ip_local_reserved_ports = $(joined_lists "$others" "$(our_ranges)")"
    [ "$(cat "$SYSCTL_FILE" 2> /dev/null)" = "$want" ] && return 0
    mkdir -p "${SYSCTL_FILE%/*}"
    printf '%s\n' "$want" > "$SYSCTL_FILE.new"
    chmod 0644 "$SYSCTL_FILE.new"
    mv -f "$SYSCTL_FILE.new" "$SYSCTL_FILE"
}

# joined_lists <list> <list>: both comma lists in one, each item once.
joined_lists() {
    local item out=""
    for item in ${1//,/ } ${2//,/ }; do
        [[ ",$out," == *",$item,"* ]] || out="$out${out:+,}$item"
    done
    echo "$out"
}

# boot_setting [<file to leave out>]: "<file><tab><value>" for the setting of the reserved
# ports boot keeps, the last one in systemd-sysctl's order (file names sorted, a name in an
# earlier directory hiding the same name further down); nothing when no file sets it.
boot_setting() {
    local skip=${1:-} d f seen=" " list=() out="" key
    key='^[[:space:]]*-\{0,1\}net[./]ipv4[./]ip_local_reserved_ports[[:space:]]*=[[:space:]]*'
    for d in $SYSCTL_DIRS; do
        for f in "$d"/*.conf; do
            [ -e "$f" ] || continue
            [[ $seen == *" ${f##*/} "* ]] && continue
            seen="$seen${f##*/} "
            [ "$f" = "$skip" ] && continue
            list+=("${f##*/}	$f")
        done
    done
    [ ${#list[@]} -gt 0 ] || return 0
    while read -r f; do
        if grep -q "$key" "$f" 2> /dev/null; then
            out="$f	$(sed -n "s/$key//p" "$f" | tail -n 1 | tr -d '[:space:]')"
        fi
    done < <(printf '%s\n' "${list[@]}" | LC_ALL=C sort -t "	" -k1,1 | cut -f2)
    if [ -n "$out" ]; then printf '%s\n' "$out"; fi
}

remove() {
    nft delete table inet "$TABLE" 2> /dev/null || true
    sysctl -q -w net.ipv4.ip_local_reserved_ports="$(reserved_with "" "$(our_ranges)")" || true
}

fail=0
ok() { echo "  ok    $*"; }
bad() {
    echo "  FAIL  $*"
    fail=1
}

# The loaded drop rules as "family uid ports peers" lines ("local" for every local
# address), and the chain's priority as "prio N", from nft's JSON.
loaded_rules() {
    { nft -j list table inet "$TABLE" 2> /dev/null || true; } | python3 -I -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
def elements(right):
    return right.get("set", [right]) if isinstance(right, dict) and "set" in right else [right]
def ports(right):
    out = []
    for it in elements(right):
        if isinstance(it, dict) and "range" in it:
            out.append("%d-%d" % tuple(it["range"]))
        elif isinstance(it, int):
            out.append("%d-%d" % (it, it))
    return ",".join(sorted(out))
for item in doc.get("nftables", []):
    chain = item.get("chain")
    if chain and chain.get("name") == "out":
        print("prio", chain.get("prio"))
    rule = item.get("rule")
    if not rule or rule.get("chain") != "out":
        continue
    uid = fam = dport = None
    peers = []
    local = False
    drop = False
    for e in rule.get("expr", []):
        m = e.get("match")
        if m:
            left, right, op = m.get("left", {}), m.get("right"), m.get("op")
            payload = left.get("payload", {})
            if left.get("meta", {}).get("key") == "skuid" and op in ("==", "in"):
                uid = right
            elif payload.get("field") == "dport" and op == "!=":
                dport = ports(right)
            elif payload.get("protocol") in ("ip", "ip6") and payload.get("field") == "daddr" and op in ("==", "in"):
                fam = payload["protocol"]
                peers = sorted(p for p in elements(right) if isinstance(p, str))
            elif payload.get("protocol") in ("ip", "ip6") and payload.get("field") == "daddr" and op == "!=":
                fam = payload["protocol"]
            elif "daddr" in left.get("fib", {}).get("flags", []) and right == "local" and op == "==":
                local = True
        if "drop" in e:
            drop = True
    if drop and uid is not None and fam and dport and (local or peers):
        print(fam, uid, dport, "local" if local else ",".join(peers))
'
}

# The system service a process runs in, or the name of its Docker container, or nothing.
unit_of_pid() {
    local cg base id
    cg=$(sed -n 's|^0::||p;s|^[0-9]*:name=systemd:||p' "/proc/$1/cgroup" 2> /dev/null | head -n 1)
    # Only the system's own services: one in a person's session restarts with that session.
    [[ $cg =~ ^/system\.slice/[^/]+$ ]] || return 0
    base=${cg##*/}
    case "$base" in
        docker-*.scope)
            id=${base#docker-}
            id=${id%.scope}
            [[ $id =~ ^[0-9a-f]{12,64}$ ]] || return 0
            docker inspect -f '{{.Name}}' "$id" 2> /dev/null | tr -cd 'A-Za-z0-9._-' || true
            ;;
        *.service) [[ $base =~ ^[A-Za-z0-9@._:-]+$ ]] && echo "$base" ;;
    esac
    return 0
}

sorted_list() { tr ',' '\n' <<< "$1" | sed '/^$/d' | sort | paste -sd, -; }

# The account of a process.
uid_of_pid() { awk '/^Uid:/ { print $2 }' "/proc/$1/status" 2> /dev/null; }

check() {
    settings_valid
    local uid want rules fam peers reserved fwd_uid=""
    uid=$(uid_of "$TURN_USER")
    want=$(sorted_list "$(our_ranges)")
    rules=$(loaded_rules)
    if [ -z "$rules" ]; then
        bad "TURN can reach every UDP port on this machine's own address: the port lock (inet $TABLE) is not loaded"
    else
        prio=$(sed -n 's/^prio //p' <<< "$rules")
        # Docker's nat output rules run at -100 (dstnat): after them the destination is rewritten.
        if [[ $prio =~ ^-?[0-9]+$ ]] && ((prio < -100)); then
            ok "the port lock sees where coturn sends before any nat rule rewrites it"
        else
            bad "the port lock runs at priority '$prio', where a nat output rule has rewritten the destination already"
        fi
    fi
    for fam in ip ip6; do
        if [ -z "$rules" ]; then break; fi
        if grep -qxF -- "$fam $uid $want local" <<< "$rules"; then
            ok "on every $fam address of this machine but loopback TURN reaches only ports $want"
        else
            bad "the $fam port lock for this machine's own addresses does not match coturn (account $uid, ports $want)"
        fi
    done
    for fam in ip ip6; do
        peers=$(sorted_list "$(peers_of_family "$fam")")
        [ -z "$peers" ] && continue
        if grep -qxF -- "$fam $uid $want $peers" <<< "$rules"; then
            ok "TURN reaches $peers only on ports $want"
        elif [ -n "$rules" ]; then
            bad "the $fam port lock does not match coturn (account $uid, ports $want, addresses $peers)"
        fi
    done
    reserved=$(sysctl -n net.ipv4.ip_local_reserved_ports 2> /dev/null || true)
    if [ -n "$reserved" ] && [ "$(reserved_with "$(our_ranges)" "")" = "$reserved" ]; then
        ok "no other program's ephemeral port lands in $want"
    else
        bad "the TURN and forwarder ports are not reserved (net.ipv4.ip_local_reserved_ports is '$reserved')"
    fi
    local boot winner item missing="" why
    boot=$(boot_setting)
    winner=${boot%%	*}
    for item in ${want//,/ }; do
        [[ ",${boot#*	}," == *",$item,"* ]] || missing="$missing${missing:+,}$item"
    done
    if [ -z "$missing" ]; then
        ok "$want stay reserved from boot on, before other services start"
    else
        if [ -z "$boot" ]; then
            why="no sysctl.d file reserves them; sudo systemctl restart hollow-turn-port-lock writes $SYSCTL_FILE"
        elif [ "$winner" = "$SYSCTL_FILE" ]; then
            why="$SYSCTL_FILE is out of date; sudo systemctl restart hollow-turn-port-lock writes it again"
        else
            why="$winner sets the reserved ports after $SYSCTL_FILE at boot, without them; add them there or rename it to sort before ${SYSCTL_FILE##*/}"
        fi
        bad "after a reboot $missing is reserved only once the lock loads, so a service that starts earlier can take a port there ($why)"
    fi

    # Every UDP socket listening inside those ports on a reachable address must be coturn's
    # or the forwarder's, or TURN reaches it after all.
    if [[ $FORWARDER_USER =~ ^[0-9]+$ ]]; then
        fwd_uid=$FORWARDER_USER
    elif id -u -- "$FORWARDER_USER" > /dev/null 2>&1; then
        fwd_uid=$(id -u -- "$FORWARDER_USER")
    fi
    local stray="" line addr port pid owner lo hi range in_band name unit hints="" who
    while read -r line; do
        addr=$(awk '{ print $4 }' <<< "$line")
        port=${addr##*:}
        [[ $port =~ ^[0-9]+$ ]] || continue
        case "$addr" in
            127.* | "[::1]"* | "[::ffff:127."*) continue ;;
        esac
        in_band=0
        for range in ${want//,/ }; do
            lo=${range%-*}
            hi=${range#*-}
            if ((port >= lo && port <= hi)); then in_band=1; fi
        done
        ((in_band)) || continue
        # The pid ss names last ends the line: a program's own name, which its owner picks
        # and ss prints first, could otherwise pass for coturn's pid.
        pid=$(sed -n 's/.*,pid=\([0-9][0-9]*\),fd=[0-9][0-9]*))[[:space:]]*$/\1/p' <<< "$line")
        owner=""
        # A process gone since ss listed it has no owner left to read.
        if [ -n "$pid" ]; then owner=$(uid_of_pid "$pid" || true); fi
        if [ "$owner" != "$uid" ] && { [ -z "$fwd_uid" ] || [ "$owner" != "$fwd_uid" ]; }; then
            if [ -n "$owner" ]; then
                name=$(tr -cd 'A-Za-z0-9._+-' < "/proc/$pid/comm" 2> /dev/null || true)
                who="${name:-a program} (pid $pid)"
                unit=$(unit_of_pid "$pid")
                case "$unit" in
                    *.service) hints="$hints sudo systemctl restart ${unit%.service};" ;;
                    "") hints="$hints restart $who;" ;;
                    *) hints="$hints sudo docker restart $unit;" ;;
                esac
            else
                who="a kernel socket with no process, such as WireGuard's,"
            fi
            stray="$stray$who	$addr
"
        fi
    done < <(ss -Hulnp 2> /dev/null)
    if [ -z "$stray" ]; then
        ok "only coturn and the forwarder listen on TURN-reachable ports"
    else
        # One entry per program, with every address it holds there.
        stray=$(awk -F'\t' 'NF == 2 { if (!($1 in at)) order[n++] = $1; at[$1] = at[$1] (at[$1] == "" ? "" : " and ") $2 }
            END { for (i = 0; i < n; i++) printf "%s%s on %s", (i ? "; " : ""), order[i], at[order[i]] }' <<< "$stray")
        hints=$(tr ';' '\n' <<< "$hints" | sed 's/^ *//;/^$/d' | awk '!seen[$0]++' | paste -sd';' - | sed 's/;/; /g')
        bad "something other than coturn or the forwarder listens where TURN can reach it: $stray.${hints:+ Restarting it moves it out of the reserved ports, unless it is set to use that port: $hints}"
    fi
    # check-host.sh takes a check without this last line for one that died part way.
    echo "done"
    return $fail
}

# apply, quiet unless the lock or the reservation was missing or differed (the timer runs it
# every minute).
refresh() {
    local before after
    before="$(loaded_rules)|$(sysctl -n net.ipv4.ip_local_reserved_ports 2> /dev/null || true)"
    apply > /dev/null
    after="$(loaded_rules)|$(sysctl -n net.ipv4.ip_local_reserved_ports 2> /dev/null || true)"
    if [ "$before" != "$after" ]; then
        echo "The TURN port lock was missing or had changed; loaded it again for ports $(our_ranges)."
    fi
}

case "${1:-}" in
    apply) apply ;;
    refresh) refresh ;;
    remove) remove ;;
    check) check ;;
    *) die "usage: turn-port-lock.sh apply|refresh|remove|check" ;;
esac
