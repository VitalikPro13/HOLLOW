#!/usr/bin/env bash
# Sign, upload and verify the release feeds (status.json, news.json, relay.json).
#
# Apps from 0.12.2 on show a feed only when its `.sig` sidecar verifies against
# the key baked into rust/hollow_core/src/api/updater.rs, for THAT feed's name;
# an unsigned or edited-after-signing feed shows nothing. Apps up to 0.12.1 read
# the files as before and never look at the sidecar.
#
#   scripts/sign_feeds.sh --news legal/news.json
#   scripts/sign_feeds.sh --status ~/hollow-feeds/status.json [--skip-upload]
#   scripts/sign_feeds.sh --relay build/relay-binaries/relay.json [--allow-downgrade]
#
# relay.json (from scripts/build_relay_binaries.sh) is what self-hosters'
# installers read (relay-uws/deploy/lib/release_feed.sh): they refuse it unless
# its signature verifies for the relay name and its `issued` is not older than
# the copy they last accepted. Its tarballs must sit next to it (feed-sign opens
# each one) and already be live with the hashes it names (checked before the
# upload); a version and build below the live feed's needs --allow-downgrade.
# Once the live pair verifies, the pair is copied to legal/relay.json(.sig) and
# the floors in release_feed.sh are raised to it: commit all three.
#
# status.json and relay.json get `issued` rewritten before signing (--stamp):
# the highest of now, the file's issued + 1 and the LIVE copy's issued + 1,
# since apps and installers drop any copy stamped earlier than one they
# already accepted. A stamp over an hour past
# this clock is refused. Every feed is shape and size checked first
# (hollow-manifest feed-sign), so a notice the app would skip is refused here
# instead of shipping unseen.
#
# Reads MANIFEST_SIGNING_KEY (and optional RELEASE_SSH, RELEASE_DIR) from
# scripts/release.local.env. The PowerShell twin is scripts/sign_feeds.ps1.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
status_file=""
news_file=""
relay_file=""
skip_upload=0
allow_downgrade=()
while [ $# -gt 0 ]; do
  case "$1" in
    --status) status_file="$2"; shift 2 ;;
    --news) news_file="$2"; shift 2 ;;
    --relay) relay_file="$2"; shift 2 ;;
    --skip-upload) skip_upload=1; shift ;;
    --allow-downgrade) allow_downgrade=(--allow-downgrade); shift ;;
    *) echo "usage: $0 [--status <status.json>] [--news <news.json>] [--relay <relay.json> [--allow-downgrade]] [--skip-upload]" >&2; exit 2 ;;
  esac
done
if [ -z "$status_file" ] && [ -z "$news_file" ] && [ -z "$relay_file" ]; then
  echo "nothing to sign: pass --status, --news and/or --relay" >&2
  exit 2
fi

env_file="$repo/scripts/release.local.env"
[ -f "$env_file" ] || { echo "scripts/release.local.env not found (copy release.local.env.example)" >&2; exit 1; }
# Read values without sourcing the file: it is plain KEY=value, possibly quoted.
cfg() {
  { grep -E "^$1=" "$env_file" || true; } | tail -n 1 | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//'
}
key_path="$(cfg MANIFEST_SIGNING_KEY)"
[ -n "$key_path" ] || { echo "MANIFEST_SIGNING_KEY missing in release.local.env" >&2; exit 1; }
[ -f "$key_path" ] || { echo "signing key not found: $key_path" >&2; exit 1; }
ssh_target="$(cfg RELEASE_SSH)"; ssh_target="${ssh_target:-hostinger}"
remote_dir="$(cfg RELEASE_DIR)"; remote_dir="${remote_dir:-~/domains/anonlisten.com/public_html/hollow/releases}"
base_url="https://anonlisten.com/hollow/releases"

# The keys the APP trusts, read from the MANIFEST_SIGNING_PUBKEYS list only.
pubkeys="$(awk '/^const MANIFEST_SIGNING_PUBKEYS/,/^\];/' "$repo/rust/hollow_core/src/api/updater.rs" \
  | grep -oE '"[0-9a-f]{64}"' | tr -d '"')"
[ -n "$pubkeys" ] || { echo "no MANIFEST_SIGNING_PUBKEYS entry found in updater.rs" >&2; exit 1; }

(cd "$repo/rust/hollow_manifest" && cargo build --release --quiet)
tool="$repo/rust/hollow_manifest/target/release/hollow-manifest"
[ -x "$tool" ] || { echo "hollow-manifest did not build" >&2; exit 1; }

verify_any() { # <args...>: true when ANY baked-in key verifies
  for pk in $pubkeys; do
    if "$tool" feed-verify "$@" --pubkey "$pk" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

record_relay() { # <relay.json that is now live>
  if [ "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" != "$repo/legal/relay.json" ]; then
    cp "$1" "$repo/legal/relay.json"
    cp "$1.sig" "$repo/legal/relay.json.sig"
  fi
  "$tool" relay-floor "$repo/legal/relay.json" "$repo/relay-uws/deploy/lib/release_feed.sh"
}

sign_one() { # <feed> <file>
  local feed="$1" file="$2" stamp=()
  [ -f "$file" ] || { echo "$file not found" >&2; exit 1; }
  case "$feed" in
    status) stamp=(--stamp --live "$base_url/$feed.json") ;;
    relay) stamp=(--stamp --live "$base_url/$feed.json" ${allow_downgrade[@]+"${allow_downgrade[@]}"}) ;;
  esac
  echo "[$feed] signing $file"
  "$tool" feed-sign "$file" --feed "$feed" --key "$key_path" --out "$file.sig" ${stamp[@]+"${stamp[@]}"}
  verify_any "$file" "$file.sig" --feed "$feed" \
    || { echo "$file.sig does not verify against any key in updater.rs: key and MANIFEST_SIGNING_PUBKEYS have drifted" >&2; exit 1; }
  if [ "$skip_upload" = 1 ]; then
    echo "[$feed] local pair verifies; upload skipped"
    return
  fi
  if [ "$feed" = relay ]; then
    "$tool" relay-check-live "$file" \
      || { echo "[relay] upload the tarballs relay.json names before the feed" >&2; exit 1; }
  fi
  # Signature first: a reader between the two copies sees a pair that fails
  # and shows nothing until its next poll, never a forged notice.
  scp -q "$file.sig" "$ssh_target:$remote_dir/$feed.json.sig"
  scp -q "$file" "$ssh_target:$remote_dir/$feed.json"
  for pk in $pubkeys; do
    if "$tool" feed-verify --url "$base_url/$feed.json" --feed "$feed" --pubkey "$pk"; then
      [ "$feed" = relay ] && record_relay "$file"
      return
    fi
  done
  echo "[$feed] the LIVE pair does not verify (a CDN copy can lag up to 10 minutes; recheck with feed-verify --url before touching anything)" >&2
  exit 1
}

[ -n "$news_file" ] && sign_one news "$news_file"
[ -n "$status_file" ] && sign_one status "$status_file"
[ -n "$relay_file" ] && sign_one relay "$relay_file"
echo "Done. Commit legal/news.json + legal/news.json.sig when news changed; legal/relay.json, legal/relay.json.sig and relay-uws/deploy/lib/release_feed.sh when the relay changed."
