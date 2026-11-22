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
# The fair-share shaper (hollow-cake.service); its settings sit beside the
# relay's because the relay reads them too.
CAKE_UNIT=hollow-cake.service
CAKE_ENV=$RELAY_ETC/cake.env
CAKE_MODLOAD=/etc/modules-load.d/hollow-cake.conf
SYS_NET=/sys/class/net
SYS_MODULE=/sys/module

# What the feed check and the setup's own checks need at run time. The
# libraries the ready-made programs link to come below, by the names they ask for.
RUNTIME_PACKAGES="openssl ca-certificates curl jq"

# The libraries the ready-made programs link to (scripts/build_relay_binaries.sh
# refuses a build whose programs link to any other set).
PREBUILT_NEEDS="libssl.so.3 libcrypto.so.3 libsodium.so.23 libz.so.1 libstdc++.so.6 libm.so.6
libgcc_s.so.1 libc.so.6"
# The ready-made forwarder's own share of them. Where only the relay's are
# missing, the signed forwarder is installed and the relay is built here.
FORWARDER_NEEDS="libcrypto.so.3 libgcc_s.so.1 libm.so.6 libc.so.6"

# Each library by its exact soname, with the packages that hold that version on
# Ubuntu and Debian. Never a newer soname's package: a program built for
# libsodium.so.23 cannot load libsodium.so.26 (#153).
LIB_PACKAGES="libsodium.so.23=libsodium23 libsodium.so.26=libsodium26
libssl.so.3=libssl3t64,libssl3 libcrypto.so.3=libssl3t64,libssl3 libssl.so.4=libssl4
libcrypto.so.4=libssl4 libz.so.1=zlib1g libzstd.so.1=libzstd1 libstdc++.so.6=libstdc++6
libgcc_s.so.1=libgcc-s1 libm.so.6=libc6 libc.so.6=libc6"

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
# prebuilt, source, or mixed: the signed release's forwarder with a relay
# built here at the release's version (BUILT_FROM's second line says from what).
installed_source() { [ -r "$BUILT_FROM_FILE" ] && head -n 1 "$BUILT_FROM_FILE"; return 0; }

# install_programs <dir> <prebuilt|source|mixed> [<how the relay was built>]:
# the dir holds the programs and their VERSION marker. The pair it replaces is kept in previous/, so a failed
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
    # An if, not &&: under set -e a false test at the end fails the pipe.
    { printf '%s\n' "$2"; if [ -n "${3:-}" ]; then printf '%s\n' "$3"; fi; } | put_file "$BUILT_FROM_FILE" 0644 root root
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

PROGRAMS_DIR=/usr/local/bin
programs_present() {
    [ -x "$PROGRAMS_DIR/hollow-relay" ] || return 1
    [ "$CFG_FORWARDER" != yes ] || [ -x "$PROGRAMS_DIR/hollow-forwarder" ] || return 1
    [ -r "$VERSION_FILE" ]
}

# programs_libs_heal: the installed programs find every library they link to.
# A release upgrade of the system can take one away; it goes back only as the
# package holding that exact soname. Programs that still cannot start stop the
# run: replacing them is an update's or a rebuild's job, which keep the pair
# for a rollback.
programs_libs_heal() {
    local bins=("$PROGRAMS_DIR/hollow-relay") missing lib p pkgs=() none=0
    [ "$CFG_FORWARDER" = yes ] && bins+=("$PROGRAMS_DIR/hollow-forwarder")
    missing=$(libs_missing "${bins[@]}")
    [ -n "$missing" ] || return 0
    if [ "$DRY_RUN" = 1 ]; then
        say "  would install the libraries the installed programs lack: $(printf '%s' "$missing" | paste -sd' ' -)"
        return 0
    fi
    hollow_apt_wait 2>"$WORK_DIR/apt.wait" || die "$(cat "$WORK_DIR/apt.wait")"
    apt_refresh || die "the package lists could not be fetched, so the libraries the installed programs lack were not installed."
    while read -r lib; do
        if p=$(lib_package "$lib"); then pkgs+=("$p"); else none=1; fi
    done <<<"$missing"
    if [ "$none" = 0 ]; then
        say "  the installed programs lack $(printf '%s' "$missing" | paste -sd' ' -), so I install ${pkgs[*]}"
        apt_install "${pkgs[@]}" || die "apt could not install ${pkgs[*]}, which the installed programs need."
        missing=$(libs_missing "${bins[@]}")
        [ -n "$missing" ] || return 0
    fi
    die "the installed programs cannot start, because they need $(printf '%s' "$missing" | paste -sd' ' -), which this system does not have. The programs were not changed. To build the programs here, run the setup from your copy of the repository (sudo bash relay-uws/install.sh) and choose Rebuild from this copy."
}

# ---------------------------------------------------------------- libraries

# libs_missing <program...>: the libraries the programs ask for that this
# machine lacks, one per line. ldd only lists them; nothing of the program runs.
libs_missing() {
    local b
    for b in "$@"; do
        [ -f "$b" ] || continue
        LC_ALL=C ldd "$b" 2>/dev/null | sed -n 's/^[[:space:]]*\([^[:space:]]*\) => not found.*/\1/p'
    done | LC_ALL=C sort -u
}

# apt_offers <package>: installed, or a version this system's software sources serve.
apt_offers() {
    local c
    [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ] && return 0
    c=$(apt-cache policy "$1" 2>/dev/null | sed -n 's/^ *Candidate: //p' | head -n 1)
    [ -n "$c" ] && [ "$c" != "(none)" ]
}

# lib_package <soname>: the first package of LIB_PACKAGES holding it that this
# system offers. Returns 1 when none is, or the soname is not listed.
lib_package() {
    local e p list
    for e in $LIB_PACKAGES; do
        [ "${e%%=*}" = "$1" ] || continue
        list=${e#*=}
        for p in ${list//,/ }; do apt_offers "$p" && { printf '%s' "$p"; return 0; }; done
    done
    return 1
}

# libs_why <soname...>: why the ready-made programs cannot run here.
libs_why() {
    local list sys
    sys=$(hollow_os_field "${HOLLOW_OS_RELEASE:-/etc/os-release}" PRETTY_NAME)
    if [ $# -eq 1 ]; then list=$1
    else list="$(printf '%s, ' "${@:1:$#-1}")"; list="${list%, } and ${!#}"; fi
    printf 'they need %s, which %s does not offer' "$list" "${sys:-this system}"
}

# libs_not_offered <soname...>: those this system neither has nor offers.
libs_not_offered() {
    local lib
    for lib in "$@"; do
        ldconfig -p 2>/dev/null | awk -v l="$lib" '$1 == l { f = 1 } END { exit !f }' && continue
        lib_package "$lib" >/dev/null || printf '%s\n' "$lib"
    done
}

# Whether this system has or offers every library the ready-made programs link
# to. Sets PREBUILT_LIBS_WHY when it does not, and PREBUILT_RELAY_ONLY (still
# true) when only the relay's are missing and a forwarder is wanted: the
# signed forwarder can run here then. Judged only from software lists that are
# there; the check of the download itself is the one that counts.
prebuilt_libs_offered() {
    local none=()
    PREBUILT_LIBS_WHY="" PREBUILT_RELAY_ONLY=0
    compgen -G "${APT_LISTS:-/var/lib/apt/lists}/*Packages*" >/dev/null || return 0
    # shellcheck disable=SC2086 # one word per library
    mapfile -t none < <(libs_not_offered $PREBUILT_NEEDS)
    [ ${#none[@]} -eq 0 ] && return 0
    PREBUILT_LIBS_WHY=$(libs_why "${none[@]}")
    # shellcheck disable=SC2086 # one word per library
    if [ "${CFG_FORWARDER:-yes}" != no ] && [ -z "$(libs_not_offered $FORWARDER_NEEDS)" ]; then
        PREBUILT_RELAY_ONLY=1
        return 0
    fi
    return 1
}

# prebuilt_libs_ready <dir>: installs the libraries the downloaded programs
# ask for and lack, by the names they ask for. Sets PREBUILT_LIBS_WHY and
# returns 1 when one is still missing, so the programs could not start here.
# When only the relay's are missing, PREBUILT_RELAY_CANNOT is 1 and
# PREBUILT_FWD_PKGS names what the forwarder still needs installed.
prebuilt_libs_ready() {
    local relay=$1/hollow-relay fwd=() lib p pkgs=() none=() fpkgs=() fnone=() all=()
    PREBUILT_LIBS_WHY="" PREBUILT_RELAY_CANNOT=0 PREBUILT_FWD_PKGS=""
    [ "$CFG_FORWARDER" = yes ] && fwd=("$1/hollow-forwarder")
    [ -n "$(libs_missing "$relay" "${fwd[@]}")" ] || return 0
    hollow_apt_wait 2>"$WORK_DIR/apt.wait" || die "$(cat "$WORK_DIR/apt.wait")"
    apt_refresh || die "the package lists could not be fetched, so nothing was installed."
    while read -r lib; do
        if p=$(lib_package "$lib"); then pkgs+=("$p"); else none+=("$lib"); fi
    done < <(libs_missing "$relay")
    if [ ${#fwd[@]} -gt 0 ]; then
        while read -r lib; do
            if p=$(lib_package "$lib"); then fpkgs+=("$p"); else fnone+=("$lib"); fi
        done < <(libs_missing "${fwd[@]}")
    fi
    # Nothing is installed for a set that could not start anyway.
    if [ ${#none[@]} -eq 0 ] && [ ${#fnone[@]} -eq 0 ]; then
        apt_install "${pkgs[@]}" "${fpkgs[@]}" ||
            die "apt could not install the libraries the ready-made programs need (${pkgs[*]} ${fpkgs[*]}), so the programs were not installed."
        [ -n "$(libs_missing "$relay" "${fwd[@]}")" ] || return 0
        mapfile -t none < <(libs_missing "$relay")
        [ ${#fwd[@]} -gt 0 ] && mapfile -t fnone < <(libs_missing "${fwd[@]}")
        fpkgs=()
    fi
    if [ ${#fwd[@]} -gt 0 ] && [ ${#fnone[@]} -eq 0 ]; then
        PREBUILT_RELAY_CANNOT=1 PREBUILT_FWD_PKGS="${fpkgs[*]}"
    fi
    mapfile -t all < <(printf '%s\n' "${none[@]}" "${fnone[@]}" | sed '/^$/d' | LC_ALL=C sort -u)
    PREBUILT_LIBS_WHY=$(libs_why "${all[@]}")
    return 1
}

# What a relay build reads from the copy of the repository.
RELAY_SOURCE_PARTS="relay-uws/CMakeLists.txt relay-uws/src relay-uws/uWebSockets relay-uws/uSockets"

# repo_git <args>: git on the copy of the repository, reading only: nothing is
# written to it as root and no hook of it runs. Its owner chose to run the
# setup from it, so who owns it and its relay submodules does not matter here.
repo_git() {
    git -c safe.directory="$REPO" -c safe.directory="$REPO/relay-uws/uWebSockets" \
        -c safe.directory="$REPO/relay-uws/uSockets" -c safe.directory="$REPO/relay-uws/uWebSockets/uSockets" \
        -c core.fsmonitor=false --no-optional-locks -C "$REPO" "$@"
}

# mixed_possible: this copy of the repository holds exactly the relay sources
# of the release the feed names, so a relay built here beside the signed
# forwarder is that release's and its VERSION marker stays true. The feed names
# the release commit, which the tag only follows, so the trees are compared,
# never the commits. Sets MIXED_WHY when it cannot, and MIXED_NO_SOURCES when
# there is nothing here to build from at all.
mixed_possible() {
    local sv p here rel changed
    MIXED_WHY="" MIXED_NO_SOURCES=0
    if [ ! -f "$REPO/relay-uws/src/main.cpp" ] || [ ! -f "$REPO/relay-uws/uWebSockets/src/App.h" ] ||
       [ ! -f "$REPO/relay-uws/uSockets/Makefile" ]; then
        MIXED_WHY="this copy of the setup has no relay sources next to it"
        MIXED_NO_SOURCES=1
        return 1
    fi
    sv=$(relay_source_version "$REPO")
    if [ -z "$sv" ] || [ "$sv" != "$FEED_VERSION" ]; then
        MIXED_WHY="this copy of the repository holds version ${sv:-unknown}, and the release is $FEED_VERSION"
        return 1
    fi
    if ! have git; then
        MIXED_WHY="git is not installed, so I cannot tell whether this copy holds the release's relay sources"
        return 1
    fi
    if ! [[ "${FEED_COMMIT:-}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
        MIXED_WHY="the release list names no commit to compare this copy with"
        return 1
    fi
    if [ -z "$(source_commit "$REPO")" ]; then
        MIXED_WHY="this copy of the repository is not a git clone I can read, so I cannot tell whether it holds the release's relay sources"
        return 1
    fi
    if ! repo_git cat-file -e "$FEED_COMMIT^{commit}" 2>/dev/null; then
        MIXED_WHY="this copy of the repository does not have the release's commit ${FEED_COMMIT:0:12}, which git fetch --tags brings in"
        return 1
    fi
    for p in $RELAY_SOURCE_PARTS; do
        here=$(repo_git rev-parse -q --verify "HEAD:$p" 2>/dev/null) || here=""
        rel=$(repo_git rev-parse -q --verify "$FEED_COMMIT:$p" 2>/dev/null) || rel=""
        # A submodule is a commit id here: the one checked out must be it,
        # and a folder that is not a checkout is never the release's.
        if [ -n "$here" ] && [ "$(repo_git ls-tree HEAD -- "$p" 2>/dev/null | awk '{print $1}')" = 160000 ] &&
           [ "$(repo_git -C "$p" rev-parse -q --verify HEAD 2>/dev/null)" != "$here" ]; then
            here=""
        fi
        if [ -z "$here" ] || [ "$here" != "$rel" ]; then
            MIXED_WHY="the relay sources in this copy differ from those of the release's commit ${FEED_COMMIT:0:12}"
            return 1
        fi
    done
    # Untracked and ignored files too: the build copies the folders whole.
    # shellcheck disable=SC2086 # one word per path
    if ! changed=$(repo_git status --porcelain --untracked-files=all --ignored=matching --ignore-submodules=none -- $RELAY_SOURCE_PARTS 2>/dev/null); then
        MIXED_WHY="git could not read the state of this copy's relay sources, so I cannot tell whether they are the release's"
        return 1
    fi
    if [ -n "$changed" ]; then
        MIXED_WHY="this copy has changes of its own in the relay sources, which git status shows"
        return 1
    fi
    return 0
}

# programs_mixed <download dir>: the signed forwarder stays, and the relay
# built from this copy takes the place of the release's.
programs_mixed() {
    local dl=$1
    say "  the release's relay cannot run here ($PREBUILT_LIBS_WHY), so I build the relay from this copy of the repository and install the release's signed forwarder"
    if [ -n "$PREBUILT_FWD_PKGS" ]; then
        # shellcheck disable=SC2086 # one word per package
        apt_install $PREBUILT_FWD_PKGS || { rm -rf "$dl"; die "apt could not install the libraries the ready-made forwarder needs ($PREBUILT_FWD_PKGS), so nothing was installed."; }
    fi
    local still
    still=$(libs_missing "$dl/hollow-forwarder" | tr '\n' ' ')
    [ -z "$still" ] || { rm -rf "$dl"; die "the ready-made forwarder still lacks ${still}after its libraries were installed, so nothing was installed."; }
    rm -f -- "$dl/hollow-relay"
    source_build_into "$dl" no
    [ -f "$dl/hollow-relay" ] || { rm -rf "$dl"; die "the relay did not build, so nothing was installed."; }
    MIXED_FROM="relay built from $(c=$(source_commit "$REPO"); printf '%s' "${c:+commit $c of }")the copy of the repository at $REPO"
}

# prebuilt_to_source <why>: builds from source where no ready-made programs can
# run. An update installs the release it named or nothing, and a build here
# would run without the snapshot its rollback needs.
prebuilt_to_source() {
    [ "${UPDATE_RUNNING:-0}" = 1 ] && die "the release list has no programs for this machine now ($1). Nothing was installed. To build the relay here, run the setup from your copy of the repository and choose Rebuild from this copy."
    # Going back to signed releases never turns into a rebuild nobody asked for.
    [ "${SIGNED_ONLY:-0}" = 1 ] && die "the signed release's programs cannot run on this machine ($1). Nothing was installed, and the relay keeps the programs built here."
    [ -f "$REPO/relay-uws/src/main.cpp" ] || die "there are no ready-made programs for this machine ($1), and this copy of the setup has no relay sources to build them from. Nothing was installed. Run sudo bash relay-uws/install.sh from your clone of the repository."
    say "  there are no ready-made programs for this machine ($1), so I build them from source instead"
    CFG_BINARIES=source
    programs_source
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
        # No build for this machine (a 32-bit system or no aarch64 build yet):
        # the sources can still make one.
        case "$PREBUILT_WHY" in
        *"no prebuilt relay"*|*"no relay build for"*|*"build it from source"*)
            prebuilt_to_source "$PREBUILT_WHY"
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
    local kind=prebuilt
    MIXED_FROM=""
    if ! prebuilt_libs_ready "$dl"; then
        if [ "$PREBUILT_RELAY_CANNOT" = 1 ] && mixed_possible; then
            programs_mixed "$dl"
            kind=mixed
        else
            rm -rf "$dl"
            if [ "$PREBUILT_RELAY_CANNOT" = 1 ]; then
                [ "${UPDATE_RUNNING:-0}" = 1 ] && die "the relay of version $FEED_VERSION cannot run here ($PREBUILT_LIBS_WHY), and it cannot be built here either, because $MIXED_WHY. Nothing was installed. To update, check out the release's tag in your copy of the repository and run sudo bash relay-uws/install.sh from it. It installs the signed forwarder and builds only the relay."
                [ "$MIXED_NO_SOURCES" = 1 ] || [ "${SIGNED_ONLY:-0}" = 1 ] ||
                    say "  the release's forwarder could run here, but the relay cannot be built beside it, because $MIXED_WHY. So I build both from this copy."
            fi
            prebuilt_to_source "$PREBUILT_LIBS_WHY"
            return 0
        fi
    fi
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
    install_programs "$dl" "$kind" "$MIXED_FROM"
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
    if [ "$kind" = mixed ]; then
        say "  installed version $FEED_VERSION (build $FEED_BUILD): the forwarder from the signed release, signature and checksum verified, and the relay built here"
    else
        say "  installed version $FEED_VERSION (build $FEED_BUILD), signature and checksum verified"
    fi
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

# builder_ready: a package apt just upgraded (libc6, systemd) can have systemd
# re-execute itself, and a transient unit asked for meanwhile never starts
# ("Message recipient disconnected", Ubuntu 26.04). Waits until one runs.
builder_ready() {
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        systemd-run --quiet --wait --collect -p User="$BUILD_USER" /bin/true </dev/null >/dev/null 2>&1 && return 0
        sleep 1
    done
    die "systemd does not start the build's units, so nothing was built. See: journalctl -b -e"
}

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

# take_build_output <file under $BUILD_DIR> <root's staging dir>: cargo's
# output is a second name of its copy under deps/, so the build account copies
# it to a name of its own in $BUILD_DIR/out and root stages only that copy.
# Root never copies it itself: it would read whatever the build pointed it at.
take_build_output() {
    local name
    name=$(basename -- "$1")
    # shellcheck disable=SC2016 # the build account's shell expands them
    run_logged as_builder /bin/sh -c 'mkdir -p -- "$1" && rm -f -- "$1/$2" && cp -- "$3" "$1/$2"' sh \
        "$BUILD_DIR/out" "$name" "$1" || die "the build's $name could not be copied out of the build folder."
    builder_idle
    stage_build_output "$BUILD_DIR/out/$name" "$2"
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
    source_sources_check "$CFG_FORWARDER"
    step "Building the relay from source"
    if [ "$DRY_RUN" = 1 ]; then
        apt_install build-essential cmake pkg-config libssl-dev libsodium-dev zlib1g-dev perl curl ca-certificates
        ensure_account "$BUILD_USER"
        say "  would copy the sources to $BUILD_DIR and build them there as the account $BUILD_USER"
        [ "$CFG_FORWARDER" = yes ] && say "  would install Rust for $BUILD_USER and build the forwarder, with a temporary swap file if memory is short"
        return 0
    fi
    ensure_dir "$STATE_DIR" 0700 root root
    local stage
    stage=$(mktemp -d "$STATE_DIR/stage.XXXXXX")
    source_build_into "$stage" "$CFG_FORWARDER"
    source_version_marker "$REPO" >"$stage/VERSION"
    install_programs "$stage" source
    rm -rf "$stage"
}

# source_sources_check <forwarder yes|no>: this copy holds what a build needs.
source_sources_check() {
    local src=$REPO
    [ -f "$src/relay-uws/src/main.cpp" ] || die "this copy of the installer has no relay sources next to it. Run install.sh from your clone of the repository to build from source."
    if [ ! -f "$src/relay-uws/uWebSockets/src/App.h" ] || [ ! -f "$src/relay-uws/uSockets/Makefile" ]; then
        die "the relay's submodules are missing. Run: git submodule update --init --recursive, in your copy of the repository."
    fi
    if [ "$1" = yes ]; then
        [ -f "$src/rust/hollow_core/Cargo.toml" ] || die "the forwarder's sources (rust/hollow_core) are missing from this copy."
    fi
    return 0
}

# source_build_into <root's staging dir> <forwarder yes|no>: builds the relay,
# and the forwarder when asked, from this copy as the build account, and stages
# them there. $BUILD_DIR/target stays, so the next forwarder build reuses it.
source_build_into() {
    local src=$REPO stage=$1 with_fwd=$2
    source_sources_check "$with_fwd"
    apt_install build-essential cmake pkg-config libssl-dev libsodium-dev zlib1g-dev perl curl ca-certificates
    ensure_account "$BUILD_USER"
    builder_ready
    ensure_dir "$STATE_DIR" 0700 root root
    install -d -m 0750 -o "$BUILD_USER" -g "$BUILD_USER" "$BUILD_DIR"
    builder_idle
    rm -rf "$BUILD_DIR/src" "$BUILD_DIR/out" "$BUILD_DIR/relay-build"
    install -d -m 0750 -o root -g root "$BUILD_DIR/src"
    local parts
    read -r -a parts <<<"$RELAY_SOURCE_PARTS"
    [ "$with_fwd" = yes ] && parts+=(rust/hollow_core rust/hollow_dfn)
    tar -C "$src" "${SOURCE_EXCLUDES[@]}" -cf - "${parts[@]}" | tar -C "$BUILD_DIR/src" -xf -
    chown -R "$BUILD_USER:$BUILD_USER" "$BUILD_DIR/src"

    local t0 t1
    t0=$(date +%s)
    build_swap_on 1500
    say "  compiling the relay. This takes a few minutes."
    run_logged as_builder cmake -S "$BUILD_DIR/src/relay-uws" -B "$BUILD_DIR/relay-build" -DCMAKE_BUILD_TYPE=Release ||
        die "the relay's build could not be set up."
    run_logged as_builder cmake --build "$BUILD_DIR/relay-build" -j"$(nproc)" || die "the relay did not build."
    builder_idle
    take_build_output "$BUILD_DIR/relay-build/hollow-relay" "$stage"
    t1=$(date +%s)
    say "  the relay built in $(( (t1 - t0) / 60 )) min $(( (t1 - t0) % 60 )) s"

    if [ "$with_fwd" = yes ]; then
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
        take_build_output "$BUILD_DIR/target/release/hollow-forwarder" "$stage"
        t1=$(date +%s)
        say "  the forwarder built in $(( (t1 - t0) / 60 )) min $(( (t1 - t0) % 60 )) s"
    fi
    build_swap_off
    rm -rf "$BUILD_DIR/src" "$BUILD_DIR/out" "$BUILD_DIR/relay-build"
}

ensure_programs() {
    local have
    have=$(installed_source)
    # A relay built here beside the signed forwarder is what the ready-made
    # choice gives on this system.
    [ "$have" = mixed ] && have=prebuilt
    if [ "${FORCE_PROGRAMS:-0}" = 0 ] && programs_present && [ "$have" = "$CFG_BINARIES" ]; then
        programs_libs_heal
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
# the reason when it has none. PREBUILT_LIBS_DOUBT says this setup's list of the
# official programs' libraries names one this system does not offer: only a
# warning, since a later release may link to others, and only the check of the
# download (prebuilt_libs_ready) decides.
PREBUILT_WHY="" PREBUILT_LIBS_DOUBT=0
# prebuilt_available [<installed VERSION file> [allow-downgrade]]
prebuilt_available() {
    local vfile=${1:-} force=${2:-} err
    PREBUILT_WHY="" PREBUILT_RC=0 FEED_CHECKED=0 PREBUILT_LIBS_DOUBT=0 PREBUILT_RELAY_ONLY=0
    if ! feed_lib_present; then
        PREBUILT_WHY="this copy of the installer has no release feed helper"
        return 1
    fi
    feed_lib_load
    if ! err=$(hollow_feed_arch 2>&1 >/dev/null); then
        PREBUILT_WHY=${err#Hollow relay update: }
        return 1
    fi
    prebuilt_libs_offered || PREBUILT_LIBS_DOUBT=1
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
        deploy/coturn-port-lock.conf deploy/hollow-turn-port-lock-refresh.service deploy/hollow-turn-port-lock-refresh.timer deploy/hollow-turn-port-lock.service deploy/turn-port-lock.sh \
        deploy/hollow-cake.service
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
/usr/local/sbin/hollow-turn-port-lock $UNIT_DIR/hollow-coturn.service.d $CAKE_MODLOAD"

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
    # Never cp --parents: uutils' (Ubuntu 26.10) refuses a folder with it.
    for p in $UPDATE_SNAP_PATHS; do
        if [ -e "$p" ]; then
            mkdir -p -- "$UPDATE_SNAP/tree${p%/*}" && cp -a -- "$p" "$UPDATE_SNAP/tree$p" || return 1
        else
            printf '%s\n' "$p" >>"$UPDATE_SNAP/absent"
        fi
    done
    for p in "$UNIT_DIR"/hollow-*.service "$UNIT_DIR"/hollow-*.timer; do
        [ -f "$p" ] || continue
        u=${p##*/}
        mkdir -p -- "$UPDATE_SNAP/tree${p%/*}" && cp -a -- "$p" "$UPDATE_SNAP/tree$p" || return 1
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
    run rm -rf "$DDNS_ETC" /run/hollow-duckdns
}

# ---------------------------------------------------------------- the address follower

# A new public address that the relay's name points at, once proven to be this machine,
# reaches coturn, the TURN port lock and the forwarder (deploy/address-follow.sh,
# HOL-SEC-214). Both setups, after conf_save: it reads install.conf.
FOLLOW_UNITS="hollow-address-follow.service hollow-address-follow.timer"
FOLLOW_TIMER=hollow-address-follow.timer
FOLLOW_USER=hollow-addr

follow_apply() {
    local u
    if ! bash "$DEPLOY/address-follow.sh" wanted "$CFG_ADDRESS" "${CFG_TURN:-no}" "${CFG_FORWARDER:-no}" \
        "${CFG_PUBLIC_IP:-}" "${CFG_PUBLIC_IP_FIXED:-no}"; then
        follow_remove
        return 0
    fi
    step "Following a new address of $CFG_HOST"
    # Its lookups and its TURN proof (deploy/address-probe.py).
    apt_install python3 || die "python3, which the address follower needs, could not be installed."
    ensure_account "$FOLLOW_USER"
    for u in $FOLLOW_UNITS; do put_file "$UNIT_DIR/$u" 0644 root root <"$DEPLOY/$u"; done
    run systemctl daemon-reload
    run systemctl enable --quiet --now "$FOLLOW_TIMER"
    say "  when $CFG_HOST points at a new address that proves to be this machine, TURN and the forwarder take it within minutes"
}

follow_remove() {
    local u gone=0
    if unit_exists "$FOLLOW_TIMER"; then run_ok systemctl disable --now "$FOLLOW_TIMER"; fi
    # A look the timer started may still run, its probes as hollow-addr, and
    # userdel refuses an account with a process.
    if unit_exists hollow-address-follow.service; then run_ok systemctl stop hollow-address-follow.service; fi
    for u in $FOLLOW_UNITS; do
        [ -e "$UNIT_DIR/$u" ] || continue
        run rm -f "$UNIT_DIR/$u"
        gone=1
    done
    [ "$gone" = 1 ] && run systemctl daemon-reload
    # Its RAM stamps and the restarts it still owed: the setup's own run restarts what changed.
    [ ! -d /run/hollow-address ] || run rm -rf /run/hollow-address
    if getent passwd "$FOLLOW_USER" >/dev/null; then
        [ "$DRY_RUN" = 1 ] || account_idle "$FOLLOW_USER"
        run_ok userdel "$FOLLOW_USER"
    fi
    if getent group "$FOLLOW_USER" >/dev/null; then run_ok groupdel "$FOLLOW_USER"; fi
    return 0
}

# ---------------------------------------------------------------- certificate

# The distribution's certbot for names, which apt installs in seconds. IP
# address certificates need certbot 5.3 or newer: Ubuntu's snap where snapd is
# already there, otherwise a pinned certbot in its own Python environment, so a
# lean Debian box never gains snapd for it.
CERTBOT_DIR=/usr/bin
CERTBOT_VENV=/opt/hollow-certbot
CERTBOT_PIN=5.8.0
# Every package of that environment, pinned with its hash: it runs as root.
CERTBOT_REQS=certbot-requirements.txt
CERTBOT_MARK=hollow-requirements.sha256
certbot_install() {
    if [ -x /snap/bin/certbot ]; then CERTBOT_DIR=/snap/bin; return 0; fi
    if [ -x "$CERTBOT_VENV/bin/certbot" ]; then
        CERTBOT_DIR=$CERTBOT_VENV/bin
        # A setup before 0.14 filled it with whatever PyPI served that day.
        if ! certbot_venv_current; then
            step "Installing certbot $CERTBOT_PIN again, from packages the setup pins"
            certbot_venv_make ||
                warn "certbot could not be installed again, so the one that renewed until now stays. Run the setup again later."
        fi
        certbot_renew_units
        return 0
    fi
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
        certbot_venv_make || die "certbot $CERTBOT_PIN could not be installed."
        certbot_renew_units
    fi
    # Two certbots would both renew the same certificate.
    if unit_exists certbot.timer; then run_ok systemctl disable --now certbot.timer; fi
    return 0
}

certbot_venv_current() {
    [ "$(cat "$CERTBOT_VENV/$CERTBOT_MARK" 2>/dev/null)" = "$(sha256sum <"$DEPLOY/$CERTBOT_REQS" | cut -d' ' -f1)" ]
}

# Installs only the packages $CERTBOT_REQS names, each checked against its
# hash, and only as built wheels: building one from source would fetch its
# build tools unchecked. A failure puts back the environment it replaced.
certbot_venv_make() {
    local old=$CERTBOT_VENV.previous
    say "  into its own Python environment in $CERTBOT_VENV, with a timer that renews the certificate. Every package is checked against the hash the setup pins."
    apt_install python3-venv
    if [ "$DRY_RUN" = 0 ]; then
        rm -rf -- "$old"
        if [ -e "$CERTBOT_VENV" ]; then mv -T -- "$CERTBOT_VENV" "$old"; fi
    fi
    if run_logged python3 -m venv "$CERTBOT_VENV" &&
       run_logged "$CERTBOT_VENV/bin/pip" install --quiet --disable-pip-version-check --no-deps --only-binary :all: \
           --require-hashes -r "$DEPLOY/$CERTBOT_REQS" &&
       run_logged "$CERTBOT_VENV/bin/certbot" --version; then
        sha256sum <"$DEPLOY/$CERTBOT_REQS" | cut -d' ' -f1 | put_file "$CERTBOT_VENV/$CERTBOT_MARK" 0644 root root
        run rm -rf -- "$old"
        return 0
    fi
    if [ "$DRY_RUN" = 0 ]; then
        rm -rf -- "$CERTBOT_VENV"
        if [ -e "$old" ]; then mv -T -- "$old" "$CERTBOT_VENV"; fi
    fi
    return 1
}

certbot_renew_units() {
    put_unit hollow-certbot-renew.service <"$DEPLOY/hollow-certbot-renew.service"
    put_unit hollow-certbot-renew.timer <"$DEPLOY/hollow-certbot-renew.timer"
    run systemctl daemon-reload
    run systemctl enable --quiet --now hollow-certbot-renew.timer
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
                    print "    --denylist-file /etc/hollow-relay/denylist.json \\"
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
        -e "s|^public_ip = .*|public_ip = \"$(turn_public_ip)\"|" \
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
RELAY_ENV_KEYS="TURN_SECRET HOLLOW_PUSH_TOKEN HOLLOW_CONN_RATE_EXEMPT PUBLIC_STATS $LIMIT_KEYS"

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
        local k v
        for k in $LIMIT_KEYS; do
            v=CFG_$k
            if [ -n "${!v:-}" ]; then printf '%s=%s\n' "$k" "${!v}"; fi
        done
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
    # Readable by the relay, never writable by it; the operator's edits are its own.
    if [ ! -e "$RELAY_ETC/denylist.json" ]; then
        deny_empty | put_file "$RELAY_ETC/denylist.json" 0640 root hollow-relay
    fi
}

render_turn_env() {
    echo "# Written by install.sh. Root only."
    printf 'TURN_SECRET=%s\n' "$TURN_SECRET_VALUE"
    printf 'PUBLIC_IP=%s\n' "$(turn_public_ip)"
    printf 'PUBLIC_IPV6=%s\n' "$(turn_public_ipv6)"
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
# The ports' reservation for every boot, which the lock writes (its SYSCTL_FILE).
LOCK_SYSCTL=/etc/sysctl.d/zz-hollow-turn-ports.conf
# coturn-start.sh's --min-port and --max-port.
TURN_RELAY_PORTS=49152-65535

# Exactly the --allowed-peer-ip values coturn-start.sh passes, or check-host
# finds the lock and coturn disagree: the public IPv4 (this machine's own when
# none is set), this machine's own one behind NAT, and the public IPv6.
turn_lock_peers() {
    local own=${PF_LOCAL_IP:-} ip v6
    [ -n "$own" ] || own=$(local_ipv4)
    ip=$(turn_public_ip)
    v6=$(turn_public_ipv6)
    ip=${ip:-$own}
    printf '%s' "$ip"
    if [ -n "$own" ] && [ "$own" != "$ip" ]; then printf ' %s' "$own"; fi
    if [ -n "$v6" ]; then printf ' %s' "$v6"; fi
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
    turn_lock_move_avahi
}

# avahi-daemon (mDNS discovery, on desktop systems such as Linux Mint) opens two random UDP
# ports when it starts. One that started before the ports were reserved can hold one among
# TURN's, where TURN reaches it. Restarting it is harmless (it announces the machine on the
# local network again a moment later) and puts it on a port outside them; no other
# program is restarted, check-host names those.
turn_lock_move_avahi() {
    local pid line port lo hi r hit=0
    unit_active avahi-daemon.service || return 0
    pid=$(systemctl show -p MainPID --value avahi-daemon.service 2>/dev/null)
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 0
    while read -r line; do
        port=$(awk '{ print $4 }' <<<"$line")
        port=${port##*:}
        [[ $port =~ ^[0-9]+$ ]] || continue
        for r in "$TURN_RELAY_PORTS" $( [ "$CFG_FORWARDER" = yes ] && echo "${FWD_PORTS/:/-}"); do
            lo=${r%-*} hi=${r#*-}
            if ((port >= lo && port <= hi)); then hit=1; fi
        done
    done < <(ss -Hulnp 2>/dev/null | grep -E ",pid=$pid,fd=[0-9]+\)\)[[:space:]]*$")
    [ "$hit" = 1 ] || return 0
    run_ok systemctl restart avahi-daemon.service
    [ "$DRY_RUN" = 1 ] || say "  Restarted avahi-daemon, which held a port among TURN's"
}

lock_dropin_remove() {
    [ -e "$LOCK_DROPIN" ] || return 0
    run rm -f "$LOCK_DROPIN"
    run rmdir --ignore-fail-on-non-empty "$LOCK_DROPIN_DIR"
}

lock_present() {
    local u
    [ -e "$LOCK_BIN" ] || [ -e "$LOCK_ENV" ] || [ -e "$LOCK_DROPIN" ] || [ -e "$LOCK_SYSCTL" ] && return 0
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
    run rm -f "$LOCK_ENV" "$LOCK_BIN" "$LOCK_SYSCTL"
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

# ---------------------------------------------------------------- the fair-share shaper

# CAKE on the uplink gives every host this machine sends to an equal share of
# the upload once it is full (AR-01). Only a shaper that is the bottleneck
# shares anything, so it runs under the line's real speed. A setup from before
# the question (CFG_CAKE empty) leaves the machine as it is.

# The device the default route leaves through, IPv4 first.
default_route_dev() {
    local fam dev
    for fam in -4 -6; do
        dev=$(ip -o "$fam" route show default 2>/dev/null |
            awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
        if [ -n "$dev" ]; then printf '%s' "$dev"; return 0; fi
    done
    return 0
}

# A device name the kernel allows, of a device this machine has. It lands in
# tc's arguments.
is_cake_dev() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] && [ "$1" != . ] && [ "$1" != .. ] && [ -e "$SYS_NET/$1" ]; }
is_cake_mbit() { [[ "$1" =~ ^[1-9][0-9]{0,5}$ ]] && [ "$1" -le 100000 ]; }

# The operator's device while it exists, else the default route's.
cake_dev() {
    if [ -n "${CFG_CAKE_DEV:-}" ] && is_cake_dev "$CFG_CAKE_DEV"; then printf '%s' "$CFG_CAKE_DEV"
    else default_route_dev; fi
}

# The speed the kernel reports for <dev> in Mbit/s, when it is a real one:
# virtual cards often report none.
line_speed_mbit() {
    local s
    s=$(cat "$SYS_NET/$1/speed" 2>/dev/null) || return 0
    if [[ "$s" =~ ^[0-9]{2,6}$ ]] && [ "$s" -le 800000 ]; then printf '%s' "$s"; fi
    return 0
}

# 90 percent of the line, else 90 percent of the 1 Gbit/s port most servers have.
cake_default_mbit() {
    local s
    s=$(line_speed_mbit "$1")
    if [ -n "$s" ]; then echo $((s * 9 / 10)); else echo 900; fi
}

# render_cake_env <device>
render_cake_env() {
    echo "# Written by install.sh: what hollow-cake.service shapes, which the relay reads too. Not secret."
    if [ "${CFG_CAKE:-}" = on ]; then
        printf 'HOLLOW_CAKE=on\nHOLLOW_CAKE_DEV=%s\nHOLLOW_CAKE_MBIT=%s\n' "$1" "$CFG_CAKE_MBIT"
    else
        echo "HOLLOW_CAKE=off"
    fi
}

cake_text() {
    case "${CFG_CAKE:-}" in
    on) echo "on, ${CFG_CAKE_MBIT:-?} Mbit/s" ;;
    off) echo "off" ;;
    *) echo "not chosen yet. Change a setting to choose" ;;
    esac
}

# Whether this kernel has CAKE: loaded already (a container sees its host's),
# or a module modprobe can load.
cake_kernel_ready() { [ -d "$SYS_MODULE/sch_cake" ] || modprobe -n -q sch_cake 2>/dev/null; }

cake_settings_put() {
    [ -d "$RELAY_ETC" ] || ensure_dir "$RELAY_ETC" 0700 root root
    render_cake_env "$1" | put_file "$CAKE_ENV" 0600 root root
    if [ "$PUT_CHANGED" = 1 ]; then mark_restart hollow-relay; fi
    return 0
}

# A kernel without CAKE or a shaper that does not start never stops the
# setup: everything else still runs, and check-host fails until it is fixed.
cake_apply() {
    case "${CFG_CAKE:-}" in
    on) ;;
    off) cake_remove; cake_settings_put ""; return 0 ;;
    *) return 0 ;;
    esac
    local dev old changed=0 stopped=0 ready=0 rc=0
    step "Sharing the upload fairly (CAKE)"
    dev=$(cake_dev)
    if [ -z "$dev" ]; then
        warn "this machine has no default route, so I cannot tell which device carries the upload, and it is not shared fairly. Run the setup again once the network is up."
        return 0
    fi
    apt_install iproute2 || warn "iproute2, which holds tc, could not be installed."
    old=$(kv_get "$CAKE_ENV" HOLLOW_CAKE_DEV)
    # Another device: the old one's queue goes with the settings that made it.
    if [ -n "$old" ] && [ "$old" != "$dev" ] && unit_active "$CAKE_UNIT"; then
        run_ok systemctl stop "$CAKE_UNIT"
        stopped=1
    fi
    cake_settings_put "$dev"
    [ "$PUT_CHANGED" = 1 ] && changed=1
    put_file "$UNIT_DIR/$CAKE_UNIT" 0644 root root <"$DEPLOY/$CAKE_UNIT"
    [ "$PUT_CHANGED" = 1 ] && changed=1
    if cake_kernel_ready; then
        ready=1
        echo sch_cake | put_file "$CAKE_MODLOAD" 0644 root root
        run_ok modprobe -q sch_cake
    fi
    run systemctl daemon-reload
    run systemctl enable --quiet "$CAKE_UNIT"
    if [ "$changed" = 1 ] && [ "$stopped" = 0 ] && unit_active "$CAKE_UNIT"; then
        run systemctl reload "$CAKE_UNIT" || rc=1
    else
        run systemctl start "$CAKE_UNIT" || rc=1
    fi
    if [ "$rc" = 0 ]; then
        say "  the upload is shared fairly between the hosts this machine sends to, at $CFG_CAKE_MBIT Mbit/s on $dev"
    elif [ "$ready" = 0 ]; then
        warn "this machine's kernel has no CAKE (the sch_cake module), so the upload is not shared fairly yet. On Ubuntu, sudo apt install linux-modules-extra-$(uname -r) adds it. Then run sudo hollow-relay-setup again. Everything else is set up, and check-host shows a FAIL line until then."
    else
        warn "the fair-share shaper did not start, so the upload is not shared fairly yet. See: journalctl -u $CAKE_UNIT"
    fi
    return 0
}

# The shaper, its unit and its module line gone, and with them the queue it
# put on its device. Its settings are the caller's to rewrite or remove.
cake_remove() {
    local dev removed=0
    dev=$(kv_get "$CAKE_ENV" HOLLOW_CAKE_DEV)
    if unit_exists "$CAKE_UNIT"; then run_ok systemctl disable --now "$CAKE_UNIT"; fi
    # Also when its unit had failed. Another root queue is the operator's.
    if [ -n "$dev" ]; then
        case "$(tc qdisc show dev "$dev" root 2>/dev/null)" in
        "qdisc cake "*) run_ok tc qdisc del dev "$dev" root ;;
        esac
    fi
    if [ -e "$UNIT_DIR/$CAKE_UNIT" ]; then run rm -f "$UNIT_DIR/$CAKE_UNIT"; removed=1; fi
    if [ -e "$CAKE_MODLOAD" ]; then run rm -f "$CAKE_MODLOAD"; fi
    if [ "$removed" = 1 ]; then run systemctl daemon-reload; fi
    return 0
}

# For the status screen.
cake_state() {
    [ "${CFG_CAKE:-}" = on ] || { cake_text; return 0; }
    case "$(systemctl is-active "$CAKE_UNIT" 2>/dev/null)" in
    active) echo "on, $CFG_CAKE_MBIT Mbit/s on $(kv_get "$CAKE_ENV" HOLLOW_CAKE_DEV)" ;;
    failed) echo "FAILED (journalctl -u $CAKE_UNIT)" ;;
    *) echo "not in place (journalctl -u $CAKE_UNIT says why)" ;;
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
    cake_apply
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
    follow_apply
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
    follow_remove
    turn_lock_remove
    cake_remove
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
