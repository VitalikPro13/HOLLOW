# shellcheck shell=bash
# Sourced by the Apple release scripts: tells Mach-O code from other files by its
# first eight bytes, so no file-format parser (libmagic's `file`) reads build
# output in a job that holds a signing key.
#
# is_macho FILE returns 0 for a thin Mach-O (32 or 64 bit, either byte order) or a
# fat header naming 1..30 slices, 1 for anything else. A fat magic with any other
# count (a Java class file starts with cafebabe too, then its version) stops the
# script: nothing we ship is a class file, and a file we cannot classify is never
# waved through unchecked.
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
  echo "ERROR: $1 has a fat Mach-O magic but names $n slices (a Java class file or a malformed header)" >&2
  exit 1
}
