#!/bin/bash
# Proves a release's hollow_core was compiled by the pinned compiler
# (HOLLOW_RUST_TOOLCHAIN), not whatever rustc a build step found first.
#
#   bash scripts/apple_ci_rustc_check.sh BINARY
#
# The standard library leaves /rustc/<commit>/ source paths in every Rust binary:
# BINARY must hold at least one, and all of them must name the commit of
# `rustup run $HOLLOW_RUST_TOOLCHAIN rustc -vV`.
set -euo pipefail

bin="${1:-}"
: "${HOLLOW_RUST_TOOLCHAIN:?HOLLOW_RUST_TOOLCHAIN missing}"
[[ "$HOLLOW_RUST_TOOLCHAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: HOLLOW_RUST_TOOLCHAIN is not X.Y.Z" >&2; exit 1; }
[ -f "$bin" ] && [ ! -L "$bin" ] || { echo "ERROR: '$bin' is not a file" >&2; exit 1; }

want="$(rustup run "$HOLLOW_RUST_TOOLCHAIN" rustc -vV | sed -n 's/^commit-hash: //p')"
[[ "$want" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: no commit hash from rustc $HOLLOW_RUST_TOOLCHAIN" >&2; exit 1; }
found="$(LC_ALL=C grep -aoE '/rustc/[0-9a-f]{40}/' "$bin" | sort -u || true)"
[ -n "$found" ] || { echo "ERROR: $(basename "$bin") names no rustc commit" >&2; exit 1; }
if [ "$found" != "/rustc/$want/" ]; then
  echo "ERROR: $(basename "$bin") was not compiled by rustc $HOLLOW_RUST_TOOLCHAIN ($want) alone; it names:" >&2
  printf '%s\n' "$found" >&2
  exit 1
fi
echo "$(basename "$bin"): rustc $HOLLOW_RUST_TOOLCHAIN ($want)"
