#!/bin/bash
# Tests for taking over a relay this setup did not install (deploy/lib/adopt.sh).
# Sourced by run_tests.sh, whose helpers (eq, has, in_sub, ...) they use.
# shellcheck disable=SC2034,SC2317,SC2016,SC2030,SC2031,SC2154
# ---------------------------------------------------------------- adopt
# A relay this setup did not install. systemd, Docker and the disk are
# fixtures: adopt_prop answers from FIX, adopt_docker from fake rows.

declare -A FIX=()
fix_unit() { # fix_unit <unit> <prop> <value>
    FIX["$1|$2"]=$3
}
fix_exec() { # fix_exec <unit> <argv...>
    local u=$1
    shift
    fix_unit "$u" ExecStart "{ path=$1 ; argv[]=$* ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
    fix_unit "$u" LoadState loaded
}
FWD_TEST_ID=12D3KooWHtaftXh76r8hiwx6HzzSkKudx1rkjht1YYAjWSDjfeRH

# The old guide's hand setup under $1, every file where the guide put it, the
# roots moved into the test's own directory.
adopt_fixture_native() {
    local R=$1
    rm -rf "$R"
    mkdir -p "$R/units" "$R/etc/hollow-relay" "$R/etc/hollow-push" "$R/etc/hollow-forwarder" "$R/fwd" \
        "$R/state" "$R/le/live/relay" "$R/le/renewal" "$R/le/renewal-hooks/deploy" "$R/cron" "$R/w"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=Box \
        -addext subjectAltName=DNS:relay.example.org \
        -keyout "$R/le/live/relay/privkey.pem" -out "$R/le/live/relay/cert.pem" >/dev/null 2>&1
    cp "$R/le/live/relay/cert.pem" "$R/le/live/relay/fullchain.pem"
    cp "$R/le/live/relay/cert.pem" "$R/etc/hollow-relay/fullchain.pem"
    printf 'version = 5.8.0\narchive_dir = /etc/letsencrypt/archive/relay\n[renewalparams]\nauthenticator = standalone\nserver = https://acme-v02.api.letsencrypt.org/directory\n' >"$R/le/renewal/relay.conf"
    printf '#!/bin/sh\ninstall -o root -g hollow -m 0644 /etc/letsencrypt/live/relay/fullchain.pem /etc/hollow-relay/fullchain.pem\n' \
        >"$R/le/renewal-hooks/deploy/hollow-relay.sh"
    printf 'TURN_SECRET=%s\nHOLLOW_PUSH_TOKEN=%s\n' "$(printf '%064d' 7)" "$(printf '%064d' 9)" >"$R/etc/hollow-relay/relay.env"
    printf 'PUSH_TOKEN=%s\n' "$(printf '%064d' 9)" >"$R/etc/hollow-push/push.env"
    printf '{\n  "enabled": true,\n  "keys": ["AB12-CD32-BA30-LJ50", "QQ44-RT19-ZZ08-MN71", "FWDK-EY00-0000-0001", "not a key"]\n}\n' \
        >"$R/etc/hollow-relay/keys.json"
    printf 'HOLLOW_FWD_LICENSE_KEY=FWDK-EY00-0000-0001\n' >"$R/etc/hollow-forwarder/forwarder.env"
    printf 'relay_domain = "relay.example.org"\ndata_dir = "%s"\npublic_ip = "198.51.100.20"\n' "$R/fwd" \
        >"$R/etc/hollow-forwarder/forwarder.toml"
    printf 'key' >"$R/fwd/forwarder.key"
    printf 'db' >"$R/fwd/forwarder.db"
    printf '{"version":2,"salt_id":"x","keys":[],"counts":{"peerA":{"spam":2},"peerB":{"abuse":1}}}\n' >"$R/state/reports.json"
    printf 'k' >"$R/state/reports.json.key"
    echo "ExecStart=/opt/HOLLOW/relay-uws/build/hollow-relay" >"$R/units/hollow-relay.service"
    echo "ExecStart=/bin/sh /opt/HOLLOW/relay-uws/deploy/coturn/coturn-start.sh" >"$R/units/hollow-coturn.service"
    echo "ExecStart=/usr/bin/node /opt/HOLLOW/push-sidecar/index.js" >"$R/units/hollow-push.service"
    echo "ExecStart=/usr/local/bin/hollow-forwarder" >"$R/units/hollow-forwarder.service"
    echo "ExecStart=/usr/sbin/cron" >"$R/units/cron-hollow-unrelated.service"
    FIX=()
    fix_exec hollow-relay.service /opt/HOLLOW/relay-uws/build/hollow-relay --port 443 --domain relay.example.org \
        --keys-file "$R/etc/hollow-relay/keys.json" --reports-file "$R/state/reports.json" \
        --cert-file "$R/etc/hollow-relay/fullchain.pem" --key-file "$R/etc/hollow-relay/privkey.pem" \
        --forwarder-peer-id "$FWD_TEST_ID"
    fix_unit hollow-relay.service User hollow
    fix_unit hollow-relay.service EnvironmentFiles "$R/etc/hollow-relay/relay.env (ignore_errors=no)"
    fix_unit hollow-relay.service FileDescriptorStoreMax 1
    fix_unit hollow-relay.service NotifyAccess main
    fix_unit hollow-relay.service WorkingDirectory /var/lib/hollow-relay
    fix_exec hollow-coturn.service /bin/sh /opt/HOLLOW/relay-uws/deploy/coturn/coturn-start.sh
    fix_unit hollow-coturn.service EnvironmentFiles "$R/etc/hollow-relay/relay.env (ignore_errors=no)"
    fix_unit hollow-coturn.service Environment "CERT_DIR=/etc/hollow-relay"
    fix_exec hollow-push.service /usr/bin/node /opt/HOLLOW/push-sidecar/index.js
    fix_unit hollow-push.service EnvironmentFiles "$R/etc/hollow-push/push.env (ignore_errors=no)"
    fix_exec hollow-forwarder.service /usr/local/bin/hollow-forwarder --config "$R/etc/hollow-forwarder/forwarder.toml"
    fix_unit hollow-forwarder.service EnvironmentFiles "-$R/etc/hollow-forwarder/forwarder.env (ignore_errors=yes)"
    fix_exec cron-hollow-unrelated.service /usr/sbin/cron -f
    ADOPT_UNIT_DIRS=$R/units UNIT_DIR=$R/units ADOPT_LE=$R/le ADOPT_CRON_FILES="" ADOPT_USER_CRONTABS=$R/cron DDNS_ETC=$R/ddns
    ADOPT_WRITE_DIRS="$R/etc/hollow-relay $R/etc/hollow-push $R/etc/hollow-forwarder $R/state"
}

# Stand-ins for systemd, Docker, processes and the network.
adopt_stubs() {
    adopt_prop() { printf '%s' "${FIX["$1|$2"]:-}"; }
    adopt_active() { case " ${STOPPED:-} " in *" $1 "*) echo no ;; *) echo yes ;; esac; }
    adopt_enabled() { echo yes; }
    adopt_unit_on() { [ "$(adopt_active "$1")" = yes ]; }
    adopt_relay_pids() { printf '%s\n' ${PIDS:-}; }
    adopt_cgroup() { printf '%s\n' "${CGROUP[$1]:-}"; }
    adopt_proc_uid() { printf '%s' "${PUID[$1]:-0}"; }
    adopt_443_pids() { printf '%s\n' ${ON443:-}; }
    adopt_docker() { return 0; }
    relay_version_of() { echo 0.12.2; }
    tput() { case "$1" in cols) echo 80 ;; lines) echo 24 ;; esac; }
    fw_rules_now() { hollow_fw_rules no yes yes 22; }
    FW_BLOCKS=()
}
declare -A CGROUP=() PUID=()

echo "adopt: finding a hand setup"
t_adopt_native() {
    local R=$TMP/adopt_n
    adopt_stubs
    adopt_fixture_native "$R"
    adopt_detect
    eq "a hand setup is found as one" "$ADOPT_KIND" native
    eq "and nothing stands in the way" "${ADOPT_WHY_NOT[*]}" ""
    yes_ adopt_can_take
    eq "the relay unit" "$OLD_RELAY_UNIT" hollow-relay.service
    eq "the address" "$OLD_HOST" relay.example.org
    eq "the account" "$OLD_RELAY_USER" hollow
    eq "the TURN secret from its env file" "$OLD_TURN_SECRET" "$(printf '%064d' 7)"
    eq "TURN is on" "$OLD_TURN" yes
    eq "the push sender's token wins" "$OLD_PUSH_TOKEN" "$(printf '%064d' 9)"
    eq "the forwarder's id" "$OLD_FWD_ID" "$FWD_TEST_ID"
    eq "its identity file" "$OLD_FWD_KEY" "$R/fwd/forwarder.key"
    eq "its own key is no member's" "$OLD_KEYS_GOOD" 2
    eq "the entry that is not a key is counted" "$OLD_KEYS_BAD" 1
    eq "members-only" "$OLD_MEMBERS" yes
    eq "the restart handoff" "$OLD_FDSTORE" yes
    yes_ adopt_buffers_carry
    eq "a lineage named relay" "$OLD_LINEAGE" relay
    eq "renewed over HTTP" "$OLD_AUTH" standalone
    eq "which keeps port 80 open" "$OLD_ADDRESS" domain
    eq "the forwarder's public address" "$OLD_PUBLIC_IP" 198.51.100.20
    if have jq; then eq "the reports, counted" "$OLD_REPORTS_TEXT" "3 reports about 2 people"; fi
    local t
    t=$(adopt_found_text)
    has "the screen names the address" "$t" "Address: relay.example.org"
    has "and the forwarder's id" "$t" "$FWD_TEST_ID"
    has "and the keys" "$t" "Members-only: on, 2 keys"
    lacks "never the TURN secret" "$t" "$(printf '%064d' 7)"
    lacks "nor a member key" "$t" "AB12-CD32"
    ui_size "$t" 7
    eq "the found screen fits 80x24" "$UI_FITS" 1
    ui_size "$(adopt_choice_text)" 7
    eq "the choice screen fits 80x24" "$UI_FITS" 1
    ui_size "We recommend taking it over. It gets the layout of a new install, with updates and settings on the status screen." 11
    eq "the menu fits 80x24" "$UI_FITS" 1
    has "the choice says buffers carry" "$(adopt_choice_text)" "carry across that restart"
    adopt_cfg
    CFG_BINARIES=prebuilt CFG_ADDRESS=domain
    FW_BLOCKS=("nginx on 8080/tcp, master on 25/tcp")
    fix_exec hollow.service /opt/HOLLOW/relay-uws/build/hollow-relay
    OLD_RELAY_UNIT=hollow.service OLD_TURN_UNIT=turn.service
    t=$(adopt_plan_text)
    has "the plan names what stays" "$t" "Kept: the certificate, 2 member keys, the report counts, the TURN secret, the push token, the forwarder's id"
    has "and the old services that stop" "$t" "stay off: hollow.service turn.service."
    ui_size "$t" 7
    eq "the plan fits 80x24 with everything on it" "$UI_FITS" 1
    SSH_PLAN=guide
    ui_size "$(adopt_confirm_text)" 8
    eq "the confirm fits 80x24" "$UI_FITS" 1
    ADOPT_BACKUP=/root/hollow-relay-adopt-20261023-120000 OLD_DUCKDNS_CRON="root's crontab"
    t=$(adopt_done_text)
    has "the done screen names the backup" "$t" "/root/hollow-relay-adopt-20261023-120000"
    has "and what stays for the person" "$t" "the account hollow"
    ui_size "$t" 7
    eq "the done screen fits 80x24" "$UI_FITS" 1
    OLD_RELAY_UNIT=hollow-relay.service FW_BLOCKS=()

    # A staging certificate is named as one, whatever its issuer's fields say.
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj "/C=US/O=Let's Encrypt/CN=(STAGING) Baloney Bulgur YE2" \
        -keyout "$R/ca.key" -out "$R/ca.pem" >/dev/null 2>&1
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=relay.example.org -keyout "$R/leaf.key" -out "$R/leaf.csr" >/dev/null 2>&1
    openssl x509 -req -in "$R/leaf.csr" -CA "$R/ca.pem" -CAkey "$R/ca.key" -CAcreateserial -days 30 -out "$R/leaf.pem" >/dev/null 2>&1
    cert_facts "$R/leaf.pem"
    has "a staging certificate says so" "$OLD_CERT_TEXT" "from Let's Encrypt's staging service, which the app refuses"
    # The settings a take over runs with.
    adopt_cfg
    eq "mode" "$CFG_MODE" native
    eq "address mode" "$CFG_ADDRESS" domain
    eq "no new keys are made" "$CFG_MEMBER_KEYS" 2
    eq "grace" "$CFG_GRACE_SECS" 120
    CFG_MEMBERS_ONLY=yes CFG_FORWARDER=yes
    plan_member_keys "/nonexistent/keys.json" "/nonexistent/fwd.env" HOLLOW_FWD_LICENSE_KEY
    eq "the old keys are kept, no more" "${MEMBER_KEYS[*]}" "AB12-CD32-BA30-LJ50 QQ44-RT19-ZZ08-MN71"
    eq "the forwarder keeps its key" "$FWD_KEY" FWDK-EY00-0000-0001
    eq "a seeded TURN secret is kept" "$(keep_or_new /nonexistent TURN_SECRET "$SEED_TURN_SECRET")" "$(printf '%064d' 7)"
    printf 'TURN_SECRET=stored\n' >"$TMP/kon.env"
    eq "a stored value beats the seed" "$(keep_or_new "$TMP/kon.env" TURN_SECRET seed)" stored
    eq "no seed, a new one" "$(keep_or_new /nonexistent X '' | wc -c | tr -d ' ')" 64
}
in_sub t_adopt_native

echo "adopt: what stops a take over"
t_adopt_refusals() {
    local R=$TMP/adopt_r
    adopt_stubs
    # Each case starts from the clean fixture and breaks one thing.
    adopt_fixture_native "$R"; fix_exec hollow-relay.service /x/hollow-relay --port 8443 --domain relay.example.org
    adopt_detect; has "another port" "${ADOPT_WHY_NOT[*]}" "port 8443"; no_ adopt_can_take

    adopt_fixture_native "$R"; fix_exec hollow-relay.service /x/hollow-relay --port 443
    adopt_detect; has "no address" "${ADOPT_WHY_NOT[*]}" "sets no address"

    adopt_fixture_native "$R"; cp "$R/units/hollow-relay.service" "$R/units/relay2.service"
    fix_exec relay2.service /y/hollow-relay --domain relay.example.org
    adopt_detect; eq "two relays" "$ADOPT_KIND" other; has "two relays, said" "${ADOPT_WHY_NOT[*]}" "several relay services"

    adopt_fixture_native "$R"; PIDS=4242; CGROUP[4242]="0::/user.slice/user-1000.slice/session-3.scope"
    adopt_detect; has "a relay outside systemd" "${ADOPT_WHY_NOT[*]}" "outside systemd and Docker (process 4242)"
    CGROUP[4242]="0::/system.slice/hollow-relay.service"
    adopt_detect; eq "a relay inside its own unit is fine" "${ADOPT_WHY_NOT[*]}" ""
    PIDS=""

    adopt_fixture_native "$R"; rm "$R/fwd/forwarder.key"
    adopt_detect; has "a named forwarder without its identity" "${ADOPT_WHY_NOT[*]}" "identity file is not there"

    adopt_fixture_native "$R"; rm "$R/fwd/forwarder.key"; ln -s /etc/shadow "$R/fwd/forwarder.key"
    adopt_detect; has "a linked forwarder identity" "${ADOPT_WHY_NOT[*]}" "is a link or not a plain file"

    adopt_fixture_native "$R"; mv "$R/etc/hollow-relay/keys.json" "$R/keys.real"; ln -s "$R/keys.real" "$R/etc/hollow-relay/keys.json"
    adopt_detect; has "a linked keys file" "${ADOPT_WHY_NOT[*]}" "keys file"

    adopt_fixture_native "$R"; ln -s /etc/shadow "$R/etc/hollow-push/planted"
    adopt_detect; has "a link where take over writes" "${ADOPT_WHY_NOT[*]}" "planted is a link"

    adopt_fixture_native "$R"; ln -s /etc/shadow "$R/state/reports.json.key.x"; rm "$R/state/reports.json.key"; ln -s /etc/shadow "$R/state/reports.json.key"
    adopt_detect; has "a linked report key" "${ADOPT_WHY_NOT[*]}" "report key"

    adopt_fixture_native "$R"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=o \
        -addext subjectAltName=DNS:old.example.org -keyout "$R/k.pem" -out "$R/le/live/relay/cert.pem" >/dev/null 2>&1
    adopt_detect; has "a lineage for another name is never replaced" "${ADOPT_WHY_NOT[*]}" "does not cover relay.example.org"

    adopt_fixture_native "$R"; printf 'renew_hook = /opt/HOLLOW/relay-uws/deploy/renewal-hook.sh\n' >>"$R/le/renewal/relay.conf"
    adopt_detect; has "a renewal hook of the old setup" "${ADOPT_WHY_NOT[*]}" "run a program of the old setup"
    adopt_fixture_native "$R"; printf 'post_hook = systemctl reload nginx\n' >>"$R/le/renewal/relay.conf"
    adopt_detect; eq "a hook that is no relay's is fine" "${ADOPT_WHY_NOT[*]}" ""
    adopt_fixture_native "$R"; printf 'renew_hook = /hooks/install-certs.sh\n' >>"$R/le/renewal/relay.conf"
    adopt_detect; eq "the compose file's own hook is fine" "${ADOPT_WHY_NOT[*]}" ""

    adopt_fixture_native "$R"; rm -rf "$R/le/live/relay" "$R/le/renewal/relay.conf"
    adopt_detect; eq "no lineage, a new certificate" "$OLD_NEW_CERT" yes; eq "and that is no refusal" "${ADOPT_WHY_NOT[*]}" ""

    adopt_fixture_native "$R"; fix_unit hollow-relay.service FileDescriptorStoreMax 0
    adopt_detect; no_ adopt_buffers_carry
    has "the choice says buffers are lost" "$(adopt_choice_text)" "has no restart handoff"

    adopt_fixture_native "$R"; fix_exec hollow.service /opt/HOLLOW/relay-uws/build/hollow-relay --domain relay.example.org
    echo "ExecStart=/opt/HOLLOW/relay-uws/build/hollow-relay" >"$R/units/hollow.service"
    rm "$R/units/hollow-relay.service"; FIX["hollow-relay.service|LoadState"]=not-found
    fix_unit hollow.service FileDescriptorStoreMax 1; fix_unit hollow.service NotifyAccess main
    adopt_detect; eq "a relay under another name" "$OLD_RELAY_UNIT" hollow.service
    no_ adopt_buffers_carry
    ui_size "$(adopt_choice_text)" 7
    eq "the choice for a renamed service fits 80x24" "$UI_FITS" 1
    has "and says what it loses" "$(adopt_choice_text)" "Its service gets a new name"
    has "its plan stops the old unit" "$(CFG_HOST=relay.example.org CFG_TURN=yes CFG_FORWARDER=yes CFG_ADDRESS=domain CFG_PUSH=yes CFG_MEMBERS_ONLY=yes CFG_BINARIES=prebuilt adopt_plan_text 2>/dev/null)" "stay off: hollow.service"

    # The secrets of the guide before 0.12 sat in Environment= lines.
    adopt_fixture_native "$R"; FIX["hollow-relay.service|EnvironmentFiles"]=""
    fix_unit hollow-relay.service Environment "TURN_SECRET=$(printf '%064d' 5)"
    adopt_detect; eq "a secret from Environment=" "$OLD_TURN_SECRET" "$(printf '%064d' 5)"
    fix_unit hollow-relay.service Environment 'TURN_SECRET=a$b'
    adopt_detect; eq "a secret with odd characters is not carried" "$OLD_TURN_SECRET" ""
    has "and that is said" "${ADOPT_NOTES[*]}" "makes a new one"

    # DuckDNS from a cron line, renewed over HTTP: the cron line keeps it pointed.
    adopt_fixture_native "$R"
    fix_exec hollow-relay.service /x/hollow-relay --domain myrelay.duckdns.org --keys-file "$R/etc/hollow-relay/keys.json" --reports-file "$R/state/reports.json"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=d \
        -addext subjectAltName=DNS:myrelay.duckdns.org -keyout "$R/k.pem" -out "$R/le/live/relay/cert.pem" >/dev/null 2>&1
    printf '*/5 * * * * curl -fsS "https://www.duckdns.org/update?domains=myrelay&token=a1b2c3d4-0000-1111-2222-333344445555&ip=" >/dev/null\n' >"$R/cron/root"
    adopt_detect
    eq "the token from the cron line" "$OLD_DUCKDNS_TOKEN" a1b2c3d4-0000-1111-2222-333344445555
    eq "an HTTP renewal stays HTTP" "$OLD_ADDRESS" domain
    lacks "the token never shows" "$(adopt_found_text)" a1b2c3d4
    has "the cron line shows" "$(adopt_found_text)" "DuckDNS updates: a line in"
    printf 'manual_auth_hook = /opt/HOLLOW/relay-uws/deploy/certbot/duckdns-auth.sh\n' >>"$R/le/renewal/relay.conf"
    sed -i 's/^authenticator = .*/authenticator = manual/' "$R/le/renewal/relay.conf"
    adopt_detect; eq "a DNS renewal stays DNS" "$OLD_ADDRESS" duckdns
    : >"$R/cron/root"
    adopt_detect; has "a DNS renewal without its token" "${ADOPT_WHY_NOT[*]}" "no DuckDNS token"
    # whiptail takes a text that starts with a dash for an option and shows nothing.
    t=$(adopt_cannot_text); eq "the refusal screen starts with words" "${t:0:1}" I
    ui_size "$t" 7; eq "and fits 80x24 with one reason" "$UI_FITS" 1
    ADOPT_NOTES=("one note" "two notes"); t=$(adopt_notes_text); eq "the notes screen starts with words" "${t:0:1}" I
}
in_sub t_adopt_refusals

echo "adopt: the rules a take over keeps"
t_adopt_rules() {
    local R=$TMP/adopt_k
    adopt_stubs
    # A first install of this setup that stopped part of the way is no take over.
    adopt_fixture_native "$R"
    printf '# Written by install.sh from relay-uws/deploy/hollow-relay.service.\nExecStart=/usr/local/bin/hollow-relay\n' >"$R/units/hollow-relay.service"
    fix_unit hollow-relay.service FragmentPath "$R/units/hollow-relay.service"
    adopt_detect
    eq "the setup's own unfinished install carries on" "$ADOPT_KIND" none
    # The forwarder must answer to the id the relay names.
    OLD_FWD_ID=$FWD_TEST_ID DRY_RUN=0
    has "another id stops the take over" "$( (adopt_check_forwarder 12D3KooWAnotherIdAnotherIdAnotherIdAnother) 2>&1)" "DIE the forwarder came up as"
    eq "the same id goes on" "$( (adopt_check_forwarder "$FWD_TEST_ID"; echo on) 2>&1)" on
    # What take over promised, checked on the result.
    mkdir -p "$R/new/etc" "$R/new/turn" "$R/new/push"
    RELAY_ETC=$R/new/etc TURN_ETC=$R/new/turn PUSH_ETC=$R/new/push ADOPT_KIND=native ADOPT_BACKUP=$R/bk
    OLD_KEY_LIST=(AB12-CD32-BA30-LJ50 QQ44-RT19-ZZ08-MN71) OLD_MEMBERS=yes CFG_TURN=yes CFG_PUSH=yes CFG_FORWARDER=no
    SEED_TURN_SECRET=t1t1t1t1t1 SEED_PUSH_TOKEN=p1p1p1p1p1 OLD_REPORTS_FILE=/nonexistent OLD_NEW_CERT=yes SEED_KEYS_FILE=""
    printf '{\n  "enabled": true,\n  "keys": [\n    "AB12-CD32-BA30-LJ50",\n    "QQ44-RT19-ZZ08-MN71"\n  ]\n}\n' >"$R/new/etc/keys.json"
    printf 'TURN_SECRET=t1t1t1t1t1\n' >"$R/new/etc/relay.env"
    printf 'TURN_SECRET=t1t1t1t1t1\n' >"$R/new/turn/turn.env"
    printf 'PUSH_TOKEN=p1p1p1p1p1\n' >"$R/new/push/push.env"
    eq "everything kept passes" "$( (adopt_verify; echo passed) 2>&1 | tail -n 1)" passed
    sed -i 's/QQ44-RT19-ZZ08-MN71/QQ44-RT19-ZZ08-XXXX/' "$R/new/etc/keys.json"
    has "a lost member key stops it" "$( (adopt_verify) 2>&1)" "DIE a member key from the old relay is missing"
    sed -i 's/QQ44-RT19-ZZ08-XXXX/QQ44-RT19-ZZ08-MN71/; s/"enabled": true/"enabled": false/' "$R/new/etc/keys.json"
    has "members-only turned off stops it" "$( (adopt_verify) 2>&1)" "DIE members-only is off"
    sed -i 's/"enabled": false/"enabled": true/' "$R/new/etc/keys.json"
    printf 'TURN_SECRET=other\n' >"$R/new/turn/turn.env"
    has "another TURN secret for coturn stops it" "$( (adopt_verify) 2>&1)" "DIE the TURN secret changed"
    printf 'TURN_SECRET=t1t1t1t1t1\n' >"$R/new/turn/turn.env"
    printf 'PUSH_TOKEN=other\n' >"$R/new/push/push.env"
    has "another push token stops it" "$( (adopt_verify) 2>&1)" "DIE the push sender's token changed"
    printf 'PUSH_TOKEN=p1p1p1p1p1\n' >"$R/new/push/push.env"
    # a_take_over_keeps_every_report_count: the counts, never the key.
    mkdir -p "$R/bk/files$R/state"
    printf '{"counts":{"peerA":{"spam":2}}}\n' >"$R/bk/files$R/state/reports.json"
    OLD_REPORTS_FILE=$R/state/reports.json
    has "a lost report count stops it" "$( (adopt_verify) 2>&1)" "DIE the report counts changed"
    lacks "and nothing asks for the old relay's report key" "$(declare -f adopt_verify adopt_native_stage)" "reports.json.key"
}
in_sub t_adopt_rules

echo "adopt: no lockout"
t_adopt_lockout() {
    local R=$TMP/adopt_l
    adopt_stubs
    adopt_fixture_native "$R"
    adopt_detect
    # The person is on SSH port 2345, which the firewall rules would not open.
    hollow_session_ssh_port() { echo 2345; }
    ssh_firewall_guard() {
        hollow_ssh_session_covered "$(fw_rules_now)" 2>/dev/null || die "the firewall could lock you out"
    }
    ask_binaries() { CFG_BINARIES=prebuilt; }
    ask_public_ip() { CFG_PUBLIC_IP=203.0.113.7 CFG_PUBLIC_IP_FIXED=no; }
    ssh_question() { :; }
    native_apply() { echo NATIVE_APPLY_RAN; }
    adopt_backup_start() { echo BACKUP_RAN; }
    ui_msg() { :; }
    ui_yesno() { return 0; }
    ui_menu() { UI_REPLY=$4; }
    audit_collect() { AUD_LINES=("Firewall: off"); HARDEN_CHANGES=("The firewall turns on."); FW_BLOCKS=(); }
    PF_PUBLIC_IP=203.0.113.7
    out=$( (adopt_takeover) 2>&1)
    has "take over stops before a lockout" "$out" "DIE the firewall could lock you out"
    lacks "before anything changes" "$out" "BACKUP_RAN"
    run_logged() { echo "RAN $*"; }
    hollow_apt_wait() { :; }
    out=$( (adopt_leave) 2>&1)
    has "leaving it alone with the firewall stops too" "$out" "DIE the firewall could lock you out"
    lacks "before the hardening" "$out" "RAN sh"
    # Under the setup's own set -e, every hardening choice runs to the end.
    hollow_session_ssh_port() { :; }
    ssh_run() { :; }
    run_checks() { CHECK_RESULT=ok; }
    ui_msg() { [ "$1" = Done ] && printf '%s\n' "$2"; return 0; }
    local c
    for c in all nofw none; do
        ui_menu() { UI_REPLY=$HARDEN_PICK; }
        out=$( (set -e; HARDEN_PICK=$c; adopt_leave; echo FINISHED) 2>&1)
        has "the $c choice finishes" "$out" FINISHED
    done
    has "and says what it did" "$out" "Hardening: nothing changed."
}
in_sub t_adopt_lockout

echo "adopt: a docker compose setup"
# Fake Docker: one project relay-uws, its containers, volumes in $R/vol.
adopt_fixture_docker() {
    local R=$1
    rm -rf "$R"
    mkdir -p "$R/clone/relay-uws/keys" "$R/vol/relay-uws_certs/live/relay" "$R/vol/relay-uws_certs/renewal" "$R/vol/relay-uws_data" "$R/vol/relay-uws_fwd-data"
    printf 'RELAY_HOST=myrelay.duckdns.org\nDUCKDNS_TOKEN=a1b2c3d4-0000-1111-2222-333344445555\nTURN_SECRET=%s\nCOMPOSE_PROFILES=turn,forwarder\nFORWARDER_PEER_ID=%s\nCERTBOT_EMAIL=me@example.org\nSESSION_GRACE_SECS=200\n' \
        "$(printf '%064d' 3)" "$FWD_TEST_ID" >"$R/clone/relay-uws/.env"
    printf '{"enabled": false, "keys": ["AB12-CD32-BA30-LJ50"]}\n' >"$R/clone/relay-uws/keys/keys.json"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=d \
        -addext subjectAltName=DNS:myrelay.duckdns.org -keyout "$R/k.pem" -out "$R/vol/relay-uws_certs/live/relay/cert.pem" >/dev/null 2>&1
    cp "$R/vol/relay-uws_certs/live/relay/cert.pem" "$R/vol/relay-uws_certs/fullchain.pem"
    printf '[renewalparams]\nauthenticator = manual\nmanual_auth_hook = /hooks/duckdns-auth.sh\nserver = https://acme-v02.api.letsencrypt.org/directory\n' >"$R/vol/relay-uws_certs/renewal/relay.conf"
    printf '{"counts":{"p":{"spam":4}}}\n' >"$R/vol/relay-uws_data/reports.json"
    printf 'k' >"$R/vol/relay-uws_data/reports.json.key"
    printf 'key' >"$R/vol/relay-uws_fwd-data/forwarder.key"
    DFAKE=$R
    DOCKER_DIR=$R/opt-docker STACK_DIR=$R/opt-docker/relay-uws
}
adopt_docker_stubs() {
    # Docker is a stand-in here, on a machine with or without the real one.
    have() { [ "$1" = docker ] || command -v "$1" >/dev/null 2>&1; }
    adopt_docker() {
        local R=$DFAKE
        case "$1" in
        info) return 0 ;;
        ps)
            case "$*" in
            *"project=relay-uws"*)
                printf 'c1|relay|running|%s\nc2|push|running|%s\nc3|coturn|running|%s\nc4|forwarder|running|%s\nc5|certbot-init|exited|%s\n' \
                    "$R/clone/relay-uws" "$R/clone/relay-uws" "$R/clone/relay-uws" "$R/clone/relay-uws" "$R/clone/relay-uws" ;;
            *) printf 'relay-uws|%s|%s/clone/relay-uws/docker-compose.yml\n' "$R/clone/relay-uws" "$R" ;;
            esac ;;
        inspect)
            case "${@: -1}" in
            c1) printf 'volume|relay-uws_certs|%s|/certs\nvolume|relay-uws_data|%s|/data\nbind||%s|/keys\n' \
                    "$R/vol/relay-uws_certs" "$R/vol/relay-uws_data" "$R/clone/relay-uws/keys" ;;
            c4) printf 'volume|relay-uws_fwd-data|%s|/data\n' "$R/vol/relay-uws_fwd-data" ;;
            esac ;;
        volume)
            local name=${!#}
            [ -d "$R/vol/$name" ] || return 1
            case "$*" in
            *Driver*) echo local ;;
            *Mountpoint*) echo "$R/vol/$name" ;;
            esac ;;
        *) return 1 ;;
        esac
    }
}
t_adopt_docker() {
    local R=$TMP/adopt_d
    adopt_stubs
    adopt_fixture_native "$TMP/adopt_none"
    rm -f "$TMP/adopt_none/units/"*
    adopt_fixture_docker "$R"
    adopt_docker_stubs
    served_cert_to() { cp "$R/vol/relay-uws_certs/fullchain.pem" "$2"; }
    adopt_detect
    eq "a compose setup is found" "$ADOPT_KIND" docker
    eq "nothing stands in the way" "${ADOPT_WHY_NOT[*]}" ""
    eq "its project" "$OLD_PROJECT" relay-uws
    eq "its folder" "$OLD_WORKDIR" "$R/clone/relay-uws"
    eq "the certs volume" "$OLD_VOL_CERTS" relay-uws_certs
    eq "the forwarder's volume" "$OLD_VOL_FWD" relay-uws_fwd-data
    eq "the address" "$OLD_HOST" myrelay.duckdns.org
    eq "renewed through DuckDNS" "$OLD_ADDRESS" duckdns
    eq "the forwarder id" "$OLD_FWD_ID" "$FWD_TEST_ID"
    eq "the grace" "$OLD_GRACE" 200
    eq "members-only off, the key kept" "$OLD_MEMBERS:$OLD_KEYS_GOOD" no:1
    no_ adopt_buffers_carry
    has "Docker loses the buffers, and says so" "$(adopt_choice_text)" "Docker cannot carry what is in the relay's memory"
    local t
    t=$(adopt_found_text)
    has "how it runs" "$t" "Docker containers from $R/clone/relay-uws"
    lacks "never the DuckDNS token" "$t" a1b2c3d4
    ui_size "$t" 7
    eq "the Docker found screen fits 80x24" "$UI_FITS" 1
    ui_size "$(adopt_choice_text)" 7
    eq "the Docker choice screen fits 80x24" "$UI_FITS" 1
    adopt_cfg
    eq "Docker stays Docker" "$CFG_MODE" docker
    eq "the token goes along" "$CFG_DUCKDNS_TOKEN" a1b2c3d4-0000-1111-2222-333344445555
    eq "the forwarder id seed" "$SEED_FWD_ID" "$FWD_TEST_ID"
    # Volumes of an earlier setup of ours, or its folder, stop it.
    mkdir -p "$R/vol/hollow-relay_data"
    adopt_detect; has "a volume of ours already there" "${ADOPT_WHY_NOT[*]}" "hollow-relay_data already exists"
    rmdir "$R/vol/hollow-relay_data"; mkdir -p "$DOCKER_DIR"
    adopt_detect; has "our folder already there" "${ADOPT_WHY_NOT[*]}" "already exists, left from an earlier setup"
    rmdir "$DOCKER_DIR"
    # An own certificate goes along to the new .env.
    printf 'OWN_CERT_DIR=%s\n' "$R/mycerts" >>"$R/clone/relay-uws/.env"
    adopt_detect; eq "an own certificate" "$OLD_LINEAGE" own; eq "its folder" "$OLD_OWN_CERT_DIR" "$R/mycerts"
    printf 'OWN_CERT_DIR=/x/../etc\n' >>"$R/clone/relay-uws/.env"
    adopt_detect; has "a path with .. is refused" "${ADOPT_WHY_NOT[*]}" "OWN_CERT_DIR"
    # Both kinds at once: neither is taken over.
    adopt_fixture_docker "$R"
    adopt_fixture_native "$TMP/adopt_both"
    adopt_detect; eq "both kinds" "$ADOPT_KIND" other; has "said" "${ADOPT_WHY_NOT[*]}" "one in Docker"
}
in_sub t_adopt_docker

echo "adopt: docker settings"
t_adopt_docker_env() {
    local R=$TMP/adopt_de
    CFG_DUCKDNS_IP="" CFG_EMAIL="" CFG_PUBLIC_IP=203.0.113.7 CFG_PUBLIC_IPV6="" PF_LOCAL_IP=""
    mkdir -p "$R/relay-uws"
    STACK_DIR=$R/relay-uws
    put_file() { cat >"$1"; PUT_CHANGED=1; }
    CFG_TURN=yes CFG_FORWARDER=yes CFG_HOST=myrelay.duckdns.org CFG_DUCKDNS_TOKEN=t CFG_STAGING=no CFG_GRACE_SECS=200
    SEED_TURN_SECRET=$(printf '%064d' 3) SEED_FWD_ID=$FWD_TEST_ID SEED_OWN_CERT_DIR=/srv/certs SEED_EXEMPT=203.0.113.9
    FWD_KEY=""
    mem_mb() { echo 2048; }
    docker_env
    local e=$R/relay-uws/.env
    eq "the TURN secret goes along" "$(kv_get "$e" TURN_SECRET)" "$(printf '%064d' 3)"
    eq "the forwarder id goes along" "$(kv_get "$e" FORWARDER_PEER_ID)" "$FWD_TEST_ID"
    eq "the own certificate goes along" "$(kv_get "$e" OWN_CERT_DIR)" /srv/certs
    eq "the rate exemption goes along" "$(kv_get "$e" HOLLOW_CONN_RATE_EXEMPT)" 203.0.113.9
    lacks "and no email: Let's Encrypt keeps none" "$(cat "$e")" "EMAIL"
    SEED_OWN_CERT_DIR="" SEED_TURN_SECRET=""
    docker_env
    eq "a re-run keeps the own certificate" "$(kv_get "$e" OWN_CERT_DIR)" /srv/certs
    eq "and the TURN secret" "$(kv_get "$e" TURN_SECRET)" "$(printf '%064d' 3)"
}
in_sub t_adopt_docker_env

echo "adopt: backup and restore"
t_adopt_backup() {
    local R=$TMP/adopt_b
    rm -rf "$R"; mkdir -p "$R/etc" "$R/bk"
    ADOPT_BACKUP=$R/bk
    : >"$ADOPT_BACKUP/manifest"; : >"$ADOPT_BACKUP/manifest.paths"
    printf 'old unit\n' >"$R/etc/a.service"; chmod 0640 "$R/etc/a.service"
    adopt_backup "$R/etc/a.service" "$R/etc/new.service"
    has "a file is recorded with its mode" "$(cat "$ADOPT_BACKUP/manifest")" "file 640"
    has "an absent one as absent" "$(cat "$ADOPT_BACKUP/manifest")" "absent - - - $R/etc/new.service"
    eq "the copy is exact" "$(cat "$ADOPT_BACKUP/files$R/etc/a.service")" "old unit"
    ln -s /etc/hostname "$R/etc/link.service"
    has "a link is refused before anything changes" "$( (adopt_backup "$R/etc/link.service") 2>&1)" "is a link"
    mkdir -p "$R/real"; printf 'x' >"$R/real/f"; ln -s "$R/real" "$R/via"
    has "a file behind a linked folder is refused" "$( (adopt_backup "$R/via/f") 2>&1)" "behind a link"
    # What a take over does, then the restore.
    printf 'new unit\n' >"$R/etc/a.service"; chmod 0644 "$R/etc/a.service"
    printf 'made\n' >"$R/etc/new.service"
    mkdir -p "$R/made-dir"; echo "$R/made-dir" >"$ADOPT_BACKUP/dirs.absent"
    rm "$R/etc/a.service"; ln -s /etc/hostname "$R/etc/a.service"
    adopt_restore_files
    eq "the file is back" "$(cat "$R/etc/a.service")" "old unit"
    if [ -L "$R/etc/a.service" ]; then bad "a link left at the path was followed or kept"; else ok; fi
    eq "with its mode" "$(stat -c %a "$R/etc/a.service")" 640
    if [ -e "$R/etc/new.service" ]; then bad "a file the take over made stayed"; else ok; fi
    if [ -e "$R/made-dir" ]; then bad "a folder the take over made stayed"; else ok; fi
}
in_sub t_adopt_backup

echo "adopt: the machine"
t_adopt_audit() {
    adopt_stubs
    listeners() { printf 'tcp 0.0.0.0 443 hollow-relay\ntcp 0.0.0.0 8080 nginx\ntcp 127.0.0.1 5432 postgres\nudp 0.0.0.0 3478 turnserver\nudp 0.0.0.0 68 dhclient\ntcp [::] 25 master\n'; }
    eq "what the firewall would close" "$(fw_blocked "$(hollow_fw_rules no yes no 22)")" "nginx on 8080/tcp, master on 25/tcp"
    eq "nothing when the relay's ports are all" "$(listeners() { printf 'tcp 0.0.0.0 443 hollow-relay\n'; }; fw_blocked "$(hollow_fw_rules no no no 22)")" ""
    yes_ port_in_rules 50000 udp " 49152:65535/udp "
    no_ port_in_rules 50000 tcp " 49152:65535/udp "
    # The offer and the audit fit the screen with a full list.
    AUD_LINES=("SSH: password logins on, 1 keys for vitalik, root may not log in, port 22" "Firewall: off"
        "Swap: on (2G), so relay memory can reach the disk" "Journal: kept on the disk, and rsyslog copies relay lines to /var/log"
        "Core dumps: on (apport), so a crash writes relay memory to the disk" "Clock: synchronised" "fail2ban: not installed"
        "Also listening: nginx on 8080/tcp")
    AUD_EXTRA=("Older journal files stay in /var/log/journal either way. sudo journalctl --rotate --vacuum-time=1s removes them.")
    FW_BLOCKS=("nginx on 8080/tcp")
    ui_size "$(audit_text)" 7
    eq "the audit fits 80x24" "$UI_FITS" 1
    HARDEN_CHANGES=("The firewall turns on and lets in only SSH and the relay's ports." "Swap turns off, now and after every reboot."
        "The journal is kept in memory only, for one hour, and relay lines stay out of /var/log." "Core dumps go off."
        "fail2ban watches SSH logins and blocks addresses that keep guessing.")
    CFG_ADDRESS=domain CFG_TURN=yes CFG_FORWARDER=yes
    hollow_ssh_ports() { echo 22; }
    ui_size "$(harden_offer_text)" 7
    eq "the offer fits 80x24" "$UI_FITS" 1
    has "the offer says why the firewall is left out" "$(harden_offer_text)" "so we recommend leaving it out"
    ui_size "Which changes should I make? Nothing about the relay changes either way." 12
    eq "the hardening menu fits 80x24" "$UI_FITS" 1
}
in_sub t_adopt_audit

echo "adopt: in the setup"
eq "found before the welcome, after the status screen" \
    "$(grep -nE '^(if \[ -r "\$CONF_FILE" \]; then|adopt_detect|ui_msg "Hollow relay setup" \\)$' "$RELAY/install.sh" | cut -d: -f2 | tr '\n' '|')" \
    'if [ -r "$CONF_FILE" ]; then|adopt_detect|ui_msg "Hollow relay setup" \|'
has "a failed take over is put back from the exit trap" "$(sed -n '/^cleanup() {/,/^}/p' "$RELAY/install.sh")" "adopt_rollback"
has "native_apply moves the old state before the services change" "$(sed -n '/^native_apply() {/,/^}/p' "$DEPLOY/lib/native.sh" | tr '\n' ' ')" "relay_settings     adopt_step stage     turn_apply"
has "the forwarder's id is checked before the relay restarts" "$(sed -n '/^native_apply() {/,/^}/p' "$DEPLOY/lib/native.sh" | tr '\n' ' ')" "forwarder_apply     adopt_step forwarder     relay_unit_apply     adopt_step before_start     start_units"
has "docker changes over before its containers start" "$(sed -n '/^docker_apply() {/,/^}/p' "$DEPLOY/lib/docker.sh" | tr '\n' ' ')" "adopt_step docker_switch     # Leftover services"
out=$(sh "$DEPLOY/harden-host.sh" --print --no-firewall --no-ssh 2>&1 || true)
lacks "--no-firewall leaves ufw alone" "$out" "ufw default deny"
has "and says so" "$out" "left as it is"
out=$(sh "$DEPLOY/harden-host.sh" --print --no-ssh 2>&1 || true)
has "without it the firewall is set" "$out" "ufw default deny incoming"


echo "adopt: a repeated flag"
t_arg_value_matches_relay_last_wins() {
    eq "the last copy of a flag wins, as in the relay" \
        "$(arg_value --keys-file /usr/local/bin/hollow-relay --keys-file /etc/old/keys.json --domain a.example.org --keys-file /etc/hollow-relay/keys.json)" \
        /etc/hollow-relay/keys.json
    eq "a flag's value is never read as a flag" "$(arg_value --domain /x/hollow-relay --keys-file --domain b.example.org)" ""
    eq "a flag with no value after it keeps the one before" "$(arg_value --domain /x/hollow-relay --domain a.example.org --domain)" a.example.org
    eq "the program's own path is no flag" "$(arg_value --domain --domain)" ""
}
in_sub t_arg_value_matches_relay_last_wins

echo "adopt: keys stay off command lines"
# Every external program the checks may run records its arguments, so a key
# on a command line, which ps shows to every local account, is caught.
argv_shim() { # argv_shim <dir> <log>
    local c real
    mkdir -p "$1"
    : >"$2"
    for c in grep sed awk sort cut tr head tail cat cmp jq wc uniq comm diff fgrep egrep xargs; do
        real=$(command -v "$c") || continue
        case "$real" in /*) ;; *) continue ;; esac
        printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexec "%s" "$@"\n' "$2" "$real" >"$1/$c"
        chmod +x "$1/$c"
    done
}
t_adopt_key_checks_keep_keys_off_argv() {
    local R=$TMP/adopt_argv log=$TMP/adopt_argv.log k
    rm -rf "$R"; mkdir -p "$R/etc"
    argv_shim "$R/shim" "$log"
    printf '{"enabled": true, "keys": ["ABCD-EFGH-JKLM-NPQR", "QQ44-RT19-ZZ08-MN71", "WXYZ-WXYZ-WXYZ-WXYZ"]}\n' >"$R/keys.json"
    OLD_FWD_LICENSE=WXYZ-WXYZ-WXYZ-WXYZ
    PATH="$R/shim:$PATH" keys_facts "$R/keys.json"
    eq "the member keys are read" "${OLD_KEY_LIST[*]}" "ABCD-EFGH-JKLM-NPQR QQ44-RT19-ZZ08-MN71"
    eq "the forwarder's own key is no member's" "$OLD_KEYS_GOOD" 2
    eq "and is not counted as a bad one" "$OLD_KEYS_BAD" 0
    cp "$R/keys.json" "$R/etc/keys.json"
    step() { :; }
    say() { :; }
    ADOPT_KIND=native RELAY_ETC=$R/etc OLD_MEMBERS=yes CFG_TURN=no CFG_FORWARDER=no OLD_NEW_CERT=yes
    ADOPT_BACKUP=$R/nobackup DRY_RUN=0 SEED_PUSH_TOKEN=""
    out=$(PATH="$R/shim:$PATH" adopt_verify 2>&1)
    lacks "a kept key passes" "$out" "DIE"
    printf '{"enabled": true, "keys": ["QQ44-RT19-ZZ08-MN71"]}\n' >"$R/etc/keys.json"
    out=$( (PATH="$R/shim:$PATH" adopt_verify) 2>&1)
    has "a missing key stops the take over" "$out" "a member key from the old relay is missing"
    for k in ABCD-EFGH-JKLM-NPQR QQ44-RT19-ZZ08-MN71 WXYZ-WXYZ-WXYZ-WXYZ; do
        lacks "no command line names $k" "$(cat "$log")" "$k"
    done
}
in_sub t_adopt_key_checks_keep_keys_off_argv

echo "adopt: whose DuckDNS line counts"
t_duckdns_token_ignores_foreign_user_crontab() {
    local R=$TMP/adopt_dd real=11111111-2222-3333-4444-555555555555 other=99999999-8888-7777-6666-555555555555
    adopt_stubs
    adopt_fixture_native "$R"
    fix_exec hollow-relay.service /x/hollow-relay --domain myrelay.duckdns.org --keys-file "$R/etc/hollow-relay/keys.json" --reports-file "$R/state/reports.json"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=d \
        -addext subjectAltName=DNS:myrelay.duckdns.org -keyout "$R/k.pem" -out "$R/le/live/relay/cert.pem" >/dev/null 2>&1
    dd_line() { printf '*/5 * * * * curl -fsS "https://www.duckdns.org/update?domains=myrelay&token=%s&ip=%s" >/dev/null\n' "$1" "$2"; }
    # Another account's crontab sorts first; the person's own comes after.
    dd_line "$other" 198.51.100.66 >"$R/cron/aaron"
    dd_line "$real" "" >"$R/cron/vitalik"
    SUDO_USER=vitalik
    adopt_detect
    eq "the token from the person's own crontab" "$OLD_DUCKDNS_TOKEN" "$real"
    eq "whose it is" "$OLD_DUCKDNS_CRON" "vitalik's crontab"
    eq "never the other account's address" "$OLD_DUCKDNS_IP" ""
    has "the other line is noted" "${ADOPT_NOTES[*]}" "aaron's crontab has a DuckDNS line for myrelay.duckdns.org"
    lacks "without its token" "${ADOPT_NOTES[*]}" "$other"
    # Only the other account's line: nothing is used.
    rm -f "$R/cron/vitalik"
    adopt_detect
    eq "a stranger's token is never used" "$OLD_DUCKDNS_TOKEN" ""
    eq "nor named as the updater" "$OLD_DUCKDNS_CRON" ""
    # Root's own crontab counts, whoever runs the setup.
    dd_line "$real" "" >"$R/cron/root"
    adopt_detect
    eq "root's line counts" "$OLD_DUCKDNS_TOKEN" "$real"
    # The relay's own root-only settings win over every cron line.
    mkdir -p "$R/ddns"
    printf 'DUCKDNS_TOKEN=%s\n' 22222222-3333-4444-5555-666666666666 >"$R/ddns/duckdns.env"
    adopt_detect
    eq "the setup's own token file wins" "$OLD_DUCKDNS_TOKEN" 22222222-3333-4444-5555-666666666666
    rm -f "$R/ddns/duckdns.env"
    printf 'DUCKDNS_TOKEN=%s\n' 33333333-4444-5555-6666-777777777777 >"$R/elsewhere.env"
    ln -s "$R/elsewhere.env" "$R/ddns/duckdns.env"
    adopt_detect
    eq "never through a link" "$OLD_DUCKDNS_TOKEN" "$real"
}
in_sub t_duckdns_token_ignores_foreign_user_crontab

echo "adopt: a program that only shares the relay's name"
t_adopt_detect_ignores_untrusted_named_process() {
    local R=$TMP/adopt_p
    adopt_stubs
    adopt_fixture_native "$R"
    rm -f "$R/units/hollow-relay.service"
    FIX=()
    # Started by another account from its shell, from its crontab, or as a
    # rootless container: none is a relay of this machine's.
    PIDS=4242
    for cg in "0::/user.slice/user-1001.slice/session-3.scope" "0::/system.slice/cron.service" \
              "0::/user.slice/user-1001.slice/user@1001.service/app.slice/docker-x.scope"; do
        CGROUP[4242]=$cg PUID[4242]=1001 ON443=""
        adopt_detect
        eq "nothing is found for $cg" "$ADOPT_KIND" none
        has "it is noted" "${ADOPT_NOTES[*]}" "process 4242"
    done
    # Root runs it, or it holds port 443: a relay this setup cannot stop.
    CGROUP[4242]="0::/user.slice/user-1001.slice/session-3.scope" PUID[4242]=0
    adopt_detect; eq "root's own counts" "$ADOPT_KIND" other
    PUID[4242]=1001 ON443=4242
    adopt_detect; eq "one on port 443 counts" "$ADOPT_KIND" other
    has "and is named" "${ADOPT_WHY_NOT[*]}" "process 4242"
    # A system service running it as the account the service names counts.
    ON443="" CGROUP[4242]="0::/system.slice/other-relay.service" PUID[4242]=$(id -u nobody)
    fix_unit other-relay.service User nobody
    adopt_detect; eq "a service's own account counts" "$ADOPT_KIND" other
    fix_unit other-relay.service User ""
    adopt_detect; eq "another account under a root service does not" "$ADOPT_KIND" none
    # Root's container runtime: a container relay.
    CGROUP[4242]="0::/system.slice/docker-abc.scope" PUID[4242]=999
    adopt_detect; eq "a container relay counts" "$ADOPT_KIND" other
    # A relay of this setup's own first install that stopped part of the way.
    echo "# Written by install.sh from relay-uws/deploy/hollow-relay.service." >"$R/units/hollow-relay.service"
    fix_exec hollow-relay.service /usr/local/bin/hollow-relay --domain relay.example.org
    fix_unit hollow-relay.service FragmentPath "$R/units/hollow-relay.service"
    # It runs as the account its unit names, which alone would make it count.
    fix_unit hollow-relay.service User nobody
    CGROUP[4242]="0::/system.slice/hollow-relay.service" PUID[4242]=$(id -u nobody)
    adopt_detect; eq "the setup's own unit explains its relay" "$ADOPT_KIND" none
    lacks "and it is no stranger's program either" "${ADOPT_NOTES[*]}" "process 4242"
}
in_sub t_adopt_detect_ignores_untrusted_named_process

echo "adopt: a take over that was killed"
t_adopt_interrupted_takeover_offers_rollback() {
    local R=$TMP/adopt_i d
    rm -rf "$R"; mkdir -p "$R"
    ADOPT_BACKUP_ROOT=$R
    no_ adopt_interrupted
    d=$R/hollow-relay-adopt-20261023-120000
    mkdir -m 0700 "$d"
    printf 'kind=native\nrelay_unit=hollow-relay.service\nboot_unit=\nhost=relay.example.org\nproject=\n' >"$d/state"
    : >"$d/running"
    stat() { if [ "$1" = -c ]; then echo "0 700"; else command stat "$@"; fi; }
    yes_ adopt_interrupted
    eq "its backup" "$ADOPT_BACKUP" "$d"
    eq "its kind" "$ADOPT_KIND" native
    eq "its relay unit" "$OLD_RELAY_UNIT" hollow-relay.service
    eq "its address" "$OLD_HOST" relay.example.org
    # A finished one, or one root does not own alone, is not.
    rm -f "$d/running"; no_ adopt_interrupted; : >"$d/running"
    stat() { if [ "$1" = -c ]; then echo "1000 700"; else command stat "$@"; fi; }
    no_ adopt_interrupted
    stat() { if [ "$1" = -c ]; then echo "0 700"; else command stat "$@"; fi; }
    printf 'kind=native\nrelay_unit=x;rm\nhost=relay.example.org\n' >"$d/state"
    no_ adopt_interrupted
    printf 'kind=native\nrelay_unit=hollow-relay.service\nboot_unit=\nhost=relay.example.org\nproject=\n' >"$d/state"
    # The screen offers to put the old relay back, and does.
    adopt_interrupted
    adopt_rollback() { echo rolled >>"$R/rolled"; }
    ui_msg() { printf 'MSG %s\n%s\n' "$1" "$2" >>"$R/screens"; }
    ui_menu() { printf 'MENU %s\n' "$*" >>"$R/screens"; UI_REPLY=$MENU_REPLY; }
    MENU_REPLY=rollback DRY_RUN=0
    adopt_resume_main >/dev/null
    has "it says what happened" "$(cat "$R/screens")" "stopped before it was done"
    has "and names the backup" "$(cat "$R/screens")" "$d"
    has "putting it back is recommended" "$(cat "$R/screens")" "Put the old relay back (recommended)"
    ui_size "$(sed -n '/^MSG/,/^MENU/p' "$R/screens")" 7
    eq "the screen fits 80x24" "$UI_FITS" 1
    eq "the old relay is put back" "$(cat "$R/rolled")" rolled
    MENU_REPLY=leave
    adopt_resume_main >/dev/null
    eq "leaving it changes nothing" "$(cat "$R/rolled")" rolled
}
in_sub t_adopt_interrupted_takeover_offers_rollback
eq "a killed take over is found before anything else" \
    "$(grep -nE '^(if adopt_interrupted; then|if \[ -r "\$CONF_FILE" \]; then|adopt_detect)$' "$RELAY/install.sh" | cut -d: -f2 | tr '\n' '|')" \
    'if adopt_interrupted; then|if [ -r "$CONF_FILE" ]; then|adopt_detect|'
has "a checked take over is marked done" "$(sed -n '/^adopt_takeover() {/,/^}/p' "$DEPLOY/lib/adopt.sh" | tr '\n' ' ')" 'ADOPT_ARMED=0     [ "$DRY_RUN" = 1 ] || rm -f "$ADOPT_BACKUP/running"'
