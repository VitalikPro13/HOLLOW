#!/bin/bash
# The full setup: every service under systemd, each as its own account in its
# own sandbox, the layout of the official relay. Sourced by install.sh.
#
# native_apply is idempotent: it reads the CFG_* answers, compares each file
# with what is already there, and restarts only what changed. A re-run after a
# failure, a settings change and a first install all go through it.

LIB_DIR=/usr/local/lib/hollow-relay
INSTALLER_COPY=$LIB_DIR/installer
# VERSION is the marker the release tarball carries (version=, build=);
# BUILT_FROM says whether it came from the signed feed or a build here.
VERSION_FILE=$LIB_DIR/VERSION
BUILT_FROM_FILE=$LIB_DIR/BUILT_FROM
PREVIOUS_DIR=$LIB_DIR/previous
STATE_DIR=/var/lib/hollow-installer
BUILD_DIR=/var/cache/hollow-build
BUILD_SWAP=$STATE_DIR/build.swap
BACKUP_DIR=/root/hollow-relay-backup
RELAY_ETC=/etc/hollow-relay
TURN_ETC=/etc/hollow-turn
PUSH_ETC=/etc/hollow-push
FWD_ETC=/etc/hollow-forwarder
DDNS_ETC=/etc/hollow-duckdns
PUSH_DIR=/opt/hollow-push
UNIT_DIR=/etc/systemd/system
CERT_HOOK=/etc/letsencrypt/renewal-hooks/deploy/hollow-relay.sh
CERT_RENEWAL=/etc/letsencrypt/renewal/relay.conf
CERT_RENEWAL_OFF=/etc/letsencrypt/renewal/relay.conf.hollow-off
FWD_PORTS="40000:40199"

# What the prebuilt programs and the feed check need at run time, proven on
# bare Ubuntu 22.04 and 24.04 and Debian 12 and 13 images.
RUNTIME_PACKAGES="openssl libsodium23 zlib1g ca-certificates curl jq"

# What a build never reads: the submodules' fuzzing corpora and the TLS and
# QUIC libraries uSockets can bundle, over a gigabyte together.
SOURCE_EXCLUDES=(--exclude=.git --exclude='rust/*/target' --exclude=node_modules --exclude=relay-uws/build
    --exclude=relay-uws/uWebSockets/fuzzing --exclude=relay-uws/uWebSockets/uSockets
    --exclude=relay-uws/uSockets/boringssl --exclude=relay-uws/uSockets/lsquic
    --exclude=rust/hollow_core/.cargo)

RESTART_UNITS=()
mark_restart() {
    local u
    for u in "${RESTART_UNITS[@]}"; do [ "$u" = "$1" ] && return 0; done
    RESTART_UNITS+=("$1")
}

# ---------------------------------------------------------------- programs

installed_version() { kv_get "$VERSION_FILE" version; }
installed_build() { kv_get "$VERSION_FILE" build; }
installed_source() { [ -r "$BUILT_FROM_FILE" ] && head -n 1 "$BUILT_FROM_FILE"; return 0; }

# install_programs <dir> <prebuilt|source>: the dir holds the programs and
# their VERSION marker. The pair it replaces is kept in previous/, so a failed
# update can go back to it.
install_programs() {
    local dir=$1 f
    # An update that an earlier run started already kept the pair it replaces.
    if [ "$DRY_RUN" = 0 ] && [ -x /usr/local/bin/hollow-relay ] && ! update_kept programs; then
        install -d -m 0755 "$PREVIOUS_DIR"
        rm -f -- "$PREVIOUS_DIR/hollow-relay" "$PREVIOUS_DIR/hollow-forwarder" "$PREVIOUS_DIR/VERSION" "$PREVIOUS_DIR/BUILT_FROM"
        for f in /usr/local/bin/hollow-relay /usr/local/bin/hollow-forwarder "$VERSION_FILE" "$BUILT_FROM_FILE"; do
            [ -e "$f" ] && cp -p "$f" "$PREVIOUS_DIR/"
        done
        if update_pending; then update_mark_add programs; fi
    fi
    for f in hollow-relay hollow-forwarder; do
        [ -f "$dir/$f" ] || continue
        if [ "$DRY_RUN" = 1 ]; then
            say "  would install: /usr/local/bin/$f"
            continue
        fi
        install -m 0755 -o root -g root "$dir/$f" "/usr/local/bin/$f.new"
        mv -f "/usr/local/bin/$f.new" "/usr/local/bin/$f"
    done
    put_file "$VERSION_FILE" 0644 root root <"$dir/VERSION"
    printf '%s\n' "$2" | put_file "$BUILT_FROM_FILE" 0644 root root
    mark_restart hollow-relay
    [ "$CFG_FORWARDER" = yes ] && mark_restart hollow-forwarder
    return 0
}

# Puts back the pair install_programs kept. Returns 1 when there is none.
restore_previous_programs() {
    local f
    [ -x "$PREVIOUS_DIR/hollow-relay" ] || return 1
    for f in hollow-relay hollow-forwarder; do
        [ -f "$PREVIOUS_DIR/$f" ] || continue
        install -m 0755 -o root -g root "$PREVIOUS_DIR/$f" "/usr/local/bin/$f.new"
        mv -f "/usr/local/bin/$f.new" "/usr/local/bin/$f"
    done
    [ -f "$PREVIOUS_DIR/VERSION" ] && cp -p "$PREVIOUS_DIR/VERSION" "$VERSION_FILE"
    [ -f "$PREVIOUS_DIR/BUILT_FROM" ] && cp -p "$PREVIOUS_DIR/BUILT_FROM" "$BUILT_FROM_FILE"
    return 0
}

programs_present() {
    [ -x /usr/local/bin/hollow-relay ] || return 1
    [ "$CFG_FORWARDER" != yes ] || [ -x /usr/local/bin/hollow-forwarder ] || return 1
    [ -r "$VERSION_FILE" ]
}

feed_lib_present() { [ -r "$DEPLOY/lib/release_feed.sh" ]; }

# Sourced once, so a test can replace the lib's functions after loading it.
FEED_LIB_LOADED=0
feed_lib_load() {
    [ "$FEED_LIB_LOADED" = 1 ] && return 0
    # shellcheck source=/dev/null
    . "$DEPLOY/lib/release_feed.sh"
    FEED_LIB_LOADED=1
}


programs_prebuilt() {
    feed_lib_present || die "this copy of the installer has no release feed helper (deploy/lib/release_feed.sh), so it cannot fetch the ready-made programs. Update your copy of the repository, or choose to build from source."
    step "Fetching the ready-made relay programs"
    apt_install curl openssl jq tar gzip ca-certificates
    if [ "$DRY_RUN" = 1 ]; then
        say "  would check the signed release feed, download the programs for $(uname -m), check their SHA-256 and install them"
        return 0
    fi
    local check=()
    [ -n "${EXPECT_VERSION:-}" ] && check=("$VERSION_FILE")
    if [ "${DOWNGRADE:-0}" = 1 ] || [ "${FINISH_PENDING:-0}" = 1 ]; then check=("$VERSION_FILE" allow-downgrade); fi
    if ! prebuilt_available "${check[@]}"; then
        # No build for this machine (a 32-bit system, or no aarch64 build yet):
        # the sources can still make one.
        case "$PREBUILT_WHY" in
        *"no prebuilt relay"*|*"no relay build for"*|*"build it from source"*)
            # An update installs the release it named or nothing, and a build
            # here would run without the snapshot its rollback needs.
            [ "${UPDATE_RUNNING:-0}" = 1 ] && die "the release list has no programs for this machine now ($PREBUILT_WHY). Nothing was installed."
            say "  there are no ready-made programs for this machine ($PREBUILT_WHY), so I build them from source instead"
            CFG_BINARIES=source
            programs_source
            return 0 ;;
        esac
        die "the release list could not be checked, so nothing was installed ($PREBUILT_WHY)."
    fi
    [ "$FEED_CHECKED" = 1 ] || die "the release list could not be checked, so nothing was installed."
    # An update installs exactly the release the person confirmed, and only if
    # it is newer than what runs here.
    if [ -n "${EXPECT_VERSION:-}" ]; then
        if [ "$FEED_VERSION" != "$EXPECT_VERSION" ] || [ "$FEED_BUILD" != "$EXPECT_BUILD" ]; then
            die "the release list changed since the status screen (it now names $FEED_VERSION build $FEED_BUILD). Nothing was installed. Run the setup again to see the new one."
        fi
        if [ "${DOWNGRADE:-0}" != 1 ] && [ "${FINISH_PENDING:-0}" != 1 ] && { ! hollow_feed_installed "$VERSION_FILE" 2>/dev/null ||
           ! hollow_feed_newer "$INSTALLED_VERSION" "$INSTALLED_BUILD"; }; then
            die "version $FEED_VERSION build $FEED_BUILD is not newer than the one installed here. Nothing was installed."
        fi
    fi
    local dl
    ensure_dir "$STATE_DIR" 0700 root root
    dl=$(mktemp -d "$STATE_DIR/download.XXXXXX")
    say "  downloading version $FEED_VERSION ($(( ${FEED_SIZE:-0} / 1048576 )) MB)"
    run_logged hollow_feed_fetch "$dl" || { rm -rf "$dl"; die "the download did not pass its checks. Nothing was installed."; }
    # An update also brings the setup's copy the release carries, checked by
    # the same signature; a first install keeps the copy it runs from, and a
    # downgrade keeps the newer setup.
    local staged=0
    if [ "${SETUP_FROM_RELEASE:-0}" = 1 ]; then
        if [ ! -d "$dl/setup" ]; then
            SETUP_CHANGE=absent
        elif setup_copy_stage "$dl/setup" release "$FEED_VERSION" "$FEED_BUILD" "$FEED_COMMIT"; then
            staged=1
        else
            rm -rf "$dl"
            die "the copy of the setup in this release is not complete or does not start. Nothing was installed."
        fi
    fi
    if [ "${UPDATE_RUNNING:-0}" = 1 ] && ! update_begin; then
        rm -rf "$dl" "$SETUP_NEW"
        die "the settings as they are could not be kept for a rollback. Nothing was installed."
    fi
    install_programs "$dl" prebuilt
    rm -rf "$dl"
    if [ "$staged" = 1 ]; then
        if [ "${FINISH_PENDING:-0}" = 1 ] && setup_copy_is "$FEED_VERSION" "$FEED_BUILD"; then
            # An earlier run of this update already put this setup in place,
            # so SETUP_KEPT holds the copy from before it.
            rm -rf -- "$SETUP_NEW"
            update_kept setup || update_mark_add setup
        elif update_kept setup && [ -f "$SETUP_KEPT/install.sh" ]; then
            # The copy from before an unfinished update is kept already; the
            # live one is that update's and goes.
            setup_copy_swap || die "the new copy of the setup could not be put in place. Run the setup again to finish the update."
        else
            setup_copy_swap "$SETUP_KEPT" || die "the new copy of the setup could not be put in place. Run the setup again to finish the update."
        fi
        SETUP_CHANGE=replaced
    fi
    hollow_feed_accept "$STATE_DIR"
    say "  installed version $FEED_VERSION (build $FEED_BUILD), signature and checksum verified"
}

# update_begin: the release's parts are about to change. The mark names it,
# and the settings are kept as they are, unless an earlier run of this update
# kept them already.
update_begin() {
    update_mark "$FEED_VERSION" "$FEED_BUILD" "$( [ "${SETUP_FROM_RELEASE:-0}" = 1 ] && echo release || echo keep)" || return 1
    update_kept settings && return 0
    update_settings_keep || return 1
    update_mark_add settings
}

# setup_copy_is <version> <build>: the live copy came with that release.
setup_copy_is() {
    local stamp=$INSTALLER_COPY/$SETUP_SOURCE
    [ "$(kv_get "$stamp" kind)" = release ] && [ "$(kv_get "$stamp" version)" = "$1" ] && [ "$(kv_get "$stamp" build)" = "$2" ]
}

# Memory plus the swap that is on right now, in MB.
mem_and_swap_mb() {
    local s
    s=$(swapon --show=SIZE --bytes --noheadings 2>/dev/null | awk '{t += $1} END {print int(t / 1048576)}' || true)
    echo $(( $(mem_mb) + ${s:-0} ))
}

# The swap files harden-host.sh turned off (commented out in /etc/fstab).
BUILD_SWAP_REUSED=()
build_swap_on() {
    local want_mb=$1 have free f
    have=$(mem_and_swap_mb)
    [ "$have" -ge "$want_mb" ] && return 0
    # A swap file the machine came with is used first, so the build needs no
    # new space on the disk.
    for f in $(sed -n 's/^#[[:space:]]*\(\/[^[:space:]]*\)[[:space:]].*[[:space:]]swap[[:space:]].*/\1/p' /etc/fstab); do
        [ -f "$f" ] || continue
        swapon --show=NAME --noheadings 2>/dev/null | grep -xF "$f" >/dev/null && continue
        if swapon "$f" 2>/dev/null; then
            BUILD_SWAP_REUSED+=("$f")
            say "  turned the machine's own swap file $f on for the build. It goes off again as soon as the build ends."
        fi
    done
    have=$(mem_and_swap_mb)
    [ "$have" -ge "$want_mb" ] && return 0
    swapon --show=NAME --noheadings 2>/dev/null | grep -xF "$BUILD_SWAP" >/dev/null && return 0
    free=$(disk_free_mb /var/lib)
    local size=$((want_mb - have + 512))
    [ "$free" -gt $((size + 4096)) ] || die "the build needs about $((size / 1024 + 1)) GB of temporary swap and 4 GB of build space, and the disk has $((free / 1024)) GB free. The ready-made programs need neither."
    say "  this machine has $have MB of memory and swap, so the build gets a temporary swap file of $size MB. It is removed as soon as the build ends."
    run ensure_dir "$STATE_DIR" 0700 root root
    run fallocate -l "${size}M" "$BUILD_SWAP"
    run chmod 0600 "$BUILD_SWAP"
    run_logged mkswap "$BUILD_SWAP"
    run swapon "$BUILD_SWAP"
}

# Also called from the exit trap: a failed build must not leave swap behind,
# since the hardening promises none.
build_swap_off() {
    local f
    # Zeroed after use, or what was paged out during the build stays on the
    # disk. The machine's own swap files get their swap header back.
    for f in "${BUILD_SWAP_REUSED[@]}"; do
        swapoff "$f" >/dev/null 2>&1 || continue
        shred -z -n 0 "$f" >/dev/null 2>&1 && mkswap "$f" >/dev/null 2>&1 || true
    done
    BUILD_SWAP_REUSED=()
    if [ -e "$BUILD_SWAP" ]; then
        swapoff "$BUILD_SWAP" >/dev/null 2>&1 || true
        shred -z -n 0 "$BUILD_SWAP" >/dev/null 2>&1 || true
        rm -f "$BUILD_SWAP"
    fi
}

# Builds run as their own account, never as root, in a copy of the sources.
BUILD_USER=hollow-build

# Each build step is a transient unit: when it ends, systemd ends every
# process it started, so nothing of the build's can change $BUILD_DIR while
# root reads from it.
as_builder() {
    systemd-run --quiet --wait --pipe --collect \
        -p User="$BUILD_USER" -p Group="$BUILD_USER" -p WorkingDirectory="$BUILD_DIR" \
        -p NoNewPrivileges=yes -p ProtectSystem=strict -p ReadWritePaths="$BUILD_DIR" \
        -p ProtectHome=yes -p PrivateTmp=yes -p LimitCORE=0 \
        -E PATH="$BUILD_DIR/cargo/bin:/usr/local/bin:/usr/bin:/bin" -E HOME="$BUILD_DIR" \
        -E RUSTUP_HOME="$BUILD_DIR/rustup" -E CARGO_HOME="$BUILD_DIR/cargo" \
        -E CARGO_TARGET_DIR="$BUILD_DIR/target" -E CARGO_PROFILE_RELEASE_DEBUG=false \
        "$@" </dev/null
}

# account_idle <account>: ends anything still running as a service or build
# account before root reads or writes the files it owns.
account_idle() {
    have pkill || return 0
    pkill -KILL -u "$1" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -u "$1" >/dev/null 2>&1 || return 0
        sleep 1
    done
    die "processes of the account $1 keep running, so I did not touch its files."
}

builder_idle() { account_idle "$BUILD_USER"; }

# plain_file <path> <owner>: a regular file of <owner>'s with one name and no
# link anywhere on its path, so root reading it reads that file and no other.
plain_file() {
    local real
    real=$(readlink -f -- "$1" 2>/dev/null) || return 1
    [ "$real" = "$1" ] && [ ! -L "$1" ] && [ -f "$1" ] &&
        [ "$(stat -c '%U %h' -- "$1" 2>/dev/null)" = "$2 1" ]
}

# stage_build_output <file under $BUILD_DIR> <root's staging dir>: the build
# cannot point root at another file.
stage_build_output() {
    plain_file "$1" "$BUILD_USER" ||
        die "the build left $1 as something other than a plain file of its own, so I installed nothing."
    install -m 0755 -o root -g root -- "$1" "$2/$(basename -- "$1")"
}

# restore_state <state dir> <account> <file...>: puts back what an uninstall
# kept, needing the first file. Only into a state directory that does not
# exist yet, made by root before any process of the account runs.
restore_state() {
    local dir=$1 acct=$2 f
    shift 2
    [ "$DRY_RUN" = 0 ] && [ ! -e "$dir" ] && [ ! -L "$dir" ] && plain_file "$BACKUP_DIR/$1" root || return 1
    account_idle "$acct"
    install -d -m 0700 -o root -g root "$dir"
    for f in "$@"; do
        plain_file "$BACKUP_DIR/$f" root || continue
        install -m 0600 -o "$acct" -g "$acct" "$BACKUP_DIR/$f" "$dir/$f"
    done
    chown "$acct:$acct" "$dir"
}

rust_toolchain() {
    [ -x "$BUILD_DIR/cargo/bin/cargo" ] && return 0
    local triple url dl dir
    triple="$(uname -m)-unknown-linux-gnu"
    url="https://static.rust-lang.org/rustup/dist/$triple/rustup-init"
    # Fetched and checked where only root can write, then handed over.
    dl=$(mktemp -d "$STATE_DIR/rustup.XXXXXX")
    curl -fsSL --proto '=https' -o "$dl/rustup-init" "$url" || { rm -rf "$dl"; die "could not download the Rust installer."; }
    curl -fsSL --proto '=https' -o "$dl/rustup-init.sha256" "$url.sha256" || { rm -rf "$dl"; die "could not download the Rust installer's checksum."; }
    (cd "$dl" && echo "$(cut -d' ' -f1 rustup-init.sha256)  rustup-init" | sha256sum -c --quiet) ||
        { rm -rf "$dl"; die "the Rust installer did not match its checksum."; }
    builder_idle
    dir=$(mktemp -d "$BUILD_DIR/rustup-init.XXXXXX")
    install -m 0755 -o "$BUILD_USER" -g "$BUILD_USER" "$dl/rustup-init" "$dir/rustup-init"
    rm -rf "$dl"
    chown "$BUILD_USER:$BUILD_USER" "$dir"
    as_builder "$dir/rustup-init" -y --no-modify-path --profile minimal --default-toolchain stable >/dev/null ||
        die "could not install Rust for the build."
    builder_idle
    rm -rf "$dir"
}

relay_source_version() {
    sed -n 's/^#define HOLLOW_RELAY_VERSION "\(.*\)"/\1/p' "$1/relay-uws/src/version.h"
}

# The commit checked out in the copy of the repository at <dir>, or nothing.
source_commit() {
    local c
    have git || return 0
    c=$(git -c safe.directory="$1" -C "$1" rev-parse --verify -q HEAD 2>/dev/null) || return 0
    [[ "$c" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] && printf '%s' "$c"
    return 0
}

# The VERSION marker for a build of <dir>: the release marker's shape, with the
# commit when the copy is a git clone.
source_version_marker() {
    local c
    c=$(source_commit "$1")
    printf 'version=%s\nbuild=0\n' "$(relay_source_version "$1")"
    [ -n "$c" ] && printf 'commit=%s\n' "$c"
    return 0
}

programs_source() {
    local src=$REPO
    [ -f "$src/relay-uws/src/main.cpp" ] || die "this copy of the installer has no relay sources next to it. Run install.sh from your clone of the repository to build from source."
    if [ ! -f "$src/relay-uws/uWebSockets/src/App.h" ] || [ ! -f "$src/relay-uws/uSockets/Makefile" ]; then
        die "the relay's submodules are missing. Run: git submodule update --init --recursive, in your copy of the repository."
    fi
    if [ "$CFG_FORWARDER" = yes ]; then
        [ -f "$src/rust/hollow_core/Cargo.toml" ] || die "the forwarder's sources (rust/hollow_core) are missing from this copy."
    fi
    step "Building the relay from source"
    apt_install build-essential cmake pkg-config libssl-dev libsodium-dev zlib1g-dev perl curl ca-certificates
    ensure_account "$BUILD_USER"
    if [ "$DRY_RUN" = 1 ]; then
        say "  would copy the sources to $BUILD_DIR and build them there as the account $BUILD_USER"
        [ "$CFG_FORWARDER" = yes ] && say "  would install Rust for $BUILD_USER and build the forwarder, with a temporary swap file if memory is short"
        return 0
    fi
    ensure_dir "$STATE_DIR" 0700 root root
    install -d -m 0750 -o "$BUILD_USER" -g "$BUILD_USER" "$BUILD_DIR"
    builder_idle
    rm -rf "$BUILD_DIR/src" "$BUILD_DIR/out" "$BUILD_DIR/relay-build"
    install -d -m 0750 -o root -g root "$BUILD_DIR/src"
    local parts=(relay-uws/CMakeLists.txt relay-uws/src relay-uws/uWebSockets relay-uws/uSockets)
    [ "$CFG_FORWARDER" = yes ] && parts+=(rust/hollow_core rust/hollow_dfn)
    tar -C "$src" "${SOURCE_EXCLUDES[@]}" -cf - "${parts[@]}" | tar -C "$BUILD_DIR/src" -xf -
    chown -R "$BUILD_USER:$BUILD_USER" "$BUILD_DIR/src"
    local stage
    stage=$(mktemp -d "$STATE_DIR/stage.XXXXXX")

    local t0 t1
    t0=$(date +%s)
    build_swap_on 1500
    say "  compiling the relay. This takes a few minutes."
    run_logged as_builder cmake -S "$BUILD_DIR/src/relay-uws" -B "$BUILD_DIR/relay-build" -DCMAKE_BUILD_TYPE=Release ||
        die "the relay's build could not be set up."
    run_logged as_builder cmake --build "$BUILD_DIR/relay-build" -j"$(nproc)" || die "the relay did not build."
    builder_idle
    stage_build_output "$BUILD_DIR/relay-build/hollow-relay" "$stage"
    t1=$(date +%s)
    say "  the relay built in $(( (t1 - t0) / 60 )) min $(( (t1 - t0) % 60 )) s"

    if [ "$CFG_FORWARDER" = yes ]; then
        t0=$(date +%s)
        build_swap_on 4096
        say "  installing Rust for the build account"
        rust_toolchain
        say "  compiling the media forwarder. On a small machine this takes up to an hour or two. It is the whole Hollow core library."
        local timer=()
        [ -x /usr/bin/time ] && timer=(/usr/bin/time -f "peak memory %M KB")
        # A path, because systemd-run looks a bare name up in root's PATH.
        run_logged as_builder "${timer[@]}" "$BUILD_DIR/cargo/bin/cargo" build --release --locked --features forwarder --bin hollow-forwarder \
            --manifest-path "$BUILD_DIR/src/rust/hollow_core/Cargo.toml" || die "the forwarder did not build."
        [ ${#timer[@]} -gt 0 ] && say "  $(grep 'peak memory' "$WORK_DIR/cmd.log" | tail -n 1)"
        builder_idle
        stage_build_output "$BUILD_DIR/target/release/hollow-forwarder" "$stage"
        t1=$(date +%s)
        say "  the forwarder built in $(( (t1 - t0) / 60 )) min $(( (t1 - t0) % 60 )) s"
    fi
    build_swap_off
    source_version_marker "$src" >"$stage/VERSION"
    install_programs "$stage" source
    rm -rf "$stage" "$BUILD_DIR/src" "$BUILD_DIR/relay-build"
}

ensure_programs() {
    if [ "${FORCE_PROGRAMS:-0}" = 0 ] && programs_present &&
       [ "$(installed_source)" = "$CFG_BINARIES" ]; then
        say "  the relay programs are already installed, version $(installed_version)"
        return 0
    fi
    if [ "$CFG_BINARIES" = source ]; then programs_source; else programs_prebuilt; fi
}

runtime_packages() {
    # shellcheck disable=SC2086 # one word per package
    apt_install $RUNTIME_PACKAGES
}

# The feed helper warns when its test settings are on; the person must see it.
feed_show_warnings() {
    [ -r "$WORK_DIR/feed.err" ] || return 0
    if grep -q 'TEST MODE' "$WORK_DIR/feed.err"; then
        warn "$(grep 'TEST MODE' "$WORK_DIR/feed.err" | head -n 1 | sed 's/^Hollow relay update: //')"
    fi
    return 0
}

# Whether the signed feed has programs for this machine. Sets PREBUILT_WHY to
# the reason when it has none.
PREBUILT_WHY=""
# prebuilt_available [<installed VERSION file> [allow-downgrade]]
prebuilt_available() {
    local vfile=${1:-} force=${2:-} err
    PREBUILT_WHY="" PREBUILT_RC=0 FEED_CHECKED=0
    if ! feed_lib_present; then
        PREBUILT_WHY="this copy of the installer has no release feed helper"
        return 1
    fi
    feed_lib_load
    if ! err=$(hollow_feed_arch 2>&1 >/dev/null); then
        PREBUILT_WHY=${err#Hollow relay update: }
        return 1
    fi
    # A fresh machine may not have the check's tools yet; the install step
    # checks again once it has them.
    if ! have jq || ! have curl || ! have openssl; then return 0; fi
    ensure_dir "$STATE_DIR" 0700 root root
    # In this shell, never in $(...): the check's results live in variables.
    if [ -n "$force" ]; then
        hollow_feed_check "$STATE_DIR" "$vfile" "$force" 2>"$WORK_DIR/feed.err" || PREBUILT_RC=$?
    elif [ -n "$vfile" ]; then
        hollow_feed_check "$STATE_DIR" "$vfile" 2>"$WORK_DIR/feed.err" || PREBUILT_RC=$?
    else
        hollow_feed_check "$STATE_DIR" 2>"$WORK_DIR/feed.err" || PREBUILT_RC=$?
    fi
    feed_show_warnings
    if [ "$PREBUILT_RC" != 0 ]; then
        err=$(grep -v 'TEST MODE' "$WORK_DIR/feed.err" | tail -n 1 || true)
        PREBUILT_WHY=${err#Hollow relay update: }
        PREBUILT_WHY=${PREBUILT_WHY:-the release list could not be checked}
        return 1
    fi
    FEED_CHECKED=1
}

# ---------------------------------------------------------------- installer copy

# The push sender's files the copy keeps; scripts/build_relay_binaries.sh packs
# the same list into the release.
SETUP_PUSH_FILES="index.js fcm.js unifiedpush.js package.json package-lock.json hollow-push.service"
# A copy is filled in SETUP_STAGE, which nothing ever runs, and moves to
# SETUP_NEW only once it passed its checks; a swap cut short finishes from there.
SETUP_STAGE=$INSTALLER_COPY.stage
SETUP_NEW=$INSTALLER_COPY.new
SETUP_KEPT=$PREVIOUS_DIR/installer
SETUP_LINK=/usr/local/sbin/hollow-relay-setup
# Where a copy came from: a release (version, build, commit) or a clone.
SETUP_SOURCE=SOURCE
# What a copy's install.sh --self-check prints. A copy that cannot print it
# cannot carry out an update's last step, so it never goes live.
SETUP_PROTOCOL="hollow-relay-setup self-check 1: after-update"
# What this run did to the copy: kept, replaced (the old one is in SETUP_KEPT),
# absent, failed or none.
SETUP_CHANGE=none

# The paths the copy moves through, none of them a link, so nothing is ever
# written or moved through one.
setup_paths_plain() {
    local p
    for p in "$LIB_DIR" "$INSTALLER_COPY" "$SETUP_STAGE" "$SETUP_NEW" "$PREVIOUS_DIR" "$SETUP_KEPT"; do
        if [ -L "$p" ]; then
            warn "$p is a link, so I leave the setup's copy as it is."
            return 1
        fi
    done
}

# setup_needs <dir>: what a copy must hold, one path per line: what the next
# update reads, and every library its install.sh sources. The signer and
# release_feed.sh refuse a release without them (SETUP_NEEDS, sourced_libs).
setup_needs() {
    printf '%s\n' install.sh deploy/lib/release_feed.sh push-sidecar/package-lock.json push-sidecar/package.json \
        deploy/coturn-port-lock.conf deploy/hollow-turn-port-lock-refresh.service deploy/hollow-turn-port-lock-refresh.timer deploy/hollow-turn-port-lock.service deploy/turn-port-lock.sh
    sed -n 's|^\. "\$DEPLOY/lib/\([A-Za-z0-9_][A-Za-z0-9_]*\)\.sh"$|deploy/lib/\1.sh|p' -- "$1/install.sh" 2>/dev/null
    return 0
}

# setup_new_check <dir>: owner, modes and contents of a staged copy: plain
# files and folders only, everything it needs, scripts bash can parse, and its
# own install.sh --self-check, which loads every library and changes nothing.
setup_new_check() {
    local dir=$1 f out
    chown -R root:root "$dir" && chmod -R u=rwX,go=rX "$dir" && chmod 0755 "$dir/install.sh" || return 1
    [ -z "$(find "$dir" ! -type f ! -type d)" ] || return 1
    while IFS= read -r f; do
        [ -f "$dir/$f" ] || return 1
    done < <(setup_needs "$dir")
    for f in "$dir/install.sh" "$dir"/deploy/lib/*.sh; do
        bash -n "$f" 2>/dev/null || return 1
    done
    out=$(cd / && env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C bash "$dir/install.sh" --self-check 2>/dev/null) || return 1
    [ "$out" = "$SETUP_PROTOCOL" ]
}

# setup_copy_stage <folder> <release|clone> <version> <build> <commit>: copies
# a setup tree next to the live copy, stamps where it came from and checks it;
# only a copy that passed lands in SETUP_NEW, so the swap is two renames.
setup_copy_stage() {
    local from=$1
    setup_copy_repair || return 1
    rm -rf -- "$SETUP_STAGE" "$SETUP_NEW"
    ensure_dir "$LIB_DIR" 0755 root root
    mkdir -m 0755 -- "$SETUP_STAGE" || return 1
    if ! cp -R -P -- "$from/." "$SETUP_STAGE/" ||
       ! printf 'kind=%s\nversion=%s\nbuild=%s\ncommit=%s\n' "$2" "$3" "$4" "$5" >"$SETUP_STAGE/$SETUP_SOURCE" ||
       ! setup_new_check "$SETUP_STAGE" || ! mv -T -- "$SETUP_STAGE" "$SETUP_NEW"; then
        rm -rf -- "$SETUP_STAGE"
        return 1
    fi
}

# setup_copy_swap [<keep>]: puts SETUP_NEW in place of the live copy. The old
# copy goes to <keep> for a rollback, or is removed. Between the two renames
# no copy is in place: a failed second rename puts the old one back, and a run
# killed there is finished by setup_copy_repair (and hollow-relay-setup).
setup_copy_swap() {
    local keep=${1:-} old
    setup_paths_plain || return 1
    [ -d "$SETUP_NEW" ] || return 1
    old=${keep:-$INSTALLER_COPY.old}
    rm -rf -- "$old"
    [ -z "$keep" ] || ensure_dir "${keep%/*}" 0755 root root
    if [ -e "$INSTALLER_COPY" ] && ! mv -T -- "$INSTALLER_COPY" "$old"; then
        return 1
    fi
    # Only now is the copy from before an update kept for its rollback.
    if [ -n "$keep" ] && update_pending; then update_mark_add setup || true; fi
    if ! mv -T -- "$SETUP_NEW" "$INSTALLER_COPY"; then
        [ -e "$old" ] && mv -T -- "$old" "$INSTALLER_COPY"
        return 1
    fi
    [ -n "$keep" ] || rm -rf -- "$old"
    setup_launcher_install
}

# A swap killed between its renames left no copy in place: the checked one
# in SETUP_NEW goes live, else the one it replaced. Every run starts with this,
# and deploy/hollow-relay-setup does the same before each start of the units
# that run scripts from the copy.
setup_copy_repair() {
    [ "$DRY_RUN" = 1 ] && return 0
    setup_paths_plain || return 1
    [ -e "$INSTALLER_COPY" ] && return 0
    if [ -f "$SETUP_NEW/install.sh" ]; then
        mv -T -- "$SETUP_NEW" "$INSTALLER_COPY" || return 1
    elif [ -f "$SETUP_KEPT/install.sh" ]; then
        mv -T -- "$SETUP_KEPT" "$INSTALLER_COPY" || return 1
    else
        return 0
    fi
    say "  put the setup's copy back in place after a run that was cut short"
}

# hollow-relay-setup: deploy/hollow-relay-setup, a root-owned script outside
# the copy, so it still runs when a swap left no copy. Lands in one rename,
# which replaces a link left there rather than following it.
setup_launcher_install() {
    local src=$INSTALLER_COPY/deploy/hollow-relay-setup tmp
    install -d -m 0755 "${SETUP_LINK%/*}" || return 1
    # A copy from before the launcher: one already there runs it as well.
    if [ ! -f "$src" ]; then
        [ -e "$SETUP_LINK" ] || ln -sfn "$INSTALLER_COPY/install.sh" "$SETUP_LINK"
        return 0
    fi
    tmp=$(mktemp "$SETUP_LINK.new.XXXXXX") || return 1
    if ! cat -- "$src" >"$tmp" || ! chown root:root "$tmp" || ! chmod 0755 "$tmp" || ! mv -fT -- "$tmp" "$SETUP_LINK"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# Puts back the copy an update replaced. Returns 1 when it replaced none.
setup_copy_rollback() {
    [ "$SETUP_CHANGE" = replaced ] && [ -d "$SETUP_KEPT" ] && [ ! -L "$SETUP_KEPT" ] || return 1
    rm -rf -- "$SETUP_NEW"
    mv -T -- "$SETUP_KEPT" "$SETUP_NEW" || return 1
    setup_copy_swap || return 1
    SETUP_CHANGE=kept
}

# How this run's copy of the repository compares with an installed copy that
# came from a release: newer, same, older or unknown. "free" when the
# installed copy is no release's, or this run is the installed copy.
setup_clone_verdict() {
    local stamp=$INSTALLER_COPY/$SETUP_SOURCE rv rc v c
    if [ "$HERE" = "$INSTALLER_COPY" ] || [ "$(kv_get "$stamp" kind)" != release ]; then
        echo free
        return 0
    fi
    rv=$(kv_get "$stamp" version)
    rc=$(kv_get "$stamp" commit)
    v=$(relay_source_version "$REPO" 2>/dev/null) || v=""
    c=$(source_commit "$REPO")
    if ! [[ $v =~ ^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}$ ]] || ! [[ $rv =~ ^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}$ ]]; then
        echo unknown
    elif version_older "$rv" "$v"; then
        echo newer
    elif version_older "$v" "$rv"; then
        echo older
    elif [ -n "$c" ] && [ "$c" = "$rc" ]; then
        echo same
    else
        echo unknown
    fi
}

# Whether this run may replace the installed copy: always, unless that came
# from a release and this clone is older or cannot tell, when the person said
# so (SETUP_REPLACE_OK, setup_clone_gate in manage.sh).
setup_clone_may_replace() {
    case "$(setup_clone_verdict)" in free | newer | same) return 0 ;; esac
    [ "${SETUP_REPLACE_OK:-0}" = 1 ]
}

# Certbot's renewal timer and the units call scripts from here, so the copy
# outlives the clone the person ran install.sh from.
install_installer_copy() {
    if [ "$HERE" = "$INSTALLER_COPY" ]; then return 0; fi
    if [ "$DRY_RUN" = 1 ]; then
        say "  would copy install.sh and deploy/ to $INSTALLER_COPY"
        return 0
    fi
    if ! setup_clone_may_replace; then
        warn "the setup installed here came with a newer release than this copy of the repository, so I kept it."
        return 0
    fi
    local src f tree=$WORK_DIR/setup-tree
    rm -rf -- "$tree"
    install -d -m 0755 "$tree/push-sidecar"
    cp "$HERE/install.sh" "$tree/"
    cp -R "$HERE/deploy" "$tree/"
    if src=$(push_source_dir); then
        for f in $SETUP_PUSH_FILES; do
            [ -f "$src/$f" ] && cp "$src/$f" "$tree/push-sidecar/"
        done
    fi
    setup_copy_stage "$tree" clone "$(relay_source_version "$REPO" 2>/dev/null)" 0 "$(source_commit "$REPO")" ||
        die "the copy of the setup from $HERE is not complete or does not start, so I left the installed one as it is."
    rm -rf -- "$tree"
    setup_copy_swap || die "the setup's copy could not be put in place."
}

# The push sender's sources: next to the clone, or in the installer's copy.
push_source_dir() {
    if [ -f "$HERE/../push-sidecar/index.js" ]; then
        (cd "$HERE/../push-sidecar" && pwd)
    elif [ -f "$HERE/push-sidecar/index.js" ]; then
        printf '%s' "$HERE/push-sidecar"
    else
        return 1
    fi
}

# ---------------------------------------------------------------- an update's last step

# A menu update runs in three parts: this run fetches the release, keeps what
# it replaces and puts the programs and the setup in place; the new setup then
# applies every setting again (units, configs, the push sender) as a run of
# its own (--after-update); when that fails, this run puts everything back.
# UPDATE_MARK names the release until it is all done, with what is already
# kept for a rollback, so a run cut short is finished (or undone) by the next
# one and never keeps the half it reached.
UPDATE_MARK=$STATE_DIR/update_pending
UPDATE_SNAP=$STATE_DIR/update-snapshot
# What an update's settings run may rewrite.
UPDATE_SNAP_PATHS="$RELAY_ETC $TURN_ETC $PUSH_ETC $FWD_ETC $DDNS_ETC $PUSH_DIR $CERT_HOOK
/usr/local/sbin/hollow-turn-port-lock $UNIT_DIR/hollow-coturn.service.d"

update_pending() { [ -f "$UPDATE_MARK" ]; }

# update_kept <part>: 0 when the update in progress already kept <part>
# (programs, setup, settings) for a rollback.
update_kept() {
    update_pending && [[ " $(kv_get "$UPDATE_MARK" kept) " == *" $1 "* ]]
}

# update_mark <version> <build> <release|keep> [<part kept>]: names the release
# being installed, keeping the parts an earlier run already kept.
update_mark() {
    local kept=""
    update_pending && kept=$(kv_get "$UPDATE_MARK" kept)
    if [ -n "${4:-}" ] && [[ " $kept " != *" $4 "* ]]; then kept="${kept:+$kept }$4"; fi
    ensure_dir "$STATE_DIR" 0700 root root
    printf 'version=%s\nbuild=%s\nsetup=%s\nkept=%s\n' "$1" "$2" "$3" "$kept" | put_file "$UPDATE_MARK" 0600 root root
}

update_mark_add() {
    update_mark "$(kv_get "$UPDATE_MARK" version)" "$(kv_get "$UPDATE_MARK" build)" "$(kv_get "$UPDATE_MARK" setup)" "$1"
}

update_done() {
    rm -rf -- "$UPDATE_SNAP"
    rm -f -- "$UPDATE_MARK"
}

# The units and settings as they are, so a failed update puts them back as
# they were: copies of each path in UPDATE_SNAP_PATHS (or a note that it was
# absent) and of every hollow-* unit, with whether each ran and started on
# boot. Root-only, like the files it copies, and removed once the update is
# done.
update_settings_keep() {
    local p u
    for p in $UPDATE_SNAP_PATHS "$UNIT_DIR"/hollow-*.service "$UNIT_DIR"/hollow-*.timer; do
        if [ -L "$p" ]; then
            warn "$p is a link, so I did not update anything."
            return 1
        fi
    done
    rm -rf -- "$UPDATE_SNAP"
    (umask 077 && mkdir -p -- "$UPDATE_SNAP/tree") || return 1
    : >"$UPDATE_SNAP/absent"
    : >"$UPDATE_SNAP/units"
    for p in $UPDATE_SNAP_PATHS; do
        if [ -e "$p" ]; then
            cp -a --parents -- "$p" "$UPDATE_SNAP/tree" || return 1
        else
            printf '%s\n' "$p" >>"$UPDATE_SNAP/absent"
        fi
    done
    for p in "$UNIT_DIR"/hollow-*.service "$UNIT_DIR"/hollow-*.timer; do
        [ -f "$p" ] || continue
        u=${p##*/}
        cp -a --parents -- "$p" "$UPDATE_SNAP/tree" || return 1
        printf '%s %s %s\n' "$u" "$(unit_active "$u" && echo active || echo inactive)" \
            "$(systemctl is-enabled --quiet "$u" 2>/dev/null && echo enabled || echo disabled)" >>"$UPDATE_SNAP/units"
    done
}

# Puts back what update_settings_keep copied, then the units as they ran:
# units the new setup added are removed, the others restart as they were. The
# relay and the forwarder are left to update_rollback, which restarts them
# once: systemd refuses a unit started too often in a few seconds.
update_settings_restore() {
    local p u active enabled rc=0
    [ -d "$UPDATE_SNAP/tree" ] || return 1
    for p in "$UNIT_DIR"/hollow-*.service "$UNIT_DIR"/hollow-*.timer; do
        [ -e "$p" ] || continue
        u=${p##*/}
        if ! grep -q "^$u " "$UPDATE_SNAP/units"; then
            systemctl disable --now "$u" >/dev/null 2>&1 || true
            rm -f -- "$p"
        fi
    done
    for p in $UPDATE_SNAP_PATHS; do
        if [ -e "$UPDATE_SNAP/tree$p" ]; then
            rm -rf -- "$p" && cp -a -- "$UPDATE_SNAP/tree$p" "$p" || rc=1
        elif grep -qxF -- "$p" "$UPDATE_SNAP/absent"; then
            rm -rf -- "$p" || rc=1
        fi
    done
    while read -r u active enabled; do
        rm -f -- "$UNIT_DIR/$u" && cp -a -- "$UPDATE_SNAP/tree$UNIT_DIR/$u" "$UNIT_DIR/$u" || rc=1
    done <"$UPDATE_SNAP/units"
    # Right after a failed settings run systemd may still be busy; one retry.
    systemctl daemon-reload || { sleep 3; systemctl daemon-reload; } || rc=1
    while read -r u active enabled; do
        if [ "$enabled" = enabled ]; then systemctl enable --quiet "$u" || rc=1
        else systemctl disable --quiet "$u" >/dev/null 2>&1 || true; fi
        case "$u" in hollow-relay.service | hollow-forwarder.service) continue ;; esac
        systemctl reset-failed "$u" >/dev/null 2>&1 || true
        if [ "$active" = active ]; then systemctl restart "$u" || rc=1
        else systemctl stop "$u" >/dev/null 2>&1 || true; fi
    done <"$UPDATE_SNAP/units"
    return "$rc"
}

# ---------------------------------------------------------------- address

duckdns_setup() {
    # A relay taken over keeps its name where it points.
    [ "${ADOPT_KIND:-none}" != none ] || duckdns_point_now
    ensure_account hollow-ddns
    ensure_dir "$DDNS_ETC" 0700 root root
    {
        printf 'DUCKDNS_TOKEN=%s\n' "$CFG_DUCKDNS_TOKEN"
        printf 'RELAY_HOST=%s\n' "$CFG_HOST"
        printf 'DUCKDNS_IP=%s\n' "$CFG_DUCKDNS_IP"
    } | put_file "$DDNS_ETC/duckdns.env" 0600 root root
    put_unit hollow-duckdns.service <"$DEPLOY/hollow-duckdns.service"
    put_unit hollow-duckdns.timer <"$DEPLOY/hollow-duckdns.timer"
    run systemctl daemon-reload
    run systemctl enable --quiet --now hollow-duckdns.timer
}

duckdns_remove() {
    if unit_exists hollow-duckdns.timer; then
        run_ok systemctl disable --now hollow-duckdns.timer
    fi
    run rm -f "$UNIT_DIR/hollow-duckdns.service" "$UNIT_DIR/hollow-duckdns.timer"
    run rm -rf "$DDNS_ETC"
}

# ---------------------------------------------------------------- certificate

# The distribution's certbot for names, which apt installs in seconds. IP
# address certificates need certbot 5.3 or newer: Ubuntu's snap where snapd is
# already there, otherwise a pinned certbot in its own Python environment, so a
# lean Debian box never gains snapd for it.
CERTBOT_DIR=/usr/bin
CERTBOT_VENV=/opt/hollow-certbot
CERTBOT_PIN=5.8.0
certbot_install() {
    if [ -x /snap/bin/certbot ]; then CERTBOT_DIR=/snap/bin; return 0; fi
    if [ -x "$CERTBOT_VENV/bin/certbot" ]; then CERTBOT_DIR=$CERTBOT_VENV/bin; return 0; fi
    if [ "$CFG_ADDRESS" != ip ]; then
        apt_install certbot || die "certbot could not be installed."
        return 0
    fi
    step "Installing certbot $CERTBOT_PIN"
    say "  the distribution's certbot is too old for IP address certificates"
    if have snap; then
        CERTBOT_DIR=/snap/bin
        say "  from snap, which this machine already runs"
        run_logged snap install --classic certbot || die "certbot could not be installed."
    else
        CERTBOT_DIR=$CERTBOT_VENV/bin
        say "  into its own Python environment in $CERTBOT_VENV, with a timer that renews the certificate"
        apt_install python3-venv
        run_logged python3 -m venv "$CERTBOT_VENV" || die "could not make a Python environment for certbot."
        run_logged "$CERTBOT_VENV/bin/pip" install --quiet --disable-pip-version-check "certbot==$CERTBOT_PIN" ||
            die "certbot $CERTBOT_PIN could not be installed."
        put_unit hollow-certbot-renew.service <"$DEPLOY/hollow-certbot-renew.service"
        put_unit hollow-certbot-renew.timer <"$DEPLOY/hollow-certbot-renew.timer"
        run systemctl daemon-reload
        run systemctl enable --quiet --now hollow-certbot-renew.timer
    fi
    # Two certbots would both renew the same certificate.
    if unit_exists certbot.timer; then run_ok systemctl disable --now certbot.timer; fi
    return 0
}

cert_issue() {
    certbot_install
    step "Getting the certificate for $CFG_HOST"
    ensure_dir "$RELAY_ETC" 0750 root hollow-relay
    run install -D -m 0755 -o root -g root "$DEPLOY/certbot/host-deploy-hook.sh" "$CERT_HOOK"
    if [ ! -e "$CERT_RENEWAL" ] && [ -f "$CERT_RENEWAL_OFF" ]; then
        run mv -f "$CERT_RENEWAL_OFF" "$CERT_RENEWAL"
    fi
    if [ "$DRY_RUN" = 1 ]; then
        say "  would run deploy/certbot/issue.sh for $CFG_HOST ($( [ "$CFG_STAGING" = yes ] && echo staging || echo live ) Let's Encrypt)"
        return 0
    fi
    local staging=""
    [ "$CFG_STAGING" = yes ] && staging=1
    # The hooks read the DuckDNS token from its root-only file, never from here.
    say "  asking Let's Encrypt. This takes about a minute, and up to two through DuckDNS."
    run_logged env PATH="$CERTBOT_DIR:$PATH" RELAY_HOST="$CFG_HOST" \
        CERTBOT_STAGING="$staging" CERT_INSTALL_HOOK="$CERT_HOOK" \
        /bin/sh "$INSTALLER_COPY/deploy/certbot/issue.sh" ||
        die "the certificate could not be obtained. The reason is in certbot's lines above."
}

cert_expiry() {
    local f=${1:-$RELAY_ETC/fullchain.pem}
    [ -r "$f" ] || return 1
    openssl x509 -in "$f" -noout -enddate 2>/dev/null | sed 's/^notAfter=//'
}

# ---------------------------------------------------------------- units

# put_unit <name>, content on stdin.
put_unit() {
    put_file "$UNIT_DIR/$1" 0644 root root
    if [ "$PUT_CHANGED" = 1 ]; then UNITS_CHANGED=1; mark_restart "${1%.service}"; fi
    return 0
}

# Hides the installer's other settings directories from a service as well.
more_inaccessible() {
    sed 's|^InaccessiblePaths=\(.*\)$|InaccessiblePaths=\1 -/etc/hollow-turn -/etc/hollow-duckdns|'
}

# The relay unit is the official one (deploy/hollow-relay.service) with this
# relay's own flags on its ExecStart.
render_relay_unit() {
    local id=$1
    {
        echo "# Written by install.sh from relay-uws/deploy/hollow-relay.service."
        awk -v host="$CFG_HOST" -v fwd="$id" -v grace="$CFG_GRACE_SECS" '
            /^ExecStart=/ { skip = 1 }
            skip {
                if ($0 !~ /\\$/) {
                    skip = 0
                    print "ExecStart=/usr/local/bin/hollow-relay \\"
                    print "    --port 443 \\"
                    print "    --domain " host " \\"
                    print "    --keys-file /etc/hollow-relay/keys.json \\"
                    print "    --reports-file /var/lib/hollow-relay/reports.json \\"
                    print "    --cert-file /etc/hollow-relay/fullchain.pem \\"
                    line = "    --key-file /etc/hollow-relay/privkey.pem"
                    if (fwd != "") { print line " \\"; line = "    --forwarder-peer-id " fwd }
                    if (grace != "" && grace != "120") { print line " \\"; line = "    --session-grace-secs " grace }
                    print line
                }
                next
            }
            { print }
        ' "$DEPLOY/hollow-relay.service"
    } | more_inaccessible
}

# The push sender's unit is the official one without its Firebase credential,
# which only the official relay holds.
render_push_unit() {
    local allow
    allow=$(resolver_allow)
    echo "# Written by install.sh from push-sidecar/hollow-push.service, without Firebase."
    grep -v -e '^LoadCredential=' -e '^Environment=FIREBASE_KEY_PATH=' -e '^# systemd copies the credential' \
        -e '^# can read; the file under /etc' "$1" | sed '1,/^\[Unit\]/{/^#/d}' | more_inaccessible |
        awk -v allow="$allow" '{ print } /^IPAddressAllow=/ && allow != "" { print "IPAddressAllow=" allow }'
}

# The private nameservers in resolv.conf, for the push sender's IP wall:
# Debian without systemd-resolved and most clouds resolve through one. A setup
# re-run writes them again.
RESOLV_CONF=/etc/resolv.conf
resolver_allow() {
    local ns out=""
    for ns in $(sed -n 's/^[[:space:]]*nameserver[[:space:]]\{1,\}\([^[:space:]#]*\).*/\1/p' "$RESOLV_CONF" 2>/dev/null); do
        ns=${ns%%%*}
        case "$(ip4_class "$ns")" in
        private|cgnat|linklocal) out="$out $ns/32" ;;
        invalid)
            case "$(ip6_class "$ns")" in
            ula|linklocal) out="$out $ns/128" ;;
            esac ;;
        esac
    done
    printf '%s' "${out# }"
}

render_forwarder_toml() {
    sed -e "s|^relay_domain = .*|relay_domain = \"$CFG_HOST\"|" \
        -e "s|^public_ip = .*|public_ip = \"$CFG_PUBLIC_IP\"|" \
        -e '/^# install.sh writes this file/d' \
        "$DEPLOY/forwarder.toml.example"
}

# ---------------------------------------------------------------- secrets

# keep_or_new <file> <key> [<seed>]: the value a previous run stored, else the
# seed (what a relay taken over used), else a fresh one.
keep_or_new() {
    local v
    v=$(kv_get "$1" "$2")
    [ -n "$v" ] || v=${3:-}
    [ -n "$v" ] || v=$(gen_hex 32)
    printf '%s' "$v"
}

member_keys_read() {
    [ -r "$1" ] || return 0
    grep -oE '"[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}"' "$1" | tr -d '"' || true
}

# write_keys_json <enabled true|false> <key...>
keys_json() {
    local enabled=$1 first=1 k
    shift
    printf '{\n  "enabled": %s,\n  "keys": [' "$enabled"
    for k in "$@"; do
        if [ "$first" = 1 ]; then printf '\n    "%s"' "$k"; first=0; else printf ',\n    "%s"' "$k"; fi
    done
    if [ "$first" = 1 ]; then printf ']\n}\n'; else printf '\n  ]\n}\n'; fi
}

# The keys to keep in keys.json: the ones already there, topped up to the
# count asked for, plus the forwarder's own when it runs.
MEMBER_KEYS=()
FWD_KEY=""
# plan_member_keys <keys.json> <file holding the forwarder's key> <its variable>
plan_member_keys() {
    local file=${SEED_KEYS_FILE:-$1} fwd_env=$2 var=$3 want=${CFG_MEMBER_KEYS:-0} k
    MEMBER_KEYS=()
    FWD_KEY=$(kv_get "$fwd_env" "$var")
    [ -n "$FWD_KEY" ] || FWD_KEY=${SEED_FWD_LICENSE:-}
    for k in $(member_keys_read "$file"); do
        [ "$k" = "$FWD_KEY" ] && continue
        [ -n "${REMOVE_KEY:-}" ] && [ "$k" = "$REMOVE_KEY" ] && continue
        MEMBER_KEYS+=("$k")
    done
    if [ "$CFG_MEMBERS_ONLY" = yes ]; then
        while [ "${#MEMBER_KEYS[@]}" -lt "$want" ]; do MEMBER_KEYS+=("$(gen_member_key)"); done
        if [ "$CFG_FORWARDER" = yes ] && [ -z "$FWD_KEY" ]; then FWD_KEY=$(gen_member_key); fi
    fi
    [ "$CFG_FORWARDER" = yes ] || FWD_KEY=""
    return 0
}

# ---------------------------------------------------------------- services

# The relay.env lines the setup writes; every other line is the operator's.
RELAY_ENV_KEYS="TURN_SECRET HOLLOW_PUSH_TOKEN HOLLOW_CONN_RATE_EXEMPT PUBLIC_STATS"

relay_settings() {
    step "Relay settings"
    ensure_account hollow-relay
    ensure_dir "$RELAY_ETC" 0750 root hollow-relay
    local turn_secret="" push_token="" exempt kept
    if [ "$CFG_TURN" = yes ]; then turn_secret=$(keep_or_new "$TURN_ETC/turn.env" TURN_SECRET "${SEED_TURN_SECRET:-}"); fi
    if [ "$CFG_PUSH" = yes ]; then push_token=$(keep_or_new "$PUSH_ETC/push.env" PUSH_TOKEN "${SEED_PUSH_TOKEN:-}"); fi
    exempt=$(kv_get "$RELAY_ETC/relay.env" HOLLOW_CONN_RATE_EXEMPT)
    [ -n "$exempt" ] || exempt=${SEED_EXEMPT:-}
    # shellcheck disable=SC2086 # one word per key
    kept=$(env_kept_block "$RELAY_ETC/relay.env" "${SEED_ENV_FILES:-}" $RELAY_ENV_KEYS)
    {
        echo "# Written by install.sh. Root only: systemd reads it as root."
        printf 'TURN_SECRET=%s\n' "$turn_secret"
        printf 'HOLLOW_PUSH_TOKEN=%s\n' "$push_token"
        if [ -n "$exempt" ]; then printf 'HOLLOW_CONN_RATE_EXEMPT=%s\n' "$exempt"; fi
        printf 'PUBLIC_STATS=%s\n' "$(public_stats_norm "${CFG_PUBLIC_STATS:-on}")"
        if [ -n "$kept" ]; then printf '\n%s\n' "$kept"; fi
    } | put_file "$RELAY_ETC/relay.env" 0600 root root
    if [ "$PUT_CHANGED" = 1 ]; then mark_restart hollow-relay; fi
    TURN_SECRET_VALUE=$turn_secret
    PUSH_TOKEN_VALUE=$push_token
    # The report key lives only in the relay's memory since 0.13.
    if restore_state /var/lib/hollow-relay hollow-relay reports.json; then
        say "  restored the report counts from $BACKUP_DIR"
    fi

    plan_member_keys "$RELAY_ETC/keys.json" "$FWD_ETC/forwarder.env" HOLLOW_FWD_LICENSE_KEY
    local all=("${MEMBER_KEYS[@]}")
    [ -n "$FWD_KEY" ] && all+=("$FWD_KEY")
    local enabled=false
    [ "$CFG_MEMBERS_ONLY" = yes ] && enabled=true
    # The relay rereads it every 30 seconds, so no restart.
    keys_json "$enabled" "${all[@]}" | put_file "$RELAY_ETC/keys.json" 0640 root hollow-relay
}

render_turn_env() {
    echo "# Written by install.sh. Root only."
    printf 'TURN_SECRET=%s\n' "$TURN_SECRET_VALUE"
    printf 'PUBLIC_IP=%s\n' "$CFG_PUBLIC_IP"
    printf 'PUBLIC_IPV6=%s\n' "$CFG_PUBLIC_IPV6"
    # The unit's sandbox refuses the capability call ip(8) makes, so coturn
    # cannot look its own address up behind NAT.
    printf 'LOCAL_IP=%s\n' "${PF_LOCAL_IP:-}"
}

turn_apply() {
    if [ "$CFG_TURN" = yes ]; then
        step "TURN for calls (coturn)"
        apt_install coturn
        # The package's own unit would take the ports and run unsandboxed.
        if [ "$(systemctl show -p LoadState --value coturn 2>/dev/null)" = loaded ]; then
            run_ok systemctl disable --now coturn
            run systemctl mask --quiet coturn
        fi
        ensure_account hollow-turn
        ensure_dir "$TURN_ETC" 0750 root hollow-turn
        render_turn_env | put_file "$TURN_ETC/turn.env" 0600 root root
        if [ "$PUT_CHANGED" = 1 ]; then mark_restart hollow-coturn; fi
        if [ "$DRY_RUN" = 0 ] && [ -r "$RELAY_ETC/fullchain.pem" ]; then
            for f in fullchain.pem privkey.pem; do
                install -o root -g hollow-turn -m 0640 "$RELAY_ETC/$f" "$TURN_ETC/$f.new"
                if cmp -s "$TURN_ETC/$f.new" "$TURN_ETC/$f"; then rm -f "$TURN_ETC/$f.new"
                else mv -f "$TURN_ETC/$f.new" "$TURN_ETC/$f"; mark_restart hollow-coturn; fi
            done
        fi
        put_unit hollow-coturn.service <"$DEPLOY/hollow-coturn.service"
        ENABLE_UNITS+=(hollow-coturn)
        turn_lock_apply hollow-turn yes
    else
        if unit_exists hollow-coturn; then
            step "Turning TURN off"
            run_ok systemctl disable --now hollow-coturn
        fi
        run rm -f "$UNIT_DIR/hollow-coturn.service"
        run rm -rf "$TURN_ETC"
        turn_lock_remove
    fi
}

# ---------------------------------------------------------------- the TURN port lock

# coturn's peer lock lets TURN reach this machine's own address on any port;
# deploy/turn-port-lock.sh keeps it to coturn's relay ports and the
# forwarder's (AR-32). Whenever TURN is on, the lock is in place before coturn
# starts, and its settings follow the address and the forwarder.
LOCK_BIN=/usr/local/sbin/hollow-turn-port-lock
LOCK_ENV=$RELAY_ETC/turn-port-lock.env
LOCK_UNIT=hollow-turn-port-lock.service
LOCK_TIMER=hollow-turn-port-lock-refresh.timer
LOCK_UNITS="hollow-turn-port-lock.service hollow-turn-port-lock-refresh.service hollow-turn-port-lock-refresh.timer"
LOCK_DROPIN_DIR=$UNIT_DIR/hollow-coturn.service.d
LOCK_DROPIN=$LOCK_DROPIN_DIR/hollow-port-lock.conf
# coturn-start.sh's --min-port and --max-port.
TURN_RELAY_PORTS=49152-65535

# Exactly the --allowed-peer-ip values coturn-start.sh passes, or check-host
# finds the lock and coturn disagree: the public IPv4 (this machine's own when
# none is set), this machine's own one behind NAT, and the public IPv6.
turn_lock_peers() {
    local own=${PF_LOCAL_IP:-} ip
    [ -n "$own" ] || own=$(local_ipv4)
    ip=${CFG_PUBLIC_IP:-$own}
    printf '%s' "$ip"
    if [ -n "$own" ] && [ "$own" != "$ip" ]; then printf ' %s' "$own"; fi
    if [ -n "${CFG_PUBLIC_IPV6:-}" ]; then printf ' %s' "$CFG_PUBLIC_IPV6"; fi
    return 0
}

# render_turn_lock_env <coturn's account>
render_turn_lock_env() {
    echo "# Written by install.sh: what hollow-turn-port-lock.service keeps TURN to. Not secret."
    printf 'TURN_USER=%s\n' "$1"
    printf 'TURN_PEERS="%s"\n' "$(turn_lock_peers)"
    printf 'TURN_PORTS=%s\n' "$TURN_RELAY_PORTS"
    if [ "$CFG_FORWARDER" = yes ]; then printf 'FORWARDER_PORTS=%s\n' "${FWD_PORTS/:/-}"; else echo "FORWARDER_PORTS="; fi
}

# turn_lock_apply <coturn's account> <yes|no: the drop-in that ties coturn's
# own unit to the lock>. Docker gets no drop-in (coturn-port-lock.conf says why).
turn_lock_apply() {
    local user=$1 dropin=$2 env changed=0 u
    step "The TURN port lock"
    # nft holds the rule, sysctl reserves the ports, python3 and ss check them.
    apt_install nftables procps iproute2 python3 || die "the TURN port lock's packages could not be installed."
    [ -d "$RELAY_ETC" ] || ensure_dir "$RELAY_ETC" 0700 root root
    env=$(render_turn_lock_env "$user")
    # Stopped before its settings change, so the lock it loaded is removed with
    # the ports it reserved, not the new ones.
    if [ -f "$LOCK_ENV" ] && [ "$env" != "$(cat "$LOCK_ENV")" ] && unit_active "$LOCK_UNIT"; then
        run_ok systemctl stop "$LOCK_UNIT"
    fi
    put_file "$LOCK_BIN" 0755 root root <"$DEPLOY/turn-port-lock.sh"
    [ "$PUT_CHANGED" = 1 ] && changed=1
    printf '%s\n' "$env" | put_file "$LOCK_ENV" 0600 root root
    [ "$PUT_CHANGED" = 1 ] && changed=1
    for u in $LOCK_UNITS; do
        put_file "$UNIT_DIR/$u" 0644 root root <"$DEPLOY/$u"
        [ "$PUT_CHANGED" = 1 ] && changed=1
    done
    if [ "$dropin" = yes ]; then
        ensure_dir "$LOCK_DROPIN_DIR" 0755 root root
        put_file "$LOCK_DROPIN" 0644 root root <"$DEPLOY/coturn-port-lock.conf"
        if [ "$PUT_CHANGED" = 1 ]; then mark_restart hollow-coturn; fi
    else
        lock_dropin_remove
    fi
    run systemctl daemon-reload
    run systemctl enable --quiet "$LOCK_UNIT" "$LOCK_TIMER"
    if [ "$changed" = 1 ] && unit_active "$LOCK_UNIT"; then
        run systemctl restart "$LOCK_UNIT" || die "the TURN port lock did not load. See: journalctl -u $LOCK_UNIT"
    else
        run systemctl start "$LOCK_UNIT" || die "the TURN port lock did not load. See: journalctl -u $LOCK_UNIT"
    fi
    run systemctl start "$LOCK_TIMER"
    say "  TURN reaches this machine only on ports ${TURN_RELAY_PORTS/-/ to }$( [ "$CFG_FORWARDER" = yes ] && echo " and ${FWD_PORTS/:/ to }")"
}

lock_dropin_remove() {
    [ -e "$LOCK_DROPIN" ] || return 0
    run rm -f "$LOCK_DROPIN"
    run rmdir --ignore-fail-on-non-empty "$LOCK_DROPIN_DIR"
}

lock_present() {
    local u
    [ -e "$LOCK_BIN" ] || [ -e "$LOCK_ENV" ] || [ -e "$LOCK_DROPIN" ] && return 0
    for u in $LOCK_UNITS; do [ -e "$UNIT_DIR/$u" ] && return 0; done
    return 1
}

# The lock, its timer, units, settings and drop-in gone, and with them its
# firewall rule and the ports it reserved.
turn_lock_remove() {
    local u
    lock_present || return 0
    step "Removing the TURN port lock"
    for u in "$LOCK_TIMER" "$LOCK_UNIT"; do
        if unit_exists "$u"; then run_ok systemctl disable --now "$u"; fi
    done
    # Also when its unit had stopped or failed.
    if [ -x "$LOCK_BIN" ]; then
        run_ok env TURN_PORTS="$(kv_get "$LOCK_ENV" TURN_PORTS)" FORWARDER_PORTS="$(kv_get "$LOCK_ENV" FORWARDER_PORTS)" "$LOCK_BIN" remove
    fi
    lock_dropin_remove
    for u in $LOCK_UNITS; do run rm -f "$UNIT_DIR/$u"; done
    run rm -f "$LOCK_ENV" "$LOCK_BIN"
    run systemctl daemon-reload
}

# For the status screen.
lock_state() {
    case "$(systemctl is-active "$LOCK_UNIT" 2>/dev/null)" in
    active)
        if unit_active "$LOCK_TIMER"; then echo "on"
        else echo "on, but the timer that loads it again every minute is stopped ($LOCK_TIMER)"; fi ;;
    failed) echo "FAILED (journalctl -u $LOCK_UNIT)" ;;
    *) echo "not in place. A settings change or an update puts it in place" ;;
    esac
}

node_install() {
    local v
    v=$(node --version 2>/dev/null | sed -n 's/^v\([0-9]*\).*/\1/p' || true)
    if [ -n "$v" ] && [ "$v" -ge 22 ]; then return 0; fi
    say "  installing Node.js 22 from NodeSource's signed apt repository"
    if [ "$DRY_RUN" = 1 ]; then
        say "  would add deb.nodesource.com (node_22.x) with its key in /etc/apt/keyrings, and install nodejs"
        return 0
    fi
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL --proto '=https' https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        -o /etc/apt/keyrings/nodesource.asc || die "could not download NodeSource's signing key."
    chmod 0644 /etc/apt/keyrings/nodesource.asc
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_22.x nodistro main" |
        put_file /etc/apt/sources.list.d/nodesource.list 0644 root root
    printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' |
        put_file /etc/apt/preferences.d/nodesource 0644 root root
    # Security fixes for Node.js arrive with the system's own automatic updates.
    printf 'Unattended-Upgrade::Origins-Pattern {\n    "site=deb.nodesource.com";\n};\n' |
        put_file /etc/apt/apt.conf.d/52hollow-nodesource 0644 root root
    APT_UPDATED=0
    apt_install nodejs || die "Node.js could not be installed."
}

push_apply() {
    if [ "$CFG_PUSH" = yes ]; then
        step "Push sender for Android phones (UnifiedPush)"
        local src
        src=$(push_source_dir) || die "the push sender's sources (push-sidecar/) are missing from this copy."
        node_install
        ensure_account hollow-push
        ensure_dir "$PUSH_DIR" 0755 root root
        local f changed=0
        # The packages come only from the lockfile, never from version ranges.
        [ -f "$src/package-lock.json" ] || die "the push sender's lockfile (push-sidecar/package-lock.json) is missing from this copy."
        for f in index.js fcm.js unifiedpush.js package.json package-lock.json; do
            [ -f "$src/$f" ] || continue
            put_file "$PUSH_DIR/$f" 0644 root root <"$src/$f"
            if [ "$PUT_CHANGED" = 1 ]; then changed=1; fi
        done
        if [ "$changed" = 1 ] || [ ! -d "$PUSH_DIR/node_modules" ]; then
            if [ "$DRY_RUN" = 1 ]; then
                say "  would run npm ci in $PUSH_DIR (the lockfile's versions, no optional, dev or install scripts)"
            else
                (cd "$PUSH_DIR" && run_logged npm ci --omit=optional --omit=dev --ignore-scripts --no-audit --no-fund) ||
                    die "the push sender's packages could not be installed."
                chown -R root:root "$PUSH_DIR"
            fi
            mark_restart hollow-push
        fi
        ensure_dir "$PUSH_ETC" 0700 root root
        printf 'PUSH_TOKEN=%s\n' "$PUSH_TOKEN_VALUE" | put_file "$PUSH_ETC/push.env" 0600 root root
        if [ "$PUT_CHANGED" = 1 ]; then mark_restart hollow-push; fi
        render_push_unit "$src/hollow-push.service" | put_unit hollow-push.service
        ENABLE_UNITS+=(hollow-push)
    else
        if unit_exists hollow-push; then
            step "Turning the push sender off"
            run_ok systemctl disable --now hollow-push
        fi
        run rm -f "$UNIT_DIR/hollow-push.service"
        run rm -rf "$PUSH_ETC" "$PUSH_DIR"
    fi
}

# The id a running forwarder minted. A forwarder from before --print-peer-id
# names it only in its journal, on each start.
forwarder_peer_id() {
    local since=${1:-0} id
    if id=$(runuser -u hollow-fwd -- /usr/local/bin/hollow-forwarder --config "$FWD_ETC/forwarder.toml" \
        --print-peer-id 2>/dev/null) && [[ "$id" =~ ^12D3KooW[1-9A-HJ-NP-Za-km-z]+$ ]]; then
        printf '%s' "$id"
        return 0
    fi
    id=$(journalctl -u hollow-forwarder --since "@$since" -o cat 2>/dev/null |
        sed -n 's/.*forwarder peer_id: \(12D3KooW[1-9A-HJ-NP-Za-km-z]*\).*/\1/p' | tail -n 1 || true)
    [ -n "$id" ] && printf '%s' "$id"
}

FWD_ID=""
forwarder_apply() {
    if [ "$CFG_FORWARDER" = yes ]; then
        step "Media forwarder"
        ensure_account hollow-fwd
        ensure_dir "$FWD_ETC" 0750 root hollow-fwd
        render_forwarder_toml | put_file "$FWD_ETC/forwarder.toml" 0640 root hollow-fwd
        if [ "$PUT_CHANGED" = 1 ]; then mark_restart hollow-forwarder; fi
        if [ -n "$FWD_KEY" ]; then
            printf 'HOLLOW_FWD_LICENSE_KEY=%s\n' "$FWD_KEY" | put_file "$FWD_ETC/forwarder.env" 0600 root root
            if [ "$PUT_CHANGED" = 1 ]; then mark_restart hollow-forwarder; fi
        elif [ -e "$FWD_ETC/forwarder.env" ]; then
            run rm -f "$FWD_ETC/forwarder.env"
            mark_restart hollow-forwarder
        fi
        # A previous uninstall kept the identity, so viewers keep the key they pinned.
        if restore_state /var/lib/hollow-forwarder hollow-fwd forwarder.key forwarder.db; then
            say "  restored the forwarder's identity from $BACKUP_DIR"
        fi
        put_unit hollow-forwarder.service < <(more_inaccessible <"$DEPLOY/hollow-forwarder.service")
        run systemctl daemon-reload
        run systemctl enable --quiet hollow-forwarder
        if [ "$DRY_RUN" = 1 ]; then
            say "  would start the forwarder and read its id with hollow-forwarder --print-peer-id"
            FWD_ID="(the forwarder's id)"
            return 0
        fi
        local t0
        t0=$(date +%s)
        if [[ " ${RESTART_UNITS[*]} " == *" hollow-forwarder "* ]]; then
            systemctl restart hollow-forwarder
        else
            systemctl start hollow-forwarder
        fi
        local tries=0 restarted=0
        while [ "$tries" -lt 40 ]; do
            FWD_ID=$(forwarder_peer_id "$t0") && break
            tries=$((tries + 1))
            # A forwarder without --print-peer-id names its id only on a start,
            # and the journal keeps an hour.
            if [ "$tries" = 5 ] && [ "$restarted" = 0 ]; then
                t0=$(date +%s)
                systemctl restart hollow-forwarder
                restarted=1
            fi
            sleep 1
        done
        [ -n "$FWD_ID" ] || die "the forwarder did not start. See: journalctl -u hollow-forwarder"
        say "  the forwarder's id is $FWD_ID"
    else
        if unit_exists hollow-forwarder; then
            step "Turning the media forwarder off"
            run_ok systemctl disable --now hollow-forwarder
        fi
        run rm -f "$UNIT_DIR/hollow-forwarder.service"
        run rm -rf "$FWD_ETC"
        FWD_ID=""
    fi
}

relay_unit_apply() {
    step "Starting the relay"
    render_relay_unit "$FWD_ID" | put_unit hollow-relay.service
    ENABLE_UNITS+=(hollow-relay)
}

start_units() {
    run systemctl daemon-reload
    local u
    for u in "${ENABLE_UNITS[@]}"; do
        run systemctl enable --quiet "$u"
        if [[ " ${RESTART_UNITS[*]} " == *" $u "* ]] && unit_active "$u"; then
            say "  restarting $u"
            run systemctl restart "$u"
        else
            run systemctl start "$u"
        fi
    done
}

# local_get <path>: a GET to this relay on 127.0.0.1, under its own name.
local_get() {
    local k=()
    [ "${CFG_STAGING:-no}" = yes ] && k=(-k)
    curl -fsS --max-time 5 "${k[@]}" --connect-to "$CFG_HOST:443:127.0.0.1:443" "https://$CFG_HOST$1"
}

wait_for_relay() {
    [ "$DRY_RUN" = 1 ] && { say "  would check https://$CFG_HOST/health and /relay-status on this machine"; return 0; }
    for _ in $(seq 1 60); do
        local_get /health >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

# ---------------------------------------------------------------- apply

# An update's settings run: the programs it brought start with the new units.
programs_changed_restarts() {
    if [ "${PROGRAMS_CHANGED:-0}" = 1 ]; then
        mark_restart hollow-relay
        if [ "$CFG_FORWARDER" = yes ]; then mark_restart hollow-forwarder; fi
    fi
    return 0
}

native_apply() {
    APPLY_STARTED=1
    ENABLE_UNITS=()
    RESTART_UNITS=()
    UNITS_CHANGED=0
    programs_changed_restarts
    step "Packages"
    apt_install curl ca-certificates openssl ufw
    runtime_packages

    step "Hardening the machine (deploy/harden-host.sh)"
    [ "$DRY_RUN" = 1 ] || hollow_apt_wait || die "the system's automatic updates still hold the package lock. Wait until they finish, then run the setup again."
    local http=no
    [ "$CFG_ADDRESS" = duckdns ] || http=yes
    local hargs=(--http "$http" --turn "$CFG_TURN" --forwarder "$CFG_FORWARDER" --no-ssh)
    [ "$DRY_RUN" = 1 ] && hargs+=(--print)
    run_logged sh "$DEPLOY/harden-host.sh" "${hargs[@]}" || die "the hardening step failed."

    ensure_account hollow-relay
    install_installer_copy
    ensure_programs

    if [ "$CFG_ADDRESS" = duckdns ]; then
        step "Keeping $CFG_HOST pointed at this machine"
        duckdns_setup
    else
        duckdns_remove
    fi
    cert_issue
    relay_settings
    adopt_step stage
    turn_apply
    push_apply
    forwarder_apply
    adopt_step forwarder
    relay_unit_apply
    adopt_step before_start
    start_units
    if [ "$CFG_TURN" = yes ]; then
        # coturn's first start may precede the certificate copy above.
        run_ok systemctl try-restart hollow-coturn
    fi
    conf_save
    step "Checking the relay answers"
    wait_for_relay || die "the relay did not answer on 127.0.0.1. See: journalctl -u hollow-relay -e"
    if [ "$DRY_RUN" = 0 ]; then
        say "  /health: $(local_get /health)"
        say "  /relay-status: $(local_get /relay-status)"
    fi
}

# ---------------------------------------------------------------- uninstall

native_uninstall() {
    local keep=$1 u
    APPLY_STARTED=1
    step "Removing the Hollow relay"
    for u in hollow-relay hollow-forwarder hollow-push hollow-coturn hollow-duckdns.timer hollow-duckdns \
             hollow-certbot-renew.timer hollow-certbot-renew; do
        unit_exists "$u" && run_ok systemctl disable --now "$u"
        run rm -f "$UNIT_DIR/$u" "$UNIT_DIR/$u.service"
    done
    turn_lock_remove
    run systemctl daemon-reload
    # After the stop, so no service process can swap a file for a link.
    if [ "$keep" = yes ]; then
        local f acct
        ensure_dir "$BACKUP_DIR" 0700 root root
        for f in /var/lib/hollow-forwarder/forwarder.key /var/lib/hollow-forwarder/forwarder.db \
                 /var/lib/hollow-relay/reports.json; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            acct=hollow-relay
            [[ "$f" == /var/lib/hollow-forwarder/* ]] && acct=hollow-fwd
            [ "$DRY_RUN" = 1 ] || account_idle "$acct"
            if [ "$DRY_RUN" = 1 ] || plain_file "$f" "$acct"; then
                run install -m 0600 -o root -g root "$f" "$BACKUP_DIR/$(basename "$f")"
            else
                warn "$f is not a plain file of $acct's, so I did not keep it."
            fi
        done
        # A report key an older uninstall kept is no use to a relay since 0.13.
        if [ -f "$BACKUP_DIR/reports.json.key" ]; then
            run_ok shred -z -n 0 "$BACKUP_DIR/reports.json.key"
            run rm -f "$BACKUP_DIR/reports.json.key"
        fi
        say "  kept the forwarder's identity and the report counts in $BACKUP_DIR"
    fi
    # A full stop, so systemd drops the relay's held buffers along with it.
    run rm -f /usr/local/bin/hollow-relay /usr/local/bin/hollow-forwarder /usr/local/sbin/hollow-relay-setup
    run rm -f "$CERT_HOOK"
    # Its hooks are gone, so every renewal would fail twice a day. A reinstall
    # turns it back on.
    if [ -f "$CERT_RENEWAL" ]; then
        run mv -f "$CERT_RENEWAL" "$CERT_RENEWAL_OFF"
        say "  the certificate stays in /etc/letsencrypt, and its renewal is off"
    fi
    run rm -rf "$RELAY_ETC" "$TURN_ETC" "$PUSH_ETC" "$FWD_ETC" "$DDNS_ETC" "$PUSH_DIR" \
        /var/lib/hollow-relay /var/lib/hollow-forwarder "$BUILD_DIR" "$STATE_DIR"
    for u in hollow-relay hollow-turn hollow-push hollow-fwd hollow-ddns hollow-build; do
        getent passwd "$u" >/dev/null && run_ok userdel "$u"
        getent group "$u" >/dev/null && run_ok groupdel "$u"
    done
    if [ "$(systemctl show -p LoadState --value coturn 2>/dev/null)" = masked ]; then run_ok systemctl unmask coturn; fi
    local rule
    for rule in 443/tcp $HOLLOW_FW_OPTIONAL; do run_ok ufw delete allow "$rule"; done
    # Last, because it holds the copy of this script that is running.
    run rm -f "$MEMBER_KEYS_OUT"
    run rm -rf "$LIB_DIR"
}
