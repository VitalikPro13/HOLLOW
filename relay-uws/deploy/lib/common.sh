#!/bin/bash
# Shared by install.sh and its helpers. Sourced, never executed.
#
# Every change to the machine goes through run, run_logged or put_file, so
# --dry-run can print it instead.

DRY_RUN=${DRY_RUN:-0}
# The installer's scratch space is in RAM: command output can name addresses.
WORK_DIR=${WORK_DIR:-}

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { printf '\nStopped: %s\n' "$*" >&2; exit 1; }

# The first line of a command, for --dry-run output and error messages.
cmd_text() {
    local out="" a
    for a in "$@"; do
        case "$a" in
        *[[:space:]\'\"\$]*) out="$out '${a//\'/\'\\\'\'}'" ;;
        *) out="$out $a" ;;
        esac
    done
    printf '%s' "${out# }"
}

run() {
    if [ "$DRY_RUN" = 1 ]; then
        say "  would run: $(cmd_text "$@")"
        return 0
    fi
    "$@"
}

# Like run, but the output goes to a file in RAM and is shown only on failure.
# On a terminal a spinner with the time so far shows that it is still working;
# anywhere else nothing is drawn, so logs hold no control characters.
run_logged() {
    if [ "$DRY_RUN" = 1 ]; then
        say "  would run: $(cmd_text "$@")"
        return 0
    fi
    local log="$WORK_DIR/cmd.log" rc=0
    if [ -t 1 ] && [ "${UI_MODE:-}" != answers ]; then
        "$@" >"$log" 2>&1 </dev/null &
        spin_wait $!
        wait $! || rc=$?
    else
        "$@" >"$log" 2>&1 </dev/null || rc=$?
    fi
    cat "$log" >>"$WORK_DIR/run.log" 2>/dev/null || true
    if [ "$rc" != 0 ]; then
        printf '\nThis command failed (exit %s):\n  %s\nIts last lines:\n' "$rc" "$(cmd_text "$@")" >&2
        tail -n 25 "$log" >&2
    fi
    return "$rc"
}

# spin_wait <pid>: a spinner and the time so far until the process ends.
spin_wait() {
    local pid=$1 frames='|/-\' i=0 t0 s
    t0=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        s=$(( $(date +%s) - t0 ))
        printf '\r    %s %d:%02d ' "${frames:$((i % 4)):1}" $((s / 60)) $((s % 60))
        i=$((i + 1))
        sleep 0.25
    done
    printf '\r\033[K'
}

# Allowed to fail, and its output is noise.
run_ok() {
    if [ "$DRY_RUN" = 1 ]; then
        say "  would run: $(cmd_text "$@")"
        return 0
    fi
    "$@" >/dev/null 2>&1 || true
}

# put_file <path> <mode> <owner> <group>, content on stdin. Lands in one rename,
# so a reader never sees half a file. Sets PUT_CHANGED=1 when the content, mode
# or owner differed.
PUT_CHANGED=0
put_file() {
    local path=$1 mode=$2 owner=$3 group=$4 tmp
    PUT_CHANGED=0
    if [ "$DRY_RUN" = 1 ]; then
        cat >/dev/null
        say "  would write: $path ($mode $owner:$group)"
        PUT_CHANGED=1
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    tmp=$(mktemp "$path.new.XXXXXX")
    chmod 0600 "$tmp"
    cat >"$tmp"
    chown "$owner:$group" "$tmp"
    chmod "$mode" "$tmp"
    if [ -f "$path" ] && cmp -s "$tmp" "$path" &&
       [ "$(stat -c '%a %U %G' "$path")" = "$(stat -c '%a %U %G' "$tmp")" ]; then
        rm -f "$tmp"
        return 0
    fi
    mv -f "$tmp" "$path"
    PUT_CHANGED=1
}

# ensure_dir <path> <mode> <owner> <group>
ensure_dir() {
    if [ "$DRY_RUN" = 1 ]; then
        [ -d "$1" ] && [ "$(stat -c '%a %U %G' "$1")" = "${2#0} $3 $4" ] && return 0
        say "  would create: $1 ($2 $3:$4)"
        return 0
    fi
    install -d -m "$2" -o "$3" -g "$4" "$1"
}

# ensure_account <name>: a system account that cannot log in and has no home.
ensure_account() {
    getent passwd "$1" >/dev/null && return 0
    run useradd --system --user-group --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin "$1"
}

# Hex from the kernel's random source. Never printed by the installer.
gen_hex() {
    od -An -N"${1:-32}" -tx1 /dev/urandom | tr -d ' \n'
}

# A members-only key: four groups of four from A-Z and 0-9, without modulo bias.
gen_member_key() {
    local alphabet=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 out="" b
    while [ "${#out}" -lt 16 ]; do
        for b in $(od -An -N32 -tu1 /dev/urandom); do
            [ "$b" -lt 252 ] || continue
            out="$out${alphabet:$((b % 36)):1}"
            [ "${#out}" -lt 16 ] || break
        done
    done
    printf '%s-%s-%s-%s' "${out:0:4}" "${out:4:4}" "${out:8:4}" "${out:12:4}"
}

is_member_key() {
    [[ "$1" =~ ^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$ ]]
}

# kv_get <file> <key>: the last value a KEY=value file gives, read and never
# sourced, quotes stripped.
kv_get() {
    local v
    [ -r "$1" ] || return 0
    v=$(sed -n "s/^[[:space:]]*$2[[:space:]]*=//p" "$1" | tail -n 1)
    v=${v%"${v##*[![:space:]]}"}
    v=${v#"${v%%[![:space:]]*}"}
    case "$v" in
    \"*\") v=${v#\"}; v=${v%\"} ;;
    \'*\') v=${v#\'}; v=${v%\'} ;;
    esac
    printf '%s' "$v"
}

# What a rewrite of relay.env or .env keeps: the lines the setup does not
# write, an operator's own settings (HOLLOW_SEND_BUDGET_BYTES, or anything
# else) and their comments, under this line.
ENV_KEPT_HEADER="# Your own settings, which install.sh keeps as they are:"

# env_operator_lines <file> <strict yes|no> <key the setup writes...>. Strict
# is for a file another setup wrote, or one another account could change: it
# keeps only HOLLOW_* settings with plain values, never a comment.
env_operator_lines() {
    local file=$1 strict=$2 line key
    shift 2
    [ -f "$file" ] && [ ! -L "$file" ] && [ "$(readlink -f -- "$file")" = "$file" ] || return 0
    if [ "$(stat -c %u -- "$file")" != "$(id -u)" ] || [ -n "$(find "$file" -perm /022)" ]; then strict=yes; fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
        "" | "# Written by install.sh"* | "$ENV_KEPT_HEADER") continue ;;
        esac
        key=$(sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p' <<<"$line")
        if [ -n "$key" ] && [[ " $* " == *" $key "* ]]; then continue; fi
        if [ "$strict" = yes ]; then
            [[ "$key" =~ ^HOLLOW_[A-Z0-9_]{1,64}$ ]] && [[ "$line" =~ ^[[:space:]]*$key=[A-Za-z0-9._:/,+=@%-]{1,1024}$ ]] || continue
            line=${line#"${line%%[![:space:]]*}"}
        fi
        printf '%s\n' "$line"
    done <"$file"
}

# env_kept_block <the file being rewritten> <files another setup wrote, or "">
# <key the setup writes...>: the kept lines with their header, or nothing. A
# setting from the other files counts only where the first has none.
env_kept_block() {
    local own=$1 seeds=$2 kept="" line f strict=no
    shift 2
    # A take over rewrites the old setup's own files in place.
    [ "${ADOPT_KIND:-none}" = none ] || strict=yes
    kept=$(env_operator_lines "$own" "$strict" "$@")
    for f in $seeds; do
        [ "$f" != "$own" ] || continue
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            [[ $'\n'"$kept" == *$'\n'"${line%%=*}="* ]] && continue
            kept+=${kept:+$'\n'}$line
        done < <(env_operator_lines "$f" yes "$@")
    done
    [ -n "$kept" ] || return 0
    printf '%s\n%s\n' "$ENV_KEPT_HEADER" "$kept"
}

have() { command -v "$1" >/dev/null 2>&1; }

# apt_install <package...>, quietly, without questions.
APT_UPDATED=0
apt_install() {
    local missing=() p
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep "ok installed" >/dev/null || missing+=("$p")
    done
    [ ${#missing[@]} -eq 0 ] && return 0
    # On the screen, unlike apt's own output: a wait can take minutes.
    if [ "$DRY_RUN" = 0 ] && ! hollow_apt_wait 2>"$WORK_DIR/apt.wait"; then die "$(cat "$WORK_DIR/apt.wait")"; fi
    if [ "$APT_UPDATED" = 0 ]; then
        run_logged hollow_apt update -q || return 1
        APT_UPDATED=1
    fi
    run_logged hollow_apt install -y -q --no-install-recommends "${missing[@]}"
}

# The name a package has on this release: Ubuntu 24.04 renamed libssl3 to
# libssl3t64, and the old name is only a virtual package there.
pkg_name() {
    if apt-cache show "${1}t64" >/dev/null 2>&1; then printf '%st64' "$1"; else printf '%s' "$1"; fi
}

# adopt_step <point>: what taking over a relay adds at that point of a setup
# run (deploy/lib/adopt.sh); nothing otherwise.
adopt_step() {
    if declare -F adopt_hook >/dev/null; then adopt_hook "$1"; fi
}

# systemd unit helpers that keep --dry-run honest.
unit_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
unit_exists() { [ "$(systemctl show -p LoadState --value "$1" 2>/dev/null)" = loaded ]; }

# ---------------------------------------------------------------- downloads

# Which program net_get uses. A stock Debian server has wget and python3 but
# no curl, and nothing may be installed before the plan screen.
net_tool() {
    if have curl; then echo curl
    elif have wget; then echo wget
    elif have python3; then echo python3
    else return 1
    fi
}

# net_get [-4|-6] [-H '<name>: <value>'] <https url, or - to read it from
# stdin> [<seconds>]: the body on stdout, at most 64 KiB. A URL on stdin
# keeps a secret in it off every command line. Every program refuses a
# redirect of any kind and an empty body counts as a failure, so the three
# behave the same. Returns 127 when this machine has no program to fetch
# with, so a caller never mistakes that for no internet.
NET_CAP=65536
net_get() {
    local fam="" hdr="" url secs tool stdin=0 out
    while :; do
        case "${1:-}" in
        -4 | -6) fam=$1; shift ;;
        -H) hdr=$2; shift 2 ;;
        *) break ;;
        esac
    done
    url=$1 secs=${2:-8}
    tool=$(net_tool) || return 127
    if [ "$url" = - ]; then stdin=1; IFS= read -r url || return 1; fi
    case "$url" in https://*) ;; *) return 1 ;; esac
    # The x keeps a body's last newlines, and shows a body was written at all.
    out=$(net_fetch "$tool" "$fam" "$hdr" "$url" "$secs" "$stdin" && printf x) || return 1
    out=${out%x}
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# net_fetch <tool> <-4|-6|""> <header or ""> <url> <seconds> <1 when the URL
# must stay off command lines>: net_get's download, non-zero on any failure.
net_fetch() {
    local - tool=$1 fam=$2 hdr=$3 url=$4 secs=$5 stdin=$6
    set -o pipefail
    case "$tool" in
    curl)
        local cmd=(curl -q -fsS ${fam:+"$fam"} --proto "=https" -L --max-redirs 0 --max-time "$secs" ${hdr:+-H "$hdr"})
        if [ "$stdin" = 1 ]; then
            printf 'url = "%s"\n' "$url" | "${cmd[@]}" -K - 2>/dev/null | head -c "$NET_CAP"
        else
            "${cmd[@]}" "$url" 2>/dev/null | head -c "$NET_CAP"
        fi ;;
    wget)
        local wcmd=(wget -q -O - --max-redirect=0 --timeout="$secs" --tries=1 ${hdr:+--header="$hdr"})
        case "$fam" in -4) wcmd+=(--inet4-only) ;; -6) wcmd+=(--inet6-only) ;; esac
        if [ "$stdin" = 1 ]; then
            printf '%s\n' "$url" | "${wcmd[@]}" -i - 2>/dev/null | head -c "$NET_CAP"
        else
            "${wcmd[@]}" "$url" 2>/dev/null | head -c "$NET_CAP"
        fi ;;
    python3)
        printf '%s\n' "$url" | python3 -I -c '
import socket, sys, urllib.request
fam, hdr, secs, cap = sys.argv[1], sys.argv[2], float(sys.argv[3]), int(sys.argv[4])
url = sys.stdin.readline().strip()
if fam:
    want = socket.AF_INET if fam == "-4" else socket.AF_INET6
    orig = socket.getaddrinfo
    def only(host, port, family=0, *a, **k):
        return orig(host, port, want, *a, **k)
    socket.getaddrinfo = only
class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)
req = urllib.request.Request(url, headers={"User-Agent": "hollow-relay-setup"})
if hdr:
    name, value = hdr.split(":", 1)
    req.add_header(name.strip(), value.strip())
try:
    with urllib.request.build_opener(NoRedirects).open(req, timeout=secs) as r:
        sys.stdout.buffer.write(r.read(cap))
except Exception:
    sys.exit(1)
' "$fam" "$hdr" "$secs" "$NET_CAP" 2>/dev/null ;;
    *) return 1 ;;
    esac
}
