#!/bin/bash
# Unpacks a build handed from one job of .github/workflows/release-apple.yml to the next.
#
#   bash scripts/apple_ci_unpack.sh TAR SHA256 DEST TOP
#
# TAR must hash to SHA256 (the producing job's output, never a file that travelled
# with the tar), hold only TOP and entries under it, and DEST/TOP must not exist
# yet: a signing job never mixes the handed-over build with anything already there.
set -euo pipefail

tar_file="$1"; want="$2"; dest="$3"; top="$4"
[[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "ERROR: expected sha256 '$want' is not a digest (did the producing job set its output?)" >&2; exit 1; }
[[ "$top" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$top" != . ] && [ "$top" != .. ] || { echo "ERROR: bad top-level name '$top'" >&2; exit 1; }
got="$(shasum -a 256 "$tar_file" | cut -d' ' -f1)"
[ "$got" = "$want" ] || { echo "ERROR: $(basename "$tar_file") hashes to $got, the producing job said $want" >&2; exit 1; }
[ ! -e "$dest/$top" ] && [ ! -L "$dest/$top" ] || { echo "ERROR: $dest/$top already exists" >&2; exit 1; }
list="$(mktemp)"; trap 'rm -f "$list"' EXIT
tar -tf "$tar_file" > "$list"
first="$(sed -n 1p "$list")"
first_type="$(tar -tvf "$tar_file" "$first" | sed -n 1p | cut -c1)"
{ [ "$first" = "$top" ] || [ "$first" = "$top/" ]; } && [ "$first_type" = d ] \
  || { echo "ERROR: $(basename "$tar_file") does not start with the directory $top" >&2; exit 1; }
while IFS= read -r entry; do
  case "$entry" in
    "$top"|"$top/"|"$top/"*) ;;
    *) echo "ERROR: $(basename "$tar_file") holds an entry outside $top/: $entry" >&2; exit 1 ;;
  esac
  case "/$entry/" in
    */../*) echo "ERROR: $(basename "$tar_file") holds a '..' entry: $entry" >&2; exit 1 ;;
  esac
done < "$list"
mkdir -p "$dest"
tar -xpf "$tar_file" -C "$dest"
[ -d "$dest/$top" ] && [ ! -L "$dest/$top" ] || { echo "ERROR: $dest/$top is not a directory" >&2; exit 1; }
echo "unpacked $top ($got)"
