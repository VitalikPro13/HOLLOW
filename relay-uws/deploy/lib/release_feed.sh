# shellcheck shell=bash
# The signed relay feed: relay.json + relay.json.sig next to the app's update
# manifest, naming one prebuilt relay tarball per machine. Sourced by install.sh,
# which runs as root and installs what this hands it, so everything here fails
# closed: a feed is used only when its signature verifies under the release key
# over the domain-separated message (`feed_message("relay", bytes)` in
# rust/hollow_manifest/src/feeds.rs), it is not older than this copy of the
# library, than the last feed this box accepted or (when asked) than the relay
# installed, and the tarball matches the feed's size and sha256 and holds
# exactly the three expected regular files, plus the setup's own copy under
# setup/ when the release carries one (plain files only, bounded, with every
# library its install.sh sources), in one gzip member.
#
# Needs bash, curl, openssl 3, jq, sha256sum, tar, gzip, flock and coreutils.
# Every function prints its reason on stderr, returns non-zero on any failure
# and leaves no partial file behind. Feed content is never evaluated as code.
# Safe under `set -euo pipefail`.
#
#   hollow_feed_arch                 prints linux-x86_64 or linux-aarch64
#   hollow_feed_check <state_dir> [<installed VERSION file> [allow-downgrade]]
#                                    sets FEED_VERSION FEED_BUILD FEED_ISSUED
#                                    FEED_COMMIT FEED_URL FEED_SHA256 FEED_SIZE;
#                                    returns 3 when the feed verifies but is
#                                    older than the installed relay
#   hollow_feed_fetch <dest_dir>     puts hollow-relay, hollow-forwarder, VERSION there,
#                                    and the setup's copy as <dest_dir>/setup when the
#                                    release carries one (dest must not hold a setup entry)
#   hollow_feed_accept <state_dir>   records FEED_ISSUED after a good install
#   hollow_feed_newer <version> <build>   0 when the checked feed is newer
#   hollow_feed_installed <VERSION file>  sets INSTALLED_VERSION INSTALLED_BUILD
#                                         INSTALLED_COMMIT
#
# Nothing in the environment changes the trusted keys, the origin or the
# protocols. Tests redefine _hf_release_keys, _hf_base, _hf_protos and
# hollow_feed_arch after sourcing this file.

_HF_RELEASE_BASE="https://anonlisten.com/hollow/releases"
# The signer refuses bodies over these (RELAY_CAP_BYTES, MAX_RELAY_TARBALL_BYTES).
_HF_FEED_CAP=16384
_HF_SIG_CAP=1024
_HF_TARBALL_CAP=268435456
_HF_STATE_FILE="relay_feed_issued"
_HF_FILES="VERSION hollow-forwarder hollow-relay"
# The setup's own copy (install.sh, deploy/, push-sidecar/) under setup/, so one
# signature covers it with the programs. These bounds are SETUP_* in
# rust/hollow_manifest/src/feeds.rs; a release outside them would strand every
# box, so the signer refuses it first.
_HF_SETUP_MAX_FILES=512
_HF_SETUP_MAX_FILE=1048576
_HF_SETUP_MAX_BYTES=8388608
# Besides these, every library install.sh sources (_hf_sourced_libs); the push
# sender installs only from its lockfile, and TURN never runs without its port lock.
_HF_SETUP_NEEDS="setup/deploy/coturn-port-lock.conf setup/deploy/hollow-turn-port-lock-refresh.service
setup/deploy/hollow-turn-port-lock-refresh.timer setup/deploy/hollow-turn-port-lock.service setup/deploy/lib/release_feed.sh
setup/deploy/turn-port-lock.sh setup/install.sh setup/push-sidecar/package-lock.json setup/push-sidecar/package.json"
# Every member's mtime is below 2^33 (MAX_MEMBER_MTIME): 2242-03-16 12:56:31
# UTC is the last second, as tar lists it with its digits run together.
_HF_MTIME_LAST=22420316125631
# What one tarball may unpack to (MAX_RELAY_UNPACKED_BYTES).
_HF_UNPACKED_CAP=1073741824
_HF_SETUP_LIST=""
# How far past this box's clock `issued` may be; the signer allows an hour, and
# a stamp kept from the future would refuse every later feed.
_HF_MAX_AHEAD=86400

# The relay feed that was live when this copy was released. A box with no mark
# (first install, reinstall, a switch from source) still never takes an older
# one. scripts/sign_feeds.sh --relay raises these to every feed it signs, and
# test/release_feed checks them against legal/relay.json.
_HF_MIN_ISSUED=1793472159
_HF_MIN_VERSION=0.13.0
_HF_MIN_BUILD=1

# MANIFEST_SIGNING_PUBKEYS in rust/hollow_core/src/api/updater.rs: the same key
# signs the app manifest and every feed. test/release_feed guards this copy.
_hf_release_keys() {
    printf '%s\n' \
        "b6fcb5b64cd5317b470b31ac08892528b0d5c9e82c6cdaa13654a7c9e7f8b09c"
}

_hf_base() { printf '%s' "$_HF_RELEASE_BASE"; }

_hf_protos() { printf '=https'; }

_hf_err() { printf 'Hollow relay update: %s\n' "$*" >&2; }

_hf_need() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || { _hf_err "$tool is not installed"; return 1; }
    done
}

_hf_size() { stat -c %s -- "$1" 2>/dev/null; }

_hf_version_ok() { [[ ${1:-} =~ ^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}$ ]]; }
_hf_build_ok() { [[ ${1:-} =~ ^[0-9]{1,4}$ ]]; }

# <version a> <build a> <version b> <build b>, all well formed: 0 when a is
# older than b.
_hf_older() {
    local i x y
    local -a a=() b=()
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$3"
    a+=("$2")
    b+=("$4")
    for i in 0 1 2 3; do
        x=$((10#${a[$i]}))
        y=$((10#${b[$i]}))
        [ "$x" -lt "$y" ] && return 0
        [ "$x" -gt "$y" ] && return 1
    done
    return 1
}

# <url> <out> <max bytes> <max seconds>. Only https in production; a redirect
# may only lead to https. -q keeps any .curlrc out of a root process.
_hf_get() {
    local url=$1 out=$2 cap=$3 secs=$4 n rc
    # Bounded here as well: curl before 8.x ignores --max-filesize when the host
    # sends no Content-Length.
    {
        rc=0
        curl -q -fsS --proto "$(_hf_protos)" --proto-redir "=https" -L --max-redirs 3 \
            --connect-timeout 20 --max-time "$secs" --max-filesize "$cap" -o - "$url" || rc=$?
        printf '%s' "$rc" > "$out.rc"
    } | head -c "$((cap + 1))" > "$out" || true
    rc=$(cat -- "$out.rc" 2>/dev/null) || rc=""
    rm -f -- "$out.rc"
    n=$(_hf_size "$out") || n=""
    # 63: curl saw the size before downloading it.
    if ! [[ $n =~ ^[0-9]+$ ]] || [ "$n" -gt "$cap" ] || [ "$rc" = 63 ]; then
        rm -f -- "$out"
        _hf_err "$url is larger than $cap bytes, refusing it"
        return 1
    fi
    if [ "$rc" != 0 ]; then
        rm -f -- "$out"
        _hf_err "could not download $url"
        return 1
    fi
}

# Exactly the canonical base64 of 64 bytes, with at most one trailing newline:
# the form `hollow-manifest feed-sign` writes.
_hf_sig_text_ok() {
    local file=$1 text
    text=$(cat -- "$file") || return 1
    [[ $text =~ ^[A-Za-z0-9+/]{85}[AQgw]==$ ]] || return 1
    printf '%s\n' "$text" | cmp -s - "$file" || printf '%s' "$text" | cmp -s - "$file"
}

# <feed file> <sig file> <work dir>: 0 when any trusted key verifies the
# signature over "hollow-feed-sig-v1\0relay\0" + the feed's exact bytes.
_hf_verify_sig() {
    local feed=$1 sigf=$2 work=$3 key out
    if ! _hf_sig_text_ok "$sigf"; then
        _hf_err "relay.json.sig is not a signature in the expected form, refusing the update list"
        return 1
    fi
    base64 -d < "$sigf" > "$work/sig.bin" 2>/dev/null || { _hf_err "relay.json.sig does not decode"; return 1; }
    { printf 'hollow-feed-sig-v1\0relay\0'; cat -- "$feed"; } > "$work/msg" || return 1
    while IFS= read -r key; do
        # A raw Ed25519 key wrapped as SubjectPublicKeyInfo (RFC 8410), DER.
        printf '%b' "$(printf '302a300506032b6570032100%s' "$key" | sed 's/../\\x&/g')" > "$work/pub.der" || return 1
        if out=$(openssl pkeyutl -verify -pubin -inkey "$work/pub.der" -keyform DER -rawin \
            -in "$work/msg" -sigfile "$work/sig.bin" 2>&1) && [[ $out == *"Signature Verified Successfully"* ]]; then
            return 0
        fi
    done < <(_hf_release_keys)
    _hf_err "the relay update list is not signed by Hollow's release key, refusing it"
    return 1
}

# <feed file> <arch>: prints version, build, issued, commit, url, sha256, size
# (tab separated) once each is the type and form the signer writes.
_hf_parse() {
    local feed=$1 arch=$2 line version build issued commit url sha size want
    line=$(jq -er --arg arch "$arch" '
        if type != "object" or .feed != "relay" then error("not the relay feed") else . end
        | if (.artifacts | type) != "object" then error("no artifacts") else . end
        | .artifacts[$arch] as $a
        | if ($a | type) != "object" then error("no relay build for " + $arch) else . end
        | [(.version | strings), (.build | numbers | tostring), (.issued | numbers | tostring),
           (.commit | strings), ($a.url | strings), ($a.sha256 | strings), ($a.size | numbers | tostring)]
        | if length != 7 then error("a field is missing or has the wrong type") else @tsv end
    ' "$feed" 2>&1) || { _hf_err "the relay update list is unusable: $line"; return 1; }
    IFS=$'\t' read -r version build issued commit url sha size <<< "$line"
    if ! _hf_version_ok "$version" || ! _hf_build_ok "$build" \
        || ! [[ $issued =~ ^[1-9][0-9]{0,11}$ ]] || ! [[ $sha =~ ^[0-9a-f]{64}$ ]] \
        || ! [[ $commit =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
        || ! [[ $size =~ ^[1-9][0-9]{0,9}$ ]] || [ "$size" -gt "$_HF_TARBALL_CAP" ]; then
        _hf_err "the relay update list has a malformed version, build, issued, commit, sha256 or size"
        return 1
    fi
    want="$_HF_RELEASE_BASE/$(_hf_tarball_name "$version" "$build" "$arch")"
    if [ "$url" != "$want" ]; then
        _hf_err "the relay update list names $url, expected $want"
        return 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$version" "$((10#$build))" "$issued" "$commit" "$url" "$sha" "$size"
}

# relay_tarball_name in feeds.rs: the build appears only on a patch.
_hf_tarball_name() {
    if [ "$2" -gt 0 ]; then
        printf 'hollow-relay-%s-b%s-%s.tar.gz' "$1" "$((10#$2))" "$3"
    else
        printf 'hollow-relay-%s-%s.tar.gz' "$1" "$3"
    fi
}

# <state dir>: prints the highest `issued` this box accepted, 0 when none.
_hf_accepted_issued() {
    local file="$1/$_HF_STATE_FILE" text
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
        printf '0'
        return 0
    fi
    if [ ! -f "$file" ] || ! text=$(cat -- "$file") || ! [[ $text =~ ^[0-9]{1,12}$ ]]; then
        _hf_err "$file is damaged; remove it to accept the current relay update list again"
        return 1
    fi
    printf '%s' "$((10#$text))"
}

_hf_clear() {
    unset FEED_VERSION FEED_BUILD FEED_ISSUED FEED_COMMIT FEED_URL FEED_SHA256 FEED_SIZE
    _HF_OK="" _HF_V="" _HF_B="" _HF_I="" _HF_C="" _HF_U="" _HF_H="" _HF_S="" _HF_A="" _HF_SETUP_LIST=""
}

hollow_feed_arch() {
    local m dpkg_arch want
    if [ "$(uname -s)" != Linux ]; then
        _hf_err "prebuilt relays are for Linux only"
        return 1
    fi
    m=$(uname -m)
    case "$m" in
        x86_64 | amd64) m=linux-x86_64 want=amd64 ;;
        aarch64 | arm64) m=linux-aarch64 want=arm64 ;;
        *) _hf_err "there is no prebuilt relay for $m; build it from source instead"; return 1 ;;
    esac
    # A 64-bit kernel can run a 32-bit system (Raspberry Pi OS), which cannot
    # start a 64-bit binary.
    if command -v dpkg >/dev/null 2>&1; then
        dpkg_arch=$(dpkg --print-architecture 2>/dev/null) || dpkg_arch=unknown
        if [ "$dpkg_arch" != "$want" ]; then
            _hf_err "this system is $dpkg_arch on a $(uname -m) kernel; there is no prebuilt relay for it, build it from source instead"
            return 1
        fi
    fi
    printf '%s\n' "$m"
}

# <work> <state> <arch> <installed VERSION file or ""> <allow-downgrade or "">:
# prints the parsed line; 3 when only the installed relay is newer.
_hf_check_in() {
    local work=$1 state=$2 arch=$3 vfile=$4 force=$5 base t="" line version build issued accepted now
    base=$(_hf_base)
    case "$base" in http://* | https://*) t="?t=$(date +%s)" ;; esac
    # One cache buster on both files, so a CDN never pairs a new feed with an old signature.
    _hf_get "$base/relay.json$t" "$work/relay.json" "$_HF_FEED_CAP" 60 || return 1
    _hf_get "$base/relay.json.sig$t" "$work/relay.json.sig" "$_HF_SIG_CAP" 60 || return 1
    _hf_verify_sig "$work/relay.json" "$work/relay.json.sig" "$work" || return 1
    line=$(_hf_parse "$work/relay.json" "$arch") || return 1
    IFS=$'\t' read -r version build issued _ <<< "$line"
    now=$(date +%s) || return 1
    if [ "$issued" -gt "$((now + _HF_MAX_AHEAD))" ]; then
        _hf_err "the relay update list is dated more than a day after this server's clock (issued $issued, clock $now). Check this server's date and time, then try again. Refusing it for now."
        return 1
    fi
    if [ "$issued" -lt "$_HF_MIN_ISSUED" ] || _hf_older "$version" "$build" "$_HF_MIN_VERSION" "$_HF_MIN_BUILD"; then
        _hf_err "the relay update list (version $version build $build, issued $issued) is older than this installer, which came out with version $_HF_MIN_VERSION build $_HF_MIN_BUILD (issued $_HF_MIN_ISSUED); refusing it"
        return 1
    fi
    accepted=$(_hf_accepted_issued "$state") || return 1
    if [ "$issued" -lt "$accepted" ]; then
        _hf_err "the relay update list is older than one this server already accepted (issued $issued, before $accepted); refusing it"
        return 1
    fi
    if [ -n "$vfile" ] && { [ -e "$vfile" ] || [ -L "$vfile" ]; }; then
        hollow_feed_installed "$vfile" || { _hf_err "cannot tell which relay is installed, refusing to replace it"; return 1; }
        if _hf_older "$version" "$build" "$INSTALLED_VERSION" "$INSTALLED_BUILD"; then
            if [ "$force" != allow-downgrade ]; then
                _hf_err "the relay update list names version $version build $build, older than the installed $INSTALLED_VERSION build $INSTALLED_BUILD; refusing to downgrade"
                return 3
            fi
            _hf_err "installing the older version $version build $build over $INSTALLED_VERSION build $INSTALLED_BUILD, as asked"
        fi
    fi
    printf '%s\n' "$line"
}

hollow_feed_check() {
    local state=${1:-} vfile=${2:-} force=${3:-} arch work line rc=0
    _hf_clear
    if [ -z "$state" ] || [ $# -gt 3 ] || { [ -n "$force" ] && [ "$force" != allow-downgrade ]; }; then
        _hf_err "usage: hollow_feed_check <state_dir> [<installed VERSION file> [allow-downgrade]]"
        return 2
    fi
    _hf_need curl openssl jq sha256sum base64 stat cmp head || return 1
    arch=$(hollow_feed_arch) || return 1
    case "$arch" in
        linux-x86_64 | linux-aarch64) ;;
        *) _hf_err "there is no prebuilt relay for $arch"; return 1 ;;
    esac
    work=$(mktemp -d "${TMPDIR:-/tmp}/hollow-feed.XXXXXX") || { _hf_err "cannot make a temporary folder"; return 1; }
    line=$(_hf_check_in "$work" "$state" "$arch" "$vfile" "$force") || rc=$?
    rm -rf -- "$work"
    [ "$rc" = 0 ] || { [ "$rc" = 3 ] && return 3; return 1; }
    IFS=$'\t' read -r _HF_V _HF_B _HF_I _HF_C _HF_U _HF_H _HF_S <<< "$line"
    _HF_A=$arch
    _HF_OK=1
    FEED_VERSION=$_HF_V FEED_BUILD=$_HF_B FEED_ISSUED=$_HF_I FEED_COMMIT=$_HF_C
    FEED_URL=$_HF_U FEED_SHA256=$_HF_H FEED_SIZE=$_HF_S
}

# <name>: install.sh, or a file below deploy/ or push-sidecar/, under setup/.
# Each part starts with a letter, digit or underscore, so no part is . or ..,
# hidden, or read as an option.
_hf_setup_name_ok() {
    local part='[A-Za-z0-9_][A-Za-z0-9._-]{0,63}'
    local re="^setup/(install\.sh|(deploy|push-sidecar)(/$part){1,5})$"
    [[ $1 =~ $re ]]
}

# <tarball>: one gzip member with content, nothing after it. gzip -d reads
# every member as one stream and skips trailing zeros; the last member's size
# field (ISIZE) equals the whole stream only when no member before it holds
# anything and nothing follows (single_gzip_member in feeds.rs).
_hf_gzip_ok() {
    local - total isize
    set -o pipefail
    total=$(gzip -dc -- "$1" 2>/dev/null | wc -c) || return 1
    isize=$(tail -c 4 -- "$1" | od -An -tu4 --endian=little | tr -d ' \n') || return 1
    [[ $total =~ ^[0-9]+$ ]] && [[ $isize =~ ^[0-9]+$ ]] && [ "$((total % 4294967296))" = "$isize" ]
}

# <install.sh>: the libraries it sources, as setup/deploy/lib/<name>, one per
# line: each line exactly . "$DEPLOY/lib/<name>.sh" (sourced_libs in feeds.rs).
_hf_sourced_libs() {
    sed -n 's|^\. "\$DEPLOY/lib/\([A-Za-z0-9_][A-Za-z0-9_]*\)\.sh"$|setup/deploy/lib/\1.sh|p' -- "$1"
}

# <name> <newline-ended list>: 0 when the list has that line. A pattern, not
# grep -q, which may stop reading before the writer is done and fail the
# pipeline under pipefail.
_hf_has_line() {
    case $'\n'"$2" in *$'\n'"$1"$'\n'*) return 0 ;; esac
    return 1
}

# <tarball>: VERSION, hollow-forwarder and hollow-relay at the root and, when
# the release carries the setup's copy, its files under setup/: every entry a
# regular file, named once, setup files 0644 or 0755 and bounded. Sets
# _HF_SETUP_LIST to the setup's files, one per line.
_hf_tar_listing_ok() {
    local names listed line mode size when name n=0 bytes=0 total=0 f
    local re='^([-a-z][-rwxsStT]{9}) [0-9]+/[0-9]+ +([0-9]{1,12}) ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)? +([^ ].*)$'
    local -a seen=()
    _HF_SETUP_LIST=""
    _hf_gzip_ok "$1" || return 1
    names=$(LC_ALL=C tar -tzf "$1" 2>/dev/null | LC_ALL=C sort) || return 1
    [ -n "$names" ] && [ -z "$(printf '%s\n' "$names" | uniq -d)" ] || return 1
    # Full UTC times, so every line has the same fields whatever the mtime.
    listed=$(LC_ALL=C TZ=UTC0 tar -tvzf "$1" --numeric-owner --full-time 2>/dev/null) || return 1
    while IFS= read -r line; do
        [[ $line =~ $re ]] || return 1
        mode=${BASH_REMATCH[1]} size=${BASH_REMATCH[2]} when=${BASH_REMATCH[3]} name=${BASH_REMATCH[5]}
        [ "${mode:0:1}" = - ] || return 1
        when=${when//[^0-9]/}
        [ "$when" -ge 19700101000000 ] && [ "$when" -le "$_HF_MTIME_LAST" ] || return 1
        total=$((total + 10#$size))
        case " $_HF_FILES " in
        *" $name "*) ;;
        *)
            _hf_setup_name_ok "$name" || return 1
            [ "$mode" = -rw-r--r-- ] || [ "$mode" = -rwxr-xr-x ] || return 1
            [ "$((10#$size))" -le "$_HF_SETUP_MAX_FILE" ] || return 1
            n=$((n + 1))
            bytes=$((bytes + 10#$size))
            _HF_SETUP_LIST+="$name"$'\n' ;;
        esac
        seen+=("$name")
    done <<< "$listed"
    # Both listings name the same entries, so nothing hid from the check above.
    [ "$(printf '%s\n' "${seen[@]}" | LC_ALL=C sort)" = "$names" ] || return 1
    for f in $_HF_FILES; do
        _hf_has_line "$f" "$names"$'\n' || return 1
    done
    [ "$total" -le "$_HF_UNPACKED_CAP" ] && [ "$n" -le "$_HF_SETUP_MAX_FILES" ] && [ "$bytes" -le "$_HF_SETUP_MAX_BYTES" ] || return 1
    if [ "$n" -gt 0 ]; then
        for f in $_HF_SETUP_NEEDS; do
            _hf_has_line "$f" "$_HF_SETUP_LIST" || return 1
        done
    fi
}

# <folder>: what extraction left is exactly the listed files, each a regular
# file, with folders only below setup/, and a setup copy holds every library
# its install.sh sources.
_hf_extracted_ok() {
    local dir=$1 f want got dirs
    want=$(printf '%s\n' $_HF_FILES $_HF_SETUP_LIST | LC_ALL=C sort)
    got=$(cd -- "$dir" && find . -mindepth 1 ! -type d | sed 's|^\./||' | LC_ALL=C sort) || return 1
    [ "$got" = "$want" ] || return 1
    for f in $want; do
        [ -f "$dir/$f" ] && [ ! -L "$dir/$f" ] || return 1
    done
    if [ -n "$_HF_SETUP_LIST" ]; then
        for f in $(_hf_sourced_libs "$dir/setup/install.sh"); do
            _hf_has_line "$f" "$_HF_SETUP_LIST" || return 1
        done
    fi
    if [ -n "$_HF_SETUP_LIST" ]; then
        dirs=$(cd -- "$dir" && find . -mindepth 1 -type d ! -path ./setup ! -path './setup/*') || return 1
    else
        dirs=$(cd -- "$dir" && find . -mindepth 1 -type d) || return 1
    fi
    [ -z "$dirs" ]
}

# <file> <arch>: a 64-bit little-endian ELF executable for that machine.
_hf_elf_ok() {
    local head machine
    head=$(od -An -tx1 -N20 -- "$1" 2>/dev/null | tr -d ' \n') || return 1
    case "$2" in
        linux-x86_64) machine=3e00 ;;
        linux-aarch64) machine=b700 ;;
        *) return 1 ;;
    esac
    [[ $head =~ ^7f454c460201.{20}0[23]00${machine}$ ]]
}

# <dest> <backup dir> <file...>: puts back what the named files replaced in
# dest, or removes them where dest had nothing.
_hf_undo() {
    local dest=$1 old=$2 f rc=0
    shift 2
    for f in "$@"; do
        if [ -e "$old/$f" ] || [ -L "$old/$f" ]; then
            mv -fT -- "$old/$f" "$dest/$f" || rc=1
        else
            rm -rf -- "${dest:?}/$f" || rc=1
        fi
    done
    [ "$rc" = 0 ] || _hf_err "could not put back everything in $dest; check it by hand"
    return "$rc"
}

# <from> <dest> <backup dir>: the binaries first, then the setup's copy, and
# VERSION last, so a marker never names files that did not land; any failure
# puts dest back.
_hf_land() {
    local from=$1 dest=$2 old=$3 f
    local -a landed=() names=(hollow-relay hollow-forwarder)
    if [ -d "$from/setup" ]; then
        if [ -e "$dest/setup" ] || [ -L "$dest/setup" ]; then
            _hf_err "$dest already holds a setup entry, so nothing was replaced"
            return 1
        fi
        names+=(setup)
    fi
    names+=(VERSION)
    mkdir -- "$old" || return 1
    for f in "${names[@]}"; do
        if [ "$f" != setup ] && { [ -f "$dest/$f" ] || [ -L "$dest/$f" ]; } \
            && ! ln -P -- "$dest/$f" "$old/$f" 2>/dev/null && ! cp -P -p -- "$dest/$f" "$old/$f"; then
            _hf_err "cannot keep a copy of $dest/$f, so nothing was replaced"
            _hf_undo "$dest" "$old" ${landed[@]+"${landed[@]}"}
            return 1
        fi
        if ! mv -fT -- "$from/$f" "$dest/$f"; then
            _hf_err "cannot move $f into $dest, so nothing was replaced"
            rm -f -- "$old/$f"
            _hf_undo "$dest" "$old" ${landed[@]+"${landed[@]}"}
            return 1
        fi
        landed+=("$f")
    done
}

_hf_fetch_in() {
    local dest=$1 work=$2 base
    base=$(_hf_base)
    _hf_get "$base/${_HF_U##*/}" "$work/relay.tar.gz" "$_HF_S" 1800 || return 1
    if [ "$(_hf_size "$work/relay.tar.gz")" != "$_HF_S" ]; then
        _hf_err "the relay download has the wrong size, refusing it"
        return 1
    fi
    if [ "$(sha256sum -- "$work/relay.tar.gz" | cut -d' ' -f1)" != "$_HF_H" ]; then
        _hf_err "the relay download does not match its sha256 in the signed list, refusing it"
        return 1
    fi
    if ! _hf_tar_listing_ok "$work/relay.tar.gz"; then
        _hf_err "the relay download holds something other than the expected files, refusing it"
        return 1
    fi
    mkdir -- "$work/x" || return 1
    # Only the members the listing named and checked; their names hold no
    # spaces or wildcards.
    # shellcheck disable=SC2086
    if ! tar -xzf "$work/relay.tar.gz" -C "$work/x" --no-same-owner --no-same-permissions -- $_HF_FILES $_HF_SETUP_LIST \
        || ! _hf_extracted_ok "$work/x"; then
        _hf_err "the relay download did not unpack to the expected files, refusing it"
        return 1
    fi
    if ! _hf_elf_ok "$work/x/hollow-relay" "$_HF_A" || ! _hf_elf_ok "$work/x/hollow-forwarder" "$_HF_A"; then
        _hf_err "the relay download is not built for $_HF_A, refusing it"
        return 1
    fi
    if ! printf 'version=%s\nbuild=%s\ncommit=%s\n' "$_HF_V" "$_HF_B" "$_HF_C" | cmp -s - "$work/x/VERSION"; then
        _hf_err "the relay download's VERSION does not match the signed list, refusing it"
        return 1
    fi
    chmod 0755 "$work/x/hollow-relay" "$work/x/hollow-forwarder" && chmod 0644 "$work/x/VERSION" || return 1
    if [ -n "$_HF_SETUP_LIST" ]; then
        chmod -R u=rwX,go=rX -- "$work/x/setup" || return 1
    fi
    _hf_land "$work/x" "$dest" "$work/old"
}

hollow_feed_fetch() {
    local dest=${1:-} work rc=0
    if [ "${_HF_OK:-}" != 1 ]; then
        _hf_err "run hollow_feed_check successfully before hollow_feed_fetch"
        return 1
    fi
    if [ -z "$dest" ] || [ ! -d "$dest" ] || [ -L "$dest" ]; then
        _hf_err "usage: hollow_feed_fetch <existing folder>"
        return 2
    fi
    _hf_need curl sha256sum tar gzip od cmp head tail wc sed || return 1
    # Inside dest, so the final moves are renames on one filesystem.
    work=$(mktemp -d "$dest/.hollow-feed.XXXXXX") || { _hf_err "cannot make a temporary folder in $dest"; return 1; }
    _hf_fetch_in "$dest" "$work" || rc=1
    rm -rf -- "$work"
    return "$rc"
}

# <state dir>, under its lock: raises the mark to the checked feed's issued.
_hf_raise_mark() {
    local state=$1 file="$1/$_HF_STATE_FILE" tmp accepted
    accepted=$(_hf_accepted_issued "$state") || return 1
    [ "$_HF_I" -gt "$accepted" ] || return 0
    tmp=$(mktemp "$state/.$_HF_STATE_FILE.XXXXXX") || { _hf_err "cannot write in $state"; return 1; }
    # mktemp makes it owner-only (0600).
    if ! printf '%s\n' "$_HF_I" > "$tmp" || ! mv -fT -- "$tmp" "$file"; then
        rm -f -- "$tmp"
        _hf_err "cannot record the accepted relay update list in $file"
        return 1
    fi
}

hollow_feed_accept() {
    local state=${1:-} fd rc=0
    if [ "${_HF_OK:-}" != 1 ]; then
        _hf_err "run hollow_feed_check successfully before hollow_feed_accept"
        return 1
    fi
    if [ -z "$state" ]; then
        _hf_err "usage: hollow_feed_accept <state_dir>"
        return 2
    fi
    _hf_need flock || return 1
    # shellcheck disable=SC2174 # only the last folder is the lib's own
    mkdir -p -m 0700 -- "$state" || { _hf_err "cannot create $state"; return 1; }
    # Two runs at once must not let the lower stamp land last.
    exec {fd}< "$state" || { _hf_err "cannot open $state"; return 1; }
    if ! flock -x -w 120 "$fd"; then
        exec {fd}<&-
        _hf_err "another relay update is using $state; try again when it is done"
        return 1
    fi
    _hf_raise_mark "$state" || rc=1
    exec {fd}<&-
    return "$rc"
}

# <installed version> <installed build>: 0 when the checked feed is newer,
# 1 when it is not, 2 on bad input.
hollow_feed_newer() {
    local ver=${1:-} bld=${2:-}
    if [ "${_HF_OK:-}" != 1 ]; then
        _hf_err "run hollow_feed_check successfully before hollow_feed_newer"
        return 2
    fi
    if ! _hf_version_ok "$ver" || ! _hf_build_ok "$bld"; then
        _hf_err "usage: hollow_feed_newer <x.y.z> <build>"
        return 2
    fi
    _hf_older "$ver" "$bld" "$_HF_V" "$_HF_B"
}

# <VERSION file>: the marker a tarball carries (version=x.y.z, build=n,
# commit=<sha>), or one a source build writes without the commit line.
hollow_feed_installed() {
    local file=${1:-} v b c
    unset INSTALLED_VERSION INSTALLED_BUILD INSTALLED_COMMIT
    if [ -z "$file" ] || [ ! -f "$file" ]; then
        _hf_err "no relay version marker at ${file:-<none>}"
        return 1
    fi
    v=$(sed -n '1s/^version=//p' -- "$file") || return 1
    b=$(sed -n '2s/^build=//p' -- "$file") || return 1
    c=$(sed -n '3s/^commit=//p' -- "$file") || return 1
    if ! _hf_version_ok "$v" || ! _hf_build_ok "$b" \
        || { [ -n "$c" ] && ! [[ $c =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; } \
        || ! { if [ -n "$c" ]; then printf 'version=%s\nbuild=%s\ncommit=%s\n' "$v" "$b" "$c"; else
            printf 'version=%s\nbuild=%s\n' "$v" "$b"; fi; } | cmp -s - "$file"; then
        _hf_err "$file is not a relay version marker"
        return 1
    fi
    INSTALLED_VERSION=$v
    INSTALLED_BUILD=$((10#$b))
    INSTALLED_COMMIT=$c
}
