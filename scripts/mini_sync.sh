#!/bin/bash
# Ship a worktree to its own folder on the Mac mini (~/wt/<name>) for iOS Simulator,
# Android emulator and macOS checks. The mini's own checkout (~/src/HOLLOW) is never
# written: Windows is the source of truth, and several agents share the mini. Files go
# over as git would store them (LF), uncommitted changes included; the gitignored
# platform files (Firebase configs, iOS signing) are copied from ~/src/HOLLOW once.
# Every shipped file is checked against its git hash on the mini.
#
#   bash scripts/mini_sync.sh <name> [worktree]    first run ships everything, later runs the changes
#   MINI_HOST=jabun@192.168.18.36 bash scripts/mini_sync.sh <name>
#
# Run the fleet from that folder with your own peer letters, never another agent's:
#   ssh <mini> 'cd ~/wt/<name> && FLEET_BACKEND=android pwsh scripts/fleet.ps1 -Build -Peers c,d'
set -euo pipefail

name=${1:?usage: mini_sync.sh <name> [worktree]}
src=${2:-$(pwd)}
[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "name: lowercase letters, digits and dashes"; exit 2; }
dest="wt/$name"
ssh_opts=(-o HostKeyAlias=192.168.18.39 -o ConnectTimeout=4 -o BatchMode=yes)

# The mini's DHCP lease moves; its host key does not.
host=${MINI_HOST:-}
if [ -z "$host" ]; then
    for ip in 36 2 37 38 39 40 41; do
        if ssh "${ssh_opts[@]}" "jabun@192.168.18.$ip" true 2> /dev/null; then
            host="jabun@192.168.18.$ip"
            break
        fi
    done
fi
[ -n "$host" ] || { echo "mini not reachable (powered off, or Remote Login off)"; exit 1; }
mini() { ssh "${ssh_opts[@]}" "$host" "$@"; }

cd "$src"
git rev-parse --git-dir > /dev/null
# The tree as it stands now, built in a throwaway index so the real one is untouched.
idx=$(mktemp)
trap 'rm -f "$idx" "$idx".*' EXIT
cp "$(git rev-parse --git-path index)" "$idx"
GIT_INDEX_FILE=$idx git add -A -- . ':(exclude)tmp*.txt'
tree=$(GIT_INDEX_FILE=$idx git write-tree)
export_git() { git -c core.autocrlf=false -c core.eol=lf "$@"; }

base=$(mini "cat ~/$dest/.mini_sync_tree 2> /dev/null || true")
if [ -n "$base" ] && git cat-file -e "$base^{tree}" 2> /dev/null; then
    [ "$base" = "$tree" ] && { echo "$name: up to date on $host"; exit 0; }
    git diff --no-renames --name-status "$base" "$tree" > "$idx.list"
    mapfile -t changed < <(awk -F'\t' '$1 != "D" {print $2}' "$idx.list")
    mapfile -t gone < <(awk -F'\t' '$1 == "D" {print $2}' "$idx.list")
    # A long path list would pass Windows' command-line limit: ship the whole tree then.
    if [ ${#changed[@]} -gt 400 ]; then
        export_git archive "$tree" | mini "tar -xf - -C ~/$dest"
    elif [ ${#changed[@]} -gt 0 ]; then
        export_git archive "$tree" -- "${changed[@]}" | mini "tar -xf - -C ~/$dest"
    fi
    if [ ${#gone[@]} -gt 0 ]; then
        printf '%s\0' "${gone[@]}" | mini "cd ~/$dest && xargs -0 rm -f --"
    fi
    echo "$name: ${#changed[@]} changed, ${#gone[@]} removed"
else
    echo "$name: first sync to $host:~/$dest (whole tree)"
    mini "mkdir -p ~/$dest"
    export_git archive "$tree" | mini "tar -xf - -C ~/$dest"
    mini "cd ~/src/HOLLOW && for f in ios/GoogleService-Info.plist ios/Flutter/LocalSigning.xcconfig \
        macos/Flutter/LocalSigning.xcconfig android/app/google-services.json; do \
        [ -e \"\$f\" ] && cp \"\$f\" ~/$dest/\"\$f\"; done; true"
    mapfile -t changed < <(git ls-tree -r --name-only "$tree")
fi

# Every shipped regular file must hash on the mini to what git holds (symlinks and the
# relay's submodules are not files there).
if [ ${#changed[@]} -gt 0 ]; then
    git ls-tree -r --format='%(objectmode) %(objectname) %(path)' "$tree" |
        awk '$1 == "100644" || $1 == "100755"' > "$idx.all"
    printf '%s\n' "${changed[@]}" > "$idx.paths"
    awk 'NR == FNR { want[$0] = 1; next } substr($0, 49) in want' "$idx.paths" "$idx.all" > "$idx.sel"
    want=$(cut -c8-47 "$idx.sel" | sort | sha256sum)
    got=$(cut -c49- "$idx.sel" | mini "cd ~/$dest && git hash-object --stdin-paths" | sort | sha256sum)
    [ "$want" = "$got" ] || { echo "$name: shipped files do not match the tree; not marking it synced"; exit 1; }
fi
mini "echo $tree > ~/$dest/.mini_sync_tree"
echo "$name: synced $tree to $host:~/$dest"
