#!/bin/bash
# The questions of a first install, each one screen, and the DNS check that
# runs before the plan. They fill the CFG_* answers. Sourced by install.sh.

# ask_valid <key> <title> <text> <default> <check> <what is wrong>: asks until
# <check> accepts UI_REPLY. A person sees what was wrong on the same screen,
# with their answer filled in to edit; only an answer file stops the run.
ask_valid() {
    local key=$1 title=$2 text=$3 value=$4 check=$5 wrong=$6 shown=$3
    while :; do
        ui_input "$key" "$title" "$shown" "$value"
        "$check" "$UI_REPLY" && return 0
        [ "$UI_MODE" = answers ] && die "the answer file gives $key=$UI_REPLY. $wrong"
        value=$UI_REPLY
        shown="$UI_REPLY does not work here. $wrong

$text"
    done
}

is_ip4() { [ "$(ip4_class "$1")" != invalid ]; }
is_public_ip4() { [ "$(ip4_class "$1")" = public ]; }
is_domain() { valid_domain "$1"; }
is_duckdns_name() { [ -n "$(duckdns_name_norm "$1")" ]; }
is_key_count() { [[ "$1" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 200 ]; }
is_grace() { [[ "$1" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$1))" -ge 30 ] && [ "$((10#$1))" -le 600 ]; }

# yes_no <variable> <ui_yesno arguments...>: never inside $(...), where the
# screen itself would be captured.
yes_no() {
    local var=$1
    shift
    if ui_yesno "$@"; then printf -v "$var" yes; else printf -v "$var" no; fi
}

ask_mode() {
    ui_menu mode "How to run it" \
"We recommend the full setup. Each part of the relay runs as a system service under its own account and in its own sandbox, the way the official relay runs. Messages waiting for people who are offline, dropped connections and destroy orders all survive a restart or an update of the relay.

With Docker, everything runs in containers from the repository's compose file, and every restart or update of the relay container drops what is in its memory: messages waiting for people who are offline, the phones' push registrations, and destroy orders waiting for an offline device. Apps then fetch what they missed from each other, but a waiting destroy order is gone for good." \
        native native "Full setup (recommended)" docker "Docker"
    CFG_MODE=$UI_REPLY
}

ask_binaries() {
    if ! feed_lib_present; then
        CFG_BINARIES=source
        ui_msg "Building from source" "This copy of the installer cannot fetch the ready-made programs yet, so I will build the relay here from this copy of the repository. That takes a few minutes for the relay and up to an hour or two for the media forwarder."
        return 0
    fi
    ui_menu binaries "Ready-made programs or a build here" \
"We recommend the ready-made programs. I download the relay and the media forwarder built by the Hollow project, check the signature on the release list and the checksum of the download, and install them. It takes a minute, and an update later is one choice on the status screen.

To build from source, I compile both here from this copy of the repository. The relay takes a few minutes. The media forwarder is the whole Hollow core library and takes up to an hour or two on a small machine. When memory is short I add a temporary swap file for the build and remove it as soon as the build ends, because the hardening keeps swap off. An update then means pulling the repository and running the setup again." \
        prebuilt prebuilt "Ready-made programs (recommended)" source "Build from source"
    CFG_BINARIES=$UI_REPLY
    if [ "$CFG_BINARIES" = prebuilt ] && ! prebuilt_available; then
        CFG_BINARIES=source
        ui_msg "Building from source instead" "There are no ready-made programs for this machine, because $PREBUILT_WHY. I will build them here from this copy of the repository instead. That takes a few minutes for the relay and up to an hour or two for the media forwarder."
    fi
}

ask_public_ip() {
    local ip
    if ans_has public_ip; then
        ip=$(ans_get public_ip)
        is_ip4 "$ip" || die "the answer file gives public_ip=$ip, which is not an IPv4 address."
        CFG_PUBLIC_IP=$ip
        CFG_PUBLIC_IP_FIXED=yes
    elif [ "$PF_BEHIND_NAT" = 1 ] && [ "$UI_MODE" != answers ]; then
        ask_valid public_ip "The address people reach" \
"The internet sees this machine as $PF_PUBLIC_IP, and I will point the relay's address there. If people reach this machine at another address, for example only on your own network, type that address instead. Otherwise press Enter." \
            "$PF_PUBLIC_IP" is_ip4 "An IPv4 address has four numbers from 0 to 255 with dots between them, like 192.168.1.20."
        CFG_PUBLIC_IP=$UI_REPLY
        if [ "$UI_REPLY" = "$PF_PUBLIC_IP" ]; then CFG_PUBLIC_IP_FIXED=no; else CFG_PUBLIC_IP_FIXED=yes; fi
    else
        CFG_PUBLIC_IP=$PF_PUBLIC_IP
        CFG_PUBLIC_IP_FIXED=no
    fi
    CFG_PUBLIC_IPV6=$(ans_get public_ipv6 "$PF_PUBLIC_IPV6")
    # It opens coturn's peer lock to that address, so one global address only.
    if [ -n "$CFG_PUBLIC_IPV6" ] && [ "$(ip6_class "$CFG_PUBLIC_IPV6")" != global ]; then
        die "public_ipv6=$CFG_PUBLIC_IPV6 is not one public IPv6 address."
    fi
    CFG_DUCKDNS_IP=""
    [ "$CFG_PUBLIC_IP_FIXED" = yes ] && CFG_DUCKDNS_IP=$CFG_PUBLIC_IP
    return 0
}

ask_duckdns() {
    local name token resp
    local wrong=""
    ask_valid duckdns_name "Your DuckDNS name" \
"Sign in at duckdns.org with any of the accounts it offers and add a subdomain. Then type the first part of your DuckDNS name here. For hollowtest.duckdns.org, that is hollowtest. The whole name works too." \
        "${CFG_DUCKDNS_NAME:-}" is_duckdns_name "The first part of a DuckDNS name has letters, digits and hyphens only."
    name=$(duckdns_name_norm "$UI_REPLY")
    while :; do
        duckdns_token_prompt "$wrong"
        token=$(printf '%s' "$UI_REPLY" | tr -d '[:space:]')
        if ! valid_duckdns_token "$token"; then
            [ "$UI_MODE" = answers ] && die "the DuckDNS token from the answer file does not look like one (8-4-4-4-12 hexadecimal)."
            wrong="That was not a DuckDNS token. One looks like a1b2c3d4-0000-1111-2222-333344445555."
            continue
        fi
        if [ "$DRY_RUN" = 1 ]; then
            say "  would check the token with DuckDNS, leaving the name's address as it is"
            break
        fi
        say "  checking the token with DuckDNS. The name's address stays as it is until you confirm the plan."
        resp=$(duckdns_check_token "$name" "$token")
        case "$resp" in
        OK*) break ;;
        esac
        [ "$UI_MODE" = answers ] && die "DuckDNS refused the name $name with that token. Check both on the DuckDNS page."
        wrong="DuckDNS refused the name $name with that token. Check that the subdomain is on your DuckDNS page and that the token was copied whole."
    done
    CFG_DUCKDNS_NAME=$name
    CFG_DUCKDNS_TOKEN=$token
    CFG_HOST=$name.duckdns.org
}

ask_address() {
    ask_public_ip
    ui_menu address "Your relay's address" \
"People type this address into the app, and it needs a certificate from Let's Encrypt, because Hollow refuses self-signed ones.

We recommend a free DuckDNS name, like myrelay.duckdns.org. If this machine ever gets a new address, the name follows it and nobody has to type anything new. The certificate comes through DNS, so port 80 stays closed.

The bare IP address, $CFG_PUBLIC_IP, needs no sign-up. Port 80 has to stay open for the certificate, which lasts six days and renews on its own. If the address ever changes, every member has to type the new one.

For a domain you own, point its A record at $CFG_PUBLIC_IP first. Port 80 has to stay open for the certificate." \
        duckdns duckdns "A DuckDNS name (recommended)" ip "The bare IP address" domain "A domain I own"
    CFG_ADDRESS=$UI_REPLY
    case "$CFG_ADDRESS" in
    duckdns) ask_duckdns ;;
    ip)
        ask_valid ip "The IP address" "The relay's address will be this IPv4 address. Press Enter to use the one the internet sees." \
            "$CFG_PUBLIC_IP" is_public_ip4 "Let's Encrypt certifies only a public IPv4 address, not a private one such as 192.168.1.20."
        CFG_HOST=$UI_REPLY ;;
    domain)
        local d=${CFG_HOST:-}
        [ "$(ip4_class "$d")" = invalid ] && [[ "$d" != *.duckdns.org ]] || d=""
        ask_valid domain "Your domain" "Type the full name, like relay.example.com. Its A record must point at $CFG_PUBLIC_IP." \
            "$d" is_domain "A domain has letters, digits, hyphens and dots, like relay.example.com, with no port and no https://."
        CFG_HOST=${UI_REPLY,,} ;;
    esac
}

# No email: Let's Encrypt keeps none on an account any more. An answer file's
# email= is still accepted and ignored.
cert_answers() {
    CFG_STAGING=$(ans_get staging no)
    case "$CFG_STAGING" in yes|no) ;; *) die "staging takes yes or no." ;; esac
}

ask_turn() {
    yes_no CFG_TURN turn "TURN for calls" \
"TURN gets a call through when both people are behind strict networks and no direct route exists, which happens with some mobile carriers and office networks. The call's audio and video then flow through this machine, so those calls cost its bandwidth.

We recommend yes. It opens TCP and UDP ports 3478 and 5349, and UDP ports 49152 to 65535.

With no, calls need a direct route between the two people, which works most of the time. When a call fails for this reason, the app says so." "${CFG_TURN:-yes}"
}

ask_push() {
    if [ "$CFG_MODE" = docker ]; then CFG_PUSH=yes; return 0; fi
    yes_no CFG_PUSH push "Push notifications for Android" \
"An Android phone that is asleep needs a wake-up when a message arrives. This adds a small sender for UnifiedPush. Each person installs a UnifiedPush app such as ntfy on their phone and picks it in Hollow under Settings > Notifications > Push delivery, in the Wake-up service row. The wake-up carries no message content and is encrypted to the phone before it leaves this machine.

It needs Node.js 22. I install it from NodeSource's signed apt repository, so its security fixes arrive with the system's own automatic updates. No port opens to the internet.

We recommend yes. Without it, Android phones only get new messages while Hollow is open.

iPhone notifications don't work on a self-hosted relay. Apple only delivers notifications signed with the key from Hollow's Apple Developer account. That key stays on the official relay, because anyone who has it could send notifications pretending to be Hollow. iPhones still get new messages while Hollow is open." "${CFG_PUSH:-yes}"
}

ask_forwarder() {
    local docker_note=""
    [ "$CFG_MODE" = docker ] && docker_note="

In the Docker setup the forwarder is built from source, which takes up to an hour or two on a small machine."
    yes_no CFG_FORWARDER forwarder "Media forwarder for screen shares" \
"When someone shares their screen with several viewers, the forwarder takes one copy of the stream and sends it on to each viewer, so the person sharing uploads it only once. It carries only encrypted media and holds no keys, so it cannot see the screen.

It costs this machine upload for every viewer, roughly 1 to 3 Mbit/s each, and opens UDP ports 40000 to 40199. Without it, screen shares still work. A viewer's own app can pass the stream on, or the person sharing sends a copy to each viewer.

We recommend yes if this machine has a fast connection and your group shares screens.$docker_note" "${CFG_FORWARDER:-yes}"
}

ask_members() {
    yes_no CFG_MEMBERS_ONLY members_only "Who may connect" \
"By default anyone who knows your relay's address can connect, the same as on the official relay. A members-only relay asks for an access key the first time someone connects. One key admits up to 5 devices, so a person's phone and desktop share one key.

We recommend no for most groups, since only the people you give the address to will find the relay. Choose yes to hand out keys. You can add or remove keys later from the status screen." "${CFG_MEMBERS_ONLY:-no}"
    if [ "$CFG_MEMBERS_ONLY" = yes ]; then
        local have=$CFG_MEMBER_KEYS
        [ "$have" -gt 0 ] 2>/dev/null || have=5
        ask_valid member_keys "How many keys" "How many keys should I make? One for each person. The setup shows them at the end, and the status screen shows them again whenever you run it." \
            "$have" is_key_count "Type a whole number from 1 to 200."
        CFG_MEMBER_KEYS=$((10#$UI_REPLY))
    fi
}

# public_stats_norm <value>: on or off, read the way the relay reads
# PUBLIC_STATS (server_stats.h): empty means on, and a value it does not know
# means off.
public_stats_norm() {
    local v=${1,,}
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    case "$v" in
    "" | on | true | yes | 1) echo on ;;
    *) echo off ;;
    esac
}

public_stats_text() {
    if [ "$(public_stats_norm "${CFG_PUBLIC_STATS:-on}")" = on ]; then echo on
    else echo "off, without the online count and the traffic"; fi
}

ask_public_stats() {
    ui_menu public_stats "The public stats page" \
"Your relay serves a small stats page that anyone who knows its address can open. It shows how many people are online, how much traffic the relay carries and how much memory it uses. The app's relay card shows the same figures.

We recommend on. With it off, the page leaves out the online count and the traffic and rounds the memory to whole percent. The app's relay card then shows only memory.

On a relay for a small group, the online count can tell an outsider when its people are around. Choose off if that matters to you." \
        "$(public_stats_norm "${CFG_PUBLIC_STATS:-on}")" on "On (recommended)" off "Off"
    CFG_PUBLIC_STATS=$UI_REPLY
}

ask_grace() {
    ask_valid grace_secs "Waiting for dropped connections" \
"When someone's connection drops, the relay keeps their place for a while: the rooms they were in and everything sent to them since. If their app comes back in time, it picks up where it left off and misses nothing.

We recommend the default of 120 seconds. Anything from 30 to 600 works. A longer wait covers longer gaps, like a train tunnel, and holds more memory while people are away, at most 8 MB each." \
        "${CFG_GRACE_SECS:-120}" is_grace "Type a whole number of seconds from 30 to 600."
    CFG_GRACE_SECS=$((10#$UI_REPLY))
}

# DNS is checked before any certificate request: Let's Encrypt allows only a
# few failed attempts an hour. A person can fix it and check again, or pick
# another address; an answer file stops.
address_prepare() {
    while :; do
        address_check && return 0
        [ "$UI_MODE" = answers ] && die "$ADDRESS_WHY"
        ui_menu address_retry "The address is not ready" "$ADDRESS_WHY" \
            retry retry "Check again" change "Choose another address" stop "Stop here"
        case "$UI_REPLY" in
        change) ask_address ;;
        stop) say "Stopped. Nothing was changed, and the next run offers your answers again."; exit 0 ;;
        esac
    done
}

# Sets ADDRESS_WHY when the chosen address cannot get its certificate yet.
address_check() {
    ADDRESS_WHY=""
    case "$CFG_ADDRESS" in
    ip) return 0 ;;
    # Pointed at this machine only after the plan screen (duckdns_point_now).
    duckdns) return 0 ;;
    domain)
        if [ "$CFG_MODE" = native ] && port_busy 80 && [ "$(port_owner 80)" != hollow-relay ]; then
            ADDRESS_WHY="Port 80 is in use by $(port_owner 80), and a domain's certificate needs it free. Stop that program, then check again."
            return 1
        fi ;;
    esac
    step "Checking that $CFG_HOST points at $CFG_PUBLIC_IP"
    if dns_points_at "$CFG_HOST" "$CFG_PUBLIC_IP" 30; then
        say "  it does"
        return 0
    fi
    [ "$DRY_RUN" = 1 ] && { say "  it does not yet (${DNS_SEEN:-no answer}); a real run would stop here"; return 0; }
    ADDRESS_WHY="$CFG_HOST points at ${DNS_SEEN:-nothing}, not at this machine ($CFG_PUBLIC_IP). Set its A record to $CFG_PUBLIC_IP at your DNS provider and wait until it shows, then check again. I did not ask Let's Encrypt yet, so no attempt was used up."
    return 1
}
