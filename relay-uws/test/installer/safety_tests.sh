#!/bin/bash
# Tests for the rules that keep the setup safe on someone's server: what
# counts as a key login, password logins a Match block keeps, keys on command
# lines, whiptail and dashes, a pasted key's result, and a certificate whose
# renewal method changes. Sourced by run_tests.sh, whose helpers they use.
# shellcheck disable=SC2034,SC2317,SC2016,SC2030,SC2031,SC2154

echo "ssh logins: only sshd's own lines"
t_ssh_logins_anchored() {
    local args=$TMP/jargs
    journalctl() { printf '%s\n' "$*" >"$args"; printf '%s\n' "${JLINES[@]}"; }
    JLINES=(
        "1700000100.000001 box sshd[100]: Accepted publickey for boxu from 198.51.100.7 port 50000 ssh2: ED25519 SHA256:realkey"
        "1700000101.000001 box sshd[101]: Invalid user Accepted publickey for boxu from 203.0.113.9 SHA256:forged from 203.0.113.9 port 4242"
        "1700000102.000001 box sshd[102]: Accepted password for boxu from 198.51.100.8 port 50001 ssh2"
        "1700000103.000001 box sshd[103]: Connection closed by authenticating user boxu 203.0.113.9 port 1 Accepted publickey for boxu from 192.0.2.1 port 5 ssh2: ED25519 SHA256:forged2 [preauth]"
        "1700000104.000001 box sshd-session[104]: Accepted publickey for boxu from 198.51.100.9 port 50002 ssh2: ED25519 SHA256:tenkey"
        "1700000105.000001 box sshd[105]: Accepted keyboard-interactive/pam for boxu from 198.51.100.10 port 50003 ssh2"
        "1700000106.000001 box sshd[106]: Accepted publickey for boxu from 198.51.100.11 port 50004 ssh2: ED25519 SHA256:k2 SHA256:forged3"
        "1700000107.000001 box sshd[107]: Accepted publickey for boxu from 198.51.100.12 port 50005 ssh2: ED25519-CERT SHA256:certkey ID boxu (serial 1) CA ED25519 SHA256:cakey"
        "1700000108.000001 box sshd[108]: Accepted publickey for boxu from 198.51.100.13 port x ssh2: ED25519 SHA256:badport"
    )
    eq "only whole Accepted lines count" "$(ssh_logins boxu 1700000000 | tr '\n' ';')" \
        "1700000100 key 198.51.100.7 SHA256:realkey;1700000102 password 198.51.100.8 -;1700000104 key 198.51.100.9 SHA256:tenkey;1700000105 password 198.51.100.10 -;1700000107 key 198.51.100.12 SHA256:certkey;"
    # The journal is asked for root's sshd processes only: a local account can
    # name its own lines sshd, but never its process or its user id.
    has "lines from root" " $(cat "$args") " " _UID=0 "
    has "written by sshd" " $(cat "$args") " " _COMM=sshd "
    has "or by OpenSSH 10's sshd-session" " $(cat "$args") " " _COMM=sshd-session "
    lacks "never by the name a line gives itself" " $(cat "$args") " " -t "
}
in_sub t_ssh_logins_anchored

echo "ssh: a Match block that keeps passwords"
# A fake sshd_config tree and an sshd -T that reports the global settings.
match_fixture() { # match_fixture <dir>
    local S=$1
    rm -rf "$S"
    mkdir -p "$S/sshd_config.d" "$S/more"
    cat >"$S/sshd_config" <<EOF
Include sshd_config.d/*.conf
PasswordAuthentication no
Match User alice
    PasswordAuthentication yes
Match Address 10.0.0.0/8
    X11Forwarding no
EOF
    printf '# Match User bob\n#    PasswordAuthentication yes\nMatch User carol\n    PasswordAuthentication no\n' >"$S/sshd_config.d/30-y.conf"
    printf 'Match Group admins\n    KbdInteractiveAuthentication=yes\n' >"$S/sshd_config.d/20-x.conf"
    SSHD_CONFIG=$S/sshd_config SSHD_DIR=$S
}
t_audit_flags_match_block_password_auth() {
    local S=$TMP/match got
    match_fixture "$S"
    got=$(ssh_match_passwords)
    eq "each block that takes passwords, in sshd's order" "$got" \
        "$S/sshd_config.d/20-x.conf line 1 (Match Group admins)
$S/sshd_config line 3 (Match User alice)"
    # An Include inside a block puts the included lines in it too.
    printf 'Match User dave\nInclude %s/more/*.conf\n' "$S" >"$S/sshd_config.d/40-z.conf"
    printf 'ChallengeResponseAuthentication yes\n' >"$S/more/a.conf"
    has "an included line counts for its block" "$(ssh_match_passwords)" "40-z.conf line 1 (Match User dave)"
    rm -f "$S/sshd_config.d/40-z.conf"
    printf 'PasswordAuthentication yes\n' >"$S/sshd_config.d/50-global.conf"
    lacks "a global line is sshd -T's to report" "$(ssh_match_passwords)" "50-global"
    rm -f "$S/sshd_config.d/50-global.conf"

    sshd() { [ "$1" = -T ] && printf 'passwordauthentication no\nkbdinteractiveauthentication no\npermitrootlogin no\nport 22\n'; }
    eq "the global state is off" "$(ssh_password_state)" off
    hollow_ssh_ports() { echo 22; }
    have() { return 1; }
    swapon() { :; }
    systemd-analyze() { :; }
    sysctl() { echo '|/bin/false'; }
    clock_synced() { return 0; }
    fw_rules_now() { echo 22/tcp; }
    fw_blocked() { :; }
    SUDO_USER=vitalik
    ssh_home() { echo "$TMP/nohome"; }
    audit_collect
    has "the audit never says keys only" "${AUD_LINES[0]}" "SSH: keys only except where a Match block allows passwords"
    has "and names the block" "${AUD_EXTRA[*]}" "$S/sshd_config line 3 (Match User alice)"
    has "and that it stays" "${AUD_EXTRA[*]}" "I leave that as it is"
    # With the paths a real machine has, and none of this machine's own notes.
    AUD_LINES[3]="Journal: in memory only"
    ui_size "$(AUD_EXTRA=("${AUD_EXTRA[0]}"); audit_text | sed "s|$S|/etc/ssh|g")" 7
    eq "the audit still fits 80x24" "$UI_FITS" 1
    # The switch is not offered for them, and the result says they stay.
    SSH_PLAN=none
    ssh_run
    lacks "the result never claims keys only" "$SSH_RESULT" "SSH already takes keys only"
    has "it names the block" "$SSH_RESULT" "Match User alice"
    has "and how to end it" "$SSH_RESULT" "then run sudo systemctl reload ssh"
    # After a switch that worked, the same.
    eq "the summary text" "$(ssh_keys_only_text "key SHA256:x from 192.0.2.1")" \
        "Password logins are off now. Your key login worked after the change, with the key SHA256:x from 192.0.2.1. That computer holds the key to this server.$(ssh_match_note)"
    # Without such a block, keys only is said plainly.
    printf 'PasswordAuthentication no\n' >"$S/sshd_config"
    rm -f "$S/sshd_config.d/20-x.conf"
    eq "no block, no list" "$(ssh_match_passwords)" ""
    ssh_run
    eq "keys only" "$SSH_RESULT" "SSH already takes keys only."
    audit_collect
    has "the audit says keys only" "${AUD_LINES[0]}" "SSH: keys only, "
}
in_sub t_audit_flags_match_block_password_auth

echo "ssh: when sshd cannot say"
t_audit_says_unknown_when_sshd_cannot_tell() {
    sshd() { return 255; }
    eq "unknown, not on" "$(ssh_password_state)" unknown
    yes_ ssh_passwords_on
    no_ ssh_passwords_surely_on
    SSHD_CONFIG=$TMP/none SSHD_DIR=$TMP
    hollow_ssh_ports() { echo 22; }
    have() { return 1; }
    swapon() { :; }
    systemd-analyze() { :; }
    sysctl() { echo '|/bin/false'; }
    clock_synced() { return 0; }
    fw_rules_now() { echo 22/tcp; }
    fw_blocked() { :; }
    ssh_home() { echo "$TMP/nohome"; }
    audit_collect
    has "the audit says it could not tell" "${AUD_LINES[0]}" "SSH: password logins unknown (sshd -T failed)"
    sshd() { [ "$1" = -T ] && printf 'passwordauthentication yes\n'; }
    eq "on" "$(ssh_password_state)" on
    audit_collect
    has "on is on" "${AUD_LINES[0]}" "SSH: password logins on"
}
in_sub t_audit_says_unknown_when_sshd_cannot_tell

echo "ssh: a pasted key nobody confirmed"
t_ssh_add_key_unconfirmed_names_the_key() {
    WORK_DIR=$TMP
    local K=$TMP/keys_v1 H=$TMP/home_v1 fp
    rm -rf "$K" "$H"
    mkdir -p "$K" "$H/.ssh"
    ssh-keygen -q -t ed25519 -N '' -C old -f "$K/old"
    ssh-keygen -q -t ed25519 -N '' -C jabun@mac-mini -f "$K/new"
    ssh-keygen -q -t ed25519 -N '' -C '' -f "$K/bare"
    cp "$K/old.pub" "$H/.ssh/authorized_keys"
    chmod 700 "$H/.ssh"; chmod 600 "$H/.ssh/authorized_keys"
    ssh_as() { shift; "$@"; }
    ssh_home() { echo "$H"; }
    ssh_host_for_person() { echo relay.example.org; }
    ssh_passwords_surely_on() { return 1; }
    ssh_wait_login() { return 1; }
    ui_msg() { :; }
    SUDO_USER=vitalik UI_MODE=plain DRY_RUN=0
    ui_input() { UI_REPLY=$PASTE; }
    PASTE=$(cat "$K/new.pub")
    fp=$(ssh_pubkey_fp "$PASTE")
    ssh_add_key_run >/dev/null
    has "the result names the key's label" "$SSH_RESULT" "jabun@mac-mini"
    has "and its fingerprint" "$SSH_RESULT" "$fp"
    has "and the line to delete" "$SSH_RESULT" "line 2 of $H/.ssh/authorized_keys"
    has "and that it stays" "$SSH_RESULT" "It stays there"
    ui_size "$SSH_RESULT" 7
    eq "the screen fits 80x24" "$UI_FITS" 1
    eq "the key is still there" "$(sed -n 2p "$H/.ssh/authorized_keys")" "$PASTE"
    # A key without a label is named by its fingerprint and line alone.
    PASTE=$(cat "$K/bare.pub")
    ssh_add_key_run >/dev/null
    has "a key with no label" "$SSH_RESULT" "the key with no label"
    has "on its own line" "$SSH_RESULT" "line 3 of"
}
in_sub t_ssh_add_key_unconfirmed_names_the_key

echo "keys stay off whiptail's command line"
t_remove_key_menu_keeps_keys_off_argv() {
    local F=$TMP/wt_keys log=$TMP/wt_keys.log
    mkdir -p "$F"
    : >"$log"
    # A whiptail that records its arguments and picks the second item.
    cat >"$F/whiptail" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$log"
for a; do case "\$a" in --menu) echo 2 >&2 ;; esac; done
exit 0
EOF
    chmod +x "$F/whiptail"
    PATH="$F:$PATH"
    tput() { case "$1" in cols) echo 80 ;; lines) echo 24 ;; esac; }
    member_list() { printf '%s\n' AAAA-BBBB-CCCC-DDDD EEEE-FFFF-GGGG-HHHH; }
    member_count() { echo 2; }
    ui_remember() { :; }
    ssh_firewall_guard() { :; }
    apply_all() { :; }
    summary_screen() { :; }
    eval "$(declare -f ui_menu | sed '1s/^ui_menu/real_ui_menu/')"
    ui_menu() { if [ "$1" = change ]; then UI_REPLY=removekey; else real_ui_menu "$@"; fi; }
    UI_MODE=whiptail CFG_MEMBERS_ONLY=yes REMOVE_KEY="" CFG_TURN=yes CFG_MODE=native CFG_PUSH=yes CFG_FORWARDER=yes
    CFG_GRACE_SECS=120 CFG_HOST=relay.example.org CFG_EMAIL=""
    manage_change
    eq "the chosen key is the one removed" "$REMOVE_KEY" EEEE-FFFF-GGGG-HHHH
    has "the menu names keys by their end" "$(cat "$log")" "the key ending in HHHH"
    lacks "never a whole key" "$(cat "$log")" "AAAA-BBBB-CCCC-DDDD"
    lacks "nor the other" "$(cat "$log")" "EEEE-FFFF-GGGG-HHHH"
    # The keys screen shows them in the terminal, never on the command line.
    : >"$log"
    clear() { :; }
    out=$(UI_TTY=/dev/null ui_msg_keys "Members-only keys" "The keys to hand out, one per person:
  AAAA-BBBB-CCCC-DDDD")
    has "the keys reach the screen" "$out" "AAAA-BBBB-CCCC-DDDD"
    eq "and whiptail never ran" "$(cat "$log")" ""
    # An answer file still names the whole key.
    declare -gA ANS=([remove_key]=AAAA-BBBB-CCCC-DDDD)
    UI_MODE=answers REMOVE_KEY=""
    manage_change >/dev/null
    eq "an answer file's key is removed" "$REMOVE_KEY" AAAA-BBBB-CCCC-DDDD
    ANS=([remove_key]=ZZZZ-ZZZZ-ZZZZ-ZZZZ)
    has "a key that is not there stops" "$( (manage_change) 2>&1)" "DIE"
}
in_sub t_remove_key_menu_keeps_keys_off_argv
key_screens=$(grep -hE '\$\((member_keys_shown|manage_keys_text)\)' "$RELAY/install.sh" "$DEPLOY/lib/manage.sh")
has "the keys screens go through ui_msg_keys" "$key_screens" 'ui_msg_keys "Members-only keys" "$(member_keys_shown)"'
has "both of them" "$key_screens" 'ui_msg_keys "Members-only keys" "$(manage_keys_text)"'
lacks "and none shows them with ui_msg" "$key_screens" 'ui_msg "'

echo "whiptail and a leading dash"
t_no_screen_text_starts_with_a_dash() {
    local F=$TMP/wt_dash log=$TMP/wt_dash.log
    mkdir -p "$F"
    : >"$log"
    # Like whiptail's own parser: an unknown word starting with a dash before
    # -- is an option it does not know, and the screen never shows. It exits 0
    # there, because the ui loops ask again after a failed whiptail forever.
    cat >"$F/whiptail" <<EOF
#!/bin/sh
seen=0
while [ \$# -gt 0 ]; do
    if [ "\$seen" = 1 ]; then printf 'ARG %s\n' "\$1" >>"$log"; shift; continue; fi
    case "\$1" in
    --) seen=1 ;;
    --backtitle|--title|--default-item) shift ;;
    --msgbox|--yesno|--menu|--inputbox|--passwordbox|--defaultno) ;;
    -*) printf 'BAD %s\n' "\$1" >>"$log"; exit 0 ;;
    *) printf 'ARG %s\n' "\$1" >>"$log" ;;
    esac
    shift
done
echo 1 >&2
exit 0
EOF
    chmod +x "$F/whiptail"
    PATH="$F:$PATH"
    tput() { case "$1" in cols) echo 80 ;; lines) echo 24 ;; esac; }
    ui_remember() { :; }
    ui_cancelled() { echo CANCELLED >>"$log"; return 1; }
    UI_MODE=whiptail
    ui_msg "-t" "- a list item first"
    ui_yesno k "T" "-yes text" yes || true
    ui_menu k "T" "-menu text" -a -a "-label a" -b "-label b"
    ui_input k "T" "-input text" "-default"
    ui_secret k "T" "-secret text"
    lacks "no word was taken for an option" "$(cat "$log")" "BAD"
    has "the message shows" "$(cat "$log")" "ARG - a list item first"
    has "the question shows" "$(cat "$log")" "ARG -yes text"
    has "the menu text shows" "$(cat "$log")" "ARG -menu text"
    has "and its items" "$(cat "$log")" "ARG -label b"
    has "the input text shows" "$(cat "$log")" "ARG -input text"
    has "with its default" "$(cat "$log")" "ARG -default"
    has "the secret's text shows" "$(cat "$log")" "ARG -secret text"
}
in_sub t_no_screen_text_starts_with_a_dash
wt_calls=$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$DEPLOY/lib/ui.sh" | grep -E 'whiptail --')
eq "every whiptail call ends its options with --" "$(grep -c -- ' -- ' <<<"$wt_calls")" "$(grep -c . <<<"$wt_calls")"

echo "a changed address mode and the certificate's renewal"
# issue.sh against a fake certbot and a Let's Encrypt folder of the test's own.
t_a_changed_address_mode_rewrites_the_certificates_renewal_method() {
    local L=$TMP/le_v4 F=$TMP/cb_v4 out calls hooks=$DEPLOY/certbot
    mkdir -p "$F"
    cat >"$F/certbot" <<'EOF'
#!/bin/sh
# certbot 2.1 answers reconfigure --help with its general help and exit 0.
case "$1" in
--version) echo "certbot ${CB_VERSION:-2.9.0}"; exit 0 ;;
reconfigure) [ "${2:-}" = --help ] && exit 0
    case "${CB_VERSION:-2.9.0}" in 2.[012].*|1.*) echo "certbot: error: unrecognized arguments: reconfigure" >&2; exit 2 ;; esac ;;
esac
printf '%s\n' "$*" >>"$CB_CALLS"
exit 0
EOF
    chmod +x "$F/certbot"
    printf '#!/bin/sh\nexit 0\n' >"$F/install-hook"
    chmod +x "$F/install-hook"
    export CB_CALLS=$TMP/cb_v4.calls
    v4_lineage() { # v4_lineage <renewalparams lines>
        rm -rf "$L"
        mkdir -p "$L/renewal" "$L/live/relay"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=x \
            -addext subjectAltName=DNS:myrelay.duckdns.org -keyout "$L/k.pem" -out "$L/live/relay/cert.pem" >/dev/null 2>&1
        printf 'version = 2.9.0\n[renewalparams]\n%s\nserver = https://acme-v02.api.letsencrypt.org/directory\n' "$1" >"$L/renewal/relay.conf"
        : >"$CB_CALLS"
    }
    v4_issue() { # v4_issue <token or empty>
        PATH="$F:$PATH" HOLLOW_LE_DIR=$L RELAY_HOST=myrelay.duckdns.org DUCKDNS_TOKEN=$1 CERT_INSTALL_HOOK=$F/install-hook \
            sh "$hooks/issue.sh" 2>&1
    }
    # Port 80 renewals, now through DuckDNS.
    v4_lineage "authenticator = standalone"
    out=$(v4_issue a1b2c3d4-0000-1111-2222-333344445555)
    calls=$(cat "$CB_CALLS")
    has "certbot is told the new way to renew" "$calls" "reconfigure --cert-name relay"
    has "through DuckDNS" "$calls" "--manual --preferred-challenges dns --manual-auth-hook $hooks/duckdns-auth.sh --manual-cleanup-hook $hooks/duckdns-cleanup.sh"
    has "and the run says why" "$out" "renews it another way now"
    lacks "it never deletes the certificate" "$calls" "delete"
    # A certbot without reconfigure gets the certificate again the new way.
    v4_lineage "authenticator = standalone"
    out=$(CB_VERSION=2.1.0 v4_issue a1b2c3d4-0000-1111-2222-333344445555)
    calls=$(cat "$CB_CALLS")
    lacks "certbot 2.1 has no reconfigure" "$calls" "reconfigure --cert-name"
    has "so the certificate is renewed now, the new way" "$calls" "--force-renewal"
    has "through DuckDNS" "$calls" "--manual-auth-hook $hooks/duckdns-auth.sh"
    lacks "and not kept as it is" "$calls" "--keep-until-expiring"
    lacks "and the run never tried reconfigure on it" "$out" "unrecognized arguments"
    # DuckDNS renewals, now over port 80.
    v4_lineage "authenticator = manual
manual_auth_hook = $hooks/duckdns-auth.sh"
    out=$(v4_issue "")
    has "back to port 80" "$(cat "$CB_CALLS")" "reconfigure --cert-name relay --non-interactive --standalone"
    has "over HTTP, not the DNS challenge it had" "$(cat "$CB_CALLS")" "--standalone --preferred-challenges http"
    # A hook from an old copy of the repository moves to this one's.
    v4_lineage "authenticator = manual
manual_auth_hook = /opt/HOLLOW/relay-uws/deploy/certbot/duckdns-auth.sh"
    out=$(v4_issue a1b2c3d4-0000-1111-2222-333344445555)
    has "an old hook path is replaced" "$(cat "$CB_CALLS")" "reconfigure --cert-name relay --non-interactive --manual --preferred-challenges dns --manual-auth-hook $hooks/duckdns-auth.sh"
    # Nothing changed, nothing rewritten.
    v4_lineage "authenticator = manual
manual_auth_hook = $hooks/duckdns-auth.sh"
    out=$(v4_issue a1b2c3d4-0000-1111-2222-333344445555)
    lacks "the same way stays" "$(cat "$CB_CALLS")" "reconfigure"
    has "and the certificate is kept until it expires" "$(cat "$CB_CALLS")" "--keep-until-expiring"
    v4_lineage "authenticator = standalone"
    out=$(v4_issue "")
    lacks "port 80 stays port 80" "$(cat "$CB_CALLS")" "reconfigure"
}
in_sub t_a_changed_address_mode_rewrites_the_certificates_renewal_method

echo "certbot registers without an email"
# Let's Encrypt keeps no account email, so even a .env from an older setup
# that still names one registers without it.
t_certbot_registers_without_an_email() {
    local L=$TMP/le_em F=$TMP/cb_em calls
    mkfake "$F" certbot 'case "$1" in --version) echo "certbot 2.9.0"; exit 0 ;; esac; printf "%s\n" "$*" >>"$CB_CALLS"'
    mkfake "$F" install-hook 'exit 0'
    export CB_CALLS=$TMP/cb_em.calls
    : >"$CB_CALLS"
    rm -rf "$L"; mkdir -p "$L"
    PATH="$F:$PATH" HOLLOW_LE_DIR=$L RELAY_HOST=relay.example.org CERTBOT_EMAIL=ops@example.org \
        CERT_INSTALL_HOOK=$F/install-hook sh "$DEPLOY/certbot/issue.sh" >/dev/null 2>&1
    calls=$(cat "$CB_CALLS")
    has "a first certificate registers without an email" "$calls" "certonly --non-interactive --agree-tos --register-unsafely-without-email"
    lacks "and never with the old one" "$calls" "--email"
    # A renewal way that changes goes through the account too.
    mkdir -p "$L/renewal" "$L/live/relay"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=x \
        -addext subjectAltName=DNS:relay.example.org -keyout "$L/k.pem" -out "$L/live/relay/cert.pem" >/dev/null 2>&1
    printf '[renewalparams]\nauthenticator = manual\nserver = https://acme-v02.api.letsencrypt.org/directory\n' >"$L/renewal/relay.conf"
    : >"$CB_CALLS"
    PATH="$F:$PATH" HOLLOW_LE_DIR=$L RELAY_HOST=relay.example.org CERTBOT_EMAIL=ops@example.org \
        CERT_INSTALL_HOOK=$F/install-hook sh "$DEPLOY/certbot/issue.sh" >/dev/null 2>&1
    calls=$(cat "$CB_CALLS")
    has "reconfigure registers without one" "$calls" "reconfigure --cert-name relay --non-interactive --standalone --preferred-challenges http --agree-tos --register-unsafely-without-email"
    lacks "and never with the old one" "$calls" "--email"
}
in_sub t_certbot_registers_without_an_email

echo "harden-host.sh and Match blocks"
# The official box's script too: it says keys only only when no Match block
# lets a password back in.
t_harden_host_names_match_blocks() {
    local H=$TMP/hm S=$TMP/hm_ssh F=$TMP/hm_bin out
    rm -rf "$H" "$F"
    cp -R "$DEPLOY" "$H"
    match_fixture "$S"
    printf '\nSSHD_CONFIG=%s/sshd_config SSHD_DIR=%s\n' "$S" "$S" >>"$H/lib/ssh_keys.sh"
    mkdir -p "$TMP/hm_home/.ssh"
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB7 hm" >"$TMP/hm_home/.ssh/authorized_keys"
    mkfake "$F" getent "echo 'hm:x:1000:1000::$TMP/hm_home:/bin/bash'"
    out=$(PATH="$F:$PATH" SUDO_USER=hm sh "$H/harden-host.sh" --print --no-firewall 2>&1)
    has "it still writes the keys-only settings" "$out" "sshd_config.d"
    has "and names the block that takes passwords" "$out" "$S/sshd_config line 3 (Match User alice)"
    has "and each one" "$out" "$S/sshd_config.d/20-x.conf line 1 (Match Group admins)"
    has "and leaves them as they are" "$out" "I leave that as it is"
    printf 'PasswordAuthentication no\n' >"$S/sshd_config"
    rm -f "$S/sshd_config.d/20-x.conf"
    out=$(PATH="$F:$PATH" SUDO_USER=hm sh "$H/harden-host.sh" --print --no-firewall 2>&1)
    lacks "without such a block it names none" "$out" "Match"
}
in_sub t_harden_host_names_match_blocks

echo "daily security updates"
# An apt-config that prints what APT_CONF says, and a harden-host copy that
# writes its apt drop-ins into a test folder.
t_auto_upgrades() {
    local H=$TMP/au F=$TMP/au_bin C=$TMP/au_conf out
    rm -rf "$H" "$F" "$C"
    cp -R "$DEPLOY" "$H"
    mkdir -p "$C"
    printf '\nHOLLOW_APT_CONF_D=%s\n' "$C" >>"$H/lib/host.sh"
    mkfake "$F" apt-config 'cat "$APT_CONF" 2>/dev/null'
    PATH="$F:$PATH"
    . "$H/lib/host.sh"
    export APT_CONF=$TMP/au_dump
    : >"$APT_CONF"
    eq "Debian's stock settings leave the daily job idle" "$(hollow_auto_upgrades)" unset
    eq "so both settings are written" "$(hollow_auto_upgrades_dropin | grep -c '"1";')" 2
    eq "into the file dpkg-reconfigure writes" "$(hollow_auto_upgrades_file)" "$C/20auto-upgrades"
    out=$(sh "$H/harden-host.sh" --print --no-firewall --no-ssh 2>&1)
    has "harden-host switches them on" "$out" "would write: $C/20auto-upgrades"
    has "with the list update" "$out" 'APT::Periodic::Update-Package-Lists "1";'
    has "and the upgrade" "$out" 'APT::Periodic::Unattended-Upgrade "1";'
    has "and says so" "$out" "switching unattended security updates on in $C/20auto-upgrades"
    printf 'APT::Periodic::Unattended-Upgrade "1";\n' >"$APT_CONF"
    : >"$C/20auto-upgrades"
    eq "one set alone is not on" "$(hollow_auto_upgrades)" unset
    eq "only the missing one is written" "$(hollow_auto_upgrades_dropin | grep -v '^//')" 'APT::Periodic::Update-Package-Lists "1";'
    printf 'APT::Periodic::Update-Package-Lists "1";\n' >"$APT_CONF"
    eq "whichever one it is" "$(hollow_auto_upgrades_dropin | grep -v '^//')" 'APT::Periodic::Unattended-Upgrade "1";'
    eq "next to a 20auto-upgrades already there" "$(hollow_auto_upgrades_file)" "$C/21hollow-auto-upgrades"
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "0";\n' >"$APT_CONF"
    eq "an explicit 0 is off" "$(hollow_auto_upgrades)" off
    out=$(sh "$H/harden-host.sh" --print --no-firewall --no-ssh 2>&1)
    lacks "and harden-host never overrides it" "$out" "auto-upgrades"
    has "but says so" "$out" "unattended security updates are switched OFF in apt's settings"
    printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "1";\n' >"$APT_CONF"
    eq "a list update set to 0 is off too" "$(hollow_auto_upgrades)" off
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >"$APT_CONF"
    eq "Ubuntu's settings are on" "$(hollow_auto_upgrades)" on
    out=$(sh "$H/harden-host.sh" --print --no-firewall --no-ssh 2>&1)
    lacks "and harden-host changes nothing there" "$out" "auto-upgrades"
    lacks "nor says they are off" "$out" "switched OFF"
    # A later file wins: the last value apt prints is the one it uses.
    printf 'APT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "0";\n' >"$APT_CONF"
    eq "the last value counts" "$(hollow_auto_upgrades)" off
}
in_sub t_auto_upgrades
# check-host's copy of the rule (it runs alone on the official box), run with
# the same fake apt-config.
t_check_host_auto_upgrades() {
    local F=$TMP/ch_bin block
    mkfake "$F" apt-config 'cat "$APT_CONF" 2>/dev/null'
    mkfake "$F" unattended-upgrade 'exit 0'
    PATH="$F:$PATH"
    export APT_CONF=$TMP/ch_dump
    block=$(sed -n '/^if command -v unattended-upgrade/,/^fi/p' "$DEPLOY/check-host.sh")
    run_block() { ( ok() { echo "OK $1"; }; bad() { echo "BAD $1"; }; eval "$block" ); }
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >"$APT_CONF"
    has "check-host passes daily updates" "$(run_block)" "OK unattended-upgrades installs security updates every day"
    : >"$APT_CONF"
    has "and fails them unset" "$(run_block)" "BAD unattended-upgrades is installed but apt never runs it"
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "0";\n' >"$APT_CONF"
    has "and fails them off" "$(run_block)" 'Unattended-Upgrade "0"'
    printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "1";\n' >"$APT_CONF"
    has "and fails a list update that is off" "$(run_block)" "BAD unattended-upgrades"
}
in_sub t_check_host_auto_upgrades

t_audit_auto_upgrades() {
    local state
    for state in on unset off missing; do
        AUD_LINES=() AUD_EXTRA=() HARDEN_CHANGES=()
        have() { [ "$1" != unattended-upgrade ] || [ "$state" != missing ]; }
        hollow_auto_upgrades() { echo "$state"; }
        audit_security_updates
        case "$state" in
        on) eq "the audit says daily updates run" "${AUD_LINES[*]}" "Security updates: installed every day"
            eq "and offers nothing" "${#HARDEN_CHANGES[@]}" 0 ;;
        unset) has "the audit says apt never runs them" "${AUD_LINES[*]}" "apt never runs it"
            has "and the hardening switches them on" "${HARDEN_CHANGES[*]}" "Security updates install on their own every day." ;;
        off) has "the audit says they are switched off" "${AUD_LINES[*]}" "switched off in apt's settings"
            eq "and the hardening leaves the 0 alone" "${#HARDEN_CHANGES[@]}" 0
            has "and says how to turn them on" "${AUD_EXTRA[*]}" "dpkg-reconfigure -plow unattended-upgrades" ;;
        missing) has "the audit says nothing installs them" "${AUD_LINES[*]}" "not installed automatically"
            has "and the hardening installs them" "${HARDEN_CHANGES[*]}" "Security updates install on their own every day." ;;
        esac
    done
}
in_sub t_audit_auto_upgrades

echo "no pipeline ends in grep -q"
# a_pipeline_never_ends_in_grep_q_under_pipefail: grep -q stops reading at its
# first match, the writer then dies of SIGPIPE, and pipefail turns the match
# into a failure now and then. install.sh and its libraries run with pipefail.
t_no_grep_q_after_a_pipe() {
    local hits
    hits=$(awk 'FNR == 1 { prev = "" }
        { if ($0 ~ /(^|[^|])\|[ \t]*grep[ \t]+-[A-Za-z]*q/ || (prev ~ /[^|]\|[ \t]*$/ && $0 ~ /^[ \t]*grep[ \t]+-[A-Za-z]*q/))
              print FILENAME ":" FNR
          prev = $0 }' "$RELAY/install.sh" "$DEPLOY"/lib/*.sh)
    eq "no pipeline in the setup ends in grep -q" "$hits" ""
    # The scan sees both shapes.
    printf 'a | grep -q x\nb |\n    grep -qi y\nc || grep -q z\n' >"$TMP/pipes.sh"
    eq "the scan finds them" "$(awk 'FNR == 1 { prev = "" }
        { if ($0 ~ /(^|[^|])\|[ \t]*grep[ \t]+-[A-Za-z]*q/ || (prev ~ /[^|]\|[ \t]*$/ && $0 ~ /^[ \t]*grep[ \t]+-[A-Za-z]*q/))
              print FNR
          prev = $0 }' "$TMP/pipes.sh" | tr '\n' ' ')" "1 3 "
}
in_sub t_no_grep_q_after_a_pipe

# ---------------------------------------------------------------- round 4: the 0.13 relay

echo "the TURN port lock's settings follow coturn"
# the_port_lock_peers_are_exactly_coturns_allowed_peer_ips: check-host fails
# the lock when its addresses differ from coturn's --allowed-peer-ip values.
t_lock_peers_match_coturn() {
    local F=$TMP/fake_coturn case pub own v6 got want
    mkdir -p "$F" "$TMP/rt"
    for case in "203.0.113.7 10.0.0.5 2001:db8::7" "203.0.113.7 203.0.113.7 -" "198.51.100.9 192.168.1.20 -"; do
        read -r pub own v6 <<<"$case"
        [ "$v6" = - ] && v6=""
        mkfake "$F" hostname "echo '$own '"
        mkfake "$F" ip "echo '1.1.1.1 via 10.0.0.1 dev eth0 src $own uid 0'"
        mkfake "$F" turnserver 'for a; do case "$a" in --allowed-peer-ip=*) echo "${a#--allowed-peer-ip=}" ;; esac; done'
        got=$(PATH="$F:$PATH" TURN_SECRET=x PUBLIC_IP=$pub LOCAL_IP=$own PUBLIC_IPV6=$v6 RUNTIME_DIRECTORY=$TMP/rt \
            sh "$DEPLOY/coturn/coturn-start.sh" 2>/dev/null | grep -v '^Starting' | sort | tr '\n' ' ')
        want=$(CFG_PUBLIC_IP=$pub PF_LOCAL_IP=$own CFG_PUBLIC_IPV6=$v6 turn_lock_peers | tr ' ' '\n' | sort | tr '\n' ' ')
        eq "the lock's addresses are coturn's ($case)" "$want" "$got"
    done
    CFG_PUBLIC_IP=203.0.113.7 PF_LOCAL_IP=10.0.0.5 CFG_PUBLIC_IPV6=2001:db8::7 CFG_FORWARDER=yes
    local env
    env=$(render_turn_lock_env hollow-turn)
    has "coturn's account" "$env" "TURN_USER=hollow-turn"
    has "its addresses, quoted for systemd" "$env" 'TURN_PEERS="203.0.113.7 10.0.0.5 2001:db8::7"'
    has "its relay ports" "$env" "TURN_PORTS=49152-65535"
    has "and the forwarder's" "$env" "FORWARDER_PORTS=40000-40199"
    CFG_FORWARDER=no
    eq "no forwarder, no forwarder ports" "$(render_turn_lock_env 65999 | tail -n 1)" "FORWARDER_PORTS="
    has "the coturn range is coturn-start.sh's" "$(cat "$DEPLOY/coturn/coturn-start.sh")" "--min-port=${TURN_RELAY_PORTS%-*}"
    has "to its end" "$(cat "$DEPLOY/coturn/coturn-start.sh")" "--max-port=${TURN_RELAY_PORTS#*-}"
}
in_sub t_lock_peers_match_coturn

echo "the TURN port lock goes in before coturn starts"
lock_stubs() { # <log>
    LOCK_LOG=$1
    : >"$LOCK_LOG"
    run() { echo "run $*" >>"$LOCK_LOG"; return 0; }
    run_ok() { echo "run $*" >>"$LOCK_LOG"; return 0; }
    put_file() { echo "put $1 $2 $3" >>"$LOCK_LOG"; cat >"$TMP/put.$(basename "$1")"; PUT_CHANGED=${PUT_FAKE:-1}; }
    ensure_dir() { echo "dir $1" >>"$LOCK_LOG"; }
    apt_install() { echo "apt $*" >>"$LOCK_LOG"; }
    step() { :; }
    say() { :; }
}
# a_turn_setup_puts_the_port_lock_in_place_first
t_lock_apply() {
    local log=$TMP/lock.log l
    lock_stubs "$log"
    RELAY_ETC=$TMP/lk_etc UNIT_DIR=$TMP/lk_units LOCK_ENV=$TMP/lk_etc/turn-port-lock.env
    LOCK_DROPIN_DIR=$TMP/lk_units/hollow-coturn.service.d LOCK_DROPIN=$TMP/lk_units/hollow-coturn.service.d/hollow-port-lock.conf
    mkdir -p "$RELAY_ETC" "$UNIT_DIR"
    CFG_PUBLIC_IP=203.0.113.7 PF_LOCAL_IP=10.0.0.5 CFG_PUBLIC_IPV6="" CFG_FORWARDER=yes DRY_RUN=0
    unit_active() { return 1; }
    turn_lock_apply hollow-turn yes
    l=$(cat "$log")
    has "nft and the checks' tools come with it" "$l" "apt nftables procps iproute2 python3"
    has "the program, root's" "$l" "put $LOCK_BIN 0755 root"
    eq "from the setup's copy" "$(cat "$TMP/put.hollow-turn-port-lock")" "$(cat "$DEPLOY/turn-port-lock.sh")"
    has "its settings, root's alone" "$l" "put $LOCK_ENV 0600 root"
    local u
    for u in hollow-turn-port-lock.service hollow-turn-port-lock-refresh.service hollow-turn-port-lock-refresh.timer; do
        has "the unit $u" "$l" "put $UNIT_DIR/$u 0644 root"
        eq "as shipped ($u)" "$(cat "$TMP/put.$u")" "$(cat "$DEPLOY/$u")"
    done
    has "coturn's own unit needs the lock" "$l" "put $LOCK_DROPIN 0644 root"
    eq "through the shipped drop-in" "$(cat "$TMP/put.hollow-port-lock.conf")" "$(cat "$DEPLOY/coturn-port-lock.conf")"
    has "the lock and its timer start on boot" "$l" "run systemctl enable --quiet hollow-turn-port-lock.service hollow-turn-port-lock-refresh.timer"
    has "and start now" "$l" "run systemctl start hollow-turn-port-lock.service"
    has "the timer too" "$l" "run systemctl start hollow-turn-port-lock-refresh.timer"
    lacks "nothing starts coturn here" "$l" "start hollow-coturn"
    # Its settings change while it runs: stopped first, so it gives back what it
    # reserved, then started with the new ones.
    printf 'TURN_USER=hollow-turn\nTURN_PEERS="203.0.113.1"\n' >"$LOCK_ENV"
    unit_active() { [ "$1" = hollow-turn-port-lock.service ]; }
    : >"$log"
    turn_lock_apply hollow-turn yes
    l=$(cat "$log")
    has "a running lock with other settings stops first" "$l" "run systemctl stop hollow-turn-port-lock.service"
    eq "before its settings are written" "$(grep -n . "$log" | grep -E 'stop hollow-turn|put .*turn-port-lock.env' | cut -d: -f2 | cut -c1-3 | tr '\n' ' ')" "run put "
    has "then loads again" "$l" "run systemctl restart hollow-turn-port-lock.service"
    render_turn_lock_env hollow-turn >"$LOCK_ENV"
    : >"$log"
    PUT_FAKE=0 turn_lock_apply hollow-turn yes
    lacks "the same settings stop nothing" "$(cat "$log")" "systemctl stop"
    lacks "nor reload it" "$(cat "$log")" "restart hollow-turn-port-lock"
    # Docker: the lock before docker.service and no drop-in.
    : >"$log"
    mkdir -p "$LOCK_DROPIN_DIR" && touch "$LOCK_DROPIN"
    turn_lock_apply 65999 no
    lacks "Docker gets no drop-in" "$(cat "$log")" "put $LOCK_DROPIN"
    has "and loses one an older run left" "$(cat "$log")" "run rm -f $LOCK_DROPIN"
    has "the shipped unit starts before Docker" "$(cat "$DEPLOY/hollow-turn-port-lock.service")" "Before=coturn.service hollow-coturn.service docker.service"
}
in_sub t_lock_apply

# Where turn_apply runs in native_apply: before start_units, which starts coturn.
t_lock_order() {
    local body
    body=$(declare -f native_apply)
    yes_ test "$(grep -n 'turn_apply' <<<"$body" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'start_units' <<<"$body" | head -n 1 | cut -d: -f1)"
    body=$(declare -f docker_apply)
    yes_ test "$(grep -n 'turn_lock_apply "$turn_uid" no' <<<"$body" | cut -d: -f1)" -lt "$(grep -n 'compose up -d' <<<"$body" | head -n 1 | cut -d: -f1)"
    has "turn_apply puts the lock in for coturn's account" "$(declare -f turn_apply)" "turn_lock_apply hollow-turn yes"
}
in_sub t_lock_order

echo "the TURN port lock goes when TURN does"
# turning_turn_off_removes_the_port_lock
t_lock_remove() {
    local log=$TMP/lockrm.log l
    lock_stubs "$log"
    UNIT_DIR=$TMP/lr_units LOCK_ENV=$TMP/lr_etc/turn-port-lock.env LOCK_BIN=$TMP/lr_bin/hollow-turn-port-lock
    LOCK_DROPIN_DIR=$TMP/lr_units/hollow-coturn.service.d LOCK_DROPIN=$TMP/lr_units/hollow-coturn.service.d/hollow-port-lock.conf
    rm -rf "$TMP/lr_units" "$TMP/lr_etc" "$TMP/lr_bin"
    mkdir -p "$UNIT_DIR" "$TMP/lr_etc" "$TMP/lr_bin"
    turn_lock_remove
    eq "with no lock there, nothing happens" "$(cat "$log")" ""
    printf 'TURN_PORTS=49152-65535\nFORWARDER_PORTS=40000-40199\n' >"$LOCK_ENV"
    printf '#!/bin/sh\n' >"$LOCK_BIN" && chmod +x "$LOCK_BIN"
    mkdir -p "$LOCK_DROPIN_DIR" && touch "$LOCK_DROPIN" "$UNIT_DIR/hollow-turn-port-lock.service"
    unit_exists() { return 0; }
    turn_lock_remove
    l=$(cat "$log")
    has "the timer stops" "$l" "run systemctl disable --now hollow-turn-port-lock-refresh.timer"
    has "and the lock, whose stop removes its rule" "$l" "run systemctl disable --now hollow-turn-port-lock.service"
    has "the rule and the reserved ports go even when it had stopped" "$l" "run env TURN_PORTS=49152-65535 FORWARDER_PORTS=40000-40199 $LOCK_BIN remove"
    has "its drop-in goes" "$l" "run rm -f $LOCK_DROPIN"
    has "its units" "$l" "run rm -f $UNIT_DIR/hollow-turn-port-lock-refresh.timer"
    has "its settings and program" "$l" "run rm -f $LOCK_ENV $LOCK_BIN"
    # Every path that turns TURN off or removes the relay takes the lock along.
    turn_lock_remove() { echo LOCK-REMOVED; }
    turn_lock_apply() { echo "LOCK-APPLY $*"; }
    CFG_TURN=no DRY_RUN=1 UNIT_DIR=$TMP/lr_units TURN_ETC=$TMP/lr_turn
    has "TURN off in the full setup" "$(turn_apply 2>&1)" LOCK-REMOVED
    has "the full setup's uninstall" "$(DRY_RUN=1 native_uninstall no 2>&1)" LOCK-REMOVED
    STACK_DIR=$TMP/lr_stack DOCKER_DIR=$TMP/lr_docker
    has "the Docker setup's uninstall" "$(DRY_RUN=1 docker_uninstall no 2>&1)" LOCK-REMOVED
    for f in apt_install run_logged docker_install install_installer_copy docker_copy_stack docker_keys docker_env conf_save build_swap_on; do
        eval "$f() { :; }"
    done
    hollow_apt_wait() { :; }
    CFG_ADDRESS=ip CFG_FORWARDER=no
    has "TURN off under Docker" "$(CFG_TURN=no DRY_RUN=1 docker_apply 2>&1)" LOCK-REMOVED
    has "TURN on under Docker locks coturn's uid, without a drop-in" "$(CFG_TURN=yes DRY_RUN=1 docker_apply 2>&1)" "LOCK-APPLY 65999 no"
    # docker_masks_the_packages_coturn: it would take TURN's ports beside the
    # container, with no lock on its account.
    systemctl() { [ "$*" = "show -p LoadState --value coturn" ] && echo "$COTURN_FAKE"; return 0; }
    COTURN_FAKE=loaded
    : >"$log"
    CFG_TURN=yes DRY_RUN=1 docker_apply >/dev/null 2>&1
    has "Docker stops the package's coturn" "$(cat "$log")" "run systemctl disable --now coturn"
    has "and masks it" "$(cat "$log")" "run systemctl mask --quiet coturn"
    # docker_warns_when_coturns_uid_is_a_host_account: the lock holds that account too.
    getent() { [ "$1 $2" = "passwd 65999" ] && echo "odd:x:65999:65999::/home/odd:/bin/sh"; }
    has "Docker says when coturn's uid is also an account here" "$(CFG_TURN=yes DRY_RUN=1 docker_apply 2>&1)" "which on this machine is also the account odd"
    unset -f getent
    # docker_never_warns_about_uid_999: dnsmasq and the like keep their own uid.
    lacks "the first system account's uid is no longer held" "$(getent() { [ "$1 $2" = "passwd 999" ] && echo "dnsmasq:x:999:65534::/var/lib/misc:/usr/sbin/nologin"; }; CFG_TURN=yes DRY_RUN=1 docker_apply 2>&1)" "also the account"
    lacks "and says nothing when it is not" "$(getent() { return 2; }; CFG_TURN=yes DRY_RUN=1 docker_apply 2>&1)" "also the account"
    COTURN_FAKE=masked
    : >"$log"
    DRY_RUN=1 docker_uninstall no >/dev/null 2>&1
    has "the Docker uninstall unmasks it" "$(cat "$log")" "run systemctl unmask coturn"
}
in_sub t_lock_remove

echo "coturn's container has a uid of its own"
# docker_coturn_runs_as_a_uid_no_host_account_has: the TURN port lock holds
# coturn's socket owner, so a host account sharing it would be held as well.
t_docker_turn_uid() {
    local uid compose=$RELAY/docker-compose.yml
    uid=$(docker_turn_uid)
    eq "the installer reads coturn's uid where certbot does" "$uid" "$(sed -n 's/^TURN_UID=//p' "$DEPLOY/certbot/lib.sh")"
    eq "the compose file runs coturn as that uid" "$(compose_turn_user "$compose")" "$uid:$uid"
    eq "and the uid is the one in the compose file" "$uid" "$(compose_turn_user "$compose" | cut -d: -f1)"
    # Above 16 bits (systemd's dynamic users, nobody), below useradd's first subordinate uid.
    yes_ test "$uid" -gt 65535
    yes_ test "$uid" -lt 100000
    eq "the relay keeps 999, which owns its certificate" "$(sed -n 's/^CERT_UID=//p' "$DEPLOY/certbot/lib.sh")" 999
    has "the relay's image runs as 999" "$(cat "$RELAY/Dockerfile")" "useradd --system --uid 999"
    has "coturn reads its own copy of the certificate" \
        "$(awk '/^  [^ #]/ { svc = $1 } svc == "coturn:"' "$compose")" "CERT_DIR=/certs/turn"
    eq "a compose file without coturn names no user" "$(printf 'services:\n  relay:\n    user: "1:1"\n' >"$TMP/nc.yml"; compose_turn_user "$TMP/nc.yml")" ""
}
in_sub t_docker_turn_uid

# certs_volume_gives_coturn_its_own_copy: the relay's key stays 0600 and 999's,
# so coturn's uid reads a copy of its own instead of a wider mode.
t_cert_copies() {
    local le=$TMP/le_pair src=$TMP/src_pair F=$TMP/fake_chown log=$TMP/chown.log
    rm -rf "$le" "$src" "$log"
    mkdir -p "$le" "$src"
    printf 'chain\n' >"$src/fullchain.pem"
    printf 'key\n' >"$src/privkey.pem"
    mkfake "$F" chown 'echo "chown $*" >>"$CHOWN_LOG"'
    PATH="$F:$PATH" CHOWN_LOG=$log HOLLOW_LE_DIR=$le \
        sh -c '. "$1"; install_pair "$2/fullchain.pem" "$2/privkey.pem"' _ "$DEPLOY/certbot/lib.sh" "$src"
    eq "the relay's key keeps its mode" "$(stat -c %a "$le/privkey.pem")" 600
    eq "and its chain" "$(stat -c %a "$le/fullchain.pem")" 644
    has "both stay 999's" "$(cat "$log")" "chown 999:999 $le/fullchain.pem.new $le/privkey.pem.new"
    eq "coturn's copy of the key" "$(cat "$le/turn/privkey.pem")" key
    eq "is 0600 too" "$(stat -c %a "$le/turn/privkey.pem")" 600
    eq "with the chain" "$(cat "$le/turn/fullchain.pem")" chain
    eq "in a folder only coturn's uid enters" "$(stat -c %a "$le/turn")" 700
    has "the folder is coturn's" "$(cat "$log")" "chown 65999:65999 $le/turn"
    has "and so is its pair" "$(cat "$log")" "chown 65999:65999 $le/turn/fullchain.pem.new $le/turn/privkey.pem.new"
    no_ test -e "$le/turn/privkey.pem.new"
}
in_sub t_cert_copies

# docker_locks_the_uid_its_compose_file_runs: a lock on another uid than
# coturn's leaves TURN unlocked, so a mismatch stops the setup first.
t_docker_lock_follows_compose() {
    local stack=$TMP/dl_stack
    rm -rf "$stack"
    mkdir -p "$stack"
    for f in apt_install run run_ok docker_install install_installer_copy docker_copy_stack docker_keys docker_env \
        conf_save build_swap_on build_swap_off hollow_apt_wait step say adopt_step wait_for_relay local_get; do
        eval "$f() { :; }"
    done
    turn_lock_apply() { echo "LOCK-APPLY $*"; }
    turn_lock_remove() { echo LOCK-REMOVED; }
    run_logged() { echo "RUN $*"; }
    systemctl() { return 0; }
    getent() { return 2; }
    die() { echo "DIE $*"; exit 1; }
    STACK_DIR=$stack DOCKER_DIR=$TMP/dl_docker CFG_ADDRESS=ip CFG_FORWARDER=no CFG_TURN=yes DRY_RUN=0 DOCKER_REBUILD=0
    cp "$RELAY/docker-compose.yml" "$stack/docker-compose.yml"
    local out
    out=$( (docker_apply) 2>&1)
    has "the shipped compose file is locked on its uid" "$out" "LOCK-APPLY 65999 no"
    lacks "and goes on" "$out" "DIE"
    has "to start the containers" "$out" "RUN compose up -d --remove-orphans"
    sed -i 's/^    user: "65999:65999"$/    user: "999:999"/' "$stack/docker-compose.yml"
    out=$( (docker_apply) 2>&1)
    has "a compose file that runs coturn as another uid stops the setup" "$out" "DIE coturn in $stack/docker-compose.yml does not run as uid 65999"
    lacks "before any lock" "$out" "LOCK-APPLY"
    lacks "or container starts" "$out" "RUN compose up"
    out=$( (CFG_TURN=no docker_apply) 2>&1)
    has "TURN off needs no match" "$out" "LOCK-REMOVED"
    # an_update_recreates_the_containers_that_run_its_hooks: a container that
    # kept running holds the folder the new copy replaced.
    sed -i 's/^    user: "999:999"$/    user: "65999:65999"/' "$stack/docker-compose.yml"
    out=$( (DOCKER_REBUILD=1 docker_apply) 2>&1)
    has "new sources recreate the renewal and DuckDNS containers" "$out" "RUN compose up -d --no-deps --force-recreate certbot-renew duckdns"
    yes_ test "$(grep -n 'RUN compose up -d --remove-orphans' <<<"$out" | cut -d: -f1)" -lt \
        "$(grep -n 'force-recreate' <<<"$out" | cut -d: -f1)"
    out=$( (docker_apply) 2>&1)
    lacks "kept sources leave them running" "$out" "force-recreate"
}
in_sub t_docker_lock_follows_compose

# an_update_and_a_take_over_keep_the_lock_for_their_rollback
t_lock_rollback_paths() {
    has "an update's snapshot keeps the lock program" "$UPDATE_SNAP_PATHS" "/usr/local/sbin/hollow-turn-port-lock"
    has "and the drop-in" " $UPDATE_SNAP_PATHS " "/hollow-coturn.service.d"
    has "the lock's settings sit where the snapshot reaches" "$LOCK_ENV" "$RELAY_ETC/"
    local p
    p=$(adopt_paths_lock)
    for f in "$LOCK_BIN" "$LOCK_ENV" "$LOCK_DROPIN" "$UNIT_DIR/hollow-turn-port-lock.service" "$UNIT_DIR/hollow-turn-port-lock-refresh.timer"; do
        has "a take over backs up $f" "$p" "$f"
    done
    has "a take over of a hand setup" "$(declare -f adopt_paths_native)" "adopt_paths_lock"
    has "and of a compose setup" "$(declare -f adopt_paths_docker)" "adopt_paths_lock"
    has "a rollback removes a lock it added" "$(declare -f adopt_rollback)" 'systemctl disable --now "$LOCK_TIMER" "$LOCK_UNIT"'
}
in_sub t_lock_rollback_paths

# the_status_screen_shows_the_port_lock
t_lock_status() {
    systemctl() {
        case "$*" in
        "is-active hollow-turn-port-lock.service") echo "$LOCK_FAKE" ;;
        "is-active --quiet hollow-turn-port-lock-refresh.timer") [ "$TIMER_FAKE" = on ] ;;
        *) return 3 ;;
        esac
    }
    LOCK_FAKE=active TIMER_FAKE=on
    eq "on" "$(lock_state)" on
    TIMER_FAKE=off
    has "on without its timer" "$(lock_state)" "the timer that loads it again every minute is stopped"
    LOCK_FAKE=failed
    has "failed" "$(lock_state)" "FAILED (journalctl -u hollow-turn-port-lock.service)"
    LOCK_FAKE=inactive
    has "not there yet" "$(lock_state)" "not in place"
    CFG_MODE=native CFG_TURN=yes CFG_PUSH=no CFG_FORWARDER=no CFG_ADDRESS=ip CFG_MEMBERS_ONLY=no CFG_STAGING=no CFG_HOST=203.0.113.7
    UPDATE_TEXT=x
    local_get() { :; }
    installed_source() { echo prebuilt; }
    served_cert_expiry() { echo soon; }
    LOCK_FAKE=active TIMER_FAKE=on
    has "the status screen names it" "$(status_text)" "TURN port lock: on"
    CFG_TURN=no
    lacks "only while TURN is on" "$(status_text)" "TURN port lock"
}
in_sub t_lock_status

echo "the public stats page"
# public_stats_reads_like_the_relay
t_public_stats_norm() {
    local v
    for v in "" on ON " on " yes 1 true; do eq "[$v] is on" "$(public_stats_norm "$v")" on; done
    for v in off OFF no 0 false maybe "o n"; do eq "[$v] is off" "$(public_stats_norm "$v")" off; done
}
in_sub t_public_stats_norm

# public_stats_has_its_own_question_recommended_on
t_public_stats_question() {
    local out
    UI_MODE=answers
    ANS=()
    ask_public_stats >/dev/null
    eq "on unless asked otherwise" "$CFG_PUBLIC_STATS" on
    ANS=([public_stats]=off)
    ask_public_stats >/dev/null
    eq "the answer file turns it off" "$CFG_PUBLIC_STATS" off
    ANS=([public_stats]=maybe)
    has "and gives only on or off" "$( (ask_public_stats) 2>&1)" "DIE"
    UI_MODE=plain
    ui_menu() { printf '%s' "$2" >"$TMP/ps.title"; printf '%s' "$3" >"$TMP/ps.text"; printf '%s' "$4" >"$TMP/ps.default"
        printf '%s\n' "${@:5}" >"$TMP/ps.items"; UI_REPLY=$4; }
    CFG_PUBLIC_STATS=""
    ask_public_stats
    out=$(cat "$TMP/ps.text")
    eq "its own screen" "$(cat "$TMP/ps.title")" "The public stats page"
    eq "on is the default" "$(cat "$TMP/ps.default")" on
    eq "and recommended" "$(tr '\n' '|' <"$TMP/ps.items")" "on|On (recommended)|off|Off|"
    has "it says what is public" "$out" "how many people are online, how much traffic the relay carries and how much memory it uses"
    has "what off leaves out" "$out" "leaves out the online count and the traffic and rounds the memory to whole percent"
    has "what the app then shows" "$out" "The app's relay card then shows only memory."
    has "and why a small group may want it off" "$out" "the online count can tell an outsider when its people are around"
    fits "the public stats screen" "$out" 9
    has "a first install asks it" "$(sed -n '/^# -* main/,$p' "$RELAY/install.sh")" "ask_public_stats"
    has "the answer file knows it" " ${ANSWER_KEYS//$'\n'/ } " " public_stats "
    has "answers.example names it" "$(cat "$T/answers.example")" "public_stats=on"
}
in_sub t_public_stats_question

# public_stats_reaches_relay_env_dot_env_install_conf_and_the_screens
t_public_stats_everywhere() {
    put_file() { cat >"$TMP/ps.put.$(basename "$1")"; PUT_CHANGED=1; }
    ensure_dir() { :; }
    ensure_account() { :; }
    restore_state() { return 1; }
    step() { :; }
    RELAY_ETC=$TMP/ps_etc TURN_ETC=$TMP/ps_turn PUSH_ETC=$TMP/ps_push FWD_ETC=$TMP/ps_fwd
    CFG_DUCKDNS_TOKEN="" CFG_DUCKDNS_IP="" CFG_PUBLIC_IP="" CFG_PUBLIC_IPV6="" PF_LOCAL_IP="" PF_BEHIND_NAT=0
    CFG_ADDRESS=ip CFG_BINARIES=prebuilt UPDATE_TEXT=x
    mkdir -p "$RELAY_ETC"
    CFG_TURN=no CFG_PUSH=no CFG_FORWARDER=no CFG_MEMBERS_ONLY=no CFG_MEMBER_KEYS=0 REMOVE_KEY="" DRY_RUN=0
    CFG_PUBLIC_STATS=off
    relay_settings
    has "relay.env takes it" "$(cat "$TMP/ps.put.relay.env")" "PUBLIC_STATS=off"
    CFG_PUBLIC_STATS=on
    relay_settings
    has "on as well" "$(cat "$TMP/ps.put.relay.env")" "PUBLIC_STATS=on"
    STACK_DIR=$TMP/ps_stack CFG_HOST=relay.example.org CFG_GRACE_SECS=120 CFG_STAGING=no FWD_KEY="" CFG_PUBLIC_STATS=off
    mem_mb() { echo 1024; }
    docker_env
    has ".env takes it" "$(cat "$TMP/ps.put..env")" "PUBLIC_STATS=off"
    has "which compose hands the relay" "$(cat "$RELAY/docker-compose.yml")" 'PUBLIC_STATS=${PUBLIC_STATS:-on}'
    CONF_FILE=$TMP/ps.conf
    CFG_MODE=native
    conf_save
    has "install.conf keeps the answer" "$(cat "$TMP/ps.put.ps.conf")" "public_stats=off"
    printf 'mode=native\nturn=yes\n' >"$CONF_FILE"
    printf 'PUBLIC_STATS=off\n' >"$RELAY_ETC/relay.env"
    conf_load
    eq "a setup from before the question keeps what the relay reads" "$CFG_PUBLIC_STATS" off
    rm -f "$RELAY_ETC/relay.env"
    conf_load
    eq "and with nothing set it is on, as the relay has it" "$CFG_PUBLIC_STATS" on
    CFG_PUBLIC_STATS=off CFG_HOST=relay.example.org CFG_STAGING=no CFG_MEMBERS_ONLY=no CFG_GRACE_SECS=120 CFG_TURN=no CFG_PUSH=no CFG_FORWARDER=no
    local_get() { :; }
    installed_source() { echo prebuilt; }
    served_cert_expiry() { echo soon; }
    has "the status screen shows it" "$(status_text)" "Public stats page: off, without the online count and the traffic"
    load_fn "$RELAY/install.sh" plan_text summary_running fw_rules_now ports_text
    hollow_ssh_ports() { echo 22; }
    member_count() { echo 0; }
    has "the plan shows it" "$(plan_text)" "Public stats page: off, without the online count and the traffic"
    has "and the summary" "$(summary_running)" "Public stats page: off, without the online count and the traffic."
    # The change menu offers it and asks its own screen again.
    UI_MODE=plain
    ui_menu() { printf '%s\n' "$@" >"$TMP/ps.items"; UI_REPLY=public_stats; }
    ask_public_stats() { echo ASKED-PUBLIC-STATS >>"$TMP/ps.asked"; }
    ssh_firewall_guard() { :; }
    apply_all() { :; }
    summary_screen() { :; }
    update_pending() { return 1; }
    : >"$TMP/ps.asked"
    manage_change >/dev/null
    has "the change menu lists it" "$(cat "$TMP/ps.items")" "Public stats page: off"
    has "and asks it again" "$(cat "$TMP/ps.asked")" ASKED-PUBLIC-STATS
}
in_sub t_public_stats_everywhere

echo "the report key stays in memory"
# the_setup_never_carries_the_report_key
t_report_key_memory_only() {
    local calls=$TMP/rk.calls
    : >"$calls"
    ensure_account() { :; }
    ensure_dir() { :; }
    put_file() { cat >/dev/null; PUT_CHANGED=0; }
    restore_state() { echo "$*" >>"$calls"; return 1; }
    CFG_TURN=no CFG_PUSH=no CFG_MEMBERS_ONLY=no CFG_FORWARDER=no CFG_MEMBER_KEYS=0 DRY_RUN=0 REMOVE_KEY=""
    RELAY_ETC=$TMP/rk_etc TURN_ETC=$TMP/rk_turn PUSH_ETC=$TMP/rk_push FWD_ETC=$TMP/rk_fwd
    relay_settings >/dev/null 2>&1
    eq "a reinstall picks up the report counts alone" "$(cat "$calls")" "/var/lib/hollow-relay hollow-relay reports.json"
    has "an uninstall keeps the report counts" "$(declare -f native_uninstall | grep 'for f in /var/lib')" "/var/lib/hollow-relay/reports.json"
    lacks "never a report key" "$(declare -f native_uninstall | grep 'for f in /var/lib')" "reports.json.key"
    has "and erases one an older uninstall kept" "$(declare -f native_uninstall)" 'shred -z -n 0 "$BACKUP_DIR/reports.json.key"'
    lacks "a take over never copies one into the new layout" "$(declare -f adopt_native_stage)" "REPORTS_FILE.key"
    has "nor into the new volume" "$(declare -f adopt_docker_switch)" "reports.json.key ] && continue"
    load_fn "$RELAY/install.sh" summary_backup
    ssh_passwords_on() { return 0; }
    CFG_MODE=native CFG_FORWARDER=yes DRY_RUN=1
    lacks "the backup screen names no key" "$(summary_backup)" "reports.json.key"
    has "only the counts" "$(summary_backup)" "/var/lib/hollow-relay/reports.json, the report counts"
    CFG_MODE=docker COMPOSE_PROJECT=hollow-relay
    lacks "nor under Docker" "$(summary_backup)" "their key"
    reports_facts_out() { OLD_REPORTS_TEXT=""; reports_facts "$1"; printf '%s' "$OLD_REPORTS_TEXT"; }
    mkdir -p "$TMP/rk_state"
    printf '{"counts":{"p":{"spam":2}}}\n' >"$TMP/rk_state/reports.json"
    lacks "the take over screen says nothing of a key" "$(reports_facts_out "$TMP/rk_state/reports.json")" "key"
}
in_sub t_report_key_memory_only

echo "an operator's own lines in relay.env and .env"
# operator_lines_survive_every_rewrite
t_operator_lines() {
    local env
    put_file() { cat >"$1"; PUT_CHANGED=1; }
    ensure_dir() { mkdir -p "$1"; }
    ensure_account() { :; }
    restore_state() { return 1; }
    step() { :; }
    RELAY_ETC=$TMP/op_etc TURN_ETC=$TMP/op_turn PUSH_ETC=$TMP/op_push FWD_ETC=$TMP/op_fwd
    CFG_DUCKDNS_TOKEN="" CFG_DUCKDNS_IP="" CFG_PUBLIC_IP="" CFG_PUBLIC_IPV6="" PF_LOCAL_IP=""
    rm -rf "$RELAY_ETC" && mkdir -p "$RELAY_ETC"
    CFG_TURN=no CFG_PUSH=no CFG_FORWARDER=no CFG_MEMBERS_ONLY=no CFG_MEMBER_KEYS=0 REMOVE_KEY="" DRY_RUN=0 CFG_PUBLIC_STATS=on
    ADOPT_KIND=none SEED_ENV_FILES=""
    printf '# Written by install.sh. Root only: systemd reads it as root.\nTURN_SECRET=\nHOLLOW_PUSH_TOKEN=\nHOLLOW_CONN_RATE_EXEMPT=203.0.113.0/24\n# my own budget\nHOLLOW_SEND_BUDGET_BYTES=900000000\nSOMETHING_ELSE=yes please\nPUBLIC_STATS=off\n' >"$RELAY_ETC/relay.env"
    chmod 0600 "$RELAY_ETC/relay.env"
    relay_settings
    env=$(cat "$RELAY_ETC/relay.env")
    has "the operator's budget stays" "$env" "HOLLOW_SEND_BUDGET_BYTES=900000000"
    has "with its comment" "$env" "# my own budget"
    has "any other setting too" "$env" "SOMETHING_ELSE=yes please"
    has "the exemption keeps its value" "$env" "HOLLOW_CONN_RATE_EXEMPT=203.0.113.0/24"
    eq "a setting the setup owns appears once" "$(grep -c '^PUBLIC_STATS=' <<<"$env")" 1
    has "with the setup's value" "$env" "PUBLIC_STATS=on"
    eq "under one header" "$(grep -c "^$ENV_KEPT_HEADER" <<<"$env")" 1
    eq "and one line saying who wrote the file" "$(grep -c '^# Written by install.sh' <<<"$env")" 1
    relay_settings
    eq "a second rewrite changes nothing" "$(cat "$RELAY_ETC/relay.env")" "$env"
    # A file another account could change, or another setup wrote: only plain HOLLOW_ settings.
    printf 'HOLLOW_SEND_BUDGET_BYTES=900000000\nLD_PRELOAD=/tmp/evil.so\nHOLLOW_X=two words\n# a note\nTURN_SECRET=old\n' >"$RELAY_ETC/relay.env"
    chmod 0620 "$RELAY_ETC/relay.env"
    relay_settings
    env=$(cat "$RELAY_ETC/relay.env")
    has "group-writable: the budget stays" "$env" "HOLLOW_SEND_BUDGET_BYTES=900000000"
    lacks "but nothing else does" "$env" "LD_PRELOAD"
    lacks "no value with spaces" "$env" "HOLLOW_X"
    lacks "no comment" "$env" "# a note"
    printf 'HOLLOW_SEND_BUDGET_BYTES=1\nLD_PRELOAD=/tmp/evil.so\n' >"$RELAY_ETC/relay.env"
    chmod 0600 "$RELAY_ETC/relay.env"
    ADOPT_KIND=native relay_settings
    lacks "a take over keeps only plain HOLLOW_ settings of the old file" "$(cat "$RELAY_ETC/relay.env")" "LD_PRELOAD"
    has "such as the budget" "$(cat "$RELAY_ETC/relay.env")" "HOLLOW_SEND_BUDGET_BYTES=1"
    # The old relay's own file elsewhere, read the same way; this file wins.
    printf 'HOLLOW_SEND_BUDGET_BYTES=2\nHOLLOW_OTHER=a,b\nFOO=bar\n' >"$TMP/op_old.env"
    ADOPT_KIND=native SEED_ENV_FILES="$TMP/op_old.env" relay_settings
    env=$(cat "$RELAY_ETC/relay.env")
    has "a setting only the old file had comes along" "$env" "HOLLOW_OTHER=a,b"
    eq "the one both have, once, from the file in place" "$(grep '^HOLLOW_SEND_BUDGET_BYTES=' <<<"$env")" "HOLLOW_SEND_BUDGET_BYTES=1"
    lacks "and never a non-HOLLOW one" "$env" "FOO=bar"
    # .env under Docker.
    STACK_DIR=$TMP/op_stack CFG_HOST=relay.example.org CFG_GRACE_SECS=120 CFG_STAGING=no FWD_KEY="" ADOPT_KIND=none SEED_ENV_FILES=""
    mem_mb() { echo 1024; }
    mkdir -p "$STACK_DIR"
    printf 'RELAY_HOST=old.example.org\nHOLLOW_SEND_BUDGET_BYTES=700000000\n# mine\nPUBLIC_STATS=off\n' >"$STACK_DIR/.env"
    chmod 0600 "$STACK_DIR/.env"
    CFG_PUBLIC_STATS=on
    docker_env
    env=$(cat "$STACK_DIR/.env")
    has ".env keeps the budget" "$env" "HOLLOW_SEND_BUDGET_BYTES=700000000"
    has "and the comment" "$env" "# mine"
    eq "the address is the setup's, once" "$(grep '^RELAY_HOST=' <<<"$env")" "RELAY_HOST=relay.example.org"
    eq "and so is the stats setting" "$(grep '^PUBLIC_STATS=' <<<"$env")" "PUBLIC_STATS=on"
    docker_env
    eq "a second rewrite of .env changes nothing" "$(cat "$STACK_DIR/.env")" "$env"
    has "compose hands the relay the budget" "$(cat "$RELAY/docker-compose.yml")" 'HOLLOW_SEND_BUDGET_BYTES=${HOLLOW_SEND_BUDGET_BYTES:-}'
    has "a take over hands the old relay's settings files on" "$(declare -f adopt_cfg)" 'SEED_ENV_FILES=$OLD_ENV_FILES'
}
in_sub t_operator_lines

echo "a take over keeps the public stats setting and the operator's own settings"
# adopt_reads_public_stats_and_hands_on_the_old_settings_files
t_adopt_public_stats() {
    local R=$TMP/adopt_ps
    adopt_stubs
    adopt_fixture_native "$R"
    printf 'PUBLIC_STATS=off\nHOLLOW_SEND_BUDGET_BYTES=5\n' >>"$R/etc/hollow-relay/relay.env"
    adopt_detect
    eq "the old relay's PUBLIC_STATS is read" "$OLD_PUBLIC_STATS" off
    has "and shown" "$(adopt_found_text)" "Public stats page: off"
    adopt_cfg
    eq "a take over keeps it" "$CFG_PUBLIC_STATS" off
    has "and hands the old settings file on" " $SEED_ENV_FILES " " $R/etc/hollow-relay/relay.env "
    sed -i '/^PUBLIC_STATS=/d' "$R/etc/hollow-relay/relay.env"
    adopt_detect
    eq "unset, it is on, as the relay has it" "$OLD_PUBLIC_STATS" on
    R=$TMP/adopt_psd
    adopt_fixture_native "$TMP/adopt_psnone"
    rm -f "$TMP/adopt_psnone/units/"*
    adopt_fixture_docker "$R"
    adopt_docker_stubs
    served_cert_to() { cp "$R/vol/relay-uws_certs/fullchain.pem" "$2"; }
    printf 'PUBLIC_STATS=no\n' >>"$R/clone/relay-uws/.env"
    adopt_detect
    eq "Docker: .env's PUBLIC_STATS is read" "$OLD_PUBLIC_STATS" off
    adopt_cfg
    eq "and kept" "$CFG_PUBLIC_STATS" off
    eq "and .env is handed on" "$SEED_ENV_FILES" "$R/clone/relay-uws/.env"
}
in_sub t_adopt_public_stats
