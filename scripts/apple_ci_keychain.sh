#!/bin/bash
# A throwaway keychain for one job of .github/workflows/release-apple.yml.
#
#   bash scripts/apple_ci_keychain.sh create developer-id   # macOS: Developer ID Application
#   bash scripts/apple_ci_keychain.sh create distribution   # iOS: Apple Distribution
#   bash scripts/apple_ci_keychain.sh delete                # always safe, also when create never ran
#
# create reads P12_BASE64 and P12_PASSWORD (the job's secrets) and MAC_TEAM_ID
# (+ MAC_SIGN_NAME for developer-id): the keychain must end up holding exactly one
# valid identity of that kind for that team. The keychain password is random and
# never leaves this process; the private key is imported non-extractable and only
# Apple's signing tools may use it; the decoded .p12 is gone before this returns.
# Runs only on a GitHub runner: it changes the user's keychain search list.
set -euo pipefail

[ "${GITHUB_ACTIONS:-}" = true ] || { echo "ERROR: apple_ci_keychain.sh runs only on a GitHub Actions runner" >&2; exit 1; }
: "${RUNNER_TEMP:?RUNNER_TEMP missing}"
KC="$RUNNER_TEMP/hollow-signing.keychain-db"
LIST_BACKUP="$RUNNER_TEMP/hollow-keychain-list.txt"

# Apple's intermediates, pinned: codesign needs the chain to embed.
DEVELOPER_ID_CERTS=(
  "https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a"
  "https://www.apple.com/certificateauthority/DeveloperIDCA.cer 7afc9d01a62f03a2de9637936d4afe68090d2de18d03f29c88cfb0b1ba63587f"
)
DISTRIBUTION_CERTS=(
  "https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f"
)

search_list() { security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/'; }

import_intermediates() {
  local entry url want file got
  for entry in "$@"; do
    url="${entry% *}"; want="${entry#* }"
    file="$(mktemp "$RUNNER_TEMP/apple-ca.XXXXXX")"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$file" "$url"
    got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || { echo "ERROR: $url hash $got, expected $want" >&2; rm -f "$file"; exit 1; }
    security import "$file" -k "$KC" -t cert -f x509 >/dev/null
    rm -f "$file"
  done
}

case "${1:-}" in
  create)
    kind="${2:-}"
    : "${MAC_TEAM_ID:?MAC_TEAM_ID missing}"
    [[ "$MAC_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "ERROR: MAC_TEAM_ID is not a 10-character Team ID" >&2; exit 1; }
    case "$kind" in
      developer-id)
        : "${MAC_SIGN_NAME:?MAC_SIGN_NAME missing}"
        want=(-xF "\"Developer ID Application: $MAC_SIGN_NAME ($MAC_TEAM_ID)\"")
        certs=("${DEVELOPER_ID_CERTS[@]}")
        # The DMG is signed after the app's notarization wait.
        lock_after=3600 ;;
      distribution)
        want=(-xE "\"Apple Distribution: .+ \\($MAC_TEAM_ID\\)\"")
        certs=("${DISTRIBUTION_CERTS[@]}")
        # Signing the app and its extensions takes minutes.
        lock_after=900 ;;
      *) echo "usage: $0 create developer-id|distribution" >&2; exit 2 ;;
    esac
    [ -n "${P12_BASE64:-}" ] || { echo "ERROR: P12_BASE64 is empty (the .p12 secret is not set in this environment?)" >&2; exit 1; }
    [ ! -e "$KC" ] || { echo "ERROR: $KC already exists" >&2; exit 1; }
    p12_b64="$P12_BASE64"; p12_pass="${P12_PASSWORD:-}"
    unset P12_BASE64 P12_PASSWORD
    umask 077
    p12="$(mktemp "$RUNNER_TEMP/p12.XXXXXX")"
    trap 'rm -f "$p12"' EXIT
    printf '%s' "$p12_b64" | base64 --decode > "$p12"
    unset p12_b64
    kc_pass="$(head -c 32 /dev/urandom | base64)"
    search_list > "$LIST_BACKUP"
    security create-keychain -p "$kc_pass" "$KC"
    security set-keychain-settings -lut "$lock_after" "$KC"
    security unlock-keychain -p "$kc_pass" "$KC"
    # shellcheck disable=SC2046
    security list-keychains -d user -s "$KC" $(grep -vxF "$KC" "$LIST_BACKUP" | tr '\n' ' ')
    import_intermediates "${certs[@]}"
    security import "$p12" -k "$KC" -f pkcs12 -P "$p12_pass" -x -T /usr/bin/codesign >/dev/null
    unset p12_pass
    rm -f "$p12"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_pass" "$KC" >/dev/null
    unset kc_pass
    identities="$(security find-identity -v -p codesigning "$KC" | grep -oE '"[^"]+"' || true)"
    matching="$(grep "${want[@]}" <<<"$identities" || true)"
    if [ "$(grep -c . <<<"$matching")" != 1 ] || [ "$(grep -c . <<<"$identities")" != 1 ]; then
      echo "ERROR: the .p12 must hold exactly one valid $kind identity of team $MAC_TEAM_ID; the keychain has:" >&2
      printf '%s\n' "$identities" >&2
      exit 1
    fi
    echo "keychain ready: $matching"
    ;;
  delete)
    if [ -f "$LIST_BACKUP" ]; then
      # shellcheck disable=SC2046
      security list-keychains -d user -s $(grep -vxF "$KC" "$LIST_BACKUP" | tr '\n' ' ') || true
      rm -f "$LIST_BACKUP"
    fi
    if [ -e "$KC" ]; then security delete-keychain "$KC"; fi
    echo "keychain removed"
    ;;
  *)
    echo "usage: $0 create developer-id|distribution | delete" >&2
    exit 2
    ;;
esac
