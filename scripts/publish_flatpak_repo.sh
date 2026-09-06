#!/bin/bash
# Hollow — publish the flatpak OSTree repository. RUN ON THE LINUX VM.
#
#   bash scripts/publish_flatpak_repo.sh             # rsync straight to the host
#   bash scripts/publish_flatpak_repo.sh --via-tar   # pack it for a manual hop
#   bash scripts/publish_flatpak_repo.sh --verify     # only re-check the live URL
#
# Reads scripts/release.local.env for FLATPAK_REPO_DIR, FLATPAK_REPO_URL,
# FLATPAK_PUBLISH_SSH and FLATPAK_PUBLISH_DIR. No secrets: the signing key
# never leaves FLATPAK_GPG_HOMEDIR, and only the already-signed repo is copied.
#
# --------------------------------------------------------------------------
# THE WINDOWS HOP (--via-tar)
# --------------------------------------------------------------------------
# The VM has no SSH key for the web host. Windows has keys for BOTH machines,
# so it can act as the hop. From the Windows tree, four commands:
#
#   ssh hollowvm 'bash ~/Documents/HOLLOW/scripts/publish_flatpak_repo.sh --via-tar'
#   scp hollowvm:~/hollow-flatpak-repo.tgz /tmp/hollow-flatpak-repo.tgz
#   scp /tmp/hollow-flatpak-repo.tgz hostinger:~/hollow-flatpak-repo.tgz
#   ssh hostinger 'mkdir -p ~/domains/anonlisten.com/public_html/hollow/flatpak \
#       && tar xzf ~/hollow-flatpak-repo.tgz \
#            -C ~/domains/anonlisten.com/public_html/hollow/flatpak \
#       && rm ~/hollow-flatpak-repo.tgz'
#   ssh hollowvm 'bash ~/Documents/HOLLOW/scripts/publish_flatpak_repo.sh --verify'
#
# The tar hop UNPACKS OVER the live tree, it does not mirror it: objects the
# last prune dropped stay on the host, taking disk but breaking nothing. The
# rsync path (once the VM has a key for the host) does mirror, with --delete.
# Either way the server side .htaccess files are never touched: rsync excludes
# them and tar does not carry them.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="rsync"
case "${1:-}" in
    --via-tar) MODE="tar" ;;
    --verify)  MODE="verify" ;;
    "")        ;;
    *) echo "ERROR: unknown option $1 (expected --via-tar or --verify)"; exit 2 ;;
esac

ENV_FILE="$SCRIPT_DIR/release.local.env"
if [ -f "$ENV_FILE" ]; then
    # An explicit environment value beats the file (see build-flatpak.sh).
    _ENV_FLATPAK="$(export -p | grep -E '^(declare -x |export )FLATPAK_' || true)"
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
    eval "$_ENV_FLATPAK"
fi

FLATPAK_REPO_DIR="${FLATPAK_REPO_DIR:-$HOME/hollow-flatpak-repo}"
FLATPAK_REPO_URL="${FLATPAK_REPO_URL:-https://flatpak.anonlisten.com}"
FLATPAK_PUBLISH_SSH="${FLATPAK_PUBLISH_SSH:-hostinger}"
FLATPAK_PUBLISH_DIR="${FLATPAK_PUBLISH_DIR:-~/domains/anonlisten.com/public_html/hollow/flatpak}"
TARBALL="$HOME/hollow-flatpak-repo.tgz"

# --- Verify what is actually live ----------------------------------------
# A repo whose summary 404s or is served from cache is worse than no repo:
# every client silently sees "up to date" forever.
verify_published() {
    local failed=0
    echo "==> Verifying $FLATPAK_REPO_URL"

    # summary is mandatory. summary.idx only exists on flatpak 1.14 and newer,
    # which is what build-update-repo emits here, so require it when the local
    # repo has one.
    local required=(summary summary.sig config hollow.flatpakrepo hollow.flatpakref)
    [ -f "$FLATPAK_REPO_DIR/summary.idx" ] && required+=(summary.idx summary.idx.sig)

    for f in "${required[@]}"; do
        local code
        code="$(curl -s -o /dev/null -w '%{http_code}' -I "$FLATPAK_REPO_URL/$f" || echo 000)"
        if [ "$code" = "200" ]; then
            echo "    200  $f"
        else
            echo "    $code  $f   <-- NOT SERVED"
            failed=1
        fi
    done

    # The mutable metadata must not be cached, or a client keeps reading a
    # summary that predates the release it is meant to find.
    echo "==> Cache headers on summary"
    curl -sI "$FLATPAK_REPO_URL/summary" \
        | grep -iE '^(HTTP/[0-9.]+ |cache-control:|expires:|pragma:|server:|age:|x-hcdn-cache-status:)' || true

    if [ "$failed" -ne 0 ]; then
        echo "ERROR: the repository is not fully served at $FLATPAK_REPO_URL"
        return 1
    fi
    echo "==> Repository is live"
}

if [ "$MODE" = "verify" ]; then
    verify_published
    exit $?
fi

[ -f "$FLATPAK_REPO_DIR/config" ] || {
    echo "ERROR: no OSTree repo at $FLATPAK_REPO_DIR (run flatpak/build-flatpak.sh first)"
    exit 1
}
[ -f "$FLATPAK_REPO_DIR/summary" ] || {
    echo "ERROR: $FLATPAK_REPO_DIR has no summary (run flatpak build-update-repo)"
    exit 1
}

echo "==> Repository: $FLATPAK_REPO_DIR"
du -sh "$FLATPAK_REPO_DIR" | sed 's/^/    /'

if [ "$MODE" = "tar" ]; then
    echo "==> Packing for the manual hop"
    rm -f "$TARBALL"
    # tmp/ is ostree scratch and .lock is a live file lock; neither belongs on
    # a web server. Everything else, including refs/ and summaries/, does.
    tar czf "$TARBALL" -C "$FLATPAK_REPO_DIR" \
        --exclude=./tmp --exclude=./.lock --exclude=./.htaccess .
    ls -lh "$TARBALL" | sed 's/^/    /'
    echo ""
    echo "Now run, from Windows:"
    echo "  scp hollowvm:$TARBALL /tmp/hollow-flatpak-repo.tgz"
    echo "  scp /tmp/hollow-flatpak-repo.tgz $FLATPAK_PUBLISH_SSH:~/hollow-flatpak-repo.tgz"
    echo "  ssh $FLATPAK_PUBLISH_SSH 'mkdir -p $FLATPAK_PUBLISH_DIR && tar xzf ~/hollow-flatpak-repo.tgz -C $FLATPAK_PUBLISH_DIR && rm ~/hollow-flatpak-repo.tgz'"
    echo "  ssh hollowvm 'bash $ROOT_DIR/scripts/publish_flatpak_repo.sh --verify'"
    exit 0
fi

echo "==> rsync to $FLATPAK_PUBLISH_SSH:$FLATPAK_PUBLISH_DIR"
ssh "$FLATPAK_PUBLISH_SSH" "mkdir -p $FLATPAK_PUBLISH_DIR"
# --exclude=.htaccess protects the cache rules that live only on the server:
# excluded files are also spared by --delete.
rsync -az --delete --exclude=.htaccess --exclude=tmp/ --exclude=.lock \
    "$FLATPAK_REPO_DIR/" "$FLATPAK_PUBLISH_SSH:$FLATPAK_PUBLISH_DIR/"

verify_published
