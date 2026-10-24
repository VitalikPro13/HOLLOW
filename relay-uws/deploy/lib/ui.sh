#!/bin/bash
# The installer's screens: whiptail when there is one and a terminal, plain
# prompts when there is not, and an answer file for runs nobody watches.
# Sourced, never executed.
#
# Each question has a key. In answer-file mode the key's value is the answer,
# and a key the file leaves out takes the recommended choice.

UI_MODE=${UI_MODE:-}        # whiptail | plain | answers
UI_REPLY=""
UI_BACKTITLE="Hollow relay setup"
# Where plain prompts read the person's answers.
UI_TTY=/dev/tty
declare -A ANS=()
declare -A ANS_USED=()

# A terminal this machine has no description for (Ghostty, kitty, WezTerm over
# SSH) takes the nearest one it has, so whiptail still draws its screens.
# Sets UI_TERM_OK=0 when none fits.
UI_TERM_OK=1
ui_fix_term() {
    local t
    UI_TERM_OK=1
    have infocmp || return 0
    infocmp "${TERM:-dumb}" >/dev/null 2>&1 && return 0
    for t in xterm-256color xterm; do
        if infocmp "$t" >/dev/null 2>&1; then
            export TERM=$t
            return 0
        fi
    done
    UI_TERM_OK=0
}

ui_init() {
    if [ -n "${ANSWERS_FILE:-}" ]; then
        UI_MODE=answers
    elif [ -z "$UI_MODE" ]; then
        ui_fix_term
        if [ -t 0 ] && [ -t 1 ] && have whiptail && [ "${TERM:-dumb}" != dumb ] && [ "$UI_TERM_OK" = 1 ]; then
            UI_MODE=whiptail
        elif [ -r /dev/tty ] && { [ -t 0 ] || [ -t 1 ]; }; then
            UI_MODE=plain
        else
            die "there is no terminal to ask questions on. Run it from an SSH session, or pass --answers <file>."
        fi
    fi
}

# Every key an answer file may set. A typo would otherwise silently take the
# recommended choice.
ANSWER_KEYS="action mode binaries address duckdns_name duckdns_token duckdns_token_file
domain ip public_ip public_ipv6 email staging turn push forwarder members_only
member_keys grace_secs public_stats ssh_keys ssh_key_fingerprint ssh_wait_secs confirm keep_data change remove_key
continue_anyway ssh_public_key adopt harden interrupted replace_setup"

ui_load_answers() {
    local file=$1 line key value n=0
    [ -r "$file" ] || die "cannot read the answer file $file."
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%%#*}
        line=${line%"${line##*[![:space:]]}"}
        line=${line#"${line%%[![:space:]]*}"}
        [ -z "$line" ] && continue
        [[ "$line" == *=* ]] || die "line $n of the answer file is not key=value."
        key=${line%%=*}
        value=${line#*=}
        key=${key%"${key##*[![:space:]]}"}
        value=${value#"${value%%[![:space:]]*}"}
        case "$value" in
        \"*\") value=${value#\"}; value=${value%\"} ;;
        \'*\') value=${value#\'}; value=${value%\'} ;;
        esac
        case " ${ANSWER_KEYS//$'\n'/ } " in
        *" $key "*) ;;
        *) die "line $n of the answer file sets $key, which the installer does not know." ;;
        esac
        ANS[$key]=$value
    done <"$file"
}

ans_has() { [ -n "${ANS[$1]+x}" ]; }

# The answer for <key>, or <default> when the file leaves it out.
ans_get() {
    local key=$1 default=${2:-}
    if ans_has "$key"; then
        ANS_USED[$key]=1
        printf '%s' "${ANS[$key]}"
    else
        printf '%s' "$default"
    fi
}

# Every whiptail box is one steady frame, like the Debian installer's: the
# terminal less a margin, capped so lines stay readable. ui_size <text>
# <lines the box needs besides the text: 6, or a menu's items + 7, measured
# on whiptail 0.52> sets UI_W, UI_H and UI_FITS (0 when the text needs more
# lines than the frame has).
UI_MAX_W=100
UI_MAX_H=30
ui_size() {
    local text=$1 extra=${2:-8} cols rows w h lines
    cols=$(tput cols 2>/dev/null || echo 80)
    rows=$(tput lines 2>/dev/null || echo 24)
    w=$((cols - 4)); [ "$w" -gt "$UI_MAX_W" ] && w=$UI_MAX_W; [ "$w" -lt 40 ] && w=40
    h=$((rows - 2)); [ "$h" -gt "$UI_MAX_H" ] && h=$UI_MAX_H; [ "$h" -lt 12 ] && h=12
    lines=$(printf '%s\n' "$text" | fold -s -w $((w - 6)) | wc -l)
    UI_FITS=1
    [ $((lines + extra)) -gt "$h" ] && UI_FITS=0
    UI_W=$w
    UI_H=$h
}

# A text taller than the frame scrolls inside it. whiptail then gives the
# text the focus, where Enter does nothing until Tab reaches the buttons, so
# such a screen says so first. ui_scroll <text> <what Tab reaches> sets
# UI_TEXT and UI_SCROLL (the flag, or nothing) after ui_size.
UI_SCROLL=()
ui_scroll() {
    UI_TEXT=$1 UI_SCROLL=()
    [ "$UI_FITS" = 1 ] && return 0
    UI_TEXT="Scroll with the arrow keys, then press Tab to reach the $2.

$1"
    UI_SCROLL=(--scrolltext)
}

# ui_read <variable> <prompt>: one line typed at a plain prompt. A closed
# terminal ends the run; a question that keeps asking would loop forever.
ui_read() {
    local line=""
    if read -r -p "$2" line <"$UI_TTY" || [ -n "$line" ]; then
        printf -v "$1" '%s' "$line"
        return 0
    fi
    die "the terminal closed before an answer came, so I stopped."
}

# ui_plain_once <function> <args...>: one screen in plain mode.
ui_plain_once() {
    local saved=$UI_MODE rc=0
    UI_MODE=plain
    "$@" || rc=$?
    UI_MODE=$saved
    return "$rc"
}

# Indented lines are commands and addresses: the terminal wraps them on
# screen, and a copy of one stays one line.
plain_header() {
    local line
    printf '\n----- %s -----\n\n' "$1"
    while IFS= read -r line; do
        case "$line" in
        "  "*) printf '%s\n' "$line" ;;
        *) printf '%s\n' "$line" | fold -s -w 76 ;;
        esac
    done <<<"$2"
    printf '\n'
}

# Asked only before anything has changed, so stopping is always safe there.
ui_cancelled() {
    if [ "${APPLY_STARTED:-0}" = 1 ]; then
        return 1
    fi
    ui_size "Nothing on this machine has changed yet. Stop here?" 8
    if whiptail --backtitle "$UI_BACKTITLE" --title "Stop the setup?" --yesno -- \
        "Nothing on this machine has changed yet. Stop here?" "$UI_H" "$UI_W"; then
        say "Stopped. Nothing was changed."
        exit 0
    fi
    return 1
}

ui_msg() {
    local title=$1 text=$2
    case "$UI_MODE" in
    whiptail)
        ui_size "$text" 6
        ui_scroll "$text" button
        whiptail --backtitle "$UI_BACKTITLE" --title "$title" "${UI_SCROLL[@]}" --msgbox -- "$UI_TEXT" "$UI_H" "$UI_W" || true ;;
    plain)
        plain_header "$title" "$text"
        read -r -p "Press Enter to go on. " _ <"$UI_TTY" || true ;;
    answers)
        plain_header "$title" "$text" ;;
    esac
}

# ui_msg for a screen that shows secrets: whiptail would carry them on its
# command line, which ps shows to every local account.
ui_msg_keys() {
    if [ "$UI_MODE" = whiptail ]; then clear; ui_plain_once ui_msg "$@"; else ui_msg "$@"; fi
}

# ui_msg for a screen whose job is commands to copy: a selection in a
# whiptail box drags its border characters along.
ui_msg_copy() {
    if [ "$UI_MODE" = whiptail ]; then clear; ui_plain_once ui_msg "$@"; else ui_msg "$@"; fi
}

# ui_yesno <key> <title> <text> <default yes|no>: returns 0 for yes.
ui_yesno() {
    local key=$1 title=$2 text=$3 default=${4:-yes} rc=0
    [ "$UI_MODE" = answers ] || default=$(ui_default "$key" "$default")
    ui_yesno_ask "$key" "$title" "$text" "$default" || rc=$?
    if [ "$UI_MODE" != answers ]; then
        if [ "$rc" = 0 ]; then ui_remember "$key" yes; else ui_remember "$key" no; fi
    fi
    return "$rc"
}

ui_yesno_ask() {
    local key=$1 title=$2 text=$3 default=${4:-yes} a rc
    case "$UI_MODE" in
    whiptail)
        ui_size "$text" 6
        ui_scroll "$text" "Yes and No buttons"
        local flags=("${UI_SCROLL[@]}")
        [ "$default" = no ] && flags+=(--defaultno)
        rc=0
        whiptail --backtitle "$UI_BACKTITLE" --title "$title" "${flags[@]}" --yesno -- "$UI_TEXT" "$UI_H" "$UI_W" || rc=$?
        if [ "$rc" = 255 ]; then ui_cancelled || true; ui_yesno_ask "$@"; return; fi
        return "$rc" ;;
    plain)
        plain_header "$title" "$text"
        while :; do
            if [ "$default" = yes ]; then ui_read a "Yes or no? [Y/n] "
            else ui_read a "Yes or no? [y/N] "; fi
            a=${a:-$default}
            case "$a" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            esac
        done ;;
    answers)
        a=$(ans_get "$key" "$default")
        plain_header "$title" "$text"
        say "Answer from the file ($key): $a"
        case "$a" in
        yes|y|true|1|on) return 0 ;;
        no|n|false|0|off) return 1 ;;
        *) die "the answer file gives $key=$a; it takes yes or no." ;;
        esac ;;
    esac
}

# ui_menu <key> <title> <text> <default tag> <tag> <label> [<tag> <label>...]
# Sets UI_REPLY to the chosen tag.
ui_menu() {
    local key=$1 title=$2 text=$3 default=$4
    shift 4
    [ "$UI_MODE" = answers ] || default=$(ui_default "$key" "$default")
    ui_menu_ask "$key" "$title" "$text" "$default" "$@" || return
    [ "$UI_MODE" = answers ] || ui_remember "$key" "$UI_REPLY"
}

ui_menu_ask() {
    local key=$1 title=$2 text=$3 default=$4
    shift 4
    local items=("$@") n=$(( $# / 2 )) i a
    case "$UI_MODE" in
    whiptail)
        local lh
        while :; do
            ui_size "$text" $((n + 7))
            ui_scroll "$text" choices
            # A long list scrolls too, so the text keeps a few lines.
            lh=$n
            [ "$lh" -gt $((UI_H - 12)) ] && lh=$((UI_H - 12))
            [ "$lh" -lt 1 ] && lh=1
            if UI_REPLY=$(whiptail --backtitle "$UI_BACKTITLE" --title "$title" --default-item "$default" "${UI_SCROLL[@]}" \
                --menu -- "$UI_TEXT" "$UI_H" "$UI_W" "$lh" "${items[@]}" 3>&1 1>&2 2>&3); then
                return 0
            fi
            ui_cancelled || true
        done ;;
    plain)
        plain_header "$title" "$text"
        for ((i = 0; i < n; i++)); do
            printf '  %d) %s\n' $((i + 1)) "${items[$((i * 2 + 1))]}"
        done
        while :; do
            local d=1
            for ((i = 0; i < n; i++)); do [ "${items[$((i * 2))]}" = "$default" ] && d=$((i + 1)); done
            ui_read a "Your choice [$d]: "
            a=${a:-$d}
            if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "$n" ]; then
                UI_REPLY=${items[$(((a - 1) * 2))]}
                return 0
            fi
        done ;;
    answers)
        a=$(ans_get "$key" "$default")
        plain_header "$title" "$text"
        for ((i = 0; i < n; i++)); do
            if [ "${items[$((i * 2))]}" = "$a" ]; then
                say "Answer from the file ($key): $a"
                UI_REPLY=$a
                return 0
            fi
        done
        local tags=""
        for ((i = 0; i < n; i++)); do tags="$tags ${items[$((i * 2))]}"; done
        die "the answer file gives $key=$a; it takes one of:$tags." ;;
    esac
}

# ui_input <key> <title> <text> <default>. Sets UI_REPLY.
ui_input() {
    local key=$1 title=$2 text=$3 default=${4:-}
    [ "$UI_MODE" = answers ] || default=$(ui_default "$key" "$default")
    ui_input_ask "$key" "$title" "$text" "$default"
    [ "$UI_MODE" = answers ] || ui_remember "$key" "$UI_REPLY"
}

ui_input_ask() {
    local key=$1 title=$2 text=$3 default=${4:-} a
    case "$UI_MODE" in
    whiptail)
        # A scrolling text would take the focus from the field, and what the
        # person typed would go nowhere, so a long one is asked in plain text.
        ui_size "$text" 6
        if [ "$UI_FITS" = 0 ]; then clear; ui_plain_once ui_input_ask "$@"; return; fi
        while :; do
            ui_size "$text" 6
            if UI_REPLY=$(whiptail --backtitle "$UI_BACKTITLE" --title "$title" \
                --inputbox -- "$text" "$UI_H" "$UI_W" "$default" 3>&1 1>&2 2>&3); then
                return 0
            fi
            ui_cancelled || true
        done ;;
    plain)
        plain_header "$title" "$text"
        if [ -n "$default" ]; then ui_read a "[$default]: "
        else ui_read a "> "; fi
        UI_REPLY=${a:-$default} ;;
    answers)
        plain_header "$title" "$text"
        UI_REPLY=$(ans_get "$key" "$default")
        say "Answer from the file ($key): $UI_REPLY" ;;
    esac
}

# ui_secret <key> <title> <text>: never echoed. In an answer file, <key>_file
# names a file holding the value, so the secret need not sit in the answers.
ui_secret() {
    local key=$1 title=$2 text=$3 f
    case "$UI_MODE" in
    whiptail)
        ui_size "$text" 6
        if [ "$UI_FITS" = 0 ]; then clear; ui_plain_once ui_secret "$@"; return; fi
        while :; do
            ui_size "$text" 6
            if UI_REPLY=$(whiptail --backtitle "$UI_BACKTITLE" --title "$title" \
                --passwordbox -- "$text" "$UI_H" "$UI_W" 3>&1 1>&2 2>&3); then
                return 0
            fi
            ui_cancelled || true
        done ;;
    plain)
        plain_header "$title" "$text"
        # Echo goes off before the prompt shows: read -s would switch it while
        # the prompt is up, and a token pasted at once could be lost.
        stty -echo </dev/tty 2>/dev/null || true
        printf '> ' 2>/dev/null >/dev/tty || true
        UI_REPLY=""
        IFS= read -r UI_REPLY <"$UI_TTY" || [ -n "$UI_REPLY" ] ||
            { stty echo </dev/tty 2>/dev/null; die "the terminal closed before an answer came, so I stopped."; }
        stty echo </dev/tty 2>/dev/null || true
        printf '\n' ;;
    answers)
        plain_header "$title" "$text"
        f=$(ans_get "${key}_file")
        if [ -n "$f" ]; then
            ui_secret_file "$f" || die "cannot read ${key}_file $f."
        else
            UI_REPLY=$(ans_get "$key")
        fi
        say "Answer from the file ($key): (hidden)" ;;
    esac
}

# ui_secret_file <path>: a secret from a file (a TOKEN= line, or the value alone
# on its first line) into UI_REPLY, never shown. Returns 1 when the file cannot
# be read, and warns when every account on this machine can read it.
UI_SECRET_FILE_OPEN=0
ui_secret_file() {
    local f=$1
    UI_REPLY="" UI_SECRET_FILE_OPEN=0
    [ -f "$f" ] && [ -r "$f" ] || return 1
    UI_REPLY=$(kv_get "$f" TOKEN)
    [ -n "$UI_REPLY" ] || UI_REPLY=$(head -n 1 "$f" | tr -d '[:space:]')
    if [ -n "$(find "$f" -maxdepth 0 -perm -o=r 2>/dev/null)" ]; then
        UI_SECRET_FILE_OPEN=1
        warn "every account on this machine can read $f. Delete it once the setup is done, or run: chmod 600 $f"
    fi
    return 0
}

# The terminals on stdin of this process and its parents, like /dev/tty1 or
# /dev/pts/0, one per line. Parents too, because sudo's use_pty (Ubuntu's
# default) puts the setup itself on a fresh /dev/pts even on a console.
ui_tty_name() {
    local pid=$$ n=0
    while [ "$n" -lt 40 ]; do
        readlink "/proc/$pid/fd/0" 2>/dev/null || true
        pid=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)
        case "$pid" in '' | 0 | 1 | *[!0-9]*) return 0 ;; esac
        n=$((n + 1))
    done
}

# True on the machine's own console (a VirtualBox window, a provider's web
# console, a serial line) rather than over SSH, where pasting usually fails.
on_local_console() {
    [ -n "${SSH_TTY:-}" ] && return 1
    [ -n "$(hollow_session_ssh_port)" ] && return 1
    local t
    for t in $(ui_tty_name); do
        case "$t" in
        /dev/tty[0-9]* | /dev/ttyS[0-9]* | /dev/ttyAMA[0-9]* | /dev/hvc[0-9]* | /dev/xvc[0-9]* | /dev/console) return 0 ;;
        esac
    done
    return 1
}

# Early, before the long questions: on a console, recommend SSH and offer to
# stop. Nothing has changed at this point, so stopping costs nothing.
console_notice() {
    [ "$UI_MODE" = answers ] && return 0
    on_local_console || return 0
    local user addr cmd
    user=$(ssh_account)
    addr=$(local_ipv4)
    [ -n "$addr" ] || addr=this-machine
    cmd="ssh $user@$addr"
    local server="Then run the setup again there, with the same command you used here."
    have sshd || server="This machine has no SSH server yet. Install it first with: sudo apt install openssh-server
$server"
    ui_menu console "You are on the machine's own console" \
"You are typing on this machine's own screen, like a VirtualBox window or a web console from your provider. Pasting usually does not work there, and with a DuckDNS name the setup asks for its long token.

We recommend connecting over SSH from your own computer, where copy and paste work:

  $cmd

$server Nothing has changed yet, so stopping now costs nothing.

If you stay here, the DuckDNS token can come from a file instead of a paste." \
        ssh ssh "Stop here, I will connect over SSH (recommended)" here "Go on here"
    if [ "$UI_REPLY" = ssh ]; then
        say "Stopped. Nothing was changed. Connect with: $cmd"
        exit 0
    fi
}

# Answers so far, kept while a first install is under way so a stopped run
# can start again with them. Never the DuckDNS token or a key: only these.
DRAFT_FILE=/var/lib/hollow-installer/answers.draft
DRAFT_KEYS="mode binaries address duckdns_name domain ip public_ip turn push forwarder members_only member_keys public_stats grace_secs ssh_keys"
DRAFT_ON=0
declare -A DRAFT=()
declare -A DRAFT_NOW=()

# ui_default <key> <default>: last time's answer, once, else <default>. Once,
# so a screen asked again shows what was just typed.
ui_default() {
    if [ -n "${DRAFT[$1]+x}" ]; then
        printf '%s' "${DRAFT[$1]}"
        unset "DRAFT[$1]"
    else
        printf '%s' "$2"
    fi
}

# ui_remember <key> <answer>
ui_remember() {
    [ "$DRAFT_ON" = 1 ] || return 0
    case " $DRAFT_KEYS " in *" $1 "*) ;; *) return 0 ;; esac
    case "$2" in *$'\n'*) return 0 ;; esac
    DRAFT_NOW[$1]=$2
    local k tmp
    tmp=$(umask 077 && mktemp "$DRAFT_FILE.XXXXXX") || return 0
    for k in "${!DRAFT_NOW[@]}"; do printf '%s=%s\n' "$k" "${DRAFT_NOW[$k]}"; done >"$tmp"
    mv -f "$tmp" "$DRAFT_FILE"
}

draft_clear() { rm -f "$DRAFT_FILE"; }

# A first install offers the answers a stopped run left, then keeps new ones.
draft_offer() {
    [ "$UI_MODE" != answers ] && [ "$(id -u)" = 0 ] && [ "${DRY_RUN:-0}" = 0 ] || return 0
    if [ -f "$DRAFT_FILE" ] && [ ! -L "$DRAFT_FILE" ]; then
        if ui_yesno draft_use "Use the answers from last time?" \
"The last run of the setup stopped before it finished, and I kept the answers you gave. The DuckDNS token is never written down, so you type it again.

Use them? Every screen then shows your earlier answer, and you press Enter to keep it." yes; then
            local k v
            for k in $DRAFT_KEYS; do
                v=$(kv_get "$DRAFT_FILE" "$k")
                [ -n "$v" ] || grep -q "^$k=" "$DRAFT_FILE" || continue
                DRAFT[$k]=$v
                DRAFT_NOW[$k]=$v
            done
        else
            draft_clear
        fi
    fi
    DRAFT_ON=1
}

# A progress line that also shows in whiptail mode, where the screens clear.
ui_progress() {
    step "$1"
}
