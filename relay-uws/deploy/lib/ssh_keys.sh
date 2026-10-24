#!/bin/bash
# Passwordless SSH, guided. Password logins go off only after sshd has logged
# a key login for the person's own account during this run, and stay off only
# if a second key login works after the change. Sourced.

SSH_UNDO_UNIT=hollow-ssh-undo
# How long the change stands before the timer undoes it, unless kept.
SSH_UNDO_SECS=600

ssh_account() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then printf '%s' "$SUDO_USER"; else printf 'root'; fi
}

ssh_home() { getent passwd "$1" | cut -d: -f6; }

ssh_has_key() {
    local h
    h=$(ssh_home "$1")
    [ -n "$h" ] && [ -s "$h/.ssh/authorized_keys" ] && grep -qE '^(ssh-|ecdsa-|sk-)' "$h/.ssh/authorized_keys"
}

# on, off or unknown: whether sshd takes a password outside any Match block.
ssh_password_state() {
    local t
    t=$(sshd -T 2>/dev/null) || { echo unknown; return 0; }
    if printf '%s\n' "$t" | grep -xE 'passwordauthentication yes|kbdinteractiveauthentication yes' >/dev/null; then
        echo on
    else
        echo off
    fi
}

# Password logins count as on if sshd would take a password either way.
ssh_passwords_on() { [ "$(ssh_password_state)" != off ]; }

# Unlike ssh_passwords_on, false when sshd cannot say.
ssh_passwords_surely_on() { [ "$(ssh_password_state)" = on ]; }

# The Match blocks that let some logins use a password again, which sshd -T
# never shows: one per line, "<file> line <n> (Match <criteria>)", in the
# order sshd reads its files. Read only; the person's blocks stay as they are.
SSHD_CONFIG=/etc/ssh/sshd_config
SSHD_DIR=/etc/ssh
ssh_match_passwords() {
    _SSH_MATCH="" _SSH_SEEN=" " _SSH_BLOCK=""
    _ssh_cfg_scan "$SSHD_CONFIG" 0
    printf '%s' "$_SSH_MATCH"
}

# _ssh_cfg_scan <file> <depth>: a block opened in a file stays open in the
# files it includes and after them, so nothing a block covers is missed.
_SSH_BLOCK=""
_ssh_cfg_scan() {
    local f=$1 depth=$2 n=0 line kw val pat g
    [ "$depth" -le 16 ] && [ -f "$f" ] && [ -r "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        [[ "$line" =~ ^[[:space:]]*([A-Za-z]+)([[:space:]]*=[[:space:]]*|[[:space:]]+)(.*)$ ]] || continue
        kw=${BASH_REMATCH[1],,}
        val=${BASH_REMATCH[3]%%#*}
        val=${val//\"/}
        val=${val%"${val##*[![:space:]]}"}
        case "$kw" in
        match)
            _SSH_BLOCK="$f line $n (Match $val)" ;;
        include)
            for pat in $val; do
                [[ "$pat" == /* ]] || pat=$SSHD_DIR/$pat
                for g in $pat; do _ssh_cfg_scan "$g" $((depth + 1)); done
            done ;;
        passwordauthentication | kbdinteractiveauthentication | challengeresponseauthentication)
            [ -n "$_SSH_BLOCK" ] && [ "${val,,}" = yes ] || continue
            case "$_SSH_SEEN" in *" $_SSH_BLOCK "*) continue ;; esac
            _SSH_SEEN="$_SSH_SEEN$_SSH_BLOCK "
            _SSH_MATCH="$_SSH_MATCH$_SSH_BLOCK"$'\n' ;;
        esac
    done <"$f"
}

# What the screens add while such a block exists: the audit names the blocks,
# the result also says how to end it.
ssh_match_list() { ssh_match_passwords | sed '/^$/d' | paste -sd ';' - | sed 's/;/; /g'; }
ssh_match_short() {
    local m
    m=$(ssh_match_list)
    [ -n "$m" ] || return 0
    printf 'Passwords still work where a Match block allows them: %s. I leave that as it is.' "$m"
}
ssh_match_note() {
    local m
    m=$(ssh_match_short)
    [ -n "$m" ] || return 0
    printf ' %s To end that, delete the PasswordAuthentication or KbdInteractiveAuthentication line in each, then run sudo systemctl reload ssh.' "$m"
}

ssh_keys_only_text() {
    if [ -n "$(ssh_match_passwords)" ]; then
        printf 'Password logins are off now. Your key login worked after the change, with the %s. That computer holds the key to this server.%s' "$1" "$(ssh_match_note)"
    else
        printf 'SSH takes keys only now. Your key login worked after the change, with the %s. That computer holds the key to this server.' "$1"
    fi
}

# ssh_logins <account> <unix time>: the account's SSH logins since then, oldest
# first, one per line: <unix time> <key|password> <address> <key fingerprint|->.
# Only lines root's sshd itself wrote count: journald sets _UID and _COMM, while
# any local account can give its own lines the name sshd. A whole line must be
# the Accepted message, never a name a stranger typed into another one.
# awk reads to the end, so journalctl never dies of SIGPIPE under pipefail.
ssh_logins() {
    journalctl --since "@$2" -o short-unix _UID=0 _COMM=sshd _COMM=sshd-session 2>/dev/null |
        awk -v u="$1" -v since="$2" '
        $4 == "Accepted" && $6 == "for" && $7 == u && $8 == "from" && $10 == "port" && $11 ~ /^[0-9]+$/ {
            t = int($1)
            if (t < since) next
            if ($5 == "publickey" && $12 == "ssh2:" && $14 ~ /^SHA256:/ && (NF == 14 || $13 ~ /-CERT$/)) print t, "key", $9, $14
            else if (($5 == "password" || $5 ~ /^keyboard-interactive/) && $12 == "ssh2" && NF == 12) print t, "password", $9, "-"
        }'
}

# ssh_clock <unix time>: the time of day, for the screens.
ssh_clock() { date -d "@$1" +%H:%M:%S 2>/dev/null || printf '%s' "$1"; }

ssh_host_for_person() {
    if [ -n "${CFG_HOST:-}" ]; then printf '%s' "$CFG_HOST"; else printf '%s' "${PF_PUBLIC_IP:-this-machine}"; fi
}

# Both key screens: look before making a key, since a new one in the same
# place replaces the old and locks its owner out wherever it was used.
SSH_KEYGEN_NOTE="If the first command lists the file, you have a key already, so skip ssh-keygen. If not, press Enter when ssh-keygen asks where to save it, and choose a passphrase. If it says the key already exists, answer n. Answering y would replace your key."

ssh_key_steps_text() {
    local user=$1 host
    host=$(ssh_host_for_person)
    cat <<EOF
Do this on your own computer, the one you log in from. Not on this machine.

Windows (PowerShell):
  dir \$env:USERPROFILE\\.ssh\\id_ed25519.pub
  ssh-keygen -t ed25519
  type \$env:USERPROFILE\\.ssh\\id_ed25519.pub | ssh $user@$host "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

macOS or Linux (Terminal):
  ls ~/.ssh/id_ed25519.pub
  ssh-keygen -t ed25519
  ssh-copy-id $user@$host

$SSH_KEYGEN_NOTE The last command asks for your password here once more.
EOF
}

# What to do so that losing one computer's key never locks the person out.
ssh_backup_note() {
    printf '%s' "If the SSH key file on your computer is lost, so is your way in over SSH. It is usually ~/.ssh/id_ed25519. Keep a copy somewhere safe, such as a password manager, or add a second computer's key with sudo hollow-relay-setup. If every key is gone, your provider's web console, or a screen and keyboard on the machine itself, still gets you in."
}

# ssh_session_conn: the client address and port of the SSH session this runs
# in. sudo drops SSH_CONNECTION, so the parent processes are asked too.
ssh_session_conn() {
    local pid=$$ n=0 conn=${SSH_CONNECTION:-}
    while [ -z "$conn" ] && [ "$n" -lt 40 ]; do
        pid=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)
        case "$pid" in '' | 0 | 1 | *[!0-9]*) return 0 ;; esac
        conn=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n 1)
        n=$((n + 1))
    done
    local addr port rest
    read -r addr port rest <<<"$conn"
    [[ "$port" =~ ^[0-9]+$ ]] && [ -n "$addr" ] && printf '%s %s\n' "$addr" "$port"
    return 0
}

# ssh_proc_started <pid>: when the process started, in Unix time.
ssh_proc_started() {
    local stat ticks btime hz
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    # The fields after the command name, which may hold spaces; starttime is the 20th.
    ticks=$(printf '%s' "${stat##*) }" | awk '{print $20}')
    btime=$(awk '$1 == "btime" {print $2}' /proc/stat)
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    [[ "$ticks" =~ ^[0-9]+$ ]] && [[ "$btime" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' $((btime + ticks / hz))
}

# The sshd processes above this one, one per line: <pid> <start time>.
ssh_session_pids() {
    local pid=$$ n=0 comm start
    while [ "$n" -lt 40 ]; do
        pid=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)
        case "$pid" in '' | 0 | 1 | *[!0-9]*) return 0 ;; esac
        comm=$(cat "/proc/$pid/comm" 2>/dev/null)
        case "$comm" in
        sshd | sshd-session) start=$(ssh_proc_started "$pid") && printf '%s %s\n' "$pid" "$start" ;;
        esac
        n=$((n + 1))
    done
}

# ssh_session_key <account>: the key this setup's own SSH session logged in
# with, as "<unix time> <address> <fingerprint>" in SSH_SESSION_KEY. Only a
# login sshd logged from one of this process's own sshd parents, for this
# account, from this session's address and port, counts; anything less than
# exactly one such login leaves it empty.
SSH_SESSION_KEY=""
SSH_SESSION_CHECKED=0
ssh_session_key() {
    local user=$1 caddr cport pid start lines
    SSH_SESSION_KEY=""
    SSH_SESSION_CHECKED=1
    read -r caddr cport <<<"$(ssh_session_conn)"
    [ -n "$cport" ] || return 0
    lines=$(ssh_session_pids | while read -r pid start; do
        journalctl --since "@$((start - 2))" -o short-unix "_PID=$pid" 2>/dev/null |
            awk -v since="$((start - 2))" '
            int($1) >= since {
                for (i = 4; i <= NF; i++) if ($i == "Accepted") break
                if (i > NF || $(i + 2) != "for" || $(i + 4) != "from" || $(i + 6) != "port") next
                fp = "-"
                for (j = i; j <= NF; j++) if ($j ~ /^SHA256:/) fp = $j
                print int($1), $(i + 1), $(i + 3), $(i + 5), $(i + 7), fp
            }'
    done | awk -v u="$user" -v a="$caddr" -v p="$cport" '$3 == u && $4 == a && $5 == p') || true
    [ -n "$lines" ] && [ "$(printf '%s\n' "$lines" | wc -l)" = 1 ] || return 0
    local t kind acct addr port fp
    read -r t kind acct addr port fp <<<"$lines"
    [ "$kind" = publickey ] && [ "$fp" != - ] || return 0
    SSH_SESSION_KEY="$t $addr $fp"
}

# Offers the key this session came in with as the first key login. Sets
# SSH_KEY_SEEN and returns 0 when the person says it is theirs.
ssh_offer_session_key() {
    local user=$1 t addr fp
    [ -n "$SSH_SESSION_KEY" ] || return 1
    read -r t addr fp <<<"$SSH_SESSION_KEY"
    ui_yesno ssh_own "Is that your key?" \
"You logged in to this setup with the key $fp from $addr at $(ssh_clock "$t").

Is that your key, on the computer you will use to manage this server? If it is, you skip making a key and the second window. You still log in once more after passwords go off, and if that login fails, they come back on.

Say no if you do not know this key, and I show you how to make one." no || return 1
    SSH_KEY_SEEN="key $fp from $addr"
    return 0
}

# The screen for the options round. Sets SSH_PLAN to none, guide or keep.
ssh_question() {
    local user
    user=$(ssh_account)
    SSH_PLAN=none
    if ! ssh_passwords_on; then
        return 0
    fi
    # Read now: the hardening keeps the journal for one hour only.
    ssh_session_key "$user"
    local have="You have no SSH key on this machine yet, so the next screens show you how to make one on your own computer and copy it here."
    ssh_has_key "$user" && have="The account $user already has an SSH key here. You only need to log in with it once more while the setup waits."
    [ -n "$SSH_SESSION_KEY" ] && have="You logged in to this setup with an SSH key. At the end I ask whether it is yours."
    local root_note=""
    [ "$user" != root ] && root_note=" Root logins over SSH go off at the same time, since you log in as $user and use sudo."
    if ui_yesno ssh_keys "Log in with a key instead of a password" \
"Right now this machine accepts SSH logins with a password. Bots try passwords on every server on the internet all day. A key is much safer. It is a file on your computer that proves it is you, and there is nothing to guess.

$have

I turn password logins off only after I have seen you log in with the key during this setup, and I check that a second key login still works afterwards. If either check fails, passwords stay on and nothing is locked.$root_note

We recommend yes. Choose no to keep password logins for now. You can run the setup again later to do this." yes; then
        SSH_PLAN=guide
    else
        SSH_PLAN=keep
    fi
}

# ssh_wait_login <account> <since> <what> [<deadline>]: waits for a key login
# that began after <since> and that the person says is theirs: anyone else
# with a key to this account, a backup job for one, counts for nothing. Sets
# SSH_KEY_SEEN to the key and address. Returns 2 when <deadline> (Unix time)
# passed. An answer file names the key instead (ssh_key_fingerprint), and
# SSH_WANT_FP, when set, is the only key that may count.
SSH_KEY_SEEN=""
SSH_WANT_FP=""
SSH_OPEN_OWN="Open a second window on your own computer"
SSH_OPEN=$SSH_OPEN_OWN
ssh_wait_login() {
    local user=$1 since=$2 what=$3 deadline=${4:-} wait t0 left want line why=""
    local refused=" " t kind addr fp
    SSH_KEY_SEEN=""
    if [ "$UI_MODE" = answers ]; then
        want=${SSH_WANT_FP:-$(ans_get ssh_key_fingerprint)}
        [ -n "$want" ] || return 1
        wait=$(ans_get ssh_wait_secs 300)
        if [ -n "$deadline" ]; then
            left=$((deadline - $(date +%s)))
            [ "$left" -lt "$wait" ] && wait=$left
        fi
        say "  waiting up to $wait seconds for a login as $user with the key $want ($what)"
        t0=$(date +%s)
        while [ $(( $(date +%s) - t0 )) -lt "$wait" ]; do
            line=$(ssh_logins "$user" "$since" | awk -v fp="$want" '$2 == "key" && $4 == fp' | tail -n 1)
            if [ -n "$line" ]; then
                read -r t kind addr fp <<<"$line"
                SSH_KEY_SEEN="key $fp from $addr"
                return 0
            fi
            sleep 3
        done
        [ -n "$deadline" ] && [ "$(date +%s)" -ge "$deadline" ] && return 2
        return 1
    fi
    while :; do
        ui_msg_copy "Log in with your key" \
"${why}$SSH_OPEN and log in:

  ssh $user@$(ssh_host_for_person)

It should not ask for your password. It may ask for the key's passphrase, which is fine. Leave this window open, and press Enter here once you are logged in there."
        why=""
        # The newest key login since <since> that the person has not said no to.
        line=$(ssh_logins "$user" "$since" | awk -v no="$refused" -v want="$SSH_WANT_FP" \
            '$2 == "key" && index(no, " " $4 "@" $3 " ") == 0 && (want == "" || $4 == want)' | tail -n 1)
        if [ -n "$line" ]; then
            read -r t kind addr fp <<<"$line"
            if ui_yesno ssh_confirm "Was that you?" \
"A key login arrived for $user, with the key $fp, from $addr at $(ssh_clock "$t").

Was that you, from the computer you will use to manage this server? Say no if you do not know this key or address, and I keep waiting for yours. Passwords stay on until then." no; then
                SSH_KEY_SEEN="key $fp from $addr"
                return 0
            fi
            refused="$refused$fp@$addr "
            why="I did not count the login with the key $fp from $addr.

"
            continue
        fi
        [ -n "$deadline" ] && [ "$(date +%s)" -ge "$deadline" ] && return 2
        line=$(ssh_logins "$user" "$since" | awk '$2 == "password"' | tail -n 1)
        if [ -n "$line" ]; then
            read -r t kind addr fp <<<"$line"
            why="I saw a login as $user from $addr at $(ssh_clock "$t"), and it used the password, not a key. The key is not on that computer yet, or ssh did not offer it. Show the steps again and follow the ones for that computer's system."
        else
            why="I have not seen a key login for $user yet. If the second window asked for your password, the key is not in place. Check the steps again."
        fi
        ui_menu ssh_retry "No key login yet" "$why" \
            retry retry "I logged in, check again" \
            steps "Show the steps again" \
            stop "Leave password logins on for now"
        why=""
        case "$UI_REPLY" in
        steps) ui_msg_copy "Make a key on your computer" "$(ssh_key_steps_text "$user")" ;;
        stop) return 1 ;;
        esac
    done
}

ssh_undo_now() {
    rm -f "$HOLLOW_SSHD_DROPIN"
    hollow_reload_sshd
    systemctl stop "$SSH_UNDO_UNIT.timer" >/dev/null 2>&1 || true
}

# Runs after the services are up. Sets SSH_RESULT for the summary.
ssh_run() {
    local user since since2
    user=$(ssh_account)
    SSH_RESULT=""
    case "${SSH_PLAN:-none}" in
    none)
        ssh_passwords_on && return 0
        if [ -n "$(ssh_match_passwords)" ]; then
            SSH_RESULT="SSH takes keys only, except where a Match block allows passwords.$(ssh_match_note)"
        else
            SSH_RESULT="SSH already takes keys only."
        fi
        return 0 ;;
    keep) SSH_RESULT="SSH still takes passwords, as you chose."; return 0 ;;
    esac
    step "SSH keys"
    if [ "$DRY_RUN" = 1 ]; then
        say "  would wait for a key login as $user, then write $HOLLOW_SSHD_DROPIN with a $((SSH_UNDO_SECS / 60)) minute undo timer, and keep it after a second key login"
        return 0
    fi
    if [ "$UI_MODE" = answers ] && [ -z "$(ans_get ssh_key_fingerprint)" ]; then
        SSH_RESULT="SSH still takes passwords. An answer file has to name the key that may log in (ssh_key_fingerprint=SHA256:...), so a login by any other key cannot count."
        say "  $SSH_RESULT"
        return 0
    fi
    # The one login from before the prompt that may count: the one running
    # this setup, which the person at this keyboard made.
    [ "$SSH_SESSION_CHECKED" = 1 ] || ssh_session_key "$user"
    if [ "$UI_MODE" != answers ] && ssh_offer_session_key "$user"; then
        say "  counting this session's key login for $user, $SSH_KEY_SEEN"
    else
        if ! ssh_has_key "$user"; then
            ui_msg_copy "Make a key on your computer" "$(ssh_key_steps_text "$user")"
        fi
        # Only a login that begins once the person is asked for it counts.
        since=$(date +%s)
        if ! ssh_wait_login "$user" "$since" "before the change"; then
            SSH_RESULT="SSH still takes passwords, because I never saw a key login for $user that you confirmed."
            say "  $SSH_RESULT"
            return 0
        fi
        say "  saw a key login for $user, $SSH_KEY_SEEN"
    fi

    # Passwords count as off only while the drop-in is in place after the
    # timer stopped, so a timer that fired during a slow second login is caught.
    local round rc deadline
    for round in 1 2 3; do
        ssh_change_once "$user" || return 0
        since2=$(date +%s)
        deadline=$((since2 + SSH_UNDO_SECS - SSH_UNDO_SECS / 10))
        if [ "$UI_MODE" != answers ]; then
            if [ "$round" = 1 ]; then
                ui_msg "One more login" "Password logins are now off. To be sure you can still get in, log in once more from a second window with the same command. Keep this window open until then. If that login does not work, I put passwords back on, and a timer does the same on its own in $((SSH_UNDO_SECS / 60)) minutes."
            else
                ui_msg "One more login" "The safety timer put passwords back on before I saw your login, so I turned them off again. Log in once more from a second window, within $((SSH_UNDO_SECS / 60)) minutes this time."
            fi
        fi
        rc=0
        ssh_wait_login "$user" "$since2" "after the change" "$deadline" || rc=$?
        if [ "$rc" != 0 ]; then
            ssh_undo_now
            if [ "$rc" = 2 ]; then
                SSH_RESULT="SSH still takes passwords. I saw no key login within $((SSH_UNDO_SECS / 60)) minutes of the change, so I put passwords back on."
            else
                SSH_RESULT="SSH still takes passwords. I saw no key login after the change, so I put passwords back on."
            fi
            say "  $SSH_RESULT"
            return 0
        fi
        # The service too: one the timer started may be removing the drop-in.
        systemctl stop "$SSH_UNDO_UNIT.timer" "$SSH_UNDO_UNIT.service" >/dev/null 2>&1 || true
        if [ -e "$HOLLOW_SSHD_DROPIN" ] && ! ssh_passwords_on; then
            SSH_RESULT=$(ssh_keys_only_text "$SSH_KEY_SEEN")
            [ "$user" != root ] && SSH_RESULT="$SSH_RESULT Root cannot log in over SSH either."
            say "  $SSH_RESULT"
            return 0
        fi
        say "  the safety timer put passwords back on before the second login, so I try again"
    done
    ssh_undo_now
    SSH_RESULT="SSH still takes passwords. The safety timer put them back each time before I saw your second login."
    say "  $SSH_RESULT"
}

# One try at the change, with the timer that undoes it. Returns 1 with
# SSH_RESULT set when the change could not be made; passwords are then on.
ssh_change_once() {
    local user=$1 who
    systemctl stop "$SSH_UNDO_UNIT.timer" >/dev/null 2>&1 || true
    systemctl reset-failed "$SSH_UNDO_UNIT.service" >/dev/null 2>&1 || true
    if ! systemd-run --quiet --unit="$SSH_UNDO_UNIT" --on-active="${SSH_UNDO_SECS}s" \
        /bin/sh -c "rm -f $HOLLOW_SSHD_DROPIN; systemctl reload ssh || systemctl reload sshd"; then
        ssh_undo_now
        SSH_RESULT="SSH still takes passwords. I could not set up the safety timer, so I changed nothing."
        return 1
    fi
    hollow_sshd_dropin "$user" | put_file "$HOLLOW_SSHD_DROPIN" 0644 root root
    if ! sshd -t >/dev/null 2>&1; then
        ssh_undo_now
        SSH_RESULT="SSH still takes passwords, because sshd did not accept the new setting. I removed it again."
        return 1
    fi
    hollow_reload_sshd
    sleep 1
    if ssh_passwords_on; then
        who=$(grep -liE '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication)[[:space:]]+yes' \
            /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tr '\n' ' ' || true)
        ssh_undo_now
        SSH_RESULT="SSH still takes passwords, because another setting wins over mine (${who:-in a file I could not find}). I removed mine."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- another computer's key

# ssh_pubkey_clean <text>: the pasted text without the spaces, tabs and line
# ends around it.
ssh_pubkey_clean() {
    local l=${1//$'\r'/}
    l=${l%"${l##*[![:space:]]}"}
    printf '%s' "${l#"${l%%[![:space:]]*}"}"
}

# ssh_pubkey_ok <line>: one public key line as a .pub file holds it: a key
# type, the key, an optional comment, nothing before the type (where
# authorized_keys takes options such as command=), and a key ssh-keygen reads.
ssh_pubkey_ok() {
    local l=$1 type rest f n
    [ -n "$l" ] && [ "${#l}" -le 16384 ] || return 1
    [[ "$l" =~ ^[[:print:]]+$ ]] || return 1
    read -r type rest <<<"$l"
    case "$type" in
    ssh-ed25519 | ssh-rsa | ecdsa-sha2-nistp256 | ecdsa-sha2-nistp384 | ecdsa-sha2-nistp521 | \
        sk-ssh-ed25519@openssh.com | sk-ecdsa-sha2-nistp256@openssh.com) ;;
    *) return 1 ;;
    esac
    f=$(mktemp "${WORK_DIR:-/tmp}/pubkey.XXXXXX") || return 1
    printf '%s\n' "$l" >"$f"
    n=$(ssh-keygen -l -f "$f" 2>/dev/null | grep -c '^[0-9]') || n=0
    rm -f "$f"
    [ "$n" = 1 ]
}

ssh_pubkey_or_empty() { [ -z "$1" ] || ssh_pubkey_ok "$(ssh_pubkey_clean "$1")"; }

# ssh_pubkey_fp <line>: its SHA256 fingerprint, as sshd logs it.
ssh_pubkey_fp() {
    local f fp
    f=$(mktemp "${WORK_DIR:-/tmp}/pubkey.XXXXXX") || return 1
    printf '%s\n' "$1" >"$f"
    fp=$(ssh-keygen -l -E sha256 -f "$f" 2>/dev/null | awk '{print $2}')
    rm -f "$f"
    printf '%s' "$fp"
}

# ssh_as <account> <command...>: runs it as that account, so a link in its
# own home can never make root write somewhere else.
ssh_as() {
    local user=$1
    shift
    runuser -u "$user" -- "$@"
}

# ssh_keys_file_ok <home>: refuses a .ssh or authorized_keys that is a link
# or not what it should be, with the reason in SSH_KEYS_WHY.
ssh_keys_file_ok() {
    local d=$1/.ssh
    SSH_KEYS_WHY=""
    if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then
        SSH_KEYS_WHY="$d is a link or not a folder"
    elif [ -L "$d/authorized_keys" ] || { [ -e "$d/authorized_keys" ] && [ ! -f "$d/authorized_keys" ]; }; then
        SSH_KEYS_WHY="$d/authorized_keys is a link or not a plain file"
    fi
    [ -z "$SSH_KEYS_WHY" ]
}

# ssh_key_listed <home> <fingerprint>: the key is already in authorized_keys.
ssh_key_listed() {
    local f=$1/.ssh/authorized_keys
    [ -f "$f" ] && [ ! -L "$f" ] || return 1
    ssh-keygen -l -E sha256 -f "$f" 2>/dev/null | awk -v fp="$2" '$2 == fp {found = 1} END {exit !found}'
}

# ssh_append_key <account> <line>: adds the line to the account's
# authorized_keys, written as the account itself, folder 0700 and file 0600.
ssh_append_key() {
    local user=$1 line=$2 home
    home=$(ssh_home "$user")
    [ -n "$home" ] && [ -d "$home" ] || { SSH_KEYS_WHY="$user has no home folder"; return 1; }
    ssh_keys_file_ok "$home" || return 1
    # shellcheck disable=SC2016 # expanded by the account's shell
    ssh_as "$user" /bin/sh -c '
        set -e
        umask 077
        d=$1/.ssh f=$1/.ssh/authorized_keys
        [ ! -L "$d" ] || exit 3
        [ -d "$d" ] || mkdir "$d"
        [ ! -L "$f" ] || exit 3
        tmp=$(mktemp "$d/.authorized_keys.XXXXXX")
        if [ -f "$f" ]; then
            cat "$f" >"$tmp"
            [ ! -s "$f" ] || [ "$(tail -c 1 "$f" | wc -l)" = 1 ] || printf "\n" >>"$tmp"
        fi
        printf "%s\n" "$2" >>"$tmp"
        chmod 600 "$tmp"
        mv -f "$tmp" "$f"
        chmod 700 "$d"' sh "$home" "$line" >/dev/null 2>&1 ||
        { SSH_KEYS_WHY="writing it as $user failed"; return 1; }
}

# ssh_unconfirmed_text <account> <home> <line>: a key added without a confirmed
# login stays, so the result says which one it is and how to take it out.
ssh_unconfirmed_text() {
    local user=$1 f=$2/.ssh/authorized_keys line=$3 type key label fp n name end=""
    read -r type key label <<<"$line"
    fp=$(ssh_pubkey_fp "$line")
    [ "${#label}" -le 40 ] || label="${label:0:40}..."
    n=$(grep -nxF -- "$line" "$f" 2>/dev/null | tail -n 1 | cut -d: -f1)
    if [ -n "$label" ]; then name="the key $label ($fp)"; end=", the one that ends in $label"
    else name="the key with no label ($fp)"; fi
    printf 'I added %s for %s, but you did not confirm a login with it. It stays there, so that computer can log in.\n\nIf you did not mean to add it, delete line %s of %s%s.\n\nTo try again, run this on that computer:\n  ssh %s@%s' \
        "$name" "$user" "${n:-?}" "$f" "$end" "$user" "$(ssh_host_for_person)"
}

ssh_print_key_text() {
    cat <<EOF
Password logins are off, so the new computer cannot copy its key here by itself. Make a key on it, then paste the key into the next screen.

Windows (PowerShell):
  dir \$env:USERPROFILE\\.ssh\\id_ed25519.pub
  ssh-keygen -t ed25519
  type \$env:USERPROFILE\\.ssh\\id_ed25519.pub

macOS or Linux (Terminal):
  ls ~/.ssh/id_ed25519.pub
  ssh-keygen -t ed25519
  cat ~/.ssh/id_ed25519.pub

$SSH_KEYGEN_NOTE The last command prints one line that starts with ssh-ed25519. Copy that whole line.
EOF
}

# Re-run: lets one more computer log in, through the same confirmed key login
# as the switch. It never turns passwords back on and never removes a key.
# Sets SSH_RESULT.
ssh_add_key_run() {
    local user home line since added=0
    user=$(ssh_account)
    home=$(ssh_home "$user")
    SSH_RESULT="" SSH_WANT_FP="" SSH_OPEN="Open a terminal on the new computer"
    # A paste works either way, so only passwords sshd says are on send the
    # person to ssh-copy-id.
    if ssh_passwords_surely_on; then
        ui_msg_copy "Add another computer's key" "$(ssh_key_steps_text "$user" | sed '1s/.*/Do this on the new computer that should log in too. Not on this machine./')"
    else
        ui_msg_copy "Add another computer's key" "$(ssh_print_key_text)"
        ask_valid ssh_public_key "Paste the new computer's key" \
"Paste the line that starts with ssh-ed25519. It is the public key, which is safe to share. Never paste the private key, the file without .pub.

Leave it empty to stop." "" ssh_pubkey_or_empty "That is not one public key line. Paste the whole line from the .pub file."
        line=$(ssh_pubkey_clean "$UI_REPLY")
        if [ -z "$line" ]; then
            SSH_RESULT="Nothing changed."
            SSH_OPEN=$SSH_OPEN_OWN
            return 0
        fi
        SSH_WANT_FP=$(ssh_pubkey_fp "$line")
        if ! ssh_keys_file_ok "$home"; then
            SSH_RESULT="I added nothing, because $SSH_KEYS_WHY. Check it with: ls -la $home/.ssh"
        elif ssh_key_listed "$home" "$SSH_WANT_FP"; then
            say "  the key $SSH_WANT_FP is already allowed for $user"
        elif [ "$DRY_RUN" = 1 ]; then
            say "  would add the key $SSH_WANT_FP to $home/.ssh/authorized_keys"
            SSH_RESULT="Nothing changed in a dry run."
        elif ssh_append_key "$user" "$line"; then
            added=1
            say "  added the key $SSH_WANT_FP for $user"
        else
            SSH_RESULT="I added nothing, because $SSH_KEYS_WHY."
        fi
        if [ -n "$SSH_RESULT" ]; then
            SSH_WANT_FP="" SSH_OPEN=$SSH_OPEN_OWN
            return 0
        fi
    fi
    since=$(date +%s)
    if ssh_wait_login "$user" "$since" "with the new key"; then
        SSH_RESULT="The new computer logged in with the $SSH_KEY_SEEN. It can log in to this server from now on."
    elif [ "$added" = 1 ]; then
        SSH_RESULT=$(ssh_unconfirmed_text "$user" "$home" "$line")
    else
        SSH_RESULT="You did not confirm a key login from the new computer, so nothing changed."
    fi
    SSH_WANT_FP="" SSH_OPEN=$SSH_OPEN_OWN
}
