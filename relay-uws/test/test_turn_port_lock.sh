#!/bin/bash
# The TURN port lock (deploy/turn-port-lock.sh) against real packets, inside a network
# namespace of its own: the host's firewall, addresses and sysctls are never touched,
# and everything goes with the namespace when the test ends. Needs root (sudo), nft,
# python3, ss and setpriv; run_tests.sh skips it, saying why, without them.
#   sudo bash test_turn_port_lock.sh
set -u
cd "$(dirname "$0")" || exit 1

if [ "${1:-}" != --inside ]; then
    [ "$(id -u)" = 0 ] || { echo "skip test_turn_port_lock (needs root for a network namespace)"; exit 0; }
    for tool in nft python3 ss setpriv unshare; do
        command -v "$tool" > /dev/null || { echo "skip test_turn_port_lock (no $tool)"; exit 0; }
    done
    exec unshare --net bash "$0" --inside
fi

lock=../deploy/turn-port-lock.sh
fail=0
checks=0
check() {
    checks=$((checks + 1))
    if [ "$2" = 0 ]; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi
}

ip link set lo up
ip addr add 192.0.2.10/32 dev lo
ip addr add 2001:db8::10/128 dev lo nodad
# A routed address that is not this machine's, for a nat rule to send coturn's datagrams to.
ip link add away0 type dummy
ip addr add 198.51.100.1/24 dev away0
ip link set away0 up
TURN=65534
FWD=65533
work=$(mktemp -d)
chmod 1777 "$work"
pids=()
trap 'kill "${pids[@]}" 2> /dev/null; rm -rf "$work"' EXIT

# A UDP listener as `uid` on addr:port that writes what it receives to a file.
listen() {
    local uid=$1 addr=$2 port=$3 out=$work/got_${2//[:.]/_}_$3
    setpriv --reuid="$uid" --regid="$uid" --clear-groups python3 -I -c '
import socket, sys
fam = socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET
s = socket.socket(fam, socket.SOCK_DGRAM)
s.bind((sys.argv[1], int(sys.argv[2])))
while True:
    data, _ = s.recvfrom(64)
    with open(sys.argv[3], "ab") as f:
        f.write(data)
' "$addr" "$port" "$out" &
    pids+=($!)
}

# Sends one datagram as `uid`; prints "sent" or the error's name.
send_as() {
    local uid=$1 addr=$2 port=$3
    setpriv --reuid="$uid" --regid="$uid" --clear-groups python3 -I -c '
import errno, socket, sys
fam = socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET
s = socket.socket(fam, socket.SOCK_DGRAM)
try:
    s.sendto(b"x", (sys.argv[1], int(sys.argv[2])))
    print("sent")
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
' "$addr" "$port"
}

# `send_as` and then whether the listener got it.
reaches() {
    local uid=$1 addr=$2 port=$3 out=$work/got_${2//[:.]/_}_$3
    rm -f "$out"
    [ "$(send_as "$uid" "$addr" "$port")" = sent ] || return 1
    for _ in $(seq 20); do
        [ -s "$out" ] && return 0
        sleep 0.05
    done
    return 1
}

listen $TURN 192.0.2.10 50000
listen $FWD 192.0.2.10 40100
listen 0 192.0.2.10 3478
listen 0 192.0.2.10 12345
listen 0 127.0.0.1 12345
# Loopback is out of TURN's reach (coturn refuses loopback peers), so check ignores it.
listen 0 127.0.0.1 50001
listen $TURN 2001:db8::10 50000
listen 0 2001:db8::10 12345
sleep 0.5

export TURN_USER=$TURN TURN_PEERS="192.0.2.10 2001:db8::10" TURN_PORTS=49152-65535 \
    FORWARDER_PORTS=40000-40199 FORWARDER_USER=$FWD

echo "turn port lock: before it is loaded"
reaches $TURN 192.0.2.10 12345
check "without the lock TURN reaches any port on the address" $?
bash "$lock" check > "$work/check0" 2>&1
check "check fails while the lock is not loaded" "$([ $? = 1 ] && grep -q 'not loaded' "$work/check0" && echo 0 || echo 1)"

echo "turn port lock: loaded"
bash "$lock" apply > /dev/null
check "apply loads the lock" $?
reaches $TURN 192.0.2.10 50000
check "TURN reaches coturn's relay ports" $?
reaches $TURN 192.0.2.10 40100
check "and the forwarder's" $?
check "not coturn's own listener" "$([ "$(send_as $TURN 192.0.2.10 3478)" = EPERM ] && echo 0 || echo 1)"
check "nor a port outside both ranges" "$([ "$(send_as $TURN 192.0.2.10 12345)" = EPERM ] && echo 0 || echo 1)"
reaches $TURN 2001:db8::10 50000
check "over IPv6 it reaches coturn's ports" $?
check "and nothing else" "$([ "$(send_as $TURN 2001:db8::10 12345)" = EPERM ] && echo 0 || echo 1)"
reaches $TURN 127.0.0.1 12345
check "loopback is untouched" $?
reaches 0 192.0.2.10 12345
check "another account is untouched" $?
nft -f - << 'NAT'
table ip hollow_test_nat {
    chain out {
        type nat hook output priority dstnat; policy accept;
        ip daddr 192.0.2.10 udp dport 12345 dnat to 198.51.100.7:12345
    }
}
NAT
check "a nat output rule cannot carry TURN past the lock" \
    "$([ "$(send_as $TURN 192.0.2.10 12345)" = EPERM ] && echo 0 || echo 1)"
nft delete table ip hollow_test_nat
ip addr add 192.0.2.30/32 dev lo
ip addr add 2001:db8::30/128 dev lo nodad
listen 0 192.0.2.30 12345
listen 0 2001:db8::30 12345
sleep 0.3
check "an address this machine gained after apply is locked too" \
    "$([ "$(send_as $TURN 192.0.2.30 12345)" = EPERM ] && echo 0 || echo 1)"
check "over IPv6 as well" "$([ "$(send_as $TURN 2001:db8::30 12345)" = EPERM ] && echo 0 || echo 1)"
check "IPv6 loopback is untouched" "$([ "$(send_as $TURN ::1 12345)" = sent ] && echo 0 || echo 1)"
check "a refresh of a loaded lock says nothing" "$([ -z "$(bash "$lock" refresh)" ] && echo 0 || echo 1)"
nft delete table inet hollow_turn
check "a refresh of a lock that went loads it again and says so" \
    "$([ -n "$(bash "$lock" refresh)" ] && nft list tables | grep -q hollow_turn && echo 0 || echo 1)"
bash "$lock" apply > /dev/null
check "a second apply replaces the first" "$([ "$(nft list tables | grep -c hollow_turn)" = 1 ] && echo 0 || echo 1)"
reserved=$(sysctl -n net.ipv4.ip_local_reserved_ports)
check "both ranges are reserved from ephemeral ports" \
    "$([[ ",$reserved," == *",40000-40199,"* && ",$reserved," == *",49152-65535,"* ]] && echo 0 || echo 1)"

echo "turn port lock: check"
bash "$lock" check > "$work/check1" 2>&1
check "check passes on what apply loaded" $?
check "check ends with its done line" "$([ "$(tail -n 1 "$work/check1")" = done ] && echo 0 || echo 1)"
sed 's/priority raw;/priority filter;/' "$lock" > "$work/lock_filter.sh"
bash "$work/lock_filter.sh" apply > /dev/null
bash "$lock" check > "$work/check1b" 2>&1
check "check fails on a lock that runs after nat output" \
    "$([ $? = 1 ] && grep -q 'priority' "$work/check1b" && echo 0 || echo 1)"
sed 's/fib daddr type local/fib daddr type multicast/' "$lock" > "$work/lock_peers_only.sh"
bash "$work/lock_peers_only.sh" apply > /dev/null
bash "$lock" check > "$work/check1d" 2>&1
check "check fails on a lock that names only coturn's addresses" \
    "$([ $? = 1 ] && grep -q "this machine's own addresses" "$work/check1d" && echo 0 || echo 1)"
bash "$lock" apply > /dev/null
mkdir -p "$work/fakebin"
printf '#!/bin/sh\necho "UNCONN 0 0 192.0.2.10:50002 0.0.0.0:* users:((\\"gone\\",pid=4194999,fd=3))"\n' > "$work/fakebin/ss"
chmod 755 "$work/fakebin/ss"
PATH="$work/fakebin:$PATH" bash "$lock" check > "$work/check1c" 2>&1
check "a listener whose process is gone fails check and check still finishes" \
    "$([ $? = 1 ] && grep -q '192.0.2.10:50002' "$work/check1c" && [ "$(tail -n 1 "$work/check1c")" = done ] && echo 0 || echo 1)"
TURN_PORTS=49160-65535 bash "$lock" check > "$work/check2" 2>&1
check "check fails when coturn's ports differ from the lock's" "$([ $? = 1 ] && echo 0 || echo 1)"
TURN_PEERS="192.0.2.11 2001:db8::10" bash "$lock" check > "$work/check3" 2>&1
check "check fails when coturn's addresses differ" "$([ $? = 1 ] && echo 0 || echo 1)"
listen 0 0.0.0.0 51820
sleep 0.3
bash "$lock" check > "$work/check4" 2>&1
check "check fails on a foreign listener inside coturn's ports" \
    "$([ $? = 1 ] && grep -q '0.0.0.0:51820' "$work/check4" && echo 0 || echo 1)"

sysctl -q -w net.ipv4.ip_local_reserved_ports=""
bash "$lock" check > "$work/check5" 2>&1
check "check fails when the ports are not reserved" "$([ $? = 1 ] && grep -q 'not reserved' "$work/check5" && echo 0 || echo 1)"
TURN_PORTS=49160-65535 bash "$lock" apply > /dev/null
sysctl -q -w net.ipv4.ip_local_reserved_ports="40000-40199,49152-65535"
bash "$lock" check > "$work/check6" 2>&1
check "check fails on a lock loaded for other ports" "$([ $? = 1 ] && grep -q 'does not match' "$work/check6" && echo 0 || echo 1)"
bash "$lock" apply > /dev/null

echo "turn port lock: removed"
bash "$lock" remove
check "remove drops the lock" "$(nft list tables | grep -q hollow_turn && echo 1 || echo 0)"
reaches $TURN 192.0.2.10 12345
check "and TURN reaches every port again" $?
reserved=$(sysctl -n net.ipv4.ip_local_reserved_ports)
check "and the reservation is gone" "$([[ $reserved != *49152-65535* ]] && echo 0 || echo 1)"

if [ "$fail" = 0 ]; then
    echo "pass test_turn_port_lock ($checks checks)"
else
    echo "FAIL test_turn_port_lock"
fi
exit $fail
