#!/bin/bash
# The installer under a real systemd: one throwaway systemd container per
# image runs run_tests.sh and systemd_box_test.sh, and then this side checks
# that a new SSH login still gets through the box's firewall. Needs Docker;
# changes nothing on this machine but its own containers and images.
#
#   bash relay-uws/test/installer/run_systemd_tests.sh [image ...]
#
# Defaults to ubuntu:24.04 and debian:12. BOX_DNS=<address> hands the boxes
# that resolver (a private one tests the push sender's address wall), and
# BOX_BUILD_RELAY=0 skips the relay build, BOX_SKIP_SUITE=1 skips run_tests.sh,
# and KEEP=1 leaves the containers up. Then each take over scenario of
# adopt_box_test.sh runs in a fresh box with a relay built in its image:
# BOX_ADOPT=0 skips them, BOX_ADOPT="takeover leave" picks some, and
# BOX_ONLY_ADOPT=1 runs nothing else. Then fresh_box_test.sh runs a first
# install and the menu's updates in a box with only a stock server's packages
# (BOX_STOCK=0 skips it, BOX_ONLY_STOCK=1 runs nothing else). BOX_TAG names
# the images.
set -uo pipefail

T=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$T/../../.." && pwd)
IMAGES=${*:-ubuntu:24.04 debian:12}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
total_fail=0

ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
parts=(relay-uws push-sidecar scripts/build_relay_binaries.sh)
[ -d "$ROOT/rust" ] && parts+=(rust)
tar -C "$ROOT" --exclude='relay-uws/build' --exclude='*/node_modules' --exclude='.git' \
    --exclude='relay-uws/uWebSockets/fuzzing' --exclude='relay-uws/uSockets/boringssl' \
    --exclude='relay-uws/uSockets/lsquic' --exclude='rust/*/target' -cf "$WORK/src.tar" "${parts[@]}"

# start_box <name> <image> [docker run options]: a running systemd box with
# the sources in /src. Returns 1 when it does not come up.
start_box() {
    local name=$1 image=$2 st
    shift 2
    docker run -d --name "$name" --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock "$@" \
        "$image" >/dev/null || return 1
    for _ in $(seq 1 30); do
        st=$(docker exec "$name" systemctl is-system-running 2>/dev/null) || true
        case "$st" in running|degraded) break ;; esac
        sleep 1
    done
    docker exec -i "$name" sh -c 'mkdir -p /src && tar -C /src -xf -' <"$WORK/src.tar"
}

# relay_image <box tag> <slug>: the box image with a relay built from these
# sources in /opt/hollow-test-relay. Prints its tag.
relay_image() {
    local tag=$1 slug=$2 rtag
    rtag=${BOX_TAG:-hollow-installer-box}-relay:$slug
    rm -rf "$WORK/relayctx"
    mkdir -p "$WORK/relayctx"
    tar -C "$WORK/relayctx" -xf "$WORK/src.tar" relay-uws/CMakeLists.txt relay-uws/src relay-uws/uWebSockets relay-uws/uSockets
    cat >"$WORK/relayctx/Dockerfile" <<EOF
FROM $tag
RUN apt-get -o Acquire::Retries=5 update && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 install -y -q --no-install-recommends \\
    cmake g++ make libssl-dev libsodium-dev zlib1g-dev && rm -rf /var/lib/apt/lists/*
COPY relay-uws /build
RUN cmake -S /build -B /build/out -DCMAKE_BUILD_TYPE=Release >/dev/null && cmake --build /build/out -j"\$(nproc)" >/dev/null && \\
    install -D -m 0755 /build/out/hollow-relay /opt/hollow-test-relay/hollow-relay && rm -rf /build
EOF
    echo "--- building a relay into the $tag box" >&2
    docker build -q -t "$rtag" "$WORK/relayctx" >/dev/null || return 1
    echo "$rtag"
}

# adopt_boxes <image> <box tag> <slug>: one fresh box per take over scenario,
# from an image that holds a relay built from these sources.
adopt_boxes() {
    local img=$1 tag=$2 slug=$3 rtag sc name scenarios
    scenarios=${BOX_ADOPT:-takeover rollback interrupted fwdmismatch odd leave docker docker-rollback}
    [ "$scenarios" = 0 ] && return 0
    rtag=$(relay_image "$tag" "$slug") || { echo "FAIL  the relay did not build in the $img box"; total_fail=1; return 0; }
    local image opts dtag=${BOX_TAG:-hollow-installer-box}-docker:$slug
    for sc in $scenarios; do
        name=hollow-adopt-box-$slug-$sc-$$
        echo "--- adopt_box_test.sh $sc"
        image=$rtag opts=()
        case "$sc" in
        docker*)
            # Docker inside the box, with its own store: one overlay cannot sit on another.
            case "$img" in ubuntu*) ;; *) echo "skip  $sc needs Docker's compose plugin, which $img does not package"; continue ;; esac
            if ! docker image inspect "$dtag" >/dev/null 2>&1 || [ "${BOX_REBUILD:-0}" = 1 ]; then
                printf 'FROM %s\nRUN apt-get -o Acquire::Retries=5 update && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 install -y -q docker.io docker-compose-v2 && rm -rf /var/lib/apt/lists/*\n' "$rtag" |
                    docker build -q -t "$dtag" - >/dev/null || { echo "FAIL  Docker did not install in the $img box"; total_fail=1; continue; }
            fi
            image=$dtag opts=(-v /var/lib/docker -v /var/lib/containerd) ;;
        esac
        start_box "$name" "$image" "${opts[@]}" || { echo "FAIL  the $img box for $sc did not start"; total_fail=1; continue; }
        docker exec -e HOLLOW_INSTALLER_TEST_BOX=1 "$name" bash /src/relay-uws/test/installer/adopt_box_test.sh "$sc" || total_fail=1
        [ "${KEEP:-0}" = 1 ] || docker rm -fv "$name" >/dev/null
    done
}

# stock_box <image> <box tag> <slug>: fresh_box_test.sh in a box with the
# packages of a stock server install and nothing the setup installs itself.
# Debian's server has no curl; Ubuntu's has it and unattended-upgrades.
stock_box() {
    local img=$1 tag=$2 slug=$3 rtag stag name extra=""
    [ "${BOX_STOCK:-1}" = 0 ] && return 0
    rtag=$(relay_image "$tag" "$slug") || { echo "FAIL  the relay did not build in the $img box"; total_fail=1; return 0; }
    stag=${BOX_TAG:-hollow-installer-box}-stock:$slug
    case "$img" in ubuntu*) extra="curl unattended-upgrades" ;; esac
    printf 'FROM %s\nRUN apt-get -o Acquire::Retries=5 update && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 install -y -q --no-install-recommends systemd systemd-sysv dbus openssh-server sudo wget python3 whiptail iproute2 procps ca-certificates openssl bind9-dnsutils netcat-openbsd util-linux less cron logrotate ncurses-term %s && rm -rf /var/lib/apt/lists/*\nCMD ["/sbin/init"]\n' "$img" "$extra" |
        docker build -q -t "$stag" - >/dev/null || { echo "FAIL  the stock $img box did not build"; total_fail=1; return 0; }
    name=hollow-stock-box-$slug-$$
    echo "--- fresh_box_test.sh in a stock $img box"
    start_box "$name" "$stag" || { echo "FAIL  the stock $img box did not start"; total_fail=1; return 0; }
    docker run --rm --entrypoint cat "$rtag" /opt/hollow-test-relay/hollow-relay | docker exec -i "$name" sh -c 'cat >/root/relay.bin && chmod 755 /root/relay.bin'
    docker exec -e HOLLOW_INSTALLER_TEST_BOX=1 "$name" bash /src/relay-uws/test/installer/fresh_box_test.sh || total_fail=1
    [ "${KEEP:-0}" = 1 ] || docker rm -fv "$name" >/dev/null
}

for img in $IMAGES; do
    slug=${img//[:.\/]/-}
    tag=${BOX_TAG:-hollow-installer-box}:$slug
    name=hollow-installer-box-$slug-$$
    cat >"$WORK/Dockerfile" <<EOF
FROM $img
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \\
    systemd systemd-sysv dbus openssh-server coturn ufw iptables iproute2 curl ca-certificates jq openssl \\
    rsyslog fail2ban python3-systemd procps psmisc git python3 sudo shellcheck util-linux && \\
    rm -rf /var/lib/apt/lists/*
CMD ["/sbin/init"]
EOF
    echo "=== $img"
    docker build -q -t "$tag" "$WORK" >/dev/null || { echo "FAIL  the $img box did not build"; total_fail=1; continue; }
    [ "${BOX_ONLY_ADOPT:-0}" = 1 ] && { adopt_boxes "$img" "$tag" "$slug"; continue; }
    [ "${BOX_ONLY_STOCK:-0}" = 1 ] && { stock_box "$img" "$tag" "$slug"; continue; }
    dns=()
    [ -n "${BOX_DNS:-}" ] && dns=(--dns "$BOX_DNS")
    docker run -d --name "$name" --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock \
        "${dns[@]}" "$tag" >/dev/null || { echo "FAIL  the $img box did not start"; total_fail=1; continue; }
    for _ in $(seq 1 30); do
        st=$(docker exec "$name" systemctl is-system-running 2>/dev/null) || true
        case "$st" in running|degraded) break ;; esac
        sleep 1
    done
    docker exec -i "$name" sh -c 'mkdir -p /src /root/.ssh && tar -C /src -xf -' <"$WORK/src.tar"
    docker exec -i "$name" sh -c 'cat >/root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' <"$WORK/key.pub"

    if [ "${BOX_SKIP_SUITE:-0}" != 1 ]; then
        echo "--- run_tests.sh as root"
        docker exec -e HOLLOW_INSTALLER_TEST_BOX=1 "$name" bash /src/relay-uws/test/installer/run_tests.sh || total_fail=1
    fi
    echo "--- systemd_box_test.sh"
    docker exec -e HOLLOW_INSTALLER_TEST_BOX=1 -e BOX_BUILD_RELAY="${BOX_BUILD_RELAY:-1}" "$name" \
        bash /src/relay-uws/test/installer/systemd_box_test.sh || total_fail=1

    echo "--- from outside the box"
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")
    port=$(docker exec "$name" cat /root/ssh_test_port)
    sshb=(ssh -i "$WORK/key" -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=8 -o LogLevel=ERROR "root@$ip")
    if got=$("${sshb[@]}" 'bash -c "env -u SSH_CONNECTION sh -c \". /src/relay-uws/deploy/lib/host.sh; hollow_session_ssh_port\"; true"'); then
        echo "ok    a new SSH login on port $port gets through the box's firewall"
        if [ "$got" = "$port" ]; then echo "ok    the session's port is found without SSH_CONNECTION"
        else echo "FAIL  the session's port came out as [$got], not $port"; total_fail=1; fi
    else
        echo "FAIL  a new SSH login on port $port did not get through the box's firewall"
        total_fail=1
    fi
    [ "${KEEP:-0}" = 1 ] || docker rm -f "$name" >/dev/null
    adopt_boxes "$img" "$tag" "$slug"
    stock_box "$img" "$tag" "$slug"
done

echo ""
if [ "$total_fail" = 0 ]; then echo "systemd boxes: all passed"; else echo "systemd boxes: some FAILED"; fi
exit "$total_fail"
