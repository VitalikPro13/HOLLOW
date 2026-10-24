#!/bin/bash
# A relay this setup did not install: a hand setup from the old SELF_HOSTING.md
# (services under systemd) or a plain `docker compose up` in relay-uws. It is
# found and shown, then taken over into the setup's own layout or left alone.
# Either way the machine itself is checked and its hardening offered.
# Nothing changes until the person chooses. Sourced by install.sh.

ADOPT_KIND=none            # none | native | docker | other
ADOPT_WHY_NOT=()           # why take over is not offered
ADOPT_NOTES=()             # what the person should know either way
ADOPT_ARMED=0              # a failure from here on puts the old relay back
ADOPT_BACKUP=""
ADOPT_BACKUP_ROOT=/root
ADOPT_UNIT_DIRS="/etc/systemd/system /usr/local/lib/systemd/system /lib/systemd/system /usr/lib/systemd/system"
ADOPT_CRON_FILES="/etc/crontab /etc/cron.d/*"
ADOPT_USER_CRONTABS=/var/spool/cron/crontabs
ADOPT_LE=/etc/letsencrypt
# What a take over carries into the new settings (native.sh and docker.sh read them).
SEED_TURN_SECRET="" SEED_PUSH_TOKEN="" SEED_EXEMPT="" SEED_KEYS_FILE="" SEED_FWD_LICENSE="" SEED_FWD_ID="" SEED_OWN_CERT_DIR=""

why_not() { ADOPT_WHY_NOT+=("$1"); }
adopt_note() { ADOPT_NOTES+=("$1"); }

# Test seams: every question to systemd and Docker goes through these.
adopt_prop() { systemctl show -p "$2" --value "$1" 2>/dev/null || true; }
adopt_docker() { docker "$@"; }
adopt_unit_on() { systemctl is-active --quiet "$1" 2>/dev/null || systemctl is-enabled --quiet "$1" 2>/dev/null; }
adopt_active() { if systemctl is-active --quiet "$1" 2>/dev/null; then echo yes; else echo no; fi; }
adopt_enabled() { if systemctl is-enabled --quiet "$1" 2>/dev/null; then echo yes; else echo no; fi; }
adopt_relay_pids() { pgrep -x hollow-relay 2>/dev/null || true; }
adopt_cgroup() { cat "/proc/$1/cgroup" 2>/dev/null || true; }
adopt_proc_uid() { awk '$1 == "Uid:" {print $2}' "/proc/$1/status" 2>/dev/null || true; }
adopt_443_pids() { ss -Hltnp 'sport = :443' 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true; }
# What a take over writes into, checked for links first.
ADOPT_WRITE_DIRS="/etc/hollow-relay /etc/hollow-push /etc/hollow-forwarder /etc/hollow-turn /etc/hollow-duckdns /var/lib/hollow-relay /var/lib/hollow-forwarder /opt/hollow-push /usr/local/lib/hollow-relay"

# Shapes a value must have before it goes into a unit, an env file or .env.
safe_secret() { [[ "$1" =~ ^[A-Za-z0-9._~+/=-]{8,512}$ ]]; }
safe_path() { [[ "$1" =~ ^/[A-Za-z0-9._/@+-]*$ ]] && [[ "$1" != *..* ]]; }
safe_exempt() { [[ "$1" =~ ^[0-9A-Fa-f.:/,\ ]{0,1024}$ ]]; }
is_peer_id() { [[ "$1" =~ ^12D3KooW[1-9A-HJ-NP-Za-km-z]{20,80}$ ]]; }
host_usable() { valid_domain "$1" || [ "$(ip4_class "$1")" != invalid ]; }

# plain_read <path>: a regular file that is not a link, so reading it as root
# reads that file and no other.
plain_read() {
    local dir
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    dir=$(cd "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
    [ "$(readlink -f -- "$1")" = "$dir/$(basename -- "$1")" ]
}

# arg_value <flag> <program> <word...>: the value the relay takes for <flag>,
# read as its config.h reads argv: the last copy wins, and the word after any
# flag that takes one is that flag's value, never a flag of its own.
RELAY_VALUE_FLAGS=" --port --public-ip --domain --keys-file --reports-file --cert-file --key-file --forwarder-peer-id --session-grace-secs "
arg_value() {
    local flag=$1 i v=""
    shift
    local a=("$@")
    for ((i = 1; i < ${#a[@]}; i++)); do
        [ "${a[$i]}" = "$flag" ] || [[ "$RELAY_VALUE_FLAGS" == *" ${a[$i]} "* ]] || continue
        [ $((i + 1)) -lt ${#a[@]} ] || break
        [ "${a[$i]}" = "$flag" ] && v=${a[$((i + 1))]}
        i=$((i + 1))
    done
    printf '%s' "$v"
}

# adopt_argv <unit>: the words of its one ExecStart. Returns 2 when it has more.
adopt_argv() {
    local s n
    s=$(adopt_prop "$1" ExecStart)
    n=$(grep -o 'argv\[\]=' <<<"$s" | wc -l)
    [ "$n" -le 1 ] || return 2
    sed -n 's/.*argv\[\]=\([^;]*\) ;.*/\1/p' <<<"$s" | sed 's/[[:space:]]*$//'
}

# adopt_unit_env <unit> <VAR>: what the service gets for VAR. Its environment
# files win over Environment=, as in systemd. Read, never sourced or printed.
adopt_unit_env() {
    local u=$1 var=$2 v f x
    v=$(adopt_prop "$u" Environment | tr ' ' '\n' | sed -n "s/^$var=//p" | tail -n 1)
    for f in $(adopt_prop "$u" EnvironmentFiles | grep -oE '/[^ ]+' || true); do
        plain_read "$f" || continue
        x=$(kv_get "$f" "$var")
        [ -n "$x" ] && v=$x
    done
    printf '%s' "$v"
}

# A path the relay reads, made absolute against its working directory.
abs_in() {
    case "$2" in
    /*) printf '%s' "$2" ;;
    '') printf '%s/%s' "${1%/}" "$3" ;;
    *) printf '%s/%s' "${1%/}" "$2" ;;
    esac
}

# ---------------------------------------------------------------- finding

A_RELAY_UNITS=() A_FWD_UNITS=() A_TURN_UNITS=() A_PUSH_UNITS=() A_BOOT_UNITS=() A_OWN_UNITS=()
A_OUTSIDE=() A_IN_CONTAINER=0 A_PROJECTS=() A_DOCKER_DOWN=0

adopt_unit_files() {
    local d
    for d in $ADOPT_UNIT_DIRS; do
        [ -d "$d" ] || continue
        grep -lE 'hollow|turnserver|coturn|push-sidecar' "$d"/*.service 2>/dev/null || true
    done
}

adopt_scan_units() {
    A_RELAY_UNITS=() A_FWD_UNITS=() A_TURN_UNITS=() A_PUSH_UNITS=() A_BOOT_UNITS=() A_OWN_UNITS=()
    local f u seen=" " argv rc exe
    for f in $(adopt_unit_files); do
        u=$(basename "$f")
        case "$seen" in *" $u "*) continue ;; esac
        seen="$seen$u "
        [ "$(adopt_prop "$u" LoadState)" = loaded ] || continue
        rc=0
        argv=$(adopt_argv "$u") || rc=$?
        if [ "$rc" = 2 ]; then
            grep -q 'hollow-relay' "$f" 2>/dev/null && why_not "$u starts more than one program, so I cannot tell which one is the relay."
            continue
        fi
        exe=${argv%% *}
        case "${exe##*/}" in
        hollow-relay)
            # A first install of this setup that stopped part of the way carries on.
            if head -n 1 "$(adopt_prop "$u" FragmentPath)" 2>/dev/null | grep '^# Written by install.sh' >/dev/null; then
                A_OWN_UNITS+=("$u")
                continue
            fi
            A_RELAY_UNITS+=("$u"); continue ;;
        hollow-forwarder) A_FWD_UNITS+=("$u"); continue ;;
        turnserver)
            # The package's own coturn counts only while it runs or starts on boot.
            adopt_unit_on "$u" && A_TURN_UNITS+=("$u")
            continue ;;
        esac
        case " $argv " in
        *coturn-start.sh*) A_TURN_UNITS+=("$u") ;;
        *push-sidecar/index.js*|*hollow-push/index.js*) A_PUSH_UNITS+=("$u") ;;
        *" compose up"*|*"docker-compose up"*)
            case "$(adopt_prop "$u" WorkingDirectory)" in */relay-uws) A_BOOT_UNITS+=("$u") ;; esac ;;
        esac
    done
}

# Relays running where no unit or compose project explains them. Any account
# can start a program of its own called hollow-relay, from its shell or its
# crontab, so one counts only when root runs it, it holds port 443, it runs as
# the account its system service names, or root's container runtime started it.
adopt_scan_processes() {
    A_OUTSIDE=() A_IN_CONTAINER=0
    local pid cg u uid on443 who trusted unit_user
    on443=" $(adopt_443_pids | tr '\n' ' ') "
    for pid in $(adopt_relay_pids); do
        cg=$(adopt_cgroup "$pid")
        uid=$(adopt_proc_uid "$pid")
        trusted=0
        { [ "$uid" = 0 ] || [[ "$on443" == *" $pid "* ]]; } && trusted=1
        case "$cg" in
        */user.slice/*) ;;
        *docker*|*containerd*|*libpod*) A_IN_CONTAINER=1; continue ;;
        *.service*)
            u=$(sed -n 's|.*/\([^/]*\.service\).*|\1|p' <<<"$cg" | head -n 1)
            case " ${A_RELAY_UNITS[*]} ${A_OWN_UNITS[*]} " in *" $u "*) continue ;; esac
            unit_user=$(adopt_prop "$u" User)
            [ -n "$uid" ] && [ "$uid" = "$(getent passwd "${unit_user:-root}" 2>/dev/null | cut -d: -f3)" ] && trusted=1 ;;
        esac
        if [ "$trusted" = 1 ]; then
            A_OUTSIDE+=("$pid")
        else
            who=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
            adopt_note "A program called hollow-relay runs as ${who:-the account $uid} (process $pid). It does not run as root and does not hold port 443, so it is not this machine's relay. I left it alone."
        fi
    done
}

adopt_scan_docker() {
    A_PROJECTS=() A_DOCKER_DOWN=0
    have docker || return 0
    if ! adopt_docker info >/dev/null 2>&1; then A_DOCKER_DOWN=1; return 0; fi
    local proj wd cfg
    while IFS='|' read -r proj wd cfg; do
        [ -n "$proj" ] || continue
        case "$cfg" in
        */relay-uws/docker-compose.yml|*/relay-uws/docker-compose.yaml|*/relay-uws/compose.yml|*/relay-uws/compose.yaml) ;;
        *) case "$wd" in */relay-uws) ;; *) continue ;; esac ;;
        esac
        # The setup's own stack.
        [ "$wd" = "$STACK_DIR" ] && continue
        case " ${A_PROJECTS[*]} " in *" $proj "*) ;; *) A_PROJECTS+=("$proj") ;; esac
    done < <(adopt_docker ps -a --filter label=com.docker.compose.project \
        --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.Label "com.docker.compose.project.config_files"}}' 2>/dev/null || true)
}

# Sets ADOPT_KIND and everything the screens show. Reads only.
adopt_detect() {
    ADOPT_KIND=none ADOPT_WHY_NOT=() ADOPT_NOTES=()
    adopt_scan_units
    adopt_scan_processes
    adopt_scan_docker
    local nn=${#A_RELAY_UNITS[@]} nd=${#A_PROJECTS[@]}
    if [ "$nn" = 0 ] && [ "$nd" = 0 ] && [ ${#A_OUTSIDE[@]} = 0 ] && [ "$A_IN_CONTAINER" = 0 ] && [ ${#ADOPT_WHY_NOT[@]} = 0 ]; then
        return 0
    fi
    if [ "$nn" -gt 0 ] && [ "$nd" -gt 0 ]; then
        why_not "There is a relay under systemd (${A_RELAY_UNITS[*]}) and one in Docker (${A_PROJECTS[*]}). I take over only one relay, so remove the one you do not use first."
    elif [ "$nn" -gt 1 ]; then
        why_not "There are several relay services (${A_RELAY_UNITS[*]}), so I cannot tell which one people use."
    elif [ "$nd" -gt 1 ]; then
        why_not "There are several Docker projects with a relay (${A_PROJECTS[*]}), so I cannot tell which one people use."
    fi
    [ ${#A_OUTSIDE[@]} -gt 0 ] && why_not "A relay runs outside systemd and Docker (process ${A_OUTSIDE[*]}), so I cannot stop it safely or know how it starts."
    if [ "$A_IN_CONTAINER" = 1 ] && [ "$nd" = 0 ]; then
        why_not "A relay runs in a container that does not come from relay-uws/docker-compose.yml."
    fi
    if [ "$nn" = 1 ] && [ "$nd" = 0 ]; then
        ADOPT_KIND=native
        adopt_native_facts
    elif [ "$nd" = 1 ] && [ "$nn" = 0 ]; then
        ADOPT_KIND=docker
        adopt_docker_facts
    else
        ADOPT_KIND=other
    fi
    [ "$A_DOCKER_DOWN" = 1 ] && adopt_note "Docker is installed but not running, so I could not look for relay containers."
    return 0
}

adopt_can_take() {
    case "$ADOPT_KIND" in native|docker) [ ${#ADOPT_WHY_NOT[@]} = 0 ] ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- facts both setups share

OLD_HOST="" OLD_TURN_SECRET="" OLD_PUSH_TOKEN="" OLD_EXEMPT="" OLD_GRACE=120 OLD_FWD_ID=""
OLD_TURN=no OLD_TURN_RUNS=no OLD_PUSH=no OLD_PUSH_RUNS=no OLD_FWD=no OLD_FWD_RUNS=no OLD_FWD_KEY=""
OLD_KEYS_FILE="" OLD_MEMBERS=no OLD_KEYS_GOOD=0 OLD_KEYS_BAD=0 OLD_KEY_LIST=()
OLD_REPORTS_FILE="" OLD_REPORTS_TEXT="" OLD_VERSION="" OLD_RELAY_RUNS=no
OLD_CERT_TEXT="" OLD_CERT_FP="" OLD_CERT_END="" OLD_LINEAGE="" OLD_AUTH="" OLD_STAGING=no OLD_RENEW="" OLD_NEW_CERT=no
OLD_ADDRESS=domain OLD_DUCKDNS_TOKEN="" OLD_DUCKDNS_IP="" OLD_DUCKDNS_CRON="" OLD_PUBLIC_IP="" OLD_PUBLIC_IPV6=""
OLD_OWN_CERT_DIR="" OLD_FWD_LICENSE="" OLD_PUBLIC_STATS=on OLD_ENV_FILES=""

# keys_facts <keys.json>: how many keys, and how many of them the app cannot use.
keys_facts() {
    OLD_KEYS_GOOD=0 OLD_KEYS_BAD=0 OLD_MEMBERS=no OLD_KEY_LIST=()
    [ -n "$1" ] && [ -e "$1" ] || return 0
    if ! plain_read "$1"; then why_not "The members-only keys file $1 is a link or not a plain file."; return 0; fi
    # The forwarder's own key sits in the same file and is no member's. Keys are
    # compared in bash: on a command line, ps shows them to every local account.
    local k all=() fwd_in=0
    mapfile -t all < <(member_keys_read "$1" | sort -u)
    for k in "${all[@]}"; do
        if [ -n "${OLD_FWD_LICENSE:-}" ] && [ "$k" = "$OLD_FWD_LICENSE" ]; then fwd_in=1; else OLD_KEY_LIST+=("$k"); fi
    done
    OLD_KEYS_GOOD=${#OLD_KEY_LIST[@]}
    grep -qE '"enabled"[[:space:]]*:[[:space:]]*true' "$1" && OLD_MEMBERS=yes
    if have jq; then
        local total
        total=$(jq -r '[.keys[]? | strings] | unique | length' "$1" 2>/dev/null || echo "")
        if [ -z "$total" ]; then
            why_not "The members-only keys file $1 is not valid JSON, so I could not read the keys in it."
        else
            [ "$fwd_in" = 1 ] && total=$((total - 1))
            [ "$total" -gt "$OLD_KEYS_GOOD" ] && OLD_KEYS_BAD=$((total - OLD_KEYS_GOOD))
        fi
    fi
    return 0
}

# reports_facts <reports.json>: a count for the screen, never who.
reports_facts() {
    local f=$1 n p
    OLD_REPORTS_TEXT="none yet"
    [ -n "$f" ] || return 0
    if [ -e "$f" ] && ! plain_read "$f"; then why_not "The report counts file $f is a link or not a plain file."; return 0; fi
    if [ -e "$f.key" ] && ! plain_read "$f.key"; then why_not "The report key $f.key is a link or not a plain file."; return 0; fi
    [ -e "$f" ] || return 0
    if have jq; then
        n=$(jq -r '[.counts // {} | .[] | .[]? | numbers] | add // 0' "$f" 2>/dev/null || true)
        p=$(jq -r '.counts // {} | length' "$f" 2>/dev/null || true)
        if [ -n "$n" ] && [ -n "$p" ]; then
            OLD_REPORTS_TEXT="$n reports about $p people"
            [ "$p" = 1 ] && OLD_REPORTS_TEXT="$n reports about 1 person"
            [ "$n" = 1 ] && OLD_REPORTS_TEXT="1 report about 1 person"
            [ "$n" = 0 ] && OLD_REPORTS_TEXT="none yet"
        else
            OLD_REPORTS_TEXT="a file I could not read as JSON"
        fi
    else
        OLD_REPORTS_TEXT="kept, not counted (jq is not installed yet)"
    fi
    return 0
}

# cert_facts <pem>: sets OLD_CERT_TEXT, OLD_CERT_FP and OLD_CERT_END.
cert_facts() {
    local f=$1 issuer subject org cn
    OLD_CERT_TEXT="" OLD_CERT_FP="" OLD_CERT_END=""
    [ -s "$f" ] || return 1
    OLD_CERT_END=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)
    [ -n "$OLD_CERT_END" ] || return 1
    OLD_CERT_FP=$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' || true)
    issuer=$(openssl x509 -in "$f" -noout -issuer 2>/dev/null | sed 's/^issuer= *//' || true)
    subject=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^subject= *//' || true)
    org=$(grep -oE 'O ?= ?[^,/]*' <<<"$issuer" | head -n 1 | sed 's/^O ?= ?//; s/^O *= *//' || true)
    cn=$(grep -oE 'CN ?= ?[^,/]*' <<<"$issuer" | head -n 1 | sed 's/^CN *= *//' || true)
    if [ "$issuer" = "$subject" ]; then
        OLD_CERT_TEXT="self-signed, which the app refuses"
    elif [[ "$issuer" == *STAGING* ]]; then
        OLD_CERT_TEXT="from Let's Encrypt's staging service, which the app refuses"
    else
        OLD_CERT_TEXT="from ${org:-an unknown issuer}${cn:+ ($cn)}"
    fi
    OLD_CERT_TEXT="$OLD_CERT_TEXT, valid until $(date -d "$OLD_CERT_END" +'%-d %b %Y' 2>/dev/null || echo "$OLD_CERT_END")"
}

# cert_covers <pem> <host>
cert_covers() {
    openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' |
        sed 's/^[[:space:]]*//; s/^DNS://; s/^IP Address://' | grep -ixF -- "$2" >/dev/null
}

# The cert a relay on this machine serves under <host>, into <file>.
served_cert_to() {
    timeout 6 openssl s_client -connect 127.0.0.1:443 -servername "$1" </dev/null 2>/dev/null |
        openssl x509 >"$2" 2>/dev/null || true
}

# lineage_facts <le dir> <host>: certbot's lineage named relay, how it renews,
# and the address mode that renewal needs.
lineage_facts() {
    local le=$1 host=$2 conf
    OLD_LINEAGE="" OLD_AUTH="" OLD_STAGING=no
    conf=$le/renewal/relay.conf
    [ -e "$le/live/relay/cert.pem" ] || [ -e "$conf" ] || return 0
    if ! plain_read "$conf"; then
        why_not "certbot's settings for the certificate ($conf) are missing, a link or not a plain file."
        return 0
    fi
    OLD_LINEAGE=relay
    OLD_AUTH=$(kv_get "$conf" authenticator)
    grep -q 'acme-staging' "$conf" && OLD_STAGING=yes
    # A hook of the old setup's own would hand each renewal to the old account.
    # The compose file's own hook is the same path in the new containers.
    if grep -E '^[[:space:]]*(renew_hook|deploy_hook|post_hook|pre_hook)[[:space:]]*=' "$conf" |
       grep -v '=[[:space:]]*/hooks/install-certs.sh[[:space:]]*$' | grep -i hollow >/dev/null; then
        why_not "certbot's settings for the certificate ($conf) run a program of the old setup after each renewal, and I cannot tell how to keep it working."
    fi
    # The live copy is a link into archive/, which is certbot's own layout.
    if [ -r "$le/live/relay/cert.pem" ] && ! cert_covers "$le/live/relay/cert.pem" "$host"; then
        OLD_LINEAGE=other
    fi
}

renew_text() {
    case "$OLD_AUTH" in
    standalone) printf 'over HTTP on port 80' ;;
    manual)
        if grep -q duckdns-auth "$1" 2>/dev/null; then printf 'through DuckDNS'
        else printf 'with hooks of your own'; fi ;;
    webroot) printf 'through your web server' ;;
    '') printf 'in a way I cannot tell' ;;
    *) printf 'with the %s plugin' "$OLD_AUTH" ;;
    esac
}

# Which address mode keeps the renewal working as it does today.
address_mode_for() {
    local host=$1 conf=$2 token=$3
    if [ "$(ip4_class "$host")" != invalid ]; then echo ip; return; fi
    # A renewal through DuckDNS stays one, token or not; the caller refuses
    # one without its token.
    if [ "$OLD_LINEAGE" = relay ] && [ "$OLD_AUTH" = manual ] && grep -q duckdns-auth "$conf" 2>/dev/null; then
        echo duckdns
    elif [ "$OLD_LINEAGE" != relay ] && [[ "$host" == *.duckdns.org ]] && [ -n "$token" ]; then
        echo duckdns
    else
        echo domain
    fi
}

relay_version_of() {
    curl -fsSk --max-time 4 --connect-to "$1:443:127.0.0.1:443" "https://$1/relay-status" 2>/dev/null |
        sed -n 's/.*"version":"\([^"]*\)".*/\1/p' || true
}

# ---------------------------------------------------------------- the hand setup

OLD_RELAY_UNIT="" OLD_RELAY_USER="" OLD_RELAY_BIN="" OLD_FDSTORE=no OLD_CERT_FILE=""
OLD_TURN_UNIT="" OLD_PUSH_UNIT="" OLD_FWD_UNIT="" OLD_FWD_CONF="" OLD_FWD_DATA=""
OLD_STATE_DIRS=""

# DuckDNS updates from a cron line, as the old guide set them up. Sets
# OLD_DUCKDNS_CRON (whose crontab), the token, never shown, and the address it
# pins. Only lines root or the person running the setup wrote count: any
# account can put a line of its own in its crontab, which is only noted.
duckdns_cron_facts() {
    local f line who tok ip dom acct me
    OLD_DUCKDNS_CRON=""
    me=$(ssh_account)
    # shellcheck disable=SC2086 # globs
    for f in $ADOPT_CRON_FILES $ADOPT_USER_CRONTABS/*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        line=$(grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep 'duckdns.org/update' | head -n 1 || true)
        [ -n "$line" ] || continue
        dom=$(grep -oE 'domains=[^&" ]*' <<<"$line" | head -n 1 | cut -d= -f2)
        [ "$dom.duckdns.org" = "$OLD_HOST" ] || [[ ",$dom," == *",${OLD_HOST%.duckdns.org},"* ]] || continue
        who=$f acct=root
        case "$f" in "$ADOPT_USER_CRONTABS"/*) acct=$(basename "$f") who="$acct's crontab" ;; esac
        if [ "$acct" != root ] && [ "$acct" != "$me" ]; then
            adopt_note "$who has a DuckDNS line for $OLD_HOST. That account is not root and not yours, so I did not use it."
            continue
        fi
        OLD_DUCKDNS_CRON=$who
        tok=$(grep -oE 'token=[^&" ]*' <<<"$line" | head -n 1 | cut -d= -f2)
        ip=$(grep -oE '[?&]ip=[^&" ]*' <<<"$line" | head -n 1 | cut -d= -f2)
        valid_duckdns_token "$tok" && [ -z "$OLD_DUCKDNS_TOKEN" ] && OLD_DUCKDNS_TOKEN=$tok
        [ "$(ip4_class "$ip")" != invalid ] && OLD_DUCKDNS_IP=$ip
        return 0
    done
}

adopt_native_facts() {
    local u=${A_RELAY_UNITS[0]} argv words wd v
    OLD_RELAY_UNIT=$u
    OLD_RELAY_USER=$(adopt_prop "$u" User)
    OLD_RELAY_RUNS=$(adopt_active "$u")
    argv=$(adopt_argv "$u")
    read -r -a words <<<"$argv"
    OLD_RELAY_BIN=${words[0]:-}
    wd=$(adopt_prop "$u" WorkingDirectory)
    [ -n "$wd" ] || wd=/
    OLD_HOST=$(arg_value --domain "${words[@]}")
    OLD_HOST=${OLD_HOST,,}
    v=$(arg_value --port "${words[@]}")
    if [ -n "$v" ] && [ "$v" != 443 ]; then
        why_not "The relay listens on port $v. The setup runs a relay on 443 only."
    fi
    if [ -z "$OLD_HOST" ]; then
        why_not "The relay's service sets no address (--domain), so I do not know the address people type."
    elif ! host_usable "$OLD_HOST"; then
        why_not "The relay's address, $OLD_HOST, is not a name or an IPv4 address the setup can use."
    fi
    OLD_KEYS_FILE=$(abs_in "$wd" "$(arg_value --keys-file "${words[@]}")" keys.json)
    OLD_REPORTS_FILE=$(abs_in "$wd" "$(arg_value --reports-file "${words[@]}")" reports.json)
    OLD_CERT_FILE=$(abs_in "$wd" "$(arg_value --cert-file "${words[@]}")" "")
    v=$(arg_value --session-grace-secs "${words[@]}")
    OLD_GRACE=120
    if [ -n "$v" ]; then
        if is_grace "$v"; then OLD_GRACE=$((10#$v)); else adopt_note "The relay's wait for dropped connections, $v, is outside 30 to 600 seconds, so take over uses 120."; fi
    fi
    v=$(arg_value --forwarder-peer-id "${words[@]}")
    OLD_FWD_ID=""
    if [ -n "$v" ]; then
        if is_peer_id "$v"; then OLD_FWD_ID=$v; else why_not "The relay names a forwarder id that is not one ($v)."; fi
    fi
    OLD_FDSTORE=no
    v=$(adopt_prop "$u" FileDescriptorStoreMax)
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ]; then
        case "$(adopt_prop "$u" NotifyAccess)" in main|all) OLD_FDSTORE=yes ;; esac
    fi

    OLD_TURN_SECRET=$(adopt_unit_env "$u" TURN_SECRET)
    OLD_EXEMPT=$(adopt_unit_env "$u" HOLLOW_CONN_RATE_EXEMPT)
    OLD_PUSH_TOKEN=$(adopt_unit_env "$u" HOLLOW_PUSH_TOKEN)
    OLD_PUBLIC_STATS=$(public_stats_norm "$(adopt_unit_env "$u" PUBLIC_STATS)")
    # The operator's own settings in them carry over (env_kept_block).
    OLD_ENV_FILES=""
    for v in $(adopt_prop "$u" EnvironmentFiles | grep -oE '/[^ ]+' || true); do
        plain_read "$v" && OLD_ENV_FILES="$OLD_ENV_FILES $v"
    done

    OLD_TURN_UNIT="" OLD_TURN_RUNS=no
    if [ ${#A_TURN_UNITS[@]} -gt 0 ]; then
        OLD_TURN_UNIT=${A_TURN_UNITS[0]}
        OLD_TURN_RUNS=$(adopt_active "$OLD_TURN_UNIT")
        v=$(adopt_unit_env "$OLD_TURN_UNIT" TURN_SECRET)
        if [ -n "$v" ] && [ -n "$OLD_TURN_SECRET" ] && [ "$v" != "$OLD_TURN_SECRET" ]; then
            adopt_note "The relay and coturn have different TURN secrets, so calls through TURN could not work. Take over keeps the relay's."
        fi
        OLD_PUBLIC_IP=$(adopt_unit_env "$OLD_TURN_UNIT" PUBLIC_IP)
        OLD_PUBLIC_IPV6=$(adopt_unit_env "$OLD_TURN_UNIT" PUBLIC_IPV6)
    fi
    OLD_TURN=no
    [ -n "$OLD_TURN_SECRET" ] && OLD_TURN=yes

    OLD_PUSH=no OLD_PUSH_RUNS=no OLD_PUSH_UNIT=""
    if [ ${#A_PUSH_UNITS[@]} -gt 0 ]; then
        OLD_PUSH=yes
        OLD_PUSH_UNIT=${A_PUSH_UNITS[0]}
        OLD_PUSH_RUNS=$(adopt_active "$OLD_PUSH_UNIT")
        v=$(adopt_unit_env "$OLD_PUSH_UNIT" PUSH_TOKEN)
        [ -n "$v" ] && OLD_PUSH_TOKEN=$v
    fi

    OLD_FWD=no OLD_FWD_RUNS=no OLD_FWD_UNIT="" OLD_FWD_KEY="" OLD_FWD_DATA=""
    if [ ${#A_FWD_UNITS[@]} -gt 0 ]; then
        OLD_FWD=yes
        OLD_FWD_UNIT=${A_FWD_UNITS[0]}
        OLD_FWD_RUNS=$(adopt_active "$OLD_FWD_UNIT")
        read -r -a words <<<"$(adopt_argv "$OLD_FWD_UNIT" || true)"
        OLD_FWD_CONF=$(arg_value --config "${words[@]}")
        OLD_FWD_CONF=${OLD_FWD_CONF:-/etc/hollow-forwarder.toml}
        if plain_read "$OLD_FWD_CONF"; then
            OLD_FWD_DATA=$(sed -n 's/^[[:space:]]*data_dir[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$OLD_FWD_CONF" | tail -n 1)
            v=$(sed -n 's/^[[:space:]]*public_ip[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$OLD_FWD_CONF" | tail -n 1)
            [ "$(ip4_class "$v")" != invalid ] && OLD_PUBLIC_IP=$v
            v=$(sed -n 's/^[[:space:]]*license_key[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$OLD_FWD_CONF" | tail -n 1)
            is_member_key "$v" && OLD_FWD_LICENSE=$v
        else
            why_not "The forwarder's settings file, $OLD_FWD_CONF, is missing, a link or not a plain file."
        fi
        v=$(adopt_unit_env "$OLD_FWD_UNIT" HOLLOW_FWD_LICENSE_KEY)
        is_member_key "$v" && OLD_FWD_LICENSE=$v
        if [ -n "$OLD_FWD_DATA" ] && ! safe_path "$OLD_FWD_DATA"; then
            why_not "The forwarder keeps its identity in $OLD_FWD_DATA, a path I do not take."
        elif [ -n "$OLD_FWD_DATA" ] && [ -e "$OLD_FWD_DATA/forwarder.key" ]; then
            if plain_read "$OLD_FWD_DATA/forwarder.key"; then OLD_FWD_KEY=$OLD_FWD_DATA/forwarder.key
            else why_not "The forwarder's identity, $OLD_FWD_DATA/forwarder.key, is a link or not a plain file."; fi
            if [ -e "$OLD_FWD_DATA/forwarder.db" ] && ! plain_read "$OLD_FWD_DATA/forwarder.db"; then
                why_not "The forwarder's identity database, $OLD_FWD_DATA/forwarder.db, is a link or not a plain file."
            fi
        elif [ -n "$OLD_FWD_ID" ]; then
            why_not "The relay names the forwarder $OLD_FWD_ID, but the forwarder's identity file is not there, so I could not keep that id."
        else
            adopt_note "The forwarder has no identity yet. It gets one when it first starts."
        fi
    elif [ -n "$OLD_FWD_ID" ]; then
        adopt_note "The relay names a forwarder ($OLD_FWD_ID) that does not run on this machine. Take over drops that id, since no forwarder here answers to it."
        OLD_FWD_ID=""
    fi

    keys_facts "$OLD_KEYS_FILE"
    reports_facts "$OLD_REPORTS_FILE"

    # The certificate: what the relay serves, and certbot's lineage behind it.
    OLD_CERT_TEXT="unknown"
    if [ -n "$OLD_CERT_FILE" ] && plain_read "$OLD_CERT_FILE"; then cert_facts "$OLD_CERT_FILE" || true; fi
    lineage_facts "$ADOPT_LE" "$OLD_HOST"
    OLD_NEW_CERT=no
    case "$OLD_LINEAGE" in
    relay)
        OLD_RENEW="Certbot renews it $(renew_text "$ADOPT_LE/renewal/relay.conf")."
        if [ -n "$OLD_CERT_FP" ] && [ -r "$ADOPT_LE/live/relay/cert.pem" ] &&
           [ "$(openssl x509 -in "$ADOPT_LE/live/relay/cert.pem" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')" != "$OLD_CERT_FP" ]; then
            adopt_note "The relay serves an older copy of its certificate than certbot holds. Take over hands it the current one."
        fi ;;
    other)
        why_not "certbot's certificate named relay does not cover $OLD_HOST. Taking over would replace it, and I do not replace a certificate you may still use." ;;
    *)
        OLD_NEW_CERT=yes
        OLD_RENEW="No certbot certificate named relay is on this machine, so take over asks Let's Encrypt for a new one."
        ;;
    esac
    OLD_RENEW_TIMER=""
    if systemctl is-enabled --quiet snap.certbot.renew.timer 2>/dev/null; then OLD_RENEW_TIMER="certbot's snap timer"
    elif systemctl is-enabled --quiet certbot.timer 2>/dev/null; then OLD_RENEW_TIMER="certbot's timer"
    elif grep -qs 'certbot' /etc/crontab /etc/cron.d/* 2>/dev/null; then OLD_RENEW_TIMER="a cron line"; fi
    if [ "$OLD_LINEAGE" = relay ] && [ -z "$OLD_RENEW_TIMER" ]; then
        adopt_note "Nothing I can see runs certbot's renewal, so the certificate may run out. sudo systemctl list-timers shows the timers this machine has. Take over does not change that."
    fi

    OLD_DUCKDNS_TOKEN=""
    plain_read "$DDNS_ETC/duckdns.env" && OLD_DUCKDNS_TOKEN=$(kv_get "$DDNS_ETC/duckdns.env" DUCKDNS_TOKEN)
    valid_duckdns_token "$OLD_DUCKDNS_TOKEN" || OLD_DUCKDNS_TOKEN=""
    [[ "$OLD_HOST" == *.duckdns.org ]] && duckdns_cron_facts
    OLD_ADDRESS=$(address_mode_for "$OLD_HOST" "$ADOPT_LE/renewal/relay.conf" "$OLD_DUCKDNS_TOKEN")
    if [[ "$OLD_HOST" == *.duckdns.org ]] && [ "$OLD_ADDRESS" = duckdns ] && [ -z "$OLD_DUCKDNS_TOKEN" ]; then
        why_not "The certificate renews through DuckDNS, and I found no DuckDNS token to keep that working."
    fi

    if [ "$OLD_RELAY_RUNS" = yes ]; then OLD_VERSION=$(relay_version_of "$OLD_HOST"); fi

    # Values that go into units and settings files.
    if [ -n "$OLD_TURN_SECRET" ] && ! safe_secret "$OLD_TURN_SECRET"; then
        adopt_note "The TURN secret has characters the setup does not write into its files, so take over makes a new one. Calls are not affected."
        OLD_TURN_SECRET=""
    fi
    if [ -n "$OLD_PUSH_TOKEN" ] && ! safe_secret "$OLD_PUSH_TOKEN"; then OLD_PUSH_TOKEN=""; fi
    safe_exempt "$OLD_EXEMPT" || OLD_EXEMPT=""
    [ "$(ip4_class "${OLD_PUBLIC_IP:-x}")" != invalid ] || OLD_PUBLIC_IP=""
    [ "$(ip6_class "${OLD_PUBLIC_IPV6:-x}")" = global ] || OLD_PUBLIC_IPV6=""

    # What take over writes into must hold no links: a service account could
    # have left one to steer a root write.
    local d l
    for d in $ADOPT_WRITE_DIRS; do
        if [ -L "$d" ]; then why_not "$d is a link. I do not write through links."; continue; fi
        [ -d "$d" ] || continue
        l=$(find "$d" -maxdepth 2 -type l 2>/dev/null | head -n 1)
        [ -n "$l" ] && why_not "$l is a link. I do not write through links."
    done
    for v in hollow-relay hollow-coturn hollow-push hollow-forwarder; do
        [ -L "$UNIT_DIR/$v.service" ] && why_not "$UNIT_DIR/$v.service is a link. I do not write through links."
    done
    for v in "$OLD_KEYS_FILE" "$OLD_REPORTS_FILE"; do
        safe_path "$v" || why_not "The relay reads $v, a path I do not take."
    done
    if [ ${#A_FWD_UNITS[@]} -gt 1 ]; then why_not "There are several forwarder services (${A_FWD_UNITS[*]})."; fi
    if [ ${#A_PUSH_UNITS[@]} -gt 1 ]; then why_not "There are several push sender services (${A_PUSH_UNITS[*]})."; fi
    if [ ${#A_TURN_UNITS[@]} -gt 1 ]; then why_not "There are several coturn services (${A_TURN_UNITS[*]})."; fi
    [ "$OLD_KEYS_BAD" -gt 0 ] && adopt_note "keys.json holds $OLD_KEYS_BAD $( [ "$OLD_KEYS_BAD" = 1 ] && echo "entry that is not a key" || echo "entries that are not keys") the app can type (four groups of four letters or digits). Take over leaves $( [ "$OLD_KEYS_BAD" = 1 ] && echo it || echo them) out. They stay in the backup."
    return 0
}

# Whether what the relay holds in memory survives the switch.
adopt_buffers_carry() {
    [ "$ADOPT_KIND" = native ] && [ "$OLD_RELAY_UNIT" = hollow-relay.service ] && [ "$OLD_FDSTORE" = yes ]
}

# ---------------------------------------------------------------- docker compose

OLD_PROJECT="" OLD_WORKDIR="" OLD_ENV="" OLD_VOL_CERTS="" OLD_VOL_DATA="" OLD_VOL_FWD="" OLD_KEYS_DIR=""
OLD_RUNNING=() OLD_CONTAINERS=() OLD_BOOT_UNIT="" OLD_PROFILES=""

# vol_dir <volume>: its directory on this machine, when it is a plain local one.
vol_dir() {
    local drv mp
    drv=$(adopt_docker volume inspect -f '{{.Driver}}' "$1" 2>/dev/null || true)
    [ "$drv" = local ] || return 1
    mp=$(adopt_docker volume inspect -f '{{.Mountpoint}}' "$1" 2>/dev/null || true)
    [ -n "$mp" ] && [ -d "$mp" ] || return 1
    printf '%s' "$mp"
}

adopt_docker_facts() {
    local id svc state wd relay_id="" fwd_id="" type name src dst v
    OLD_PROJECT=${A_PROJECTS[0]}
    OLD_RUNNING=() OLD_CONTAINERS=()
    while IFS='|' read -r id svc state wd; do
        [ -n "$id" ] || continue
        OLD_CONTAINERS+=("$id")
        [ "$state" = running ] && OLD_RUNNING+=("$svc")
        OLD_WORKDIR=$wd
        case "$svc" in relay) relay_id=$id ;; forwarder) fwd_id=$id ;; esac
    done < <(adopt_docker ps -a --filter "label=com.docker.compose.project=$OLD_PROJECT" \
        --format '{{.ID}}|{{.Label "com.docker.compose.service"}}|{{.State}}|{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
    case " ${OLD_RUNNING[*]} " in *" relay "*) OLD_RELAY_RUNS=yes ;; *) OLD_RELAY_RUNS=no ;; esac
    if [ "$OLD_PROJECT" = "$COMPOSE_PROJECT" ]; then
        why_not "The containers use the project name $COMPOSE_PROJECT, which the setup's own containers take."
    fi
    if [ -z "$relay_id" ]; then why_not "The Docker project $OLD_PROJECT has no relay container."; return 0; fi
    if [ -z "$OLD_WORKDIR" ] || ! safe_path "$OLD_WORKDIR"; then
        why_not "I could not tell which folder the containers were started from."
        return 0
    fi
    OLD_ENV=$OLD_WORKDIR/.env
    if ! plain_read "$OLD_ENV"; then why_not "$OLD_ENV is missing, a link or not a plain file."; return 0; fi
    while IFS='|' read -r type name src dst; do
        case "$type:$dst" in
        volume:/certs) OLD_VOL_CERTS=$name ;;
        volume:/data) OLD_VOL_DATA=$name ;;
        bind:/keys) OLD_KEYS_DIR=$src ;;
        esac
    done < <(adopt_docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$relay_id" 2>/dev/null || true)
    if [ -n "$fwd_id" ]; then
        while IFS='|' read -r type name src dst; do
            [ "$type:$dst" = volume:/data ] && OLD_VOL_FWD=$name
        done < <(adopt_docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$fwd_id" 2>/dev/null || true)
    fi
    for v in "$OLD_VOL_CERTS" "$OLD_VOL_DATA" "$OLD_VOL_FWD"; do
        [ -z "$v" ] || vol_dir "$v" >/dev/null || why_not "The Docker volume $v is not a plain local volume I can copy."
    done
    [ -n "$OLD_VOL_DATA" ] || why_not "The relay container has no data volume, so I could not find its report counts."

    OLD_HOST=$(kv_get "$OLD_ENV" RELAY_HOST)
    OLD_HOST=${OLD_HOST,,}
    if [ -z "$OLD_HOST" ] || ! host_usable "$OLD_HOST"; then
        why_not "RELAY_HOST in $OLD_ENV is empty or not a name or IPv4 address the setup can use."
    fi
    OLD_TURN_SECRET=$(kv_get "$OLD_ENV" TURN_SECRET)
    OLD_PROFILES=$(kv_get "$OLD_ENV" COMPOSE_PROFILES)
    OLD_TURN=no
    [ -n "$OLD_TURN_SECRET" ] && OLD_TURN=yes
    OLD_TURN_RUNS=no
    case " ${OLD_RUNNING[*]} " in *" coturn "*) OLD_TURN_RUNS=yes ;; esac
    if [ "$OLD_TURN" = yes ] && [[ ",$OLD_PROFILES," != *,turn,* ]]; then
        adopt_note "TURN_SECRET is set but the turn profile is off, so the relay offers a TURN server that does not run. Take over runs coturn."
    fi
    OLD_PUSH=yes
    case " ${OLD_RUNNING[*]} " in *" push "*) OLD_PUSH_RUNS=yes ;; *) OLD_PUSH_RUNS=no ;; esac
    OLD_FWD=no OLD_FWD_RUNS=no
    if [[ ",$OLD_PROFILES," == *,forwarder,* ]] || [ -n "$fwd_id" ]; then
        OLD_FWD=yes
        case " ${OLD_RUNNING[*]} " in *" forwarder "*) OLD_FWD_RUNS=yes ;; esac
    fi
    v=$(kv_get "$OLD_ENV" FORWARDER_PEER_ID)
    OLD_FWD_ID=""
    if [ -n "$v" ]; then
        if is_peer_id "$v"; then OLD_FWD_ID=$v; else why_not "FORWARDER_PEER_ID in $OLD_ENV is not a forwarder id."; fi
    fi
    if [ "$OLD_FWD" = yes ] && [ -n "$OLD_FWD_ID" ] && [ -z "$OLD_VOL_FWD" ]; then
        why_not "The relay names the forwarder $OLD_FWD_ID, but I found no volume holding its identity."
    fi
    v=$(kv_get "$OLD_ENV" FWD_LICENSE_KEY)
    is_member_key "$v" && OLD_FWD_LICENSE=$v
    OLD_EXEMPT=$(kv_get "$OLD_ENV" HOLLOW_CONN_RATE_EXEMPT)
    safe_exempt "$OLD_EXEMPT" || OLD_EXEMPT=""
    OLD_PUBLIC_STATS=$(public_stats_norm "$(kv_get "$OLD_ENV" PUBLIC_STATS)")
    OLD_ENV_FILES=$OLD_ENV
    v=$(kv_get "$OLD_ENV" SESSION_GRACE_SECS)
    OLD_GRACE=120
    if [ -n "$v" ]; then
        if is_grace "$v"; then OLD_GRACE=$((10#$v)); else adopt_note "SESSION_GRACE_SECS, $v, is outside 30 to 600 seconds, so take over uses 120."; fi
    fi
    OLD_DUCKDNS_TOKEN=$(kv_get "$OLD_ENV" DUCKDNS_TOKEN)
    valid_duckdns_token "$OLD_DUCKDNS_TOKEN" || OLD_DUCKDNS_TOKEN=""
    OLD_DUCKDNS_IP=$(kv_get "$OLD_ENV" DUCKDNS_IP)
    [ "$(ip4_class "${OLD_DUCKDNS_IP:-x}")" != invalid ] || OLD_DUCKDNS_IP=""
    OLD_PUBLIC_IP=$(kv_get "$OLD_ENV" PUBLIC_IP)
    [ "$(ip4_class "${OLD_PUBLIC_IP:-x}")" != invalid ] || OLD_PUBLIC_IP=""
    OLD_PUBLIC_IPV6=$(kv_get "$OLD_ENV" PUBLIC_IPV6)
    [ "$(ip6_class "${OLD_PUBLIC_IPV6:-x}")" = global ] || OLD_PUBLIC_IPV6=""
    OLD_STAGING=no
    [ "$(kv_get "$OLD_ENV" CERTBOT_STAGING)" = 1 ] && OLD_STAGING=yes
    OLD_OWN_CERT_DIR=$(kv_get "$OLD_ENV" OWN_CERT_DIR)
    if [ -n "$OLD_OWN_CERT_DIR" ] && ! safe_path "$OLD_OWN_CERT_DIR"; then
        why_not "OWN_CERT_DIR in $OLD_ENV is a path I do not take."
    fi
    if [ -n "$OLD_TURN_SECRET" ] && ! safe_secret "$OLD_TURN_SECRET"; then
        adopt_note "The TURN secret has characters the setup does not write into its files, so take over makes a new one. Calls are not affected."
        OLD_TURN_SECRET=""
    fi

    if [ -n "$OLD_KEYS_DIR" ] && safe_path "$OLD_KEYS_DIR"; then OLD_KEYS_FILE=$OLD_KEYS_DIR/keys.json; else OLD_KEYS_FILE=""; fi
    keys_facts "$OLD_KEYS_FILE"
    local data certs
    data=$(vol_dir "$OLD_VOL_DATA" 2>/dev/null || true)
    OLD_REPORTS_FILE=""
    [ -n "$data" ] && OLD_REPORTS_FILE=$data/reports.json
    reports_facts "$OLD_REPORTS_FILE"

    OLD_CERT_TEXT="unknown"
    certs=$(vol_dir "$OLD_VOL_CERTS" 2>/dev/null || true)
    if [ "$OLD_RELAY_RUNS" = yes ]; then
        served_cert_to "$OLD_HOST" "$WORK_DIR/adopt-served.pem"
        cert_facts "$WORK_DIR/adopt-served.pem" || true
    fi
    if [ -z "$OLD_CERT_FP" ] && [ -n "$certs" ] && plain_read "$certs/fullchain.pem"; then cert_facts "$certs/fullchain.pem" || true; fi
    OLD_NEW_CERT=no
    if [ -n "$OLD_OWN_CERT_DIR" ]; then
        OLD_LINEAGE=own
        OLD_RENEW="It is your own, from $OLD_OWN_CERT_DIR, and you renew it yourself. The new containers read it from there too."
    elif [ -n "$certs" ]; then
        lineage_facts "$certs" "$OLD_HOST"
        case "$OLD_LINEAGE" in
        relay) OLD_RENEW="Its container renews it $(renew_text "$certs/renewal/relay.conf")." ;;
        other) OLD_NEW_CERT=yes
            OLD_RENEW="It does not cover $OLD_HOST, so the new containers ask Let's Encrypt for a new one. The old volume keeps the old one." ;;
        *) OLD_NEW_CERT=yes
            OLD_RENEW="The containers hold no certificate yet, so the new ones ask Let's Encrypt for one." ;;
        esac
    fi
    OLD_ADDRESS=$(address_mode_for "$OLD_HOST" "$certs/renewal/relay.conf" "$OLD_DUCKDNS_TOKEN")
    if [ "$OLD_RELAY_RUNS" = yes ]; then OLD_VERSION=$(relay_version_of "$OLD_HOST"); fi

    local u
    for u in "${A_BOOT_UNITS[@]}"; do
        [ "$(adopt_prop "$u" WorkingDirectory)" = "$OLD_WORKDIR" ] && OLD_BOOT_UNIT=$u
    done
    if [ -e "$DOCKER_DIR" ] || [ -L "$DOCKER_DIR" ]; then
        why_not "$DOCKER_DIR already exists, left from an earlier setup. Move it away first, so I do not mix the two."
    fi
    for v in certs data fwd-data; do
        if adopt_docker volume inspect "${COMPOSE_PROJECT}_$v" >/dev/null 2>&1; then
            why_not "The Docker volume ${COMPOSE_PROJECT}_$v already exists, left from an earlier setup. Remove or rename it first, so I do not mix the two."
        fi
    done
    [ "$OLD_KEYS_BAD" -gt 0 ] && adopt_note "keys.json holds $OLD_KEYS_BAD $( [ "$OLD_KEYS_BAD" = 1 ] && echo "entry that is not a key" || echo "entries that are not keys") the app can type (four groups of four letters or digits). Take over leaves $( [ "$OLD_KEYS_BAD" = 1 ] && echo it || echo them) out. The old file keeps them."
    return 0
}

# ---------------------------------------------------------------- screens

svc_word() { if [ "$1" = yes ]; then printf 'running'; else printf 'stopped'; fi; }

adopt_found_text() {
    local how t
    if [ "$ADOPT_KIND" = docker ]; then how="Docker containers from $OLD_WORKDIR"
    else how="systemd services set up by hand ($OLD_RELAY_UNIT, account ${OLD_RELAY_USER:-root})"; fi
    t="This setup did not install the relay that runs here.

How it runs: $how
Address: $OLD_HOST
Relay: $(svc_word "$OLD_RELAY_RUNS")${OLD_VERSION:+, version $OLD_VERSION}
Certificate: $OLD_CERT_TEXT. $OLD_RENEW"
    if [ "$OLD_TURN" = yes ]; then t="$t
TURN: on, coturn $(svc_word "$OLD_TURN_RUNS")"
    else t="$t
TURN: off"; fi
    if [ "$OLD_PUSH" = yes ]; then t="$t
Push for Android: on, $(svc_word "$OLD_PUSH_RUNS")"
    else t="$t
Push for Android: off"; fi
    if [ "$OLD_FWD" = yes ]; then t="$t
Media forwarder: $(svc_word "$OLD_FWD_RUNS")${OLD_FWD_ID:+, id $OLD_FWD_ID}"
    else t="$t
Media forwarder: off"; fi
    if [ "$OLD_MEMBERS" = yes ]; then t="$t
Members-only: on, $OLD_KEYS_GOOD keys"
    else t="$t
Members-only: off"; fi
    t="$t
Public stats page: $OLD_PUBLIC_STATS
Reports: $OLD_REPORTS_TEXT"
    [ -n "$OLD_DUCKDNS_CRON" ] && t="$t
DuckDNS updates: a line in $OLD_DUCKDNS_CRON"
    printf '%s' "$t"
}

adopt_other_text() {
    printf '%s' "Signs of a Hollow relay are on this machine, and this setup did not install it. I cannot tell for sure how it is set up."
}

adopt_list() { local x; for x in "$@"; do printf -- '- %s\n' "$x"; done; }

# adopt_switch_text [after]: the downtime and what the relay's memory loses,
# before the take over or after it.
adopt_switch_text() {
    local when=${1:-}
    if [ "$ADOPT_KIND" = docker ]; then
        if [ "$when" = after ]; then
            printf '%s' "Docker could not carry what was in the old relay's memory, so messages that waited for people who are offline were lost in the change."
        else
            printf '%s' "The relay is down for about half a minute during the change. Docker cannot carry what is in the relay's memory, so messages waiting for people who are offline are lost, as on every restart of the container."
        fi
    elif adopt_buffers_carry; then
        if [ "$when" = after ]; then printf '%s' "Messages waiting for people who are offline carried across the restart."
        else printf '%s' "The relay restarts once at the end, for a few seconds. Messages waiting for people who are offline carry across that restart."; fi
    elif [ "$OLD_FDSTORE" = yes ]; then
        if [ "$when" = after ]; then
            printf '%s' "Its service got a new name, so messages that waited for people who are offline were lost in the restart. The apps fetch what they missed from each other."
        else
            printf '%s' "The relay restarts once at the end, for a few seconds. Its service gets a new name, so what is in its memory does not carry over, and messages waiting for people who are offline are lost."
        fi
    else
        if [ "$when" = after ]; then
            printf '%s' "The old service had no restart handoff, so messages that waited for people who are offline were lost in the restart. The apps fetch what they missed from each other."
        else
            printf '%s' "The relay restarts once at the end, for a few seconds. Its service has no restart handoff, so messages waiting for people who are offline are lost then."
        fi
    fi
}

adopt_choice_text() {
    cat <<EOF
Take over moves this relay into the layout a new install gets, with each part under its own account and sandbox. Running the setup again then shows the status screen, with updates and settings.

I keep the address, the certificate and its renewal, the member keys, the report counts, the TURN secret, the push settings and the forwarder's identity. I back up every file I replace, and if a step fails, I put the old relay back as it was.

$(adopt_switch_text)

Leave it alone changes nothing about the relay. Either way, I then check how this machine is set up and offer to make it safer.
EOF
}

# ---------------------------------------------------------------- the machine

AUD_LINES=() AUD_EXTRA=() HARDEN_CHANGES=() FW_BLOCKS=()

# Listening programs the firewall rules would close. <rules> is one per line.
fw_blocked() {
    local rules line proto addr port prog out=""
    rules=" $(tr '\n' ' ' <<<"$1") "
    while read -r proto addr port prog; do
        [ -n "$port" ] || continue
        case "$addr" in 127.*|::1|\[::1\]|localhost) continue ;; esac
        # The relay's own programs, and what every system runs.
        case "$prog" in docker-proxy|sshd|sshd-session|systemd-resolve|systemd-network|dhclient|avahi-daemon|chronyd|systemd-timesyn|turnserver|hollow-forwar*) continue ;; esac
        [ "$proto" = udp ] && case "$port" in 68|546|5353|123) continue ;; esac
        port_in_rules "$port" "$proto" "$rules" && continue
        case " $out " in *" ${prog:-a program} on $port/$proto,"*) continue ;; esac
        out="$out ${prog:-a program} on $port/$proto,"
    done < <(listeners)
    out=${out%,}
    printf '%s' "${out# }"
}

# One line per listening socket: <tcp|udp> <address> <port> <program>.
listeners() {
    { ss -Hltnp 2>/dev/null | awk '{print "tcp", $4, $NF}'; ss -Hlunp 2>/dev/null | awk '{print "udp", $4, $NF}'; } |
        sed -E 's/users:\(\("([^"]*)".*/\1/' |
        awk '{ a = $2; n = split(a, p, ":"); port = p[n]; addr = substr(a, 1, length(a) - length(port) - 1); print $1, addr, port, $3 }'
}

# port_in_rules <port> <proto> <" rules ">
port_in_rules() {
    local r lo hi
    for r in $3; do
        [ "${r#*/}" = "$2" ] || continue
        r=${r%/*}
        lo=${r%:*}; hi=${r#*:}
        [ "$1" -ge "$lo" ] 2>/dev/null && [ "$1" -le "$hi" ] 2>/dev/null && return 0
    done
    return 1
}

# Reads how the machine is set up and fills AUD_LINES (one per item) and
# HARDEN_CHANGES (what harden-host.sh would change). Changes nothing.
audit_collect() {
    local user keys root ports t sw j fwd core
    AUD_LINES=() AUD_EXTRA=() HARDEN_CHANGES=() FW_BLOCKS=()
    user=$(ssh_account)
    keys=0
    local h
    h=$(ssh_home "$user")
    [ -n "$h" ] && [ -f "$h/.ssh/authorized_keys" ] && keys=$(grep -cE '^[^#]*(ssh-|ecdsa-|sk-)' "$h/.ssh/authorized_keys" 2>/dev/null || true)
    root=$(sshd -T 2>/dev/null | sed -n 's/^permitrootlogin //p' || true)
    ports=$(hollow_ssh_ports)
    case "$root" in
    yes) root="root may log in with a password" ;;
    no) root="root may not log in" ;;
    prohibit-password|without-password) root="root may log in with a key only" ;;
    *) root="root login unknown" ;;
    esac
    case "$(ssh_password_state)" in
    on) t="password logins on" ;;
    unknown) t="password logins unknown (sshd -T failed)" ;;
    *) t="keys only" ;;
    esac
    local note
    note=$(ssh_match_short)
    if [ -n "$note" ]; then
        [ "$t" = "keys only" ] && t="keys only except where a Match block allows passwords"
        AUD_EXTRA+=("$note")
    fi
    local kw=keys
    [ "$keys" = 1 ] && kw=key
    AUD_LINES+=("SSH: $t, $keys $kw for $user, $root, port $(tr ' ' ',' <<<"$ports")")

    if have ufw && ufw status 2>/dev/null | grep 'Status: active' >/dev/null; then
        if ufw status verbose 2>/dev/null | grep 'deny (incoming)' >/dev/null; then t="on, closed except for what it allows"
        else t="on, but inbound is allowed by default"; HARDEN_CHANGES+=("The firewall denies everything inbound but SSH and the relay's ports."); fi
    else
        t="off"
        HARDEN_CHANGES+=("The firewall turns on and lets in only SSH and the relay's ports.")
    fi
    AUD_LINES+=("Firewall: $t")
    local rules
    rules=$(fw_rules_now)
    local blocked
    blocked=$(fw_blocked "$rules")
    [ -n "$blocked" ] && FW_BLOCKS=("$blocked")

    sw=$(swapon --noheadings --show=SIZE 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true)
    if [ -n "$sw" ]; then
        AUD_LINES+=("Swap: on ($sw), so relay memory can reach the disk")
        HARDEN_CHANGES+=("Swap turns off, now and after every reboot.")
    else
        AUD_LINES+=("Swap: off")
    fi

    j=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E '^Storage=' | tail -n 1 | cut -d= -f2 || true)
    fwd=""
    if systemctl is-active --quiet rsyslog 2>/dev/null && [ ! -f /etc/rsyslog.d/00-hollow-privacy.conf ]; then
        fwd=", and rsyslog copies relay lines to /var/log"
    fi
    if [ "$j" = volatile ] && [ -z "$fwd" ]; then
        AUD_LINES+=("Journal: in memory only")
    else
        if [ "$j" = volatile ]; then AUD_LINES+=("Journal: in memory$fwd")
        else AUD_LINES+=("Journal: kept on the disk$fwd"); fi
        HARDEN_CHANGES+=("The journal is kept in memory only, for one hour, and relay lines stay out of /var/log.")
    fi
    if [ -d /var/log/journal ] && [ -n "$(find /var/log/journal -name '*.journal' -print -quit 2>/dev/null)" ]; then
        AUD_EXTRA+=("Older journal files stay in /var/log/journal either way. sudo journalctl --rotate --vacuum-time=1s removes them.")
    fi
    if grep -qsE '^[^#]*@@?[A-Za-z0-9[]' /etc/rsyslog.conf /etc/rsyslog.d/*.conf ||
       systemctl is-active --quiet systemd-journal-upload 2>/dev/null; then
        AUD_LINES+=("Logs: sent to another machine as well")
        AUD_EXTRA+=("This machine sends its logs to another machine, and the setup leaves that as it is. Check that the relay's lines do not go there.")
    fi

    core=$(sysctl -n kernel.core_pattern 2>/dev/null || true)
    if [ "$core" = "|/bin/false" ] && ! systemctl is-active --quiet apport 2>/dev/null; then
        AUD_LINES+=("Core dumps: off")
    else
        case "$core" in *apport*) t="on (apport)" ;; *systemd-coredump*) t="on (systemd-coredump)" ;; *) t="on" ;; esac
        AUD_LINES+=("Core dumps: $t, so a crash writes relay memory to the disk")
        HARDEN_CHANGES+=("Core dumps go off.")
    fi
    if clock_synced; then AUD_LINES+=("Clock: synchronised")
    else AUD_LINES+=("Clock: not synchronised, and relay logins need it within 60 seconds"); HARDEN_CHANGES+=("The clock is kept synchronised."); fi
    if ! have fail2ban-client; then
        AUD_LINES+=("fail2ban: not installed"); HARDEN_CHANGES+=("fail2ban watches SSH logins and blocks addresses that keep guessing.")
    elif ! fail2ban-client status sshd >/dev/null 2>&1; then
        AUD_LINES+=("fail2ban: installed, not watching SSH"); HARDEN_CHANGES+=("fail2ban watches SSH logins and blocks addresses that keep guessing.")
    else
        AUD_LINES+=("fail2ban: watching SSH")
    fi
    audit_security_updates
    [ -n "$blocked" ] && AUD_LINES+=("Also listening: $blocked")
    return 0
}

# Whether apt's daily job installs security updates: installed is not
# enough, Debian leaves the job idle (hollow_auto_upgrades).
audit_security_updates() {
    if ! have unattended-upgrade; then
        AUD_LINES+=("Security updates: not installed automatically"); HARDEN_CHANGES+=("Security updates install on their own every day.")
        return 0
    fi
    case "$(hollow_auto_upgrades)" in
    on) AUD_LINES+=("Security updates: installed every day") ;;
    unset) AUD_LINES+=("Security updates: unattended-upgrades is installed, but apt never runs it"); HARDEN_CHANGES+=("Security updates install on their own every day.") ;;
    off)
        AUD_LINES+=("Security updates: switched off in apt's settings")
        AUD_EXTRA+=("apt's settings switch the daily security updates off (an APT::Periodic value of 0). The setup leaves that as you set it. sudo dpkg-reconfigure -plow unattended-upgrades turns them on.") ;;
    esac
}

audit_text() {
    printf '%s\n' "${AUD_LINES[@]}"
    [ -n "${FW_BLOCKS[0]:-}" ] && printf '\nThe firewall would close %s.\n' "${FW_BLOCKS[0]}"
    [ ${#AUD_EXTRA[@]} -gt 0 ] && printf '\n%s\n' "${AUD_EXTRA[@]}"
    return 0
}

harden_offer_text() {
    printf 'I can make these changes, the same ones a new install makes:\n'
    adopt_list "${HARDEN_CHANGES[@]}"
    printf '\nAutomatic security updates go on as well. The ports the firewall lets in:\n'
    fw_rules_now | sed 's/^/  /; s/:/ to /' | tr '\n' ' ' | sed 's/  */ /g; s/^ //'
    printf '\n\nNothing about the relay itself changes.'
    [ -n "${FW_BLOCKS[0]:-}" ] && printf ' The firewall would close %s, so we recommend leaving it out.' "${FW_BLOCKS[0]}"
    printf '\n'
}

# ---------------------------------------------------------------- answers for the setup

# The CFG_* answers a takeover runs with, from what the old relay uses.
adopt_cfg() {
    CFG_MODE=$ADOPT_KIND
    CFG_HOST=$OLD_HOST
    CFG_ADDRESS=$OLD_ADDRESS
    CFG_DUCKDNS_NAME="" CFG_DUCKDNS_TOKEN=""
    if [[ "$OLD_HOST" == *.duckdns.org ]]; then
        CFG_DUCKDNS_NAME=${OLD_HOST%.duckdns.org}
        # Docker keeps its updater container whenever .env has a token.
        if [ "$CFG_ADDRESS" = duckdns ] || [ "$ADOPT_KIND" = docker ]; then CFG_DUCKDNS_TOKEN=$OLD_DUCKDNS_TOKEN; fi
    fi
    CFG_STAGING=$OLD_STAGING
    CFG_TURN=$OLD_TURN
    CFG_PUSH=$OLD_PUSH
    CFG_FORWARDER=$OLD_FWD
    CFG_MEMBERS_ONLY=$OLD_MEMBERS
    CFG_MEMBER_KEYS=$OLD_KEYS_GOOD
    CFG_GRACE_SECS=$OLD_GRACE
    CFG_PUBLIC_STATS=$OLD_PUBLIC_STATS
    CFG_PUBLIC_IPV6=$OLD_PUBLIC_IPV6
    SEED_ENV_FILES=$OLD_ENV_FILES
    SEED_TURN_SECRET=$OLD_TURN_SECRET
    SEED_PUSH_TOKEN=$OLD_PUSH_TOKEN
    SEED_EXEMPT=$OLD_EXEMPT
    SEED_KEYS_FILE=$OLD_KEYS_FILE
    SEED_FWD_LICENSE=$OLD_FWD_LICENSE
    SEED_FWD_ID=$OLD_FWD_ID
    SEED_OWN_CERT_DIR=$OLD_OWN_CERT_DIR
}

# The public address coturn and the forwarder hand out: the one the old relay
# used when it named one, else the one a new install would find or ask for.
adopt_public_ip() {
    if [ -n "$OLD_PUBLIC_IP" ]; then
        CFG_PUBLIC_IP=$OLD_PUBLIC_IP
        if [ "$OLD_PUBLIC_IP" = "$PF_PUBLIC_IP" ]; then CFG_PUBLIC_IP_FIXED=no; else CFG_PUBLIC_IP_FIXED=yes; fi
    else
        ask_public_ip
    fi
    CFG_DUCKDNS_IP=""
    [ -n "$OLD_DUCKDNS_IP" ] && CFG_DUCKDNS_IP=$OLD_DUCKDNS_IP
    [ "$CFG_PUBLIC_IP_FIXED" = yes ] && [ -z "$CFG_DUCKDNS_IP" ] && CFG_DUCKDNS_IP=$CFG_PUBLIC_IP
    [ -n "$OLD_PUBLIC_IPV6" ] && CFG_PUBLIC_IPV6=$OLD_PUBLIC_IPV6
    return 0
}

# The ports the old relay needs, for a hardening that leaves it alone.
adopt_cfg_for_firewall() {
    CFG_HOST=$OLD_HOST
    CFG_TURN=$OLD_TURN
    CFG_FORWARDER=$OLD_FWD
    # Port 80 stays open unless the certificate needs nothing on it.
    CFG_ADDRESS=domain
    if [ "$ADOPT_KIND" = docker ] && [ -n "$OLD_OWN_CERT_DIR" ]; then CFG_ADDRESS=duckdns
    elif [ "$OLD_ADDRESS" = duckdns ]; then CFG_ADDRESS=duckdns; fi
    if [ "$ADOPT_KIND" = other ]; then CFG_TURN=yes CFG_FORWARDER=yes; fi
}

# ---------------------------------------------------------------- backup and rollback

# Every path a take over may write, remove or replace, so a failure can put
# each back exactly. Plain files only: a link here stops the take over before
# anything changes.
adopt_paths_native() {
    local u
    for u in hollow-relay hollow-coturn hollow-push hollow-forwarder hollow-duckdns hollow-certbot-renew; do
        echo "$UNIT_DIR/$u.service"
    done
    echo "$UNIT_DIR/hollow-duckdns.timer"
    echo "$UNIT_DIR/hollow-certbot-renew.timer"
    for u in "$OLD_RELAY_UNIT" "$OLD_TURN_UNIT" "$OLD_PUSH_UNIT" "$OLD_FWD_UNIT"; do
        [ -n "$u" ] || continue
        adopt_prop "$u" FragmentPath
        echo
        adopt_prop "$u" DropInPaths | tr ' ' '\n'
    done
    for u in hollow-relay hollow-coturn hollow-push hollow-forwarder; do
        adopt_prop "$u.service" DropInPaths | tr ' ' '\n'
    done
    for u in relay.env keys.json fullchain.pem privkey.pem install.conf; do echo "$RELAY_ETC/$u"; done
    echo "$PUSH_ETC/push.env"
    echo "$FWD_ETC/forwarder.toml"
    echo "$FWD_ETC/forwarder.env"
    echo "$TURN_ETC/turn.env"
    echo "$DDNS_ETC/duckdns.env"
    echo "$OLD_KEYS_FILE"
    echo "$OLD_FWD_CONF"
    echo "$CERT_HOOK"
    echo "$ADOPT_LE/renewal/relay.conf"
    echo /usr/local/bin/hollow-relay
    echo /usr/local/bin/hollow-forwarder
    echo "$OLD_REPORTS_FILE"
    # The old relay's report key: a relay since 0.13 erases it on its first
    # start, and a rollback hands it back.
    echo "$OLD_REPORTS_FILE.key"
    echo /var/lib/hollow-relay/reports.json
    echo /var/lib/hollow-relay/reports.json.key
    adopt_paths_lock
    if [ -n "$OLD_FWD_DATA" ]; then echo "$OLD_FWD_DATA/forwarder.key"; echo "$OLD_FWD_DATA/forwarder.db"; fi
    echo /var/lib/hollow-forwarder/forwarder.key
    echo /var/lib/hollow-forwarder/forwarder.db
    # A setup run may clear these folders; whatever else is in them comes back too.
    find "$RELAY_ETC" "$PUSH_ETC" "$FWD_ETC" "$TURN_ETC" "$DDNS_ETC" -maxdepth 1 -type f 2>/dev/null || true
    # Other renewal hooks that hand the certificate to the old account.
    grep -lsF /etc/hollow-relay "$ADOPT_LE"/renewal-hooks/*/* 2>/dev/null || true
}

adopt_paths_docker() {
    [ -n "$OLD_BOOT_UNIT" ] && adopt_prop "$OLD_BOOT_UNIT" FragmentPath && echo
    echo "$CONF_FILE"
    adopt_paths_lock
}

# The TURN port lock both setups add (turn_lock_apply in native.sh).
adopt_paths_lock() {
    local u
    for u in $LOCK_UNITS; do echo "$UNIT_DIR/$u"; done
    echo "$LOCK_BIN"
    echo "$LOCK_ENV"
    echo "$LOCK_DROPIN"
}

# Directories and accounts a take over may create, removed again by a rollback.
ADOPT_DIRS="/etc/systemd/system/hollow-coturn.service.d /etc/hollow-relay /var/lib/hollow-relay /etc/hollow-turn /etc/hollow-push /etc/hollow-forwarder /etc/hollow-duckdns /opt/hollow-push /var/lib/hollow-forwarder /usr/local/lib/hollow-relay /usr/local/lib/hollow-relay/installer /opt/hollow-relay-docker"
ADOPT_ACCOUNTS="hollow-relay hollow-turn hollow-push hollow-fwd hollow-ddns hollow-build"
ADOPT_LINKS="/usr/local/sbin/hollow-relay-setup"

# adopt_backup <path...>: copies each into $ADOPT_BACKUP and records how to
# put it back. Refuses links and anything that is not a plain file.
adopt_backup() {
    local p dest meta
    for p in "$@"; do
        [ -n "$p" ] || continue
        grep -qxF -- "$p" "$ADOPT_BACKUP/manifest.paths" 2>/dev/null && continue
        if [ -L "$p" ]; then die "$p is a link. I do not back up or write through links, so I changed nothing."; fi
        if [ -e "$p" ]; then
            [ -f "$p" ] || die "$p is not a plain file, so I changed nothing."
            [ "$(readlink -f -- "$p")" = "$p" ] || die "$p sits behind a link, so I changed nothing."
            dest=$ADOPT_BACKUP/files$p
            mkdir -p "$(dirname "$dest")"
            cp -p --no-dereference -- "$p" "$dest"
            meta=$(stat -c '%a %U %G' -- "$p")
            printf 'file %s %s\n' "$meta" "$p" >>"$ADOPT_BACKUP/manifest"
        else
            printf 'absent - - - %s\n' "$p" >>"$ADOPT_BACKUP/manifest"
        fi
        printf '%s\n' "$p" >>"$ADOPT_BACKUP/manifest.paths"
    done
}

adopt_backup_start() {
    local d p
    ADOPT_BACKUP=$ADOPT_BACKUP_ROOT/hollow-relay-adopt-$(date +%Y%m%d-%H%M%S)
    if [ "$DRY_RUN" = 1 ]; then
        say "  would back up every file I replace to $ADOPT_BACKUP"
        return 0
    fi
    install -d -m 0700 -o root -g root "$ADOPT_BACKUP"
    date +%s >"$ADOPT_BACKUP/t0"
    # Until the take over is checked, a run that was killed finds this and
    # offers to put the old relay back.
    printf 'kind=%s\nrelay_unit=%s\nboot_unit=%s\nhost=%s\nproject=%s\n' \
        "$ADOPT_KIND" "$OLD_RELAY_UNIT" "${OLD_BOOT_UNIT:-}" "$OLD_HOST" "${OLD_PROJECT:-}" >"$ADOPT_BACKUP/state"
    : >"$ADOPT_BACKUP/running"
    : >"$ADOPT_BACKUP/manifest"
    : >"$ADOPT_BACKUP/manifest.paths"
    for d in $ADOPT_DIRS; do
        if [ -e "$d" ]; then echo "$d" >>"$ADOPT_BACKUP/dirs.present"; else echo "$d" >>"$ADOPT_BACKUP/dirs.absent"; fi
    done
    for d in $ADOPT_ACCOUNTS; do
        getent passwd "$d" >/dev/null || echo "$d" >>"$ADOPT_BACKUP/accounts.absent"
    done
    for d in $ADOPT_LINKS; do
        [ -e "$d" ] || [ -L "$d" ] || echo "$d" >>"$ADOPT_BACKUP/links.absent"
    done
    [ "$(systemctl show -p LoadState --value coturn 2>/dev/null)" = masked ] && touch "$ADOPT_BACKUP/coturn.masked"
    # Directories keep their owner and mode: an old setup let its account own some.
    for d in /etc/hollow-relay /etc/hollow-push /etc/hollow-forwarder /var/lib/hollow-relay /var/lib/hollow-forwarder; do
        [ -d "$d" ] && [ ! -L "$d" ] && printf 'dir %s %s\n' "$(stat -c '%a %U %G' "$d")" "$d" >>"$ADOPT_BACKUP/manifest"
    done
    # Which units ran and started on boot, to put back exactly that.
    for d in "$OLD_RELAY_UNIT" "$OLD_TURN_UNIT" "$OLD_PUSH_UNIT" "$OLD_FWD_UNIT" "$OLD_BOOT_UNIT" coturn.service \
             "$LOCK_UNIT" "$LOCK_TIMER"; do
        [ -n "$d" ] || continue
        # A port lock set up by hand before, put back as it ran.
        case "$d" in "$LOCK_UNIT" | "$LOCK_TIMER") [ -e "$UNIT_DIR/$d" ] || continue ;; esac
        printf '%s %s %s\n' "$d" "$(adopt_active "$d")" "$(adopt_enabled "$d")" >>"$ADOPT_BACKUP/units"
    done
    if [ "$ADOPT_KIND" = native ]; then
        mapfile -t p < <(adopt_paths_native | grep -v '^$' | sort -u)
    else
        mapfile -t p < <(adopt_paths_docker | grep -v '^$' | sort -u)
        printf '%s\n' "${OLD_RUNNING[@]}" >"$ADOPT_BACKUP/docker.running"
    fi
    adopt_backup "${p[@]}"
    chmod -R go-rwx "$ADOPT_BACKUP"
}

# restore_file <mode> <owner> <group> <path>: lands in one rename, which
# replaces a link left at <path> rather than following it.
restore_file() {
    local mode=$1 owner=$2 group=$3 path=$4 tmp
    mkdir -p "$(dirname "$path")"
    tmp=$(mktemp "$path.restore.XXXXXX") || return 1
    cat "$ADOPT_BACKUP/files$path" >"$tmp"
    chown "$owner:$group" "$tmp" 2>/dev/null || chown root:root "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$path"
}

# Every file back as the backup holds it, and what the take over made, gone.
adopt_restore_files() {
    local kind mode owner group p
    while read -r kind mode owner group p; do
        case "$kind" in
        file) restore_file "$mode" "$owner" "$group" "$p" ;;
        dir) [ -d "$p" ] && [ ! -L "$p" ] && chown "$owner:$group" "$p" && chmod "$mode" "$p" ;;
        absent) if [ -f "$p" ] || [ -L "$p" ]; then rm -f -- "$p"; fi ;;
        esac
    done <"$ADOPT_BACKUP/manifest"
    if [ -f "$ADOPT_BACKUP/dirs.absent" ]; then
        while read -r p; do [ -n "$p" ] && rm -rf -- "$p"; done <"$ADOPT_BACKUP/dirs.absent"
    fi
    if [ -f "$ADOPT_BACKUP/links.absent" ]; then
        while read -r p; do [ -n "$p" ] && rm -f -- "$p"; done <"$ADOPT_BACKUP/links.absent"
    fi
    return 0
}

# Puts the old relay back as it was. Runs from the exit trap after a failure,
# so it never stops at an error and needs no terminal.
adopt_rollback() {
    set +e
    trap '' HUP PIPE
    [ -n "$ADOPT_BACKUP" ] && [ -d "$ADOPT_BACKUP" ] || return 0
    printf '\nTaking over did not work, so I am putting the old relay back as it was.\n' >&2
    local p u active enabled
    # A port lock the take over added goes, with its firewall rule.
    if grep -qx "absent - - - $UNIT_DIR/$LOCK_UNIT" "$ADOPT_BACKUP/manifest" 2>/dev/null; then
        systemctl disable --now "$LOCK_TIMER" "$LOCK_UNIT" >/dev/null 2>&1
        [ -x "$LOCK_BIN" ] && env TURN_PORTS="$(kv_get "$LOCK_ENV" TURN_PORTS)" \
            FORWARDER_PORTS="$(kv_get "$LOCK_ENV" FORWARDER_PORTS)" "$LOCK_BIN" remove >/dev/null 2>&1
    fi
    if [ "$ADOPT_KIND" = docker ]; then
        if [ -f "$STACK_DIR/docker-compose.yml" ]; then
            compose --profile turn --profile forwarder down -v --remove-orphans >/dev/null 2>&1
        fi
        # The relay first: the push sender shares its network.
        for u in relay push coturn certbot-renew duckdns forwarder; do
            grep -qx "$u" "$ADOPT_BACKUP/docker.running" 2>/dev/null || continue
            adopt_docker ps -aq --filter "label=com.docker.compose.project=$OLD_PROJECT" \
                --filter "label=com.docker.compose.service=$u" 2>/dev/null | while read -r c; do
                adopt_docker start "$c" >/dev/null 2>&1
            done
        done
    else
        # The setup's own units that did not exist before go first.
        for u in hollow-duckdns.timer hollow-duckdns.service hollow-certbot-renew.timer hollow-certbot-renew.service \
                 hollow-coturn.service hollow-push.service hollow-forwarder.service hollow-relay.service; do
            if grep -qx "absent - - - $UNIT_DIR/$u" "$ADOPT_BACKUP/manifest" 2>/dev/null; then
                systemctl disable --now "$u" >/dev/null 2>&1
            fi
        done
    fi
    adopt_restore_files
    if [ ! -e "$ADOPT_BACKUP/coturn.masked" ] && [ "$(systemctl show -p LoadState --value coturn 2>/dev/null)" = masked ]; then
        systemctl unmask coturn >/dev/null 2>&1
    fi
    systemctl daemon-reload >/dev/null 2>&1
    # Back to how each ran: a restart, never a stop and a start, so systemd
    # keeps the relay's held buffers for the old one to take back.
    # The relay last, so everything it talks to is up again first. A service
    # the take over never restarted still runs as it did and is left alone.
    while read -r u active enabled; do
        [ -n "$u" ] || continue
        if [ "$enabled" = yes ]; then systemctl enable "$u" >/dev/null 2>&1; else systemctl disable "$u" >/dev/null 2>&1; fi
        [ "$active" = yes ] || continue
        [ "$ADOPT_KIND" = docker ] && [ "$u" = "$OLD_BOOT_UNIT" ] && continue
        systemctl is-active --quiet "$u" 2>/dev/null && ! adopt_started_since "$u" && continue
        systemctl reset-failed "$u" >/dev/null 2>&1
        systemctl restart "$u" >/dev/null 2>&1
    done < <(grep -v "^$OLD_RELAY_UNIT " "$ADOPT_BACKUP/units" 2>/dev/null; grep "^$OLD_RELAY_UNIT " "$ADOPT_BACKUP/units" 2>/dev/null)
    while read -r p; do
        [ -n "$p" ] || continue
        account_idle_quiet "$p"
        userdel "$p" >/dev/null 2>&1
        groupdel "$p" >/dev/null 2>&1
    done <"$ADOPT_BACKUP/accounts.absent" 2>/dev/null
    local up=no
    for _ in $(seq 1 30); do
        if curl -fsSk --max-time 3 --connect-to "$OLD_HOST:443:127.0.0.1:443" "https://$OLD_HOST/health" >/dev/null 2>&1; then up=yes; break; fi
        sleep 2
    done
    if [ "$up" = yes ]; then
        printf 'The old relay runs again, as it did before. Everything I replaced is back. A copy of it stays in %s.\n' "$ADOPT_BACKUP" >&2
    else
        printf 'I put every file back, but the old relay does not answer yet. Its copy of everything I replaced is in %s.\n' "$ADOPT_BACKUP" >&2
    fi
    printf "The machine's hardening stays, if it got that far.\n" >&2
    rm -f "$ADOPT_BACKUP/running"
    return 0
}

# A take over that was killed part of the way, so no exit trap put the old
# relay back: sets ADOPT_BACKUP and what adopt_rollback needs from its state.
adopt_interrupted() {
    local d st v
    for d in "$ADOPT_BACKUP_ROOT"/hollow-relay-adopt-*; do
        [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/running" ] && [ -f "$d/state" ] || continue
        [ "$(stat -c '%u %a' "$d" 2>/dev/null)" = "0 700" ] || continue
        st=$d
    done
    [ -n "${st:-}" ] || return 1
    v=$(kv_get "$st/state" kind)
    case "$v" in native|docker) ADOPT_KIND=$v ;; *) return 1 ;; esac
    OLD_RELAY_UNIT=$(kv_get "$st/state" relay_unit) OLD_BOOT_UNIT=$(kv_get "$st/state" boot_unit)
    OLD_HOST=$(kv_get "$st/state" host) OLD_PROJECT=$(kv_get "$st/state" project)
    [[ "$OLD_RELAY_UNIT" =~ ^[A-Za-z0-9@._-]*$ ]] && [[ "$OLD_BOOT_UNIT" =~ ^[A-Za-z0-9@._-]*$ ]] &&
        [[ "$OLD_PROJECT" =~ ^[a-z0-9_-]*$ ]] && { [ -z "$OLD_HOST" ] || host_usable "$OLD_HOST"; } || return 1
    ADOPT_BACKUP=$st
    return 0
}

adopt_resume_main() {
    ui_msg "A take over did not finish" "The last run of the setup began taking over the relay on this machine and stopped before it was done, perhaps because the connection dropped. The relay may be half moved.

Everything it replaced is in $ADOPT_BACKUP, and I can put the old relay back exactly as it was. Then run the setup again to take it over."
    ui_menu interrupted "Put the old relay back?" "We recommend putting it back. Nothing changes if you leave it, and the setup asks again next time." \
        rollback rollback "Put the old relay back (recommended)" leave "Leave everything as it is for now"
    if [ "$UI_REPLY" = rollback ]; then
        [ "$DRY_RUN" = 1 ] && { say "  would put the old relay back from $ADOPT_BACKUP"; return 0; }
        (adopt_rollback)
        say "Run the setup again to take the relay over: sudo bash relay-uws/install.sh"
    else
        say "Nothing changed."
    fi
}

# Whether <unit>'s running process began after the backup, so the take over
# restarted it.
adopt_started_since() {
    local ts t0
    t0=$(cat "$ADOPT_BACKUP/t0" 2>/dev/null) || return 0
    ts=$(systemctl show -p ExecMainStartTimestamp --value "$1" 2>/dev/null)
    [ -n "$ts" ] || return 0
    ts=$(date -d "$ts" +%s 2>/dev/null) || return 0
    [ "$ts" -ge "$t0" ]
}

account_idle_quiet() {
    have pkill || return 0
    pkill -KILL -u "$1" >/dev/null 2>&1
    sleep 1
}

# ---------------------------------------------------------------- steps the setup calls

# adopt_hook <point>: what take over adds to native_apply and docker_apply.
adopt_hook() {
    case "$ADOPT_KIND" in native|docker) ;; *) return 0 ;; esac
    case "$1" in
    stage) adopt_native_stage ;;
    before_start) adopt_native_before_start ;;
    forwarder) adopt_check_forwarder "$FWD_ID" ;;
    docker_switch) adopt_docker_switch ;;
    esac
}

# A unit the old setup ran under another name than the setup's own.
adopt_other_name() {
    local mine=$1 old=$2
    [ -n "$old" ] && [ "$old" != "$mine.service" ]
}

# After the settings are written, before any service changes: the state the
# old relay kept elsewhere, the drop-ins that would bend the new units, and
# old services under other names.
adopt_native_stage() {
    local u f
    step "Moving the old relay's state into place"
    if [ "$DRY_RUN" = 1 ]; then
        say "  would copy the report counts and the forwarder's identity into /var/lib, and stop the old services that run under other names"
        return 0
    fi
    # The report counts, when the old relay kept them elsewhere. Never their
    # key: a relay since 0.13 keeps it in memory only, and the backup holds the
    # old relay's copy for a rollback.
    if [ "$OLD_REPORTS_FILE" != /var/lib/hollow-relay/reports.json ] && [ -e "$OLD_REPORTS_FILE" ] &&
       [ ! -e /var/lib/hollow-relay/reports.json ]; then
        install -d -m 0700 -o hollow-relay -g hollow-relay /var/lib/hollow-relay
        plain_read "$OLD_REPORTS_FILE" || die "$OLD_REPORTS_FILE is a link or not a plain file, so I did not copy it."
        install -m 0600 -o hollow-relay -g hollow-relay -- "$OLD_REPORTS_FILE" /var/lib/hollow-relay/reports.json
        say "  copied $OLD_REPORTS_FILE"
    fi
    # The forwarder's identity, so its id stays the same.
    if [ -n "$OLD_FWD_KEY" ] && [ "$OLD_FWD_DATA" != /var/lib/hollow-forwarder ]; then
        ensure_account hollow-fwd
        install -d -m 0700 -o hollow-fwd -g hollow-fwd /var/lib/hollow-forwarder
        for f in forwarder.key forwarder.db; do
            [ -e "$OLD_FWD_DATA/$f" ] || continue
            [ -e "/var/lib/hollow-forwarder/$f" ] && die "/var/lib/hollow-forwarder/$f already exists, and it is not the old forwarder's. I stopped before the forwarder changed."
            plain_read "$OLD_FWD_DATA/$f" || die "$OLD_FWD_DATA/$f is a link or not a plain file, so I did not copy it."
            install -m 0600 -o hollow-fwd -g hollow-fwd -- "$OLD_FWD_DATA/$f" "/var/lib/hollow-forwarder/$f"
        done
        say "  copied the forwarder's identity from $OLD_FWD_DATA"
    fi
    # Drop-ins on the names the setup takes would change its units.
    for u in hollow-relay hollow-coturn hollow-push hollow-forwarder; do
        for f in $(adopt_prop "$u.service" DropInPaths); do
            case "$f" in "$UNIT_DIR/$u.service.d/"*) rm -f -- "$f"; say "  moved $f to the backup" ;; esac
        done
    done
    # Hooks of the old setup that would hand a renewed certificate to the old account.
    for f in $(grep -lsF /etc/hollow-relay "$ADOPT_LE"/renewal-hooks/*/* 2>/dev/null || true); do
        [ "$f" = "$CERT_HOOK" ] && continue
        rm -f -- "$f"
        say "  moved the old renewal hook $f to the backup"
    done
    # The parts that run under other names stop now; the relay, last.
    for u in "$OLD_TURN_UNIT:hollow-coturn" "$OLD_PUSH_UNIT:hollow-push" "$OLD_FWD_UNIT:hollow-forwarder"; do
        adopt_other_name "${u#*:}" "${u%%:*}" || continue
        [ "${u%%:*}" = coturn.service ] && continue
        run_ok systemctl disable --now "${u%%:*}"
        say "  stopped ${u%%:*}"
    done
}

adopt_native_before_start() {
    [ "$DRY_RUN" = 1 ] && return 0
    if adopt_other_name hollow-relay "$OLD_RELAY_UNIT"; then
        systemctl disable --now "$OLD_RELAY_UNIT" >/dev/null 2>&1 || true
        say "  stopped $OLD_RELAY_UNIT"
    fi
    return 0
}

# The forwarder answers to the id the relay names, or the take over stops.
adopt_check_forwarder() {
    [ "$DRY_RUN" = 1 ] && return 0
    [ -n "$OLD_FWD_ID" ] || return 0
    [ "$1" = "$OLD_FWD_ID" ] && return 0
    die "the forwarder came up as $1, not as $OLD_FWD_ID, the id the relay names. Viewers would have to learn a new one."
}

# Docker: the new containers exist, then the old ones stop and their volumes
# are copied into the new ones. The old volumes are never changed.
adopt_docker_switch() {
    local v src dst role
    step "Changing over to the new containers"
    if [ "$DRY_RUN" = 1 ]; then
        say "  would stop the old containers ($OLD_PROJECT), copy their volumes into new ones and start the new containers"
        return 0
    fi
    run_logged compose create || die "the new containers could not be created."
    if [ -n "$OLD_BOOT_UNIT" ]; then systemctl disable "$OLD_BOOT_UNIT" >/dev/null 2>&1 || true; fi
    if [ ${#OLD_CONTAINERS[@]} -gt 0 ]; then
        adopt_docker stop -t 30 "${OLD_CONTAINERS[@]}" >/dev/null 2>&1 || die "the old containers did not stop."
    fi
    for role in certs:"$OLD_VOL_CERTS" data:"$OLD_VOL_DATA" fwd-data:"$OLD_VOL_FWD"; do
        v=${role#*:}
        [ -n "$v" ] || continue
        [ "${role%%:*}" = fwd-data ] && [ "$CFG_FORWARDER" != yes ] && continue
        dst="${COMPOSE_PROJECT}_${role%%:*}"
        adopt_docker volume inspect "$dst" >/dev/null 2>&1 ||
            adopt_docker volume create --label "com.docker.compose.project=$COMPOSE_PROJECT" \
                --label "com.docker.compose.volume=${role%%:*}" "$dst" >/dev/null || die "the volume $dst could not be made."
        src=$(vol_dir "$v") || die "the old volume $v cannot be read."
        dst=$(vol_dir "$dst") || die "the new volume $dst cannot be read."
        [ -z "$(ls -A "$dst")" ] || die "the new volume ${COMPOSE_PROJECT}_${role%%:*} is not empty."
        # -a keeps links as links and owners as they were; nothing is followed.
        # The report key stays in the old volume: a relay since 0.13 keeps it
        # in memory only.
        (
            shopt -s dotglob nullglob
            for e in "$src"/*; do
                [ "${role%%:*}" = data ] && [ "${e##*/}" = reports.json.key ] && continue
                cp -a -- "$e" "$dst/" || exit 1
            done
            chown --reference="$src" -- "$dst" && chmod --reference="$src" -- "$dst"
        ) || die "the volume $v could not be copied."
        say "  copied $v"
    done
}

# same_counts <old reports.json> <new reports.json>: every count of the old
# file is in the new one, as high or higher (a report may arrive meanwhile).
# Never the same bytes: a relay since 0.13 rewrites the file without the
# fingerprints an older relay's key made.
same_counts() {
    have jq || return 0
    [ "$(jq -n --slurpfile a "$1" --slurpfile b "$2" '($b[0].counts // {}) as $new
        | [($a[0].counts // {}) | to_entries[] | .key as $t | .value | to_entries[] | (($new[$t] // {})[.key] // 0) >= .value]
        | all' 2>/dev/null)" = true ]
}

# What take over promised to keep, checked on the running result. A miss
# stops it, and the exit trap puts the old relay back.
adopt_verify() {
    [ "$DRY_RUN" = 1 ] && return 0
    local k keys_new tmp fp
    step "Checking that everything was kept"
    if [ "$ADOPT_KIND" = docker ]; then keys_new=$STACK_DIR/keys/keys.json; else keys_new=$RELAY_ETC/keys.json; fi
    local -A now=()
    while IFS= read -r k; do [ -n "$k" ] && now[$k]=1; done < <(member_keys_read "$keys_new")
    for k in "${OLD_KEY_LIST[@]}"; do
        [ -n "${now[$k]:-}" ] || die "a member key from the old relay is missing from $keys_new."
    done
    [ "$(grep -c '"enabled": true' "$keys_new" || true)" -ge "$([ "$OLD_MEMBERS" = yes ] && echo 1 || echo 0)" ] ||
        die "members-only is off in $keys_new, and the old relay had it on."
    if [ "$CFG_TURN" = yes ] && [ -n "$SEED_TURN_SECRET" ]; then
        if [ "$ADOPT_KIND" = docker ]; then
            [ "$(kv_get "$STACK_DIR/.env" TURN_SECRET)" = "$SEED_TURN_SECRET" ] || die "the TURN secret changed."
        else
            [ "$(kv_get "$RELAY_ETC/relay.env" TURN_SECRET)" = "$SEED_TURN_SECRET" ] &&
                [ "$(kv_get "$TURN_ETC/turn.env" TURN_SECRET)" = "$SEED_TURN_SECRET" ] || die "the TURN secret changed."
        fi
    fi
    if [ "$ADOPT_KIND" = native ] && [ -n "$SEED_PUSH_TOKEN" ] && [ "$CFG_PUSH" = yes ]; then
        [ "$(kv_get "$PUSH_ETC/push.env" PUSH_TOKEN)" = "$SEED_PUSH_TOKEN" ] || die "the push sender's token changed."
    fi
    if [ "$ADOPT_KIND" = native ] && [ -e "$ADOPT_BACKUP/files$OLD_REPORTS_FILE" ]; then
        same_counts "$ADOPT_BACKUP/files$OLD_REPORTS_FILE" /var/lib/hollow-relay/reports.json || die "the report counts changed."
    fi
    if [ "$ADOPT_KIND" = docker ] && [ -n "$OLD_VOL_DATA" ]; then
        local a b
        a=$(vol_dir "$OLD_VOL_DATA")/reports.json
        b=$(vol_dir "${COMPOSE_PROJECT}_data")/reports.json
        if [ -e "$a" ]; then same_counts "$a" "$b" || die "the report counts changed."; fi
    fi
    if [ "$CFG_FORWARDER" = yes ] && [ -n "$OLD_FWD_ID" ]; then
        local now
        if [ "$ADOPT_KIND" = docker ]; then now=$(kv_get "$STACK_DIR/.env" FORWARDER_PEER_ID); else now=$FWD_ID; fi
        [ "$now" = "$OLD_FWD_ID" ] || die "the forwarder came up as $now, not as $OLD_FWD_ID, the id the relay names."
    fi
    if [ "$OLD_NEW_CERT" = no ] && [ -n "$OLD_CERT_FP" ] && [ "$OLD_LINEAGE" != own ]; then
        tmp=$WORK_DIR/adopt-after.pem
        served_cert_to "$CFG_HOST" "$tmp"
        fp=$(openssl x509 -in "$tmp" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' || true)
        local want=$OLD_CERT_FP
        [ "$ADOPT_KIND" = native ] && [ -r "$ADOPT_LE/live/relay/cert.pem" ] &&
            want=$(openssl x509 -in "$ADOPT_LE/live/relay/cert.pem" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')
        [ "$fp" = "$want" ] || die "the relay serves another certificate than before."
    fi
    say "  kept: the member keys, the TURN secret, the push token, the report key, the forwarder's id and the certificate"
}

# ---------------------------------------------------------------- the two ways

adopt_takeover() {
    adopt_cfg
    if [ "$ADOPT_KIND" = native ]; then ask_binaries; else CFG_BINARIES=source; fi
    adopt_public_ip
    ssh_question
    ssh_firewall_guard
    audit_collect
    ui_msg "How this machine is set up" "$(audit_text)"
    ui_msg "What take over does" "$(adopt_plan_text)"
    ui_yesno confirm "Ready to take over" "$(adopt_confirm_text)" yes || { say "Stopped. Nothing was changed."; exit 0; }
    APPLY_STARTED=1
    adopt_backup_start
    [ "$DRY_RUN" = 1 ] || ADOPT_ARMED=1
    if [ "$ADOPT_KIND" = docker ]; then docker_apply; else native_apply; fi
    adopt_verify
    ADOPT_ARMED=0
    [ "$DRY_RUN" = 1 ] || rm -f "$ADOPT_BACKUP/running"
    ssh_run
    ui_msg "Taken over" "$(adopt_done_text)"
    summary_screen
}

adopt_plan_text() {
    local how parts="the relay" kept="the certificate"
    if [ "$ADOPT_KIND" = docker ]; then how="Docker containers, run from $DOCKER_DIR"
    elif [ "$CFG_BINARIES" = source ]; then how="the full setup, with programs built here from source"
    else how="the full setup, with the ready-made programs"; fi
    [ "$CFG_TURN" = yes ] && parts="$parts, TURN"
    [ "$CFG_PUSH" = yes ] && parts="$parts, the push sender"
    [ "$CFG_FORWARDER" = yes ] && parts="$parts, the media forwarder"
    [ "$OLD_NEW_CERT" = yes ] && kept=""
    if [ "$OLD_KEYS_GOOD" -gt 0 ]; then kept="$kept, $OLD_KEYS_GOOD member keys"; fi
    kept="$kept, the report counts"
    [ -n "$SEED_TURN_SECRET" ] && kept="$kept, the TURN secret"
    [ -n "$SEED_PUSH_TOKEN" ] && [ "$CFG_PUSH" = yes ] && [ "$ADOPT_KIND" = native ] && kept="$kept, the push token"
    [ -n "$OLD_FWD_ID" ] && kept="$kept, the forwarder's id"
    kept=${kept#, }
    local more=""
    [ "$OLD_NEW_CERT" = yes ] && more="$more
Let's Encrypt is asked for a new certificate for $CFG_HOST."
    if [ "$ADOPT_KIND" = native ]; then
        local u list=""
        for u in "$OLD_RELAY_UNIT:hollow-relay" "$OLD_TURN_UNIT:hollow-coturn" "$OLD_PUSH_UNIT:hollow-push" "$OLD_FWD_UNIT:hollow-forwarder"; do
            adopt_other_name "${u#*:}" "${u%%:*}" && list="$list ${u%%:*}"
        done
        [ -n "$list" ] && more="$more
These old services stop and stay off:$list."
    else
        more="$more
The old containers stop. Their volumes are copied and never changed."
    fi
    [ -n "${FW_BLOCKS[0]:-}" ] && more="$more
The firewall would close ${FW_BLOCKS[0]}."
    cat <<EOF
Address: $CFG_HOST
How: $how
Running: $parts
Kept: $kept

The machine gets the hardening of a new install, and its firewall lets in only SSH and the relay's ports.$more

$(adopt_switch_text)
EOF
}

adopt_confirm_text() {
    printf '%s' "Take the relay over now? Nothing has changed yet. Every file I replace goes to a backup in $ADOPT_BACKUP_ROOT that only root can read.$( [ "${SSH_PLAN:-none}" = guide ] && echo " At the end I wait for you to log in with your SSH key, then turn password logins off.")"
}

adopt_done_text() {
    local t left=""
    t="The relay now runs in the setup's own layout. $(adopt_switch_text after)

Everything I replaced is in $ADOPT_BACKUP, which only root can read. Delete it once you are happy with the relay."
    if [ "$ADOPT_KIND" = native ]; then
        case "$OLD_RELAY_BIN" in /usr/local/bin/*) ;; *) left="$left
- $OLD_RELAY_BIN, the old relay program" ;; esac
        [ -n "$OLD_RELAY_USER" ] && [ "$OLD_RELAY_USER" != hollow-relay ] && [ "$OLD_RELAY_USER" != root ] && left="$left
- the account $OLD_RELAY_USER"
        if [ -n "$OLD_DUCKDNS_CRON" ]; then
            left="$left
- the DuckDNS line in $OLD_DUCKDNS_CRON"
            [ "$CFG_ADDRESS" = duckdns ] && left="$left, which the setup does not need now"
        fi
    else
        left="$left
- the old containers and volumes, stopped. docker compose -p $OLD_PROJECT down -v removes them.
- $OLD_ENV, which still holds the old secrets"
    fi
    [ -n "$left" ] && t="$t

Left as it was, for you to remove when you like:$left"
    printf '%s' "$t"
}

adopt_leave() {
    adopt_cfg_for_firewall
    audit_collect
    ui_msg "How this machine is set up" "$(audit_text)"
    local choice=none
    if [ ${#HARDEN_CHANGES[@]} -gt 0 ]; then
        ui_msg "Make this machine safer?" "$(harden_offer_text)"
        local def=all
        [ -n "${FW_BLOCKS[0]:-}" ] && def=nofw
        ui_menu harden "Make this machine safer?" "Which changes should I make? Nothing about the relay changes either way." "$def" \
            all "All of them$( [ "$def" = all ] && echo " (recommended)")" \
            nofw "All but the firewall$( [ "$def" = nofw ] && echo " (recommended)")" \
            none "None"
        choice=$UI_REPLY
    fi
    ssh_question
    [ "$choice" = all ] && ssh_firewall_guard
    HARDEN_RESULT="nothing changed."
    if [ "$choice" != none ]; then
        APPLY_STARTED=1
        step "Hardening the machine (deploy/harden-host.sh)"
        [ "$DRY_RUN" = 1 ] || hollow_apt_wait || die "the system's automatic updates still hold the package lock. Wait until they finish, then run the setup again."
        local http=no
        [ "$CFG_ADDRESS" = duckdns ] || http=yes
        local hargs=(--http "$http" --turn "$CFG_TURN" --forwarder "$CFG_FORWARDER" --no-ssh)
        [ "$choice" = nofw ] && hargs+=(--no-firewall)
        [ "$DRY_RUN" = 1 ] && hargs+=(--print)
        run_logged sh "$DEPLOY/harden-host.sh" "${hargs[@]}" || die "the hardening step failed."
        HARDEN_RESULT="done."
        [ "$choice" = nofw ] && HARDEN_RESULT="done, all but the firewall."
    fi
    ssh_run
    run_checks
    ui_msg "Done" "$(adopt_leave_text)"
}

adopt_leave_text() {
    cat <<EOF
Nothing about the relay changed.

Hardening: $HARDEN_RESULT
SSH: ${SSH_RESULT:-unchanged.}
Checks: ${CHECK_RESULT:-not run.}

This setup did not install the relay, so some checks may fail on how its services run. To take it over later, run the setup again from your copy of the repository: sudo bash relay-uws/install.sh
EOF
}

# Whiptail reads a text that starts with a dash as an option, so neither does.
adopt_notes_text() {
    printf 'I also noticed:\n%s' "$(adopt_list "${ADOPT_NOTES[@]}")"
}

adopt_cannot_text() {
    printf 'I cannot take this relay over safely:\n%s\n\nI leave the relay exactly as it is. Next I check how this machine is set up and offer to make it safer.' \
        "$(adopt_list "${ADOPT_WHY_NOT[@]}")"
}

adopt_main() {
    local id ver
    id=$(kv_get /etc/os-release ID)
    ver=$(kv_get /etc/os-release VERSION_ID)
    if ! os_supported "$id" "$ver" || ! arch_supported "$(uname -m)"; then
        ui_msg "A relay is already here" "I found a Hollow relay on this machine, but the setup supports only Ubuntu 22.04 or newer and Debian 12 or newer on x86_64 or ARM64, so I changed nothing."
        exit 1
    fi
    step "Checking this machine"
    preflight_run
    if [ "$ADOPT_KIND" = other ]; then
        ui_msg "A relay is already here" "$(adopt_other_text)"
    else
        ui_msg "A relay is already here" "$(adopt_found_text)"
    fi
    if [ ${#ADOPT_NOTES[@]} -gt 0 ]; then
        ui_msg "Also worth knowing" "$(adopt_notes_text)"
    fi
    if ! adopt_can_take; then
        ui_msg "I cannot take it over" "$(adopt_cannot_text)"
        adopt_leave
        return 0
    fi
    ui_msg "Take it over, or leave it alone" "$(adopt_choice_text)"
    ui_menu adopt "What would you like to do?" "We recommend taking it over. It gets the layout of a new install, with updates and settings on the status screen." \
        takeover takeover "Take it over (recommended)" leave "Leave it alone"
    if [ "$UI_REPLY" = takeover ]; then adopt_takeover; else adopt_leave; fi
}
