#!/bin/bash
# Build the prebuilt relay tarballs self-hosters' installers download
# (relay-uws/install.sh via relay-uws/deploy/lib/release_feed.sh). RUN ON A
# LINUX MACHINE WITH DOCKER (the build VM).
#
#   bash scripts/build_relay_binaries.sh [--arch x86_64|aarch64|all] [--build N] [--out DIR] [--jobs N]
#   bash scripts/build_relay_binaries.sh --check-only    (only the tree checks below)
#   bash scripts/build_relay_binaries.sh --stage-setup <repo> <dir> | --pack <dir> <out.tar.gz>
#                                                        (the two packing steps alone, for tests)
#
# Builds hollow-relay (relay-uws, C++) and hollow-forwarder (rust/hollow_core
# --features forwarder) in an Ubuntu 22.04 container (scripts/relay_binaries.Dockerfile),
# so they need nothing newer than glibc 2.35; aarch64 is cross-compiled. Packs
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
# the next; `--clean` removes the builder image.
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

case "${1:-}" in
  --stage-setup) stage_setup "${2:?repo}" "${3:?dir}"; exit $? ;;
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

if [ "$clean" = 1 ]; then
  docker image rm -f "$IMAGE" >/dev/null 2>&1 || true
  # Volumes earlier versions of this script kept between runs.
  docker volume rm -f hollow-relay-cargo hollow-relay-cargo-git hollow-relay-work >/dev/null 2>&1 || true
  echo "removed $IMAGE"
  exit 0
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

  echo "==> [$a] hollow-relay"
  rm -rf "$relay_dir"
  cmake -S /src/relay-uws -B "$relay_dir" -DCMAKE_BUILD_TYPE=Release "${cmake_cross[@]}" >/dev/null
  cmake --build "$relay_dir" -j"${jobs:-$(nproc)}" >/dev/null

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

  # Built on 22.04, so nothing should need a newer glibc; this catches a base
  # image change before a self-hoster's box does.
  local bin newest
  for bin in hollow-relay hollow-forwarder; do
    newest="$("${prefix}objdump" -T "$stage/$bin" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/GLIBC_//' | sort -uV | tail -1)"
    if [ "$(printf '%s\n%s\n' "$newest" "$GLIBC_FLOOR" | sort -V | tail -1)" != "$GLIBC_FLOOR" ]; then
      echo "ERROR: $bin ($a) needs glibc $newest, newer than $GLIBC_FLOOR" >&2
      exit 1
    fi
    echo "    $bin: newest glibc symbol $newest; needs $("${prefix}readelf" -d "$stage/$bin" | sed -nE 's/.*Shared library: \[(.*)\]/\1/p' | tr '\n' ' ')"
  done

  local tarball="/out/hollow-relay-$TAG-linux-$a.tar.gz"
  pack_tarball "$stage" "$tarball"
  echo "    -> $tarball ($(stat -c %s "$tarball") bytes)"
}

if [ "$inside" = 1 ]; then
  [[ ${RELAY_COMMIT:-} =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || { echo "RELAY_COMMIT is not a commit" >&2; exit 1; }
  mkdir -p /work
  # A tarball from an earlier run must never end up in this run's feed.
  rm -f /out/hollow-relay-*.tar.gz /out/hollow-relay-*.part /out/relay.json
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
docker build -q -t "$IMAGE" --build-arg RUST_VERSION="$RUST_VERSION" \
  -f "$SCRIPT_DIR/relay_binaries.Dockerfile" "$SCRIPT_DIR" >/dev/null
docker run --rm \
  -v "$src:/src:ro" -v "$out:/out" \
  -e OUT_UID="$(id -u)" -e OUT_GID="$(id -g)" -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" -e RELAY_COMMIT="$COMMIT" \
  "$IMAGE" bash /src/scripts/build_relay_binaries.sh --inside --arch "$arch" --build "$build" ${jobs:+--jobs "$jobs"}
echo ""
echo "==== DONE: relay $TAG from $COMMIT ===="
ls -l "$out"
echo "Next: upload the tarballs, then scripts/sign_feeds.sh --relay $out/relay.json"
