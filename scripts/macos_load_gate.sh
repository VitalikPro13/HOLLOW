#!/bin/bash
# Keeps a macOS app bundle from loading code that lives outside it (HOL-SEC-187).
#
#   bash scripts/macos_load_gate.sh strip APP          delete every LC_RPATH that leaves the bundle
#   bash scripts/macos_load_gate.sh check APP          fail if any Mach-O can still load from outside
#   bash scripts/macos_load_gate.sh signed APP TEAMID  check, plus: every Mach-O verifies, is signed
#                                                      by TEAMID, and no executable disables library
#                                                      validation
#
# strip edits Mach-O files in place and so runs BEFORE signing. check fails on:
#   - an LC_RPATH that is not @executable_path/@loader_path inside the bundle, or /usr/lib/swift
#   - a dylib load (strong, weak, re-export, upward, lazy) by an absolute path outside /usr/lib
#     and /System/Library, by a bare relative path, or by an @-path that climbs out of the bundle
#   - any LC_DYLD_ENVIRONMENT
#   - a symlink in the bundle whose target is absolute or climbs out of the bundle
# An @-path or symlink may climb (..) only before its first named component: after a symlinked
# directory, .. leaves wherever that link points, which no text check can follow.
# Prebuilt pods (mdk ships /opt/homebrew/lib and /usr/local/lib rpaths plus weak loads of
# libraries we never bundle) are why: a user-writable rpath directory plus a weak load lets
# any local process put code into the signed app.
# Mach-O files are found by their magic bytes, never by name, mode or file(1).
set -euo pipefail

usage() { echo "usage: $0 strip APP | check APP | signed APP TEAMID" >&2; exit 2; }
[ $# -ge 2 ] || usage
MODE="$1"
TEAM=""
case "$MODE" in
  strip|check) [ $# -eq 2 ] || usage ;;
  signed) [ $# -eq 3 ] && [ -n "$3" ] || usage; TEAM="$3" ;;
  *) usage ;;
esac
[ -d "$2" ] || { echo "ERROR: $2 is not a directory" >&2; exit 2; }
APP="$(cd "$2" && pwd -P)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DYLIB_CMDS='LC_LOAD_DYLIB|LC_LOAD_WEAK_DYLIB|LC_REEXPORT_DYLIB|LC_LOAD_UPWARD_DYLIB|LC_LAZY_LOAD_DYLIB'

# A fat magic naming any count but 1..30 stops the gate: a Java class file starts with
# cafebabe too, and a file we cannot classify is never waved through unchecked.
is_macho() {
  local h n
  h="$(od -An -tx1 -N8 -- "$1")" || { echo "ERROR: cannot read $1" >&2; exit 1; }
  h="${h//[[:space:]]/}"
  case "${h:0:8}" in
    feedface|cefaedfe|feedfacf|cffaedfe) return 0 ;;
    cafebabe|cafebabf) n="${h:8:8}" ;;
    bebafeca|bfbafeca) n="${h:14:2}${h:12:2}${h:10:2}${h:8:2}" ;;
    *) return 1 ;;
  esac
  [ ${#n} = 8 ] || { echo "ERROR: $1 is a truncated fat Mach-O header" >&2; exit 1; }
  n=$((16#$n))
  [ "$n" -ge 1 ] && [ "$n" -le 30 ] && return 0
  echo "ERROR: $1 has a fat Mach-O magic but names $n slices" >&2
  exit 1
}

# Lexical: dyld resolves these strings without following symlinks we could vet here.
normalize() {
  local out="" part
  local -a parts=()
  IFS=/ read -r -a parts <<< "$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ''|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$part" ;;
    esac
  done
  printf '%s\n' "${out:-/}"
}

inside_app() { case "$1/" in "$APP"/*) return 0 ;; *) return 1 ;; esac; }

# REL read from DIR (a directory in the bundle) stays in the bundle: relative, its .. only
# leading, and no more of them than DIR lies below the bundle root.
walk_inside() {
  local dir="$1" rel="$2" part depth=0 named=0
  local -a parts=()
  case "$rel" in /*|*$'\n'*) return 1 ;; esac
  IFS=/ read -r -a parts <<< "${dir#"$APP"}"
  for part in ${parts[@]+"${parts[@]}"}; do
    [ -n "$part" ] && depth=$((depth + 1))
  done
  IFS=/ read -r -a parts <<< "$rel"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ''|.) ;;
      ..) [ $named -eq 0 ] || return 1
          depth=$((depth - 1))
          [ $depth -ge 0 ] || return 1 ;;
      *) named=1 ;;
    esac
  done
}

has_dotdot() { case "/$1/" in */../*) return 0 ;; *) return 1 ;; esac; }

# Every slice's load paths as "CMD<TAB>PATH"; a line otool did not print whole fails closed.
load_entries() {
  otool -arch all -l "$1" | awk -v cmds="^(LC_RPATH|LC_DYLD_ENVIRONMENT|$DYLIB_CMDS)\$" '
    /^ +cmd / { cmd = $2; next }
    cmd ~ cmds && /^ +(path|name) / {
      line = $0
      sub(/^ +(path|name) /, "", line)
      if (sub(/ \(offset [0-9]+\)$/, "", line) == 0) line = "<unparsed>"
      print cmd "\t" line
      cmd = ""
    }'
}

# @loader_path is the file's own directory. @executable_path is an executable's own directory
# in its own load commands; in a library's it is whichever bundled executable loaded it, so
# it must stay inside for every one of them (EXE_BASES, set per file).
EXE_DIRS=()
EXE_BASES=()
at_path_inside() {
  local p="$1" dir="$2" rest base
  case "$p" in
    @loader_path|@loader_path/*)
      rest="${p#@loader_path}"
      walk_inside "$dir" "${rest#/}" ;;
    @executable_path|@executable_path/*)
      rest="${p#@executable_path}"
      [ ${#EXE_BASES[@]} -gt 0 ] || return 1
      for base in "${EXE_BASES[@]}"; do
        walk_inside "$base" "${rest#/}" || return 1
      done ;;
    *) return 1 ;;
  esac
}

rpath_ok() {
  case "$1" in
    @loader_path|@loader_path/*|@executable_path|@executable_path/*) at_path_inside "$1" "$2" ;;
    /*) [ "$(normalize "$1")" = /usr/lib/swift ] ;;
    *) return 1 ;;
  esac
}

dylib_ok() {
  local p="$1" n
  case "$p" in
    @rpath/*) ! has_dotdot "${p#@rpath/}" ;;
    @loader_path/*|@executable_path/*) at_path_inside "$p" "$2" ;;
    /*)
      # /System/Volumes/Data is the user-writable volume under another name.
      has_dotdot "$p" && return 1
      n="$(normalize "$p")"
      case "$n" in /usr/lib/*|/System/Library/*) return 0 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

MACHOS="$TMP/machos"
: > "$MACHOS"
while IFS= read -r -d '' f; do
  if is_macho "$f"; then printf '%s\n' "$f" >> "$MACHOS"; fi
done < <(find "$APP" -type f -print0)
[ -s "$MACHOS" ] || { echo "ERROR: no Mach-O files under $APP" >&2; exit 1; }

EXES="$TMP/exes"
: > "$EXES"
while IFS= read -r f; do
  if otool -hv "$f" | grep -w EXECUTE >/dev/null; then
    printf '%s\n' "$f" >> "$EXES"
    EXE_DIRS+=("$(dirname "$f")")
  fi
done < "$MACHOS"

has_rpath() {
  otool -l "$2" | awk -v want="$1" '
    /^ +cmd / { cmd = $2; next }
    cmd == "LC_RPATH" && /^ +path / {
      line = $0; sub(/^ +path /, "", line); sub(/ \(offset [0-9]+\)$/, "", line)
      if (line == want) found = 1
    }
    END { exit found ? 0 : 1 }'
}

delete_rpath() {
  local r="$1" f="$2" arch slice tries=0
  while load_entries "$f" | grep -xF "LC_RPATH"$'\t'"$r" >/dev/null; do
    tries=$((tries + 1))
    [ $tries -le 16 ] || { echo "ERROR: could not delete rpath $r from $f" >&2; exit 1; }
    if install_name_tool -delete_rpath "$r" "$f" 2>/dev/null; then continue; fi
    # A fat file whose slices disagree: install_name_tool needs the rpath in every slice.
    for arch in $(lipo -archs "$f"); do
      slice="$TMP/slice"
      lipo -thin "$arch" "$f" -output "$slice"
      if has_rpath "$r" "$slice"; then
        install_name_tool -delete_rpath "$r" "$slice"
        lipo "$f" -replace "$arch" "$slice" -output "$TMP/fat"
        cat "$TMP/fat" > "$f"
      fi
    done
  done
}

bad=0
while IFS= read -r f; do
  dir="$(dirname "$f")"
  if grep -xF "$f" "$EXES" >/dev/null; then
    EXE_BASES=("$dir")
  else
    EXE_BASES=(${EXE_DIRS[@]+"${EXE_DIRS[@]}"})
  fi
  entries="$TMP/entries"
  if ! load_entries "$f" > "$entries"; then
    echo "FAIL ${f#"$APP"/}: otool could not read its load commands"
    bad=1; continue
  fi
  while IFS=$'\t' read -r cmd p; do
    case "$cmd" in
      LC_RPATH)
        rpath_ok "$p" "$dir" && continue
        if [ "$MODE" = strip ] && [ "$p" != "<unparsed>" ]; then
          echo "    strip ${f#"$APP"/}: LC_RPATH $p"
          delete_rpath "$p" "$f"
          continue
        fi ;;
      LC_DYLD_ENVIRONMENT) ;;
      *) dylib_ok "$p" "$dir" && continue ;;
    esac
    echo "FAIL ${f#"$APP"/}: $cmd $p"
    bad=1
  done < <(sort -u "$entries")
done < "$MACHOS"

# A bundled symlink is sealed by its text, and dyld follows it: an @rpath name, a framework's
# Versions/Current, any of them pointing out would load a file no signature of ours covers.
while IFS= read -r -d '' l; do
  t="$(readlink "$l")"
  walk_inside "$(dirname "$l")" "$t" && continue
  echo "FAIL ${l#"$APP"/}: symlink to $t leaves the bundle"
  bad=1
done < <(find "$APP" -type l -print0)

# Library validation is what keeps a file planted INSIDE a user-owned bundle out, so the
# shipped signature must not waive it and every Mach-O must carry our team.
if [ "$MODE" = signed ]; then
  while IFS= read -r f; do
    # A file strip edited after the release script signed it, or one it never re-signed.
    if ! codesign --verify --strict --all-architectures "$f" > "$TMP/verify" 2>&1; then
      why="$(grep -v '^In architecture' "$TMP/verify" | head -1)" || true
      echo "FAIL ${f#"$APP"/}: its signature does not verify (${why#"$f": })"
      bad=1
    fi
    for arch in $(lipo -archs "$f"); do
      team="$(codesign -dv --arch "$arch" "$f" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
      if [ "$team" != "$TEAM" ]; then
        echo "FAIL ${f#"$APP"/} ($arch): team '${team:-none}', expected $TEAM"
        bad=1
      fi
    done
  done < "$MACHOS"
  while IFS= read -r f; do
    if codesign -d --entitlements :- "$f" 2>/dev/null | grep -F com.apple.security.cs.disable-library-validation >/dev/null; then
      echo "FAIL ${f#"$APP"/}: its entitlements disable library validation"
      bad=1
    fi
  done < "$EXES"
fi

if [ "$MODE" != strip ]; then
  if [ $bad -ne 0 ]; then
    echo "ERROR: $APP fails the load gate (HOL-SEC-187)" >&2
    exit 1
  fi
  echo "    load gate: $(wc -l < "$MACHOS" | tr -d ' ') Mach-O files load only from the bundle and the OS"
elif [ $bad -ne 0 ]; then
  echo "ERROR: strip left load paths it cannot fix (run check for the list)" >&2
  exit 1
fi
