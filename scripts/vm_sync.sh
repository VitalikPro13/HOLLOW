#!/bin/bash
# Ship a worktree's tree to a folder on the Linux build VM for headless Linux fleet
# runs (FLEET_LINUX_HEADLESS=1), the way mini_sync.sh ships one to the Mac mini: files
# go over as git stores them (LF), uncommitted changes included, and every shipped
# file is checked against its git hash there. A folder that is a git checkout gets
# only the files that differ from its HEAD the first time (its build stays warm).
#
#   bash scripts/vm_sync.sh <folder on the VM> [worktree]     e.g. Documents/HOLLOW or wt/md-link
#   VM_HOST=hollowvm bash scripts/vm_sync.sh wt/md-link
set -euo pipefail

dest=${1:?usage: vm_sync.sh <folder relative to the VM home> [worktree]}
src=${2:-$(pwd)}
[[ "$dest" =~ ^[A-Za-z0-9][A-Za-z0-9/_.-]*$ ]] || { echo "folder: a path relative to the VM home"; exit 2; }
host=${VM_HOST:-hollowvm}
vm() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "$@"; }
vm true || { echo "VM not reachable (start it: VBoxManage startvm Ubuntu24 --type headless)"; exit 1; }

cd "$src"
idx=$(mktemp)
trap 'rm -f "$idx" "$idx".*' EXIT
cp "$(git rev-parse --git-path index)" "$idx"
GIT_INDEX_FILE=$idx git add -A -- . ':(exclude)tmp*.txt' ':(exclude).team'
tree=$(GIT_INDEX_FILE=$idx git write-tree)
export_git() { git -c core.autocrlf=false -c core.eol=lf "$@"; }

base=$(vm "cat ~/$dest/.vm_sync_tree 2> /dev/null || git -C ~/$dest rev-parse HEAD 2> /dev/null || true")
vm "mkdir -p ~/$dest"
if [ -n "$base" ] && git cat-file -e "$base^{tree}" 2> /dev/null; then
    [ "$(git rev-parse "$base^{tree}")" = "$tree" ] && { echo "$dest: up to date on $host"; exit 0; }
    git diff --no-renames --name-status "$base" "$tree" > "$idx.list"
    # No mapfile: the Mac's /bin/bash is 3.2.
    changed=() gone=()
    while IFS=$'\t' read -r status path; do
        if [ "$status" = D ]; then gone+=("$path"); else changed+=("$path"); fi
    done < "$idx.list"
    if [ ${#changed[@]} -gt 400 ]; then
        export_git archive "$tree" | vm "tar -xf - -C ~/$dest"
    elif [ ${#changed[@]} -gt 0 ]; then
        export_git archive "$tree" -- "${changed[@]}" | vm "tar -xf - -C ~/$dest"
    fi
    if [ ${#gone[@]} -gt 0 ]; then
        printf '%s\0' "${gone[@]}" | vm "cd ~/$dest && xargs -0 rm -f --"
    fi
    echo "$dest: ${#changed[@]} changed, ${#gone[@]} removed (base $base)"
else
    echo "$dest: first sync to $host (whole tree)"
    export_git archive "$tree" | vm "tar -xf - -C ~/$dest"
    changed=()
    while IFS= read -r path; do changed+=("$path"); done < <(git ls-tree -r --name-only "$tree")
fi

if [ ${#changed[@]} -gt 0 ]; then
    git ls-tree -r --format='%(objectmode) %(objectname) %(path)' "$tree" |
        awk '$1 == "100644" || $1 == "100755"' > "$idx.all"
    printf '%s\n' "${changed[@]}" > "$idx.paths"
    awk 'NR == FNR { want[$0] = 1; next } substr($0, 49) in want' "$idx.paths" "$idx.all" > "$idx.sel"
    want=$(cut -c8-47 "$idx.sel" | sort | sha256sum)
    got=$(cut -c49- "$idx.sel" | vm "cd ~/$dest && git hash-object --stdin-paths" | sort | sha256sum)
    [ "$want" = "$got" ] || { echo "$dest: shipped files do not match the tree; not marking it synced"; exit 1; }
fi
vm "echo $tree > ~/$dest/.vm_sync_tree"
echo "$dest: synced $tree to $host"
