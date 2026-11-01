#!/bin/bash
# Tests for the fair-share shaper (CAKE, AR-01): its unit and settings, the
# question and its answer-file keys, turning it off, a kernel without sch_cake,
# what the relay is told, and check-host's lines. Sourced by run_tests.sh, whose
# helpers they use.
# shellcheck disable=SC2034,SC2317,SC2016,SC2030,SC2031,SC2154

echo "fair share: the unit"
# the_shaper_unit_is_sandboxed_and_shares_per_destination_host
t_cake_unit() {
    local u line out
    u=$(cat "$DEPLOY/hollow-cake.service" 2>/dev/null)
    has "the shaper's unit ships" "$u" "[Service]"
    local q='/usr/sbin/tc qdisc replace dev ${HOLLOW_CAKE_DEV} root cake bandwidth ${HOLLOW_CAKE_MBIT}mbit besteffort dual-dsthost'
    eq "CAKE on the device its settings name, per destination host, DSCP ignored" "$(grep '^ExecStart=' <<<"$u")" "ExecStart=$q"
    eq "a reload puts the same queue in place" "$(grep '^ExecReload=' <<<"$u")" "ExecReload=$q"
    has "a stop gives the kernel's own queue back" "$u" 'ExecStop=-/usr/sbin/tc qdisc del dev ${HOLLOW_CAKE_DEV} root'
    has "it reads the setup's settings" "$u" "EnvironmentFile=/etc/hollow-relay/cake.env"
    for line in Type=oneshot RemainAfterExit=yes DynamicUser=yes User=hollow-cake AmbientCapabilities=CAP_NET_ADMIN \
        CapabilityBoundingSet=CAP_NET_ADMIN SystemCallErrorNumber=EPERM LimitCORE=0 NoNewPrivileges=yes \
        ProtectSystem=strict RestrictAddressFamilies=AF_NETLINK IPAddressDeny=any "SystemCallFilter=~@privileged @resources"; do
        has "the shaper keeps $line" "$(grep -v '^#' <<<"$u")" "$line"
    done
    lacks "never as root" "$u" "User=root"
    lacks "and no other capability" "$(grep '^CapabilityBoundingSet=' <<<"$u")" " "
    has "in place before anything sends" "$u" "Before=hollow-relay.service hollow-coturn.service hollow-forwarder.service docker.service"
    has "the relay reads the same settings, when there are any" "$(cat "$DEPLOY/hollow-relay.service")" "EnvironmentFile=-/etc/hollow-relay/cake.env"
    if command -v systemd-analyze >/dev/null; then
        cp "$DEPLOY/hollow-cake.service" "$TMP/hollow-cake.service"
        out=$(systemd-analyze verify "$TMP/hollow-cake.service" 2>&1 | grep -v -e 'Failed to resolve' -e 'is not executable' -e 'cake.env' || true)
        lacks "the shaper's unit parses" "$out" "Unknown"
        lacks "with no bad setting" "$out" "Invalid"
    fi
}
in_sub t_cake_unit

echo "fair share: the device and the speed"
# the_shaper_defaults_to_the_default_route_and_ninety_percent_of_the_line
t_cake_defaults() {
    SYS_NET=$TMP/cake_net
    rm -rf "$SYS_NET"
    mkdir -p "$SYS_NET/ens16" "$SYS_NET/eth9" "$SYS_NET/wg0"
    echo 1000 >"$SYS_NET/ens16/speed"
    echo -1 >"$SYS_NET/eth9/speed"
    ip() {
        case "$*" in
        "-o -4 route show default") printf '%s\n' "$ROUTE4" ;;
        "-o -6 route show default") printf '%s\n' "$ROUTE6" ;;
        esac
    }
    ROUTE4="default via 203.0.113.1 dev ens16 proto dhcp src 203.0.113.7 metric 100" ROUTE6=""
    eq "the device the default route leaves through" "$(default_route_dev)" ens16
    ROUTE4="" ROUTE6="default via fe80::1 dev eth9 proto ra metric 1024 pref medium"
    eq "an IPv6-only machine's" "$(default_route_dev)" eth9
    ROUTE4="" ROUTE6=""
    eq "none without a default route" "$(default_route_dev)" ""
    ROUTE4="default via 203.0.113.1 dev ens16 proto dhcp"
    CFG_CAKE_DEV=""
    eq "the shaper takes it" "$(cake_dev)" ens16
    CFG_CAKE_DEV=eth9
    eq "unless the operator named another" "$(cake_dev)" eth9
    CFG_CAKE_DEV=gone0
    eq "a named device that is gone gives way to the route's" "$(cake_dev)" ens16
    eq "a 1000 Mbit/s line" "$(line_speed_mbit ens16)" 1000
    eq "90 percent of it" "$(cake_default_mbit ens16)" 900
    echo 10000 >"$SYS_NET/ens16/speed"
    eq "of a 10 Gbit/s line too" "$(cake_default_mbit ens16)" 9000
    echo 100 >"$SYS_NET/ens16/speed"
    eq "and a 100 Mbit/s one" "$(cake_default_mbit ens16)" 90
    eq "a virtual card that names no speed" "$(line_speed_mbit eth9)" ""
    eq "gets the 1 Gbit/s guess" "$(cake_default_mbit eth9)" 900
    eq "so does one with no speed file" "$(cake_default_mbit wg0)" 900
    echo garbage >"$SYS_NET/ens16/speed"
    eq "and a speed that is no number" "$(cake_default_mbit ens16)" 900
    echo 4294967295 >"$SYS_NET/ens16/speed"
    eq "or no sane one" "$(cake_default_mbit ens16)" 900
    yes_ is_cake_mbit 1
    yes_ is_cake_mbit 950
    yes_ is_cake_mbit 100000
    no_ is_cake_mbit 0
    no_ is_cake_mbit 100001
    no_ is_cake_mbit ""
    no_ is_cake_mbit 9.5
    no_ is_cake_mbit "950 "
    no_ is_cake_mbit "950mbit"
    no_ is_cake_mbit 0950
    yes_ is_cake_dev ens16
    no_ is_cake_dev gone0
    no_ is_cake_dev "../ens16"
    no_ is_cake_dev "../$(basename "$SYS_NET")/ens16"
    no_ is_cake_dev "ens16 root"
    no_ is_cake_dev ""
}
in_sub t_cake_defaults

echo "fair share: the settings"
t_cake_env() {
    CFG_CAKE=on CFG_CAKE_MBIT=950
    eq "on: the device and the bandwidth" "$(render_cake_env ens16 | grep -v '^#')" "HOLLOW_CAKE=on
HOLLOW_CAKE_DEV=ens16
HOLLOW_CAKE_MBIT=950"
    CFG_CAKE=off
    eq "off: only that, so the relay names no cap" "$(render_cake_env ens16 | grep -v '^#')" "HOLLOW_CAKE=off"
    CFG_CAKE=on
    eq "the text for the plan and the status" "$(cake_text)" "on, 950 Mbit/s"
    CFG_CAKE=off
    eq "off by choice" "$(cake_text)" "off"
    CFG_CAKE=""
    has "a setup from before the question" "$(cake_text)" "not chosen yet"
    for k in cake cake_mbit cake_dev; do
        has "the answer file knows $k" " ${ANSWER_KEYS//$'\n'/ } " " $k "
        has "install.conf keeps $k" " ${CONF_KEYS//$'\n'/ } " " $k "
    done
    has "a stopped first install keeps cake" " $DRAFT_KEYS " " cake "
    has "and cake_mbit" " $DRAFT_KEYS " " cake_mbit "
    has "the example answer file names cake" "$(cat "$T/answers.example")" "cake=on"
    has "and cake_mbit" "$(cat "$T/answers.example")" "cake_mbit="
    has "and the change menu's option" "$(cat "$T/answers.example")" "| cake |"
    has "the change menu offers it" "$(declare -f manage_change)" "ask_cake"
    has "a first install asks it" "$(cat "$RELAY/install.sh")" "ask_cake"
    has "Docker's relay hears the cap" " $DOCKER_ENV_KEYS " " HOLLOW_CAKE_MBIT "
}
in_sub t_cake_env

echo "fair share: the question"
# the_shaper_question_reads_its_answer_file_keys_and_takes_off
t_cake_question() {
    SYS_NET=$TMP/cake_q_net
    rm -rf "$SYS_NET"
    mkdir -p "$SYS_NET/ens16" "$SYS_NET/eth9"
    echo 1000 >"$SYS_NET/ens16/speed"
    ip() { [ "$*" = "-o -4 route show default" ] && echo "default via 203.0.113.1 dev ens16"; return 0; }
    plain_header() { :; }
    say() { :; }
    UI_MODE=answers
    ask() { # ask <answer file lines>: CFG_CAKE CFG_CAKE_MBIT CFG_CAKE_DEV after ask_cake
        printf '%s\n' "$@" >"$TMP/cake.ans"
        ANS=()
        ui_load_answers "$TMP/cake.ans"
        CFG_CAKE="" CFG_CAKE_MBIT="" CFG_CAKE_DEV=""
        ( ask_cake; echo "$CFG_CAKE ${CFG_CAKE_MBIT:--} ${CFG_CAKE_DEV:--}" )
    }
    eq "no key: on, at 90 percent of the line" "$(ask "mode=native")" "on 900 -"
    eq "an explicit off" "$(ask cake=off)" "off - -"
    eq "an off asks no number" "$(ask cake=off cake_mbit=500)" "off - -"
    eq "a number from the file" "$(ask cake=on cake_mbit=500)" "on 500 -"
    eq "a device from the file" "$(ask cake=on cake_mbit=500 cake_dev=eth9)" "on 500 eth9"
    has "a device that is not here stops" "$(ask cake=on cake_dev=gone0)" "DIE"
    has "a zero stops" "$(ask cake=on cake_mbit=0)" "DIE"
    has "a word stops" "$(ask cake=on cake_mbit=fast)" "DIE"
    has "neither on nor off stops" "$(ask cake=maybe)" "DIE"
    # The person sees why the number sits under the line, in plain words.
    local text
    text=$(declare -f ask_cake cake_mbit_text)
    has "the question says why it sits under the line" "$text" "under"
    has "and how to turn it off" "$text" "Off"
    lacks "no em dash" "$text" "$(printf '\342\200\224')"
}
in_sub t_cake_question

echo "fair share: applying it"
cake_stubs() { # <log>
    CAKE_LOG=$1
    : >"$CAKE_LOG"
    run() { echo "run $*" >>"$CAKE_LOG"; case "$*" in "systemctl start hollow-cake.service" | "systemctl reload hollow-cake.service") [ "${CAKE_START_FAILS:-0}" = 0 ] ;; *) return 0 ;; esac; }
    run_ok() { echo "run $*" >>"$CAKE_LOG"; return 0; }
    put_file() { echo "put $1 $2 $3" >>"$CAKE_LOG"; cat >"$TMP/cput.$(basename "$1")"; PUT_CHANGED=${PUT_FAKE:-1}; }
    ensure_dir() { echo "dir $1" >>"$CAKE_LOG"; }
    apt_install() { echo "apt $*" >>"$CAKE_LOG"; }
    step() { :; }
    say() { echo "say $*" >>"$CAKE_LOG"; }
    warn() { echo "warn $*" >>"$CAKE_LOG"; }
    modprobe() { [ "${CAKE_MODULE:-yes}" = yes ]; }
    unit_active() { return 1; }
    unit_exists() { [ -e "$UNIT_DIR/$1" ] || [ -e "$UNIT_DIR/$1.service" ]; }
    tc() { echo "tc $*" >>"$CAKE_LOG"; [ "$*" = "qdisc show dev ens16 root" ] && echo "${CAKE_QDISC:-qdisc fq_codel 0: root}"; return 0; }
    ip() { echo "default via 203.0.113.1 dev ens16"; }
    SYS_NET=$TMP/cake_a_net SYS_MODULE=$TMP/cake_a_mod
    mkdir -p "$SYS_NET/ens16" "$SYS_MODULE"
    echo 1000 >"$SYS_NET/ens16/speed"
    RELAY_ETC=$TMP/cake_etc UNIT_DIR=$TMP/cake_units
    CAKE_ENV=$RELAY_ETC/cake.env CAKE_MODLOAD=$TMP/cake_modload/hollow-cake.conf
    rm -rf "$RELAY_ETC" "$UNIT_DIR"
    mkdir -p "$RELAY_ETC" "$UNIT_DIR"
    DRY_RUN=0 RESTART_UNITS=() CFG_CAKE_DEV=""
}
# the_setup_puts_the_shaper_in_place_and_restarts_only_what_changed
t_cake_apply() {
    local log=$TMP/cake.log l
    cake_stubs "$log"
    CFG_CAKE=on CFG_CAKE_MBIT=950
    cake_apply
    l=$(cat "$log")
    has "its settings, root's alone" "$l" "put $CAKE_ENV 0600 root"
    eq "naming the device and the bandwidth" "$(grep -v '^#' "$TMP/cput.cake.env")" "HOLLOW_CAKE=on
HOLLOW_CAKE_DEV=ens16
HOLLOW_CAKE_MBIT=950"
    has "the unit" "$l" "put $UNIT_DIR/hollow-cake.service 0644 root"
    eq "as shipped" "$(cat "$TMP/cput.hollow-cake.service")" "$(cat "$DEPLOY/hollow-cake.service")"
    has "the module loads on every boot" "$l" "put $CAKE_MODLOAD 0644 root"
    eq "sch_cake" "$(cat "$TMP/cput.hollow-cake.conf")" "sch_cake"
    has "it starts on boot" "$l" "run systemctl enable --quiet hollow-cake.service"
    has "and now" "$l" "run systemctl start hollow-cake.service"
    has "the relay restarts to name the new cap" "${RESTART_UNITS[*]}" hollow-relay
    lacks "nothing to warn about" "$l" "warn "
    # The same settings again: nothing restarts.
    : >"$log"
    RESTART_UNITS=()
    unit_active() { [ "$1" = hollow-cake.service ]; }
    PUT_FAKE=0 cake_apply
    lacks "the same settings reload nothing" "$(cat "$log")" "reload hollow-cake"
    eq "nor the relay" "${RESTART_UNITS[*]}" ""
    # A new bandwidth reloads the shaper and restarts the relay.
    printf 'HOLLOW_CAKE=on\nHOLLOW_CAKE_DEV=ens16\nHOLLOW_CAKE_MBIT=950\n' >"$CAKE_ENV"
    CFG_CAKE_MBIT=800
    : >"$log"
    cake_apply
    has "a new bandwidth reloads the shaper" "$(cat "$log")" "run systemctl reload hollow-cake.service"
    lacks "in place, without a stop" "$(cat "$log")" "systemctl stop"
    has "and restarts the relay" "${RESTART_UNITS[*]}" hollow-relay
    # Another device: the old one's queue goes first, with the old settings.
    printf 'HOLLOW_CAKE=on\nHOLLOW_CAKE_DEV=eth7\nHOLLOW_CAKE_MBIT=800\n' >"$CAKE_ENV"
    : >"$log"
    cake_apply
    has "a move to another device stops the shaper first" "$(cat "$log")" "run systemctl stop hollow-cake.service"
    eq "before its settings change" "$(grep -E 'stop hollow-cake|put .*cake.env' "$log" | cut -c1-3 | tr '\n' ' ')" "run put "
    # A setup from before the question changes nothing.
    : >"$log"
    CFG_CAKE=""
    cake_apply
    eq "not chosen yet: nothing happens" "$(cat "$log")" ""
}
in_sub t_cake_apply

# a_kernel_without_sch_cake_is_named_and_never_stops_the_setup
t_cake_missing_module() {
    local log=$TMP/cake_mm.log l
    cake_stubs "$log"
    CFG_CAKE=on CFG_CAKE_MBIT=950 CAKE_MODULE=no CAKE_START_FAILS=1
    cake_apply
    l=$(cat "$log")
    has "the setup says what is missing" "$l" "sch_cake"
    has "and how to get it on Ubuntu" "$l" "linux-modules-extra-$(uname -r)"
    lacks "no module to load on boot" "$l" "put $CAKE_MODLOAD"
    has "the settings stay, so a fix needs one restart" "$l" "put $CAKE_ENV 0600 root"
    has "and so does the unit" "$l" "run systemctl enable --quiet hollow-cake.service"
    # A kernel that has it but a shaper that does not start says so, not the module.
    : >"$log"
    CAKE_MODULE=yes CAKE_START_FAILS=1
    cake_apply
    l=$(cat "$log")
    has "a start that fails points at its journal" "$l" "journalctl -u hollow-cake"
    lacks "not at the module" "$l" "linux-modules-extra"
    # The module already loaded counts, where modprobe cannot see it (a container).
    : >"$log"
    CAKE_MODULE=no CAKE_START_FAILS=0
    mkdir -p "$SYS_MODULE/sch_cake"
    cake_apply
    lacks "a loaded module needs nothing" "$(cat "$log")" "warn "
}
in_sub t_cake_missing_module

# turning_the_shaper_off_removes_its_queue_and_unit_and_says_off
t_cake_off() {
    local log=$TMP/cake_off.log l
    cake_stubs "$log"
    touch "$UNIT_DIR/hollow-cake.service"
    mkdir -p "$(dirname "$CAKE_MODLOAD")" && touch "$CAKE_MODLOAD"
    printf 'HOLLOW_CAKE=on\nHOLLOW_CAKE_DEV=ens16\nHOLLOW_CAKE_MBIT=950\n' >"$CAKE_ENV"
    CAKE_QDISC="qdisc cake 8001: root refcnt 2 bandwidth 950Mbit besteffort dual-dsthost"
    CFG_CAKE=off
    cake_apply
    l=$(cat "$log")
    has "off stops the shaper, whose stop removes the queue" "$l" "run systemctl disable --now hollow-cake.service"
    has "a queue left behind goes too" "$l" "run tc qdisc del dev ens16 root"
    has "its unit goes" "$l" "run rm -f $UNIT_DIR/hollow-cake.service"
    has "and the module line" "$l" "run rm -f $CAKE_MODLOAD"
    has "its settings say off, for check-host and the relay" "$(cat "$TMP/cput.cake.env")" "HOLLOW_CAKE=off"
    has "the relay restarts and names no cap" "${RESTART_UNITS[*]}" hollow-relay
    # Another root queue is the operator's and stays.
    rm -f "$UNIT_DIR/hollow-cake.service"
    CAKE_QDISC="qdisc fq 8002: root refcnt 2 limit 10000p"
    : >"$log"
    cake_apply
    lacks "a queue that is not CAKE stays" "$(cat "$log")" "tc qdisc del"
    # Every path that removes the relay takes the shaper along.
    cake_remove() { echo CAKE-REMOVED; }
    turn_lock_remove() { :; }
    has "the full setup's uninstall" "$(DRY_RUN=1 native_uninstall no 2>&1)" CAKE-REMOVED
    STACK_DIR=$TMP/cake_stack DOCKER_DIR=$TMP/cake_docker
    has "the Docker setup's uninstall" "$(DRY_RUN=1 docker_uninstall no 2>&1)" CAKE-REMOVED
}
in_sub t_cake_off

# Where the shaper goes in: before the relay starts, both setups.
t_cake_order() {
    local body
    body=$(declare -f native_apply)
    has "the full setup applies it" "$body" "cake_apply"
    yes_ test "$(grep -n 'cake_apply' <<<"$body" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'start_units' <<<"$body" | head -n 1 | cut -d: -f1)"
    body=$(declare -f docker_apply)
    has "so does the Docker setup, on the host" "$body" "cake_apply"
    yes_ test "$(grep -n 'cake_apply' <<<"$body" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'compose up -d' <<<"$body" | head -n 1 | cut -d: -f1)"
    has "an update keeps its settings for a rollback" " $UPDATE_SNAP_PATHS " " $CAKE_MODLOAD "
}
in_sub t_cake_order

# docker_relay_hears_the_shapers_cap
t_cake_docker_env() {
    STACK_DIR=$TMP/cake_denv
    rm -rf "$STACK_DIR" && mkdir -p "$STACK_DIR"
    put_file() { cat >"$TMP/cake_denv.out"; PUT_CHANGED=1; }
    mem_mb() { echo 2048; }
    CFG_TURN=no CFG_FORWARDER=no CFG_HOST=relay.example.org CFG_STAGING=no CFG_GRACE_SECS=120 FWD_KEY=""
    CFG_DUCKDNS_TOKEN="" CFG_DUCKDNS_IP="" CFG_PUBLIC_IP="" CFG_PUBLIC_IPV6="" PF_LOCAL_IP="" CFG_PUBLIC_STATS=on
    CFG_CAKE=on CFG_CAKE_MBIT=500
    docker_env
    has "on: the relay's environment names the cap" "$(cat "$TMP/cake_denv.out")" "HOLLOW_CAKE_MBIT=500"
    has "and that it is on" "$(cat "$TMP/cake_denv.out")" "HOLLOW_CAKE=on"
    CFG_CAKE=off
    docker_env
    has "off: it says off" "$(cat "$TMP/cake_denv.out")" "HOLLOW_CAKE=off"
    has "with no cap" "$(cat "$TMP/cake_denv.out")" "HOLLOW_CAKE_MBIT=
"
}
in_sub t_cake_docker_env

echo "fair share: check-host"
# check_host_names_a_missing_or_wrong_shaper_and_an_off_by_choice
t_cake_check_host() {
    local block conf=$TMP/ch_cake.env net=$TMP/ch_net out
    block=$(sed -n '/^check_fair_share() {/,/^}/p' "$DEPLOY/check-host.sh")
    has "check-host has the shaper's check" "$block" "check_fair_share"
    has "and runs it" "$(cat "$DEPLOY/check-host.sh")" 'check_fair_share /etc/hollow-relay/cake.env'
    has "the shaper is one of the units it checks" "$(grep -m1 '^for u in hollow-relay' "$DEPLOY/check-host.sh")" " hollow-cake "
    rm -rf "$net" && mkdir -p "$net/ens16" "$net/eth9"
    echo 1000 >"$net/ens16/speed"
    echo -1 >"$net/eth9/speed"
    run_check() { ( ok() { echo "OK $1"; }; bad() { echo "BAD $1"; }; eval "$block"; check_fair_share "$conf" "${RELAY_HERE:-1}" "$net" ); }
    ip() { case "$*" in "-o -4 route show default") echo "default via 203.0.113.1 dev ${ROUTE_DEV:-ens16} proto dhcp" ;; esac; return 0; }
    tc() { [ "$*" = "-j qdisc show dev ${QDEV:-ens16} root" ] && printf '%s\n' "$QD"; return 0; }
    systemctl() { [ "$*" = "is-enabled --quiet hollow-cake" ] && [ "${ENABLED:-yes}" = yes ]; }
    good='[{"kind":"cake","handle":"8001:","root":true,"refcnt":2,"options":{"bandwidth":118750000,"diffserv":"besteffort","flowmode":"dual-dsthost","nat":false,"wash":false,"ingress":false,"ack-filter":"disabled","split_gso":true,"rtt":100000,"raw":true,"overhead":0,"fwmark":"0"}}]'
    QD=$good
    printf 'HOLLOW_CAKE=on\nHOLLOW_CAKE_DEV=ens16\nHOLLOW_CAKE_MBIT=950\n' >"$conf"
    out=$(run_check)
    has "the right shaper passes" "$out" "OK the upload is shared fairly between the hosts this machine sends to (CAKE, 950 Mbit/s on ens16)"
    lacks "with nothing failing" "$out" "BAD"
    QD='[{"kind":"fq_codel","handle":"0:","root":true,"refcnt":2,"options":{}}]'
    out=$(run_check)
    has "no shaper on the device fails" "$out" "BAD the fair-share shaper (CAKE) is not on ens16"
    has "and says where to look and what a kernel may lack" "$out" "linux-modules-extra"
    lacks "and passes nothing" "$out" "OK"
    QD=""
    has "nor does an empty answer pass" "$(run_check)" "BAD the fair-share shaper (CAKE) is not on ens16"
    QD=${good/118750000/125000000}
    has "another bandwidth than its settings fails" "$(run_check)" "BAD CAKE on ens16 runs at 1000 Mbit/s, not the 950 Mbit/s its settings name"
    QD=${good/besteffort/diffserv4}
    has "a shaper that honours DSCP fails" "$(run_check)" "BAD CAKE on ens16 lets a client jump the queue by marking its packets (besteffort is missing)"
    QD=${good/dual-dsthost/triple-isolate}
    has "one that does not share per destination fails" "$(run_check)" "BAD CAKE on ens16 does not share per destination host (dual-dsthost is missing)"
    QD=${good/118750000/\"unlimited\"}
    printf 'HOLLOW_CAKE=on\nHOLLOW_CAKE_DEV=ens16\n' >"$conf"
    has "one with no bandwidth shares nothing" "$(run_check)" "BAD CAKE on ens16 has no bandwidth, so it never fills and shares nothing"
    printf 'HOLLOW_CAKE=on\nHOLLOW_CAKE_DEV=ens16\nHOLLOW_CAKE_MBIT=1000\n' >"$conf"
    QD=${good/118750000/125000000}
    has "one at or over the line never fills" "$(run_check)" "BAD CAKE on ens16 at 1000 Mbit/s is not under the line's 1000 Mbit/s, so it never fills and shares nothing"
    printf 'HOLLOW_CAKE=on\nHOLLOW_CAKE_DEV=ens16\nHOLLOW_CAKE_MBIT=950\n' >"$conf"
    QD=$good ROUTE_DEV=eth9
    has "a shaper off the default route fails" "$(run_check)" "BAD CAKE sits on ens16, but the default route leaves through eth9"
    ROUTE_DEV=ens16 ENABLED=no
    has "one that will not come back after a reboot fails" "$(run_check)" "BAD hollow-cake.service is not enabled, so the shaper is gone after a reboot"
    ENABLED=yes
    printf 'HOLLOW_CAKE=off\n' >"$conf"
    QD='[{"kind":"fq_codel","handle":"0:","root":true,"refcnt":2,"options":{}}]'
    out=$(run_check)
    has "off by the operator's choice passes, and says so" "$out" "OK the fair-share shaper (CAKE) is off by the operator's choice"
    lacks "with nothing failing" "$out" "BAD"
    rm -f "$conf"
    has "a relay with no settings and no shaper fails" "$(run_check)" "BAD one host can take all of ens16's upload: no fair-share shaper (CAKE)"
    QD=$good
    has "a shaper set up by hand passes without settings" "$(run_check)" "OK the upload is shared fairly between the hosts this machine sends to (CAKE, 950 Mbit/s on ens16)"
    QD=""
    eq "a machine with no relay and no settings has nothing to check" "$(RELAY_HERE=0 run_check)" ""
    lacks "check-host's lines carry no em dash" "$block" "$(printf '\342\200\224')"
}
in_sub t_cake_check_host
