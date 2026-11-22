#!/bin/bash
# Build the prebuilt relay tarballs self-hosters' installers download
# (relay-uws/install.sh via relay-uws/deploy/lib/release_feed.sh). RUN ON A
# LINUX MACHINE WITH DOCKER (the build VM).
#
#   bash scripts/build_relay_binaries.sh [--arch x86_64|aarch64|all] [--build N] [--out DIR] [--jobs N]
#   bash scripts/build_relay_binaries.sh --check-only    (only the tree checks below)
#   bash scripts/build_relay_binaries.sh --stage-setup <repo> <dir> | --pack <dir> <out.tar.gz>
#                                                        (the two packing steps alone, for tests)
#   bash scripts/build_relay_binaries.sh --check-needed <native.sh> [--list NAME] <soname...> | --check-notices <dir>
#                                        | --check-covers <notices> <cargo tree output>
#                                        | --check-sodium <libsodium-dev version> | --check-sodium-archive <deb arch...>
#                                        | --check-sodium-owner <libsodium.a> <deb arch>
#                                        | --forwarder-notices <out> <rust/hollow_core>
#                                                        (the build's library, notices and libsodium checks alone, for tests)
#
# Builds hollow-relay (relay-uws, C++, libsodium linked in) and hollow-forwarder
# (rust/hollow_core --features forwarder) in an Ubuntu 22.04 container
# (scripts/relay_binaries.Dockerfile), so they need nothing newer than glibc
# 2.35; aarch64 is cross-compiled. Packs
#   DIR/hollow-relay-<version>[-b<N>]-linux-<arch>.tar.gz
# each holding hollow-relay, hollow-forwarder, VERSION and the setup's own copy
# under setup/ (install.sh, deploy/ and the push sender's files, what
# install_installer_copy keeps), so the one signature covers both, and writes
# DIR/relay.json (url, sha256, size per machine, issued 0) for
# `scripts/sign_feeds.sh --relay`. <version> is HOLLOW_RELAY_VERSION in
# relay-uws/src/version.h. No secrets; nothing is signed or uploaded here.
#
# What is built is exactly one commit: the tree and every submodule must be
# clean and at their recorded commits, the build reads a `git archive` of HEAD
# (never the working tree), VERSION and relay.json name the commit, and
# SOURCE_DATE_EPOCH defaults to its commit time. Cargo downloads and build
# trees live only in the container, so no cache carries from one release into
# the next. The builder image is kept between builds; `--clean` builds it again
# from nothing (no layer cache), so its apt layer takes the archive as it is
# today. The build refuses an image whose libsodium-dev is older than the one
# the archive offers, and says to use `--clean`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# The push sender's files the setup's copy holds; native.sh SETUP_PUSH_FILES.
SETUP_PUSH_FILES="index.js fcm.js unifiedpush.js package.json package-lock.json hollow-push.service"

# <repo> <dir>: the setup's copy from a tree, as install_installer_copy lays it out.
stage_setup() {
  local src=$1 dst=$2 f
  [ -f "$src/relay-uws/install.sh" ] && [ -d "$src/relay-uws/deploy" ] || { echo "no relay-uws/install.sh and deploy/ in $src" >&2; return 1; }
  mkdir -p "$dst/push-sidecar"
  cp -R "$src/relay-uws/deploy" "$dst/deploy"
  cp "$src/relay-uws/install.sh" "$dst/install.sh"
  for f in $SETUP_PUSH_FILES; do
    [ -f "$src/push-sidecar/$f" ] && cp "$src/push-sidecar/$f" "$dst/push-sidecar/"
  done
  chmod -R u=rwX,go=rX "$dst"
  chmod 0755 "$dst/install.sh"
  # Every box checks the copy this way before it goes live (setup_new_check),
  # so a copy that cannot start is never packed.
  local out
  out="$(cd / && env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C bash "$dst/install.sh" --self-check 2>&1)" ||
    { printf 'the setup copy in %s does not start: %s\n' "$dst" "$out" >&2; return 1; }
  case "$out" in "hollow-relay-setup self-check "*) ;; *) echo "the setup copy's self-check printed: $out" >&2; return 1 ;; esac
}

# <dir> <out>: the same bytes from the same files on every machine: files only
# (no folder entries), sorted, root-owned, stamped SOURCE_DATE_EPOCH, gzip
# without a name or time.
pack_tarball() {
  local stage=$1 out=$2 list
  list="$(cd "$stage" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
  printf '%s\n' "$list" | tar --owner=0 --group=0 --numeric-owner --mtime="@${SOURCE_DATE_EPOCH:-0}" \
    --format=ustar --no-recursion --verbatim-files-from -C "$stage" -T - -cf - | gzip -n -9 > "$out.part"
  mv -f "$out.part" "$out"
}

# <file> <name>: the words of a NAME="..." list that may span lines, one a line.
shell_list() {
  awk -v n="$2" 'index($0, n "=\"") == 1 { f = 1; sub(/^[^"]*"/, "") }
    f { l = $0; e = sub(/".*$/, "", l); print l; if (e) exit }' "$1" | tr -s '[:blank:]' '\n' | sed '/^$/d'
}

# <native.sh> [--list NAME] <soname...>: the libraries both programs link to,
# together, must be exactly the setup's PREBUILT_NEEDS (the forwarder's alone,
# FORWARDER_NEEDS), each with its packages in LIB_PACKAGES: a box judges from
# those lists whether the programs can start there (#153).
needed_known() {
  local lib needs known got file=$1 list=PREBUILT_NEEDS
  shift
  if [ "${1:-}" = --list ]; then list=$2; shift 2; fi
  needs="$(shell_list "$file" "$list" | LC_ALL=C sort -u)"
  known="$(shell_list "$file" LIB_PACKAGES | sed -n 's/=.*//p')"
  [ -n "$needs" ] && [ -n "$known" ] || { echo "no $list or LIB_PACKAGES in $file" >&2; return 1; }
  # The dynamic loader (ld-linux-*) is the system's own, never a package to judge.
  got="$(printf '%s\n' "$@" | sed '/^$/d; /^ld-linux/d' | LC_ALL=C sort -u)"
  if [ "$got" != "$needs" ]; then
    echo "the programs link to: $(tr '\n' ' ' <<<"$got"); $list (relay-uws/deploy/lib/native.sh) names: $(tr '\n' ' ' <<<"$needs"). Make them the same." >&2
    return 1
  fi
  for lib in $got; do
    grep -qxF -- "$lib" <<<"$known" || { echo "$lib has no packages in LIB_PACKAGES (relay-uws/deploy/lib/native.sh): add the ones that hold it" >&2; return 1; }
  done
}

# <stage>: the release carries the license notices of what is built into its
# programs, as files of the setup's copy (the tarball's root holds only the
# programs and VERSION): the relay's (libsodium, uWebSockets, uSockets and
# what they bundle, JSON for Modern C++) from the tree, and the forwarder's
# (every crate, and the C libraries three of them bundle), written by this
# build from the locked tree. The setup installs both beside the programs
# (native.sh RELEASE_NOTICES).
NOTICES=setup/deploy/THIRD_PARTY_NOTICES.txt
FWD_NOTICES=setup/deploy/THIRD_PARTY_NOTICES_FORWARDER.txt
# release_feed.sh _HF_SETUP_MAX_FILE: a bigger setup file strands every box.
NOTICES_MAX=1048576
notices_ok() {
  local f part
  for f in "$1/$NOTICES" "$1/$FWD_NOTICES"; do
    [ -f "$f" ] || { echo "$f is missing" >&2; return 1; }
    [ "$(wc -c <"$f")" -le "$NOTICES_MAX" ] || { echo "$f is over $NOTICES_MAX bytes, more than a setup file may hold" >&2; return 1; }
  done
  f=$1/$NOTICES
  for part in "libsodium" "License: ISC" "Colin Percival" "uWebSockets" "uSockets" "Apache License" "Fatkhiev" "Markus Kuhn" "JSON for Modern C++"; do
    grep -qF -- "$part" "$f" || { echo "$f does not name $part" >&2; return 1; }
  done
  f=$1/$FWD_NOTICES
  for part in "Mozilla Public License" "https://crates.io/crates/" "SQLCipher" "ZETETIC LLC" "AWS-LC" "Eric Young" "BoringSSL" "from the crate ring "; do
    grep -qF -- "$part" "$f" || { echo "$f does not name $part" >&2; return 1; }
  done
}

# <notices> <cargo tree --prefix none output>: every crate the forwarder is
# built from, but the forwarder's own, is named under a license.
notices_cover() {
  local want have missing
  want="$(sed -e 's/ (.*)$//' -e '/^hollow_core v/d' -e '/^$/d' "$2" | LC_ALL=C sort -u)"
  have="$(awk '/^Used by:$/ { f = 1; next } /^---TEXT---$/ { f = 0 } f && NF >= 2 { print $1 " v" $2 }' "$1" | LC_ALL=C sort -u)"
  [ -n "$want" ] || { echo "no crates in $2" >&2; return 1; }
  missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))"
  [ -z "$missing" ] || { echo "the forwarder's notices name no license for: $(tr '\n' ' ' <<<"$missing")" >&2; return 1; }
}

# <Cargo.lock> <crate>: its one locked version.
lock_version() {
  local v
  v="$(awk -v n="$2" '$0 == "name = \"" n "\"" { getline; if ($1 == "version") { gsub(/"/, "", $3); print $3 } }' "$1")"
  [ -n "$v" ] && [ "$(printf '%s\n' "$v" | wc -l)" -eq 1 ] || { echo "Cargo.lock does not lock exactly one $2" >&2; return 1; }
  printf '%s\n' "$v"
}

# Ubuntu 22.04's libsodium with the crypto_core_ed25519_is_valid_point fix
# (CVE-2025-69277): the hard minimum, whatever the archive says.
SODIUM_FLOOR=1.0.18-1ubuntu0.22.04.1
# <version>: a libsodium-dev the relay may link in.
sodium_ok() { [ -n "$1" ] && dpkg --compare-versions "$1" ge "$SODIUM_FLOOR"; }

# <deb arch> <installed version> <apt-cache policy output>: the candidate
# comes from the archive and the installed libsodium-dev is not older than it,
# nor than the floor. Without fresh package lists apt names the
# installed version itself as the candidate (from /var/lib/dpkg/status only),
# which would pass any image, so that case is refused too.
sodium_judge() {
  local a=$1 installed=$2 policy=$3 cand
  cand="$(printf '%s\n' "$policy" | sed -n 's/^  Candidate: //p' | head -n 1)"
  if [ -z "$cand" ] || [ "$cand" = "(none)" ] || ! printf '%s\n' "$policy" | awk -v c="$cand" '
      /^ \*\*\* / || /^     [^ ]/ { v = $(NF - 1); next }
      /^      +-?[0-9]+ [^ ]/ { if (v == c && $2 != "/var/lib/dpkg/status") ok = 1 }
      END { exit !ok }'; then
    echo "ERROR: apt offers no libsodium-dev:$a from the Ubuntu archive (its package lists could not be read), so the libsodium linked in cannot be checked against the newest one. Check this machine's network and build again." >&2
    return 1
  fi
  if [ -z "$installed" ] || ! dpkg --compare-versions "$installed" ge "$cand"; then
    echo "ERROR: the builder image has libsodium-dev:$a ${installed:-(none)}, older than $cand in the Ubuntu archive. Build again with --clean, which builds the image from nothing." >&2
    return 1
  fi
  sodium_ok "$installed" ||
    { echo "ERROR: the builder image has libsodium-dev:$a $installed, older than $SODIUM_FLOOR. Build again with --clean once the archive has the fix." >&2; return 1; }
}

# <deb arch...>: after a fresh apt-get update, each machine's libsodium-dev is
# the newest the archive offers. A list that fails to download fails the update
# (Error-Mode=any), never leaving the old lists to judge by.
sodium_current() {
  local a out
  out="$(LC_ALL=C apt-get -o APT::Update::Error-Mode=any -o Acquire::Retries=3 -qq update 2>&1)" ||
    { printf 'ERROR: apt-get update failed, so the libsodium linked in cannot be checked against the newest one. Check this machine'"'"'s network and build again:\n%s\n' "$out" >&2; return 1; }
  for a in "$@"; do
    sodium_judge "$a" "$(dpkg-query -W -f='${Version}' "libsodium-dev:$a" 2>/dev/null || true)" \
      "$(LC_ALL=C apt-cache policy "libsodium-dev:$a" 2>/dev/null || true)" || return 1
  done
}

# <libsodium.a> <deb arch>: the archive CMake linked is libsodium-dev's for
# that machine, so the version judged above is the one linked in.
sodium_archive_owned() {
  local path owner
  path="$(readlink -f -- "$1")" && [ -f "$path" ] || { echo "ERROR: no libsodium archive at ${1:-(none)}" >&2; return 1; }
  owner="$(LC_ALL=C dpkg -S "$path" 2>/dev/null || true)"
  [ "$owner" = "libsodium-dev:$2: $path" ] && return 0
  owner=${owner%": $path"}
  echo "ERROR: the relay links $path, which belongs to ${owner:-no package}, not libsodium-dev:$2" >&2
  return 1
}

# The forwarder's notices for both machines, from the locked tree: cargo-about
# (pinned in the Dockerfile) with --frozen reads only the crates as packaged,
# never the network, then the license files of the C libraries three crates
# bundle, from their locked sources. A crate the tree has and the notices miss
# stops the build.
# <out> <rust/hollow_core>
forwarder_notices() {
  local out=$1 core=$2 lock=$2/Cargo.lock t v dir f files name title spec
  rm -f "$out" "$out.part"
  cargo fetch --locked --quiet --manifest-path "$core/Cargo.toml"
  (cd "$core" && cargo about generate --frozen --features forwarder -c about_forwarder.toml \
    --target x86_64-unknown-linux-gnu --target aarch64-unknown-linux-gnu -o "$out.crates" about_forwarder.hbs) ||
    { echo "ERROR: cargo about could not write the forwarder's notices" >&2; return 1; }
  : >"$out.tree"
  for t in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
    cargo tree --frozen --quiet -e normal,build --features forwarder --target "$t" --prefix none --format '{p}' \
      --manifest-path "$core/Cargo.toml" >>"$out.tree"
  done
  notices_cover "$out.crates" "$out.tree" || return 1
  {
    cat "$out.crates"
    printf '%s\n' "==============================================================================" \
      "C libraries built in" "" \
      "Three of the crates above build C code into the program. Their license files" \
      "follow as those crates ship them: SQLCipher (sqlcipher-src, with the LibTomCrypt" \
      "license it also ships; SQLite itself is in the public domain), AWS-LC with the" \
      "OpenSSL and SSLeay licenses of the code it derives from (aws-lc-sys), and" \
      "ring's BoringSSL-derived code (ring)." ""
    for spec in "sqlcipher-src:SQLCipher:sqlcipher/LICENSE-sqlcipher sqlcipher/LICENSE-libtomcrypt" \
      "aws-lc-sys:AWS-LC:aws-lc/LICENSE" "ring:ring:LICENSE LICENSE-BoringSSL LICENSE-other-bits"; do
      IFS=: read -r name title files <<<"$spec"
      v=$(lock_version "$lock" "$name") || return 1
      dir=$(ls -d "${CARGO_HOME:-/opt/cargo}"/registry/src/*/"$name-$v" 2>/dev/null) && [ "$(printf '%s\n' "$dir" | wc -l)" -eq 1 ] ||
        { echo "ERROR: no one locked source of $name $v" >&2; return 1; }
      printf '%s\n' "------------------------------------------------------------------------------" \
        "$title, from the crate $name $v (https://crates.io/crates/$name/$v)" ""
      for f in $files; do
        [ -f "$dir/$f" ] || { echo "ERROR: $name $v has no $f" >&2; return 1; }
        printf '%s\n' "--- $f" ""
        cat "$dir/$f"
        printf '\n'
      done
    done
  } >"$out.part" || return 1
  mv -f "$out.part" "$out"
  rm -f "$out.crates" "$out.tree"
}

case "${1:-}" in
  --check-sodium) sodium_ok "${2:-}"; exit $? ;;
  --check-sodium-archive) shift; sodium_current "$@"; exit $? ;;
  --check-sodium-owner) sodium_archive_owned "${2:-}" "${3:-}"; exit $? ;;
  --check-covers) notices_cover "${2:?notices}" "${3:?tree}"; exit $? ;;
  --forwarder-notices)
    forwarder_notices "$(cd "$(dirname "${2:?out}")" && pwd)/$(basename "$2")" "$(cd "${3:?rust/hollow_core}" && pwd)"; exit $? ;;
  --check-notices) notices_ok "${2:?stage dir}"; exit $? ;;
  --stage-setup) stage_setup "${2:?repo}" "${3:?dir}"; exit $? ;;
  --check-needed) shift; needed_known "$@"; exit $? ;;
  --pack) pack_tarball "${2:?dir}" "${3:?out}"; exit $? ;;
esac
RUST_VERSION=1.95.0
# Named after the Dockerfile's hash, so an edited Dockerfile never reuses an old image.
IMAGE="hollow-relay-builder:jammy-rust$RUST_VERSION-$(sha256sum "$SCRIPT_DIR/relay_binaries.Dockerfile" | cut -c1-12)"
GLIBC_FLOOR=2.35

arch=all
build=0
out="$ROOT_DIR/build/relay-binaries"
jobs=""
inside=0
clean=0
check_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) arch="$2"; shift 2 ;;
    --build) build="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --jobs) jobs="$2"; shift 2 ;;
    --inside) inside=1; shift ;;
    --clean) clean=1; shift ;;
    --check-only) check_only=1; shift ;;
    *) echo "usage: $0 [--arch x86_64|aarch64|all] [--build N] [--out DIR] [--jobs N] [--clean | --check-only]" >&2; exit 2 ;;
  esac
done
case "$arch" in
  x86_64 | aarch64) arches="$arch" ;;
  all) arches="x86_64 aarch64" ;;
  *) echo "--arch must be x86_64, aarch64 or all" >&2; exit 2 ;;
esac
[[ $build =~ ^[0-9]{1,4}$ ]] || { echo "--build must be 0 to 9999" >&2; exit 2; }
build=$((10#$build))

VERSION="$(sed -nE 's/^#define HOLLOW_RELAY_VERSION "([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$ROOT_DIR/relay-uws/src/version.h")"
[ -n "$VERSION" ] || { echo "HOLLOW_RELAY_VERSION not found in relay-uws/src/version.h" >&2; exit 1; }
if [ "$build" -gt 0 ]; then TAG="$VERSION-b$build"; else TAG="$VERSION"; fi

docker_build_fresh=()
if [ "$clean" = 1 ]; then
  docker image rm -f "$IMAGE" >/dev/null 2>&1 || true
  # Volumes earlier versions of this script kept between runs.
  docker volume rm -f hollow-relay-cargo hollow-relay-cargo-git hollow-relay-work >/dev/null 2>&1 || true
  echo "removed $IMAGE; it is built again from nothing"
  # Removing the image alone keeps BuildKit's cached apt layer, so the same
  # libsodium-dev would come back.
  docker_build_fresh=(--no-cache --pull)
fi

# ---------------------------------------------------------------------------
# Inside the container: /src is the exported commit (read-only), /out the
# output folder, /work the build trees (gone with the container).
# ---------------------------------------------------------------------------
build_one() {
  local a=$1 triple prefix="" relay_dir="/work/relay-$1" stage="/work/stage-$1"
  local -a cmake_cross=()
  case "$a" in
    x86_64) triple=x86_64-unknown-linux-gnu ;;
    aarch64)
      triple=aarch64-unknown-linux-gnu
      prefix=aarch64-linux-gnu-
      cmake_cross=(-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64
        -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++)
      export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
      export CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc
      export CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++
      export AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar
      export PKG_CONFIG_ALLOW_CROSS=1
      export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
      ;;
  esac

  local deb_arch=amd64 sodium_version sodium_archive
  [ "$a" = aarch64 ] && deb_arch=arm64
  echo "==> [$a] hollow-relay"
  rm -rf "$relay_dir"
  # libsodium linked in, so the relay starts on systems with another libsodium
  # soname (Ubuntu 26.10, #153); needed_known below refuses a relay that still
  # links it as a shared library.
  cmake -S /src/relay-uws -B "$relay_dir" -DCMAKE_BUILD_TYPE=Release -DHOLLOW_STATIC_SODIUM=ON "${cmake_cross[@]}" >/dev/null
  cmake --build "$relay_dir" -j"${jobs:-$(nproc)}" >/dev/null
  # The archive's fixes reach a self-hoster only through a release: the
  # libsodium-dev judged newest at the start must be the one linked in.
  sodium_archive=$(sed -n 's/^HOLLOW_SODIUM_ARCHIVE:FILEPATH=//p' "$relay_dir/CMakeCache.txt")
  sodium_archive_owned "$sodium_archive" "$deb_arch" || exit 1
  sodium_version=$(dpkg-query -W -f='${Version}' "libsodium-dev:$deb_arch")
  sodium_ok "$sodium_version" ||
    { echo "ERROR: the builder image has libsodium-dev $sodium_version ($a), older than $SODIUM_FLOOR. Build again with --clean." >&2; exit 1; }
  echo "    libsodium linked in: $sodium_archive, libsodium-dev:$deb_arch $sodium_version"

  echo "==> [$a] hollow-forwarder"
  CARGO_TARGET_DIR=/work/cargo-target CARGO_PROFILE_RELEASE_DEBUG=0 CARGO_PROFILE_RELEASE_STRIP=symbols \
    cargo build --release --locked --quiet --features forwarder --bin hollow-forwarder \
    --target "$triple" ${jobs:+-j "$jobs"} --manifest-path /src/rust/hollow_core/Cargo.toml

  rm -rf "$stage"
  mkdir -p "$stage"
  install -m 0755 "$relay_dir/hollow-relay" "$stage/hollow-relay"
  install -m 0755 "/work/cargo-target/$triple/release/hollow-forwarder" "$stage/hollow-forwarder"
  "${prefix}strip" --strip-all "$stage/hollow-relay" "$stage/hollow-forwarder"
  printf 'version=%s\nbuild=%s\ncommit=%s\n' "$VERSION" "$build" "$RELAY_COMMIT" > "$stage/VERSION"
  chmod 0644 "$stage/VERSION"
  stage_setup /src "$stage/setup"
  install -m 0644 /work/forwarder-notices.txt "$stage/$FWD_NOTICES"
  notices_ok "$stage" || { echo "ERROR: the setup copy ($a) lacks the notices of what the programs build in" >&2; exit 1; }

  # Built on 22.04, so nothing should need a newer glibc; this catches a base
  # image change before a self-hoster's box does.
  local bin newest needs all_needs="" fwd_needs=""
  for bin in hollow-relay hollow-forwarder; do
    newest="$("${prefix}objdump" -T "$stage/$bin" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/GLIBC_//' | sort -uV | tail -1)"
    if [ "$(printf '%s\n%s\n' "$newest" "$GLIBC_FLOOR" | sort -V | tail -1)" != "$GLIBC_FLOOR" ]; then
      echo "ERROR: $bin ($a) needs glibc $newest, newer than $GLIBC_FLOOR" >&2
      exit 1
    fi
    needs="$("${prefix}readelf" -d "$stage/$bin" | sed -nE 's/.*Shared library: \[(.*)\]/\1/p' | tr '\n' ' ')"
    all_needs="$all_needs $needs"
    [ "$bin" = hollow-forwarder ] && fwd_needs=$needs
    echo "    $bin: newest glibc symbol $newest; needs $needs"
  done
  # shellcheck disable=SC2086 # one word per library
  needed_known /src/relay-uws/deploy/lib/native.sh $all_needs ||
    { echo "ERROR: the programs ($a) link to libraries the setup does not judge" >&2; exit 1; }
  # shellcheck disable=SC2086 # one word per library
  needed_known /src/relay-uws/deploy/lib/native.sh --list FORWARDER_NEEDS $fwd_needs ||
    { echo "ERROR: the forwarder ($a) links to libraries the setup does not judge" >&2; exit 1; }

  local tarball="/out/hollow-relay-$TAG-linux-$a.tar.gz"
  pack_tarball "$stage" "$tarball"
  echo "    -> $tarball ($(stat -c %s "$tarball") bytes)"
}

if [ "$inside" = 1 ]; then
  [[ ${RELAY_COMMIT:-} =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || { echo "RELAY_COMMIT is not a commit" >&2; exit 1; }
  mkdir -p /work
  # A tarball from an earlier run must never end up in this run's feed.
  rm -f /out/hollow-relay-*.tar.gz /out/hollow-relay-*.part /out/relay.json
  # Before anything is built: the libsodium each relay links in is the newest
  # the archive offers.
  debs=""
  for a in $arches; do case "$a" in x86_64) debs="$debs amd64" ;; aarch64) debs="$debs arm64" ;; esac; done
  # shellcheck disable=SC2086 # one word per machine
  sodium_current $debs || exit 1
  echo "==> the forwarder's notices"
  forwarder_notices /work/forwarder-notices.txt /src/rust/hollow_core || exit 1
  for a in $arches; do build_one "$a"; done
  echo "==> relay.json"
  CARGO_TARGET_DIR=/work/manifest-target cargo build --release --locked --quiet \
    --manifest-path /src/rust/hollow_manifest/Cargo.toml
  /work/manifest-target/release/hollow-manifest relay-feed --dir /out --version "$VERSION" --build "$build" --out /out/relay.json
  chown -R "${OUT_UID:-0}:${OUT_GID:-0}" /out
  exit 0
fi

# ---------------------------------------------------------------------------
# On the build machine.
# ---------------------------------------------------------------------------
command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1 || { echo "$ROOT_DIR is not a git checkout; build from one" >&2; exit 1; }
dirty="$(git -C "$ROOT_DIR" status --porcelain --ignore-submodules=none)"
if [ -n "$dirty" ]; then
  printf 'refusing to build: the tree has changes that are not committed, so the binaries would match no commit:\n%s\n' "$dirty" >&2
  exit 1
fi
# '-' = not checked out, '+' = at another commit than the tree records, 'U' = conflicted.
submods="$(git -C "$ROOT_DIR" submodule status --recursive)"
bad_submods="$(printf '%s\n' "$submods" | grep -E '^[-+U]' || true)"
if [ -n "$bad_submods" ]; then
  printf 'refusing to build: these submodules are not checked out at the commit the tree records:\n%s\nRun: git submodule update --init --recursive\n' "$bad_submods" >&2
  exit 1
fi
for need in relay-uws/uSockets relay-uws/uWebSockets; do
  if ! printf '%s\n' "$submods" | grep -qE "^ [0-9a-f]+ $need( |\$)"; then
    echo "refusing to build: $need is not a checked-out submodule. Run: git submodule update --init --recursive" >&2
    exit 1
  fi
done
COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT_DIR" log -1 --format=%ct HEAD)}"
if [ "$check_only" = 1 ]; then
  echo "clean at $COMMIT (SOURCE_DATE_EPOCH $SOURCE_DATE_EPOCH)"
  exit 0
fi

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
mkdir -p "$out"
out="$(cd "$out" && pwd)"
src="$(mktemp -d "${TMPDIR:-/tmp}/hollow-relay-src.XXXXXX")"
trap 'rm -rf "$src"' EXIT
# Exactly the commit: tracked files of HEAD and of each submodule at its recorded commit.
git -C "$ROOT_DIR" archive --format=tar HEAD -- relay-uws push-sidecar rust/hollow_core rust/hollow_dfn rust/hollow_manifest \
  scripts/build_relay_binaries.sh scripts/relay_binaries.Dockerfile legal/manifest.json | tar -x -C "$src"
while read -r _ path _; do
  git -C "$ROOT_DIR/$path" archive --format=tar --prefix="$path/" HEAD | tar -x -C "$src"
done < <(printf '%s\n' "$submods" | grep -E '^ ')
echo "==> Hollow relay $TAG, commit $COMMIT, machines: $arches"
docker build -q -t "$IMAGE" ${docker_build_fresh[@]+"${docker_build_fresh[@]}"} --build-arg RUST_VERSION="$RUST_VERSION" \
  -f "$SCRIPT_DIR/relay_binaries.Dockerfile" "$SCRIPT_DIR" >/dev/null
docker run --rm \
  -v "$src:/src:ro" -v "$out:/out" \
  -e OUT_UID="$(id -u)" -e OUT_GID="$(id -g)" -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" -e RELAY_COMMIT="$COMMIT" \
  "$IMAGE" bash /src/scripts/build_relay_binaries.sh --inside --arch "$arch" --build "$build" ${jobs:+--jobs "$jobs"}
echo ""
echo "==== DONE: relay $TAG from $COMMIT ===="
ls -l "$out"
echo "Next: upload the tarballs, then scripts/sign_feeds.sh --relay $out/relay.json"
