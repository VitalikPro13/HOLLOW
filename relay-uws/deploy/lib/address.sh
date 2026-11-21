#!/bin/bash
# The relay's address: DuckDNS, a bare IP or a domain, and the DNS check that
# runs before any certificate request. Sourced.

# A DuckDNS subdomain from what a person types: the first part alone, the whole
# name, or a pasted link. Lowercased; empty if invalid.
duckdns_name_norm() {
    local n=${1,,}
    n=${n#"${n%%[![:space:]]*}"}
    n=${n%"${n##*[![:space:]]}"}
    n=${n#http://}
    n=${n#https://}
    n=${n%%/*}
    n=${n%.}
    n=${n%.duckdns.org}
    [[ "$n" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && printf '%s' "$n"
    return 0
}

valid_duckdns_token() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# A host name the relay can have: at least two labels, letters, digits and
# hyphens, no port.
valid_domain() {
    local d=${1,,}
    [ "${#d}" -le 253 ] || return 1
    [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

# duckdns_update <name> <token> <ip or empty>: prints OK or KO, and after OK the
# address DuckDNS recorded on the next line. The URL goes to the download program on
# stdin, so the token never shows in ps.
duckdns_update() {
    printf 'https://www.duckdns.org/update?domains=%s&token=%s&ip=%s&verbose=true\n' "$1" "$2" "$3" |
        net_get - 20 || printf 'FAILED'
}

# duckdns_token_prompt [<what was wrong last time>]: asks for the token into
# UI_REPLY. An empty answer asks for a file holding it, for a console where
# pasting does not work.
duckdns_token_prompt() {
    local wrong=${1:-}
    [ -n "$wrong" ] && wrong="$wrong

"
    ui_secret duckdns_token "Your DuckDNS token" \
"${wrong}Copy the token from the top of your DuckDNS page and paste it here. It is kept in a file only root can read and is never shown.

If pasting does not work here, leave this empty and press Enter, and I will ask for a file that holds the token instead."
    [ -n "$UI_REPLY" ] || [ "$UI_MODE" = answers ] || duckdns_token_from_file
}

duckdns_token_from_file() {
    local path
    while :; do
        ui_input duckdns_token_path "Path to a file holding the token" \
"Type the path of a file that holds the token alone on its first line, for example /root/duckdns-token. If you have none yet, stop the setup, run sudo nano /root/duckdns-token, which shows what you type, save the token in it and run the setup again. Nothing has changed yet. I read the file and never show the token. Leave this empty to go back to the token screen." ""
        path=$UI_REPLY
        [ -n "$path" ] || { UI_REPLY=""; return 0; }
        if ui_secret_file "$path"; then
            if [ "$UI_SECRET_FILE_OPEN" = 1 ]; then
                ui_msg "Anyone here can read that file" "Every account on this machine can read $path. Once the setup is done, delete it, or run: chmod 600 $path"
            fi
            return 0
        fi
        ui_msg "No such file" "I cannot read $path. Check the path and try again."
    done
}

# duckdns_check_token <name> <token>: prints OK or KO, and changes nothing a
# person sees: it clears the name's TXT record, which only a DNS certificate
# challenge uses, and leaves its address alone.
duckdns_check_token() {
    printf 'https://www.duckdns.org/update?domains=%s&token=%s&txt=&clear=true\n' "$1" "$2" |
        net_get - 20 || printf 'FAILED'
}

# Points the DuckDNS name at this machine, after the plan screen, and waits
# until DNS shows it. Without a pinned address that is the address DuckDNS saw the
# update come from. For an address this run measured, that has to be the same one:
# two different ways out of this network leave TURN on an address nothing proved.
# An address kept from install.conf may be older than the line's new one, which the
# address follower then moves TURN to once it proves to be this machine.
duckdns_point_now() {
    local name=${CFG_HOST%.duckdns.org} resp want=$CFG_PUBLIC_IP seen rc=0
    step "Pointing $CFG_HOST at ${CFG_DUCKDNS_IP:-this machine}"
    if [ "$DRY_RUN" = 1 ]; then
        say "  would update $CFG_HOST to ${CFG_DUCKDNS_IP:-the address DuckDNS sees} and wait for DNS to show it"
        return 0
    fi
    resp=$(duckdns_update "$name" "$CFG_DUCKDNS_TOKEN" "$CFG_DUCKDNS_IP")
    case "$resp" in
    OK*) ;;
    *) die "DuckDNS refused the update for $CFG_HOST. Check the token and the subdomain on your DuckDNS page, then run the setup again." ;;
    esac
    seen=$(printf '%s\n' "$resp" | sed -n 2p)
    if [ -z "$CFG_DUCKDNS_IP" ] && [ "$(ip4_class "$seen")" = public ] && [ "$seen" != "$CFG_PUBLIC_IP" ]; then
        [ "${PUBLIC_IP_MEASURED:-0}" = 1 ] &&
            die "DuckDNS saw this machine at $seen, but the internet saw it at $CFG_PUBLIC_IP a moment ago, so I can't tell which address people reach. Run the setup again in a few minutes. If the two still differ, your network has more than one way out to the internet, and the relay needs the address people reach typed in, at the address question or as public_ip in an answer file."
        want=$seen
    fi
    dns_points_at "$CFG_HOST" "$want" 180 || rc=$?
    case "$rc" in
    0)
        say "  it does"
        [ "$want" = "$CFG_PUBLIC_IP" ] || say "  DuckDNS sees this machine at $want, not $CFG_PUBLIC_IP. TURN and the forwarder move there once it proves to be this machine."
        return 0 ;;
    2) say "  $(dns_lan_note "$CFG_HOST")"; return 0 ;;
    esac
    die "$CFG_HOST still points at ${DNS_SEEN:-nothing} after three minutes, not $want. DuckDNS took the update, so DNS may just be slow. Wait a few minutes and run the setup again."
}

# dns_lan_note <name>: what to say when this network's DNS answers only with LAN
# addresses, as a router or a Pi-hole does for the machines at home.
dns_lan_note() {
    printf "this network's DNS answers %s with %s, a LAN address, so the public record can't be checked from here. The certificate step checks it instead." "$1" "$DNS_SEEN"
}

# The A records of <name>, one per line, from this machine's DNS servers asked as
# DNS (deploy/address-probe.py): never /etc/hosts, where Debian and Ubuntu name the
# machine itself, and never a cache that may hold an old answer.
dns_a() {
    local out a
    out=$(timeout 12 python3 -I "$DEPLOY/address-probe.py" dns "$1" A 2>/dev/null) || return 0
    [ "$(head -n 1 <<<"$out")" = rcode=0 ] || return 0
    tail -n +2 <<<"$out" | head -n 64 | while read -r a; do
        [ "$(ip4_class "$a")" = invalid ] || printf '%s\n' "$a"
    done
    return 0
}

# dns_points_at <name> <ip> <wait seconds>: waits for the name to resolve to the
# address, since a fresh record takes a minute to show everywhere. Returns 2 at once
# when every answer is a LAN address, which no wait changes.
dns_points_at() {
    local name=$1 ip=$2 wait=${3:-0} t0 got a lan
    t0=$(date +%s)
    while :; do
        got=$(dns_a "$name" | tr '\n' ' ' || true)
        DNS_SEEN=${got% }
        [[ " $got " == *" $ip "* ]] && return 0
        lan=0
        for a in $got; do
            if [ "$(ip4_class "$a")" = public ]; then lan=0; break; fi
            lan=1
        done
        [ "$lan" = 0 ] || return 2
        [ $(( $(date +%s) - t0 )) -ge "$wait" ] && return 1
        sleep 10
    done
}
