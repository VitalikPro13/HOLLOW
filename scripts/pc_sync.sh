#!/bin/bash
# Ship a worktree from the Mac (the source of truth) to its own folder on the Windows
# PC, D:\dev\wt\<name>, for the Windows build and fleet. The PC's main checkout
# (C:\Users\Jabun\Documents\Coding\HOLLOW) is never written: it holds Vitalik's own
# uncommitted files. Files go over as git would store them (LF), uncommitted and
# untracked changes included; the first run also copies the gitignored files the
# Windows build needs (cargo config, ffmpeg, the screen audio capturer) from that
# main checkout. Every shipped file is checked against its git hash on the PC.
#
#   bash scripts/pc_sync.sh <name> [worktree]     first run ships everything, later runs the changes
#   PC_HOST=pc-ts bash scripts/pc_sync.sh <name>  over Tailscale (default: pc, then pc-ts)
#
# Then drive Windows peers from the Mac as windows:<letter> (fleet_remote.ps1), e.g.
#   FLEET_BACKEND=macos pwsh scripts/fleet.ps1 -Scenario friend_dm -Peers a=e,b=windows:f
set -euo pipefail

name=${1:?usage: pc_sync.sh <name> [worktree]}
src=${2:-$(pwd)}
[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "name: lowercase letters, digits and dashes"; exit 2; }
dest="D:\\dev\\wt\\$name"
main_tree='C:\Users\Jabun\Documents\Coding\HOLLOW'
ssh_opts=(-o ConnectTimeout=6 -o BatchMode=yes)

host=${PC_HOST:-}
if [ -z "$host" ]; then
    for candidate in pc pc-ts; do
        if ssh "${ssh_opts[@]}" "$candidate" 'exit 0' 2> /dev/null; then
            host=$candidate
            break
        fi
    done
fi
[ -n "$host" ] || { echo "PC not reachable over ssh (pc, pc-ts)"; exit 1; }
# The PC's ssh login shell is PowerShell 7: every remote command is PowerShell.
pc() { ssh "${ssh_opts[@]}" "$host" "$@"; }

cd "$src"
git rev-parse --git-dir > /dev/null
# The tree as it stands now, built in a throwaway index so the real one is untouched.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$(git rev-parse --git-path index)" "$work/index"
GIT_INDEX_FILE=$work/index git add -A -- . ':(exclude)tmp*.txt' ':(exclude).team' ':(exclude)target'
tree=$(GIT_INDEX_FILE=$work/index git write-tree)
export_git() { git -c core.autocrlf=false -c core.eol=lf "$@"; }

# Regular files only: Windows tar cannot make the iOS plugin's symlinks without admin.
git ls-tree -r --format='%(objectmode) %(objectname) %(path)' "$tree" |
    awk '$1 == "100644" || $1 == "100755"' > "$work/all"

base=$(pc "if (Test-Path '$dest\\.pc_sync_tree') { (Get-Content -Raw '$dest\\.pc_sync_tree').Trim() }" | tr -d '\r')
first=0
if [ -n "$base" ] && git cat-file -e "$base^{tree}" 2> /dev/null; then
    [ "$base" = "$tree" ] && { echo "$name: up to date on $host:$dest"; exit 0; }
    git diff --no-renames --name-status "$base" "$tree" > "$work/list"
    awk -F'\t' '$1 != "D" {print $2}' "$work/list" > "$work/changed.raw"
    awk -F'\t' '$1 == "D" {print $2}' "$work/list" > "$work/gone"
    # Keep only paths that are regular files in the new tree.
    awk 'NR == FNR { want[$0] = 1; next } substr($0, 49) in want { print substr($0, 49) }' \
        "$work/changed.raw" "$work/all" > "$work/changed"
else
    first=1
    cut -c49- "$work/all" > "$work/changed"
    : > "$work/gone"
fi
changed_count=$(wc -l < "$work/changed" | tr -d ' ')
gone_count=$(wc -l < "$work/gone" | tr -d ' ')
[ "$first" = 1 ] && echo "$name: first sync to $host:$dest (whole tree, $changed_count files)"

pc "New-Item -ItemType Directory -Force '$dest' | Out-Null"
if [ "$changed_count" -gt 0 ]; then
    files=()
    while IFS= read -r path; do files+=("$path"); done < "$work/changed"
    export_git archive --format=tar -o "$work/ship.tar" "$tree" -- "${files[@]}"
    scp -q "${ssh_opts[@]}" "$work/ship.tar" "$host:D:/dev/wt/$name.pc_sync.tar"
    pc "tar -xf 'D:\\dev\\wt\\$name.pc_sync.tar' -C '$dest'; \$code = \$LASTEXITCODE; Remove-Item -Force 'D:\\dev\\wt\\$name.pc_sync.tar'; exit \$code"
fi
if [ "$gone_count" -gt 0 ]; then
    scp -q "${ssh_opts[@]}" "$work/gone" "$host:D:/dev/wt/$name.pc_sync.gone"
    pc "Get-Content -Encoding UTF8 'D:\\dev\\wt\\$name.pc_sync.gone' | Where-Object { \$_ } | ForEach-Object { Remove-Item -LiteralPath (Join-Path '$dest' \$_) -Force -ErrorAction SilentlyContinue }; Remove-Item -Force 'D:\\dev\\wt\\$name.pc_sync.gone'"
fi
echo "$name: $changed_count shipped, $gone_count removed"

if [ "$first" = 1 ]; then
    # Read from the main checkout, written only into this worktree, never overwriting.
    pc "foreach (\$rel in 'rust\\hollow_core\\.cargo\\config.toml', 'android\\app\\google-services.json', 'vendor\\ffmpeg', 'packages\\flutter_webrtc\\test_apps\\screen_audio_test\\build\\Release') { \$s = Join-Path '$main_tree' \$rel; \$d = Join-Path '$dest' \$rel; if ((Test-Path \$s) -and -not (Test-Path \$d)) { New-Item -ItemType Directory -Force (Split-Path \$d) | Out-Null; Copy-Item -Recurse \$s \$d; Write-Output \"copied \$rel\" } }"
fi

# Every shipped file must hash on the PC to what git holds. Raw bytes, no filters:
# the PC's git config converts line endings.
if [ "$changed_count" -gt 0 ]; then
    awk 'NR == FNR { want[$0] = 1; next } substr($0, 49) in want' "$work/changed" "$work/all" > "$work/sel"
    want=$(cut -c8-47 "$work/sel" | sort | shasum -a 256)
    cut -c49- "$work/sel" > "$work/paths"
    scp -q "${ssh_opts[@]}" "$work/paths" "$host:D:/dev/wt/$name.pc_sync.paths"
    got=$(pc "Set-Location '$dest'; cmd /c 'git -c core.autocrlf=false hash-object --no-filters --stdin-paths < D:\\dev\\wt\\$name.pc_sync.paths'; Remove-Item -Force 'D:\\dev\\wt\\$name.pc_sync.paths'" |
        tr -d '\r' | sort | shasum -a 256)
    [ "$want" = "$got" ] || { echo "$name: shipped files do not match the tree; not marking it synced"; exit 1; }
fi
pc "Set-Content -NoNewline -Encoding ASCII '$dest\\.pc_sync_tree' '$tree'"
echo "$name: synced $tree to $host:$dest"
