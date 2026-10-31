#!/bin/bash
# Run the jobs of .github/workflows/ci.yml from the Mac, on the working tree as it
# stands (uncommitted and embargoed work included), so a push never meets a red CI
# for something we could have seen first. GitHub-only: the coverage upload, Sonar
# and the coverage-instrumented timings (a test with a time budget runs about 3x
# slower there).
#
#   bash scripts/ci_local.sh             every job
#   bash scripts/ci_local.sh --quick     what a release itself can break: supply
#                                        chain, the relay feed, tarball and
#                                        installer suites (a few minutes)
#   bash scripts/ci_local.sh supply relay dart clippy rust   any subset
#
# relay = Linux only: --quick runs the light bash suites on the VPS (relay); the
# full C++ + sanitizer build runs on the Linux VM (hollowvm), never the production
# box (an ASan compile OOM-killed there). The script starts the VM over the PC and
# powers it off again if it started it. RELAY_TEST_HOST overrides. rust = the full
# nextest suite on the Windows PC via scripts/pc_sync.sh (one at a time there).
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
relay_host=${RELAY_TEST_HOST:-}
# VirtualBox runs in Vitalik's desktop session; pc_vbox.ps1 reaches it from SSH.
vbox() { scp -q "$root/scripts/pc_vbox.ps1" pc:D:/dev/tmp/pc_vbox.ps1 && ssh pc "pwsh -NoProfile -File D:\\dev\\tmp\\pc_vbox.ps1 $1"; }
vm_started=0
vm_up() {
    ssh -o ConnectTimeout=8 -o BatchMode=yes hollowvm true 2>/dev/null && return 0
    vbox start >/dev/null || return 1
    vm_started=1
    local i
    for i in $(seq 1 40); do
        sleep 5
        ssh -o ConnectTimeout=8 -o BatchMode=yes hollowvm true 2>/dev/null && return 0
    done
    return 1
}
vm_down() { [ "$vm_started" = 1 ] && vbox stop >/dev/null 2>&1; vm_started=0; }
trap vm_down EXIT
log_dir=${CI_LOCAL_LOGS:-$root/build/ci_local}
mkdir -p "$log_dir"

quick=0
jobs=()
for a in "$@"; do
    case "$a" in
    --quick) quick=1 ;;
    supply | relay | dart | clippy | rust) jobs+=("$a") ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
    esac
done
if [ ${#jobs[@]} -eq 0 ]; then
    if [ "$quick" = 1 ]; then jobs=(supply relay); else jobs=(supply relay dart clippy rust); fi
fi

results=()
step() { # <name> <command...>: run, log, record PASS/FAIL
    local name=$1 log
    shift
    log="$log_dir/$name.log"
    printf '%-28s ' "$name"
    if "$@" >"$log" 2>&1; then
        echo PASS
        results+=("PASS $name")
    else
        echo "FAIL (log: $log)"
        tail -n 15 "$log" | sed 's/^/    /'
        results+=("FAIL $name")
    fi
}

supply_deny() {
    cargo deny --manifest-path rust/hollow_core/Cargo.toml --config rust/deny.toml --locked check || return 1
    local crate
    for crate in hollow_dfn hollow_art hollow_manifest; do
        cargo deny --manifest-path "rust/$crate/Cargo.toml" --config rust/deny.toml --locked check \
            --allow advisory-not-detected --allow unmatched-source || return 1
    done
}
supply_osv() {
    osv-scanner scan source --config osv-scanner.toml \
        -L pubspec.lock \
        -L packages/scrollable_positioned_list/pubspec.lock \
        -L rust_builder/cargokit/build_tool/pubspec.lock \
        -L rust/hollow_core/Cargo.lock \
        -L rust/hollow_dfn/Cargo.lock \
        -L rust/hollow_art/Cargo.lock \
        -L rust/hollow_manifest/Cargo.lock
}
# CI scans every commit; locally the working tree counts too, since it is what
# the next commit will hold.
supply_gitleaks() {
    gitleaks git --no-banner --redact --log-opts=--all . || return 1
    git diff HEAD | gitleaks stdin --no-banner --redact
}
supply_zizmor() {
    local token
    token=$(gh auth token 2>/dev/null) || token=
    if [ -n "$token" ]; then
        GH_TOKEN=$token zizmor --no-progress --min-severity low .github/
    else
        zizmor --offline --no-progress --min-severity low .github/
    fi
}

# Ships the tracked tree plus uncommitted changes (submodules included) to a
# fresh temp dir on the Linux host, runs the suites there, removes it.
relay_suites() {
    [ "$quick" = 1 ] || git submodule update --init --recursive relay-uws >/dev/null || return 1
    local suites=$1 host=$2 dir="/tmp/hollow-ci-local-$$" paths=(relay-uws scripts legal push-sidecar rust/hollow_core/src lib flatpak '*.md')
    {
        # A submodule's own path is a directory tar would copy whole; its files come from the second list.
        git ls-files -z --cached --others --exclude-standard -- "${paths[@]}" |
            grep -zv -x -F -f <(git submodule status --recursive | awk '{print $2}')
        git ls-files -z --recurse-submodules -- "${paths[@]}"
    } | sort -zu |
        COPYFILE_DISABLE=1 tar --null -T - --no-xattrs --no-mac-metadata -czf - |
        ssh -o ConnectTimeout=10 "$host" "set -e; rm -rf $dir; mkdir $dir; cd $dir; tar xzf -; git init -q .; \
            trap 'cd /; rm -rf $dir' EXIT; $suites"
}
relay_quick='bash relay-uws/test/release_feed/run_tests.sh && bash relay-uws/test/release_feed/build_tree_tests.sh && bash relay-uws/test/installer/run_tests.sh'
relay_full="bash relay-uws/test/run_tests.sh && RELAY_LIVE_JOBS=2 SANITIZE=1 bash relay-uws/test/run_tests.sh && cmake -S relay-uws -B relay-uws/build -DCMAKE_BUILD_TYPE=Release >/dev/null && cmake --build relay-uws/build -j\$(nproc) >/dev/null && $relay_quick"

dart_analyze() { flutter pub get >/dev/null && flutter analyze --no-fatal-warnings --no-fatal-infos; }
dart_test() { flutter test test/; }

clippy_lib() { (cd rust/hollow_core && cargo clippy --lib); }

# The real-keystore tests need an interactive Windows logon, which ssh lacks.
rust_pc() {
    local host=${PC_HOST:-pc} name=ci-local
    bash scripts/pc_sync.sh "$name" "$root" || return 1
    ssh -o ServerAliveInterval=15 "$host" "cd D:\\dev\\wt\\$name\\rust\\hollow_core; \$env:PATH = 'C:\\Program Files\\OpenSSL-Win64\\bin;' + \$env:PATH; cargo nextest run --lib --profile ci -j 6 -E 'not (test(keychain_tests::) | test(/platform_keystore::tests::the_real_keystore_/) | test(/wipe::tests::a_wipe_/) | test(/wipe::tests::erasing_another_profile_/) | test(/platform_keystore::tests::dpapi_round_trip/))'"
}

for job in "${jobs[@]}"; do
    case "$job" in
    supply)
        step supply-cargo-deny supply_deny
        step supply-osv-scanner supply_osv
        step supply-gitleaks supply_gitleaks
        step supply-zizmor supply_zizmor
        ;;
    relay)
        if [ "$quick" = 1 ]; then
            step relay-feed-installer relay_suites "$relay_quick" "${relay_host:-relay}"
        elif [ -n "$relay_host" ]; then
            step relay-all relay_suites "$relay_full" "$relay_host"
        elif vm_up; then
            step relay-all relay_suites "$relay_full" hollowvm
            vm_down
        else
            echo "relay-all                    FAIL (the Linux VM did not start)"; results+=("FAIL relay-all")
        fi
        ;;
    dart)
        step dart-analyze dart_analyze
        step dart-test dart_test
        ;;
    clippy) step clippy clippy_lib ;;
    rust) step rust-nextest-pc rust_pc ;;
    esac
done

echo
printf '%s\n' "${results[@]}"
for r in "${results[@]}"; do [[ $r == FAIL* ]] && exit 1; done
exit 0
