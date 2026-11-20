#!/bin/bash
# check-host's sudo verdict against REAL sudo (or sudo-rs) output: Linux Mint's stock files
# plus one more sudoers scenario at a time (#153 and its review). Never on a real machine:
# it writes sudoers files and stand-in programs, and takes them away again. Runs as root in
# a throwaway container or the systemd box (systemd_box_test.sh calls it).
#   bash relay-uws/test/installer/sudo_matrix_tests.sh
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "Runs as root, in a throwaway container." >&2; exit 2; }
[ "${HOLLOW_INSTALLER_TEST_BOX:-}" = 1 ] || [ -f /.dockerenv ] || { echo "Runs only in a throwaway container." >&2; exit 2; }
command -v sudo >/dev/null || { echo "skip sudo_matrix (no sudo here)"; exit 0; }

T=$(cd "$(dirname "$0")" && pwd)
CH=$T/../../deploy/check-host.sh
pass=0 fail=0
made=()
acct_made=0
cleanup() {
    rm -f /etc/sudoers.d/mintupdate /etc/sudoers.d/mintdrivers /etc/sudoers.d/zz-matrix
    if [ ${#made[@]} -gt 0 ]; then rm -f "${made[@]}"; fi
    if [ "$acct_made" = 1 ]; then userdel hollow-relay 2>/dev/null; fi
}
trap cleanup EXIT

rs=0
sudo -V 2>/dev/null | head -n 1 | grep -q '^sudo-rs' && rs=1
echo "sudo_matrix on $(sudo -V 2>/dev/null | head -n 1)"
if ! id hollow-relay >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin hollow-relay && acct_made=1
fi
for t in /usr/bin/mint-refresh-cache /usr/lib/linuxmint/mintUpdate/dpkg_lock_check.sh \
    /usr/lib/linuxmint/mintUpdate/synaptic-workaround.py /usr/bin/mintdrivers-remove-live-media \
    /usr/bin/mintdrivers-load-broadcom-modules; do
    [ -e "$t" ] && continue
    mkdir -p "${t%/*}"
    printf '#!/bin/sh\n' >"$t"
    chmod 0755 "$t"
    made+=("$t")
done
printf 'ALL ALL = NOPASSWD:/usr/bin/mint-refresh-cache\nALL ALL = NOPASSWD:/usr/lib/linuxmint/mintUpdate/synaptic-workaround.py\nALL ALL = NOPASSWD:/usr/lib/linuxmint/mintUpdate/dpkg_lock_check.sh\n' >/etc/sudoers.d/mintupdate
printf 'ALL ALL = NOPASSWD:/usr/bin/mintdrivers-remove-live-media\nALL ALL = NOPASSWD:/usr/bin/mintdrivers-load-broadcom-modules\n' >/etc/sudoers.d/mintdrivers
chmod 0440 /etc/sudoers.d/mintupdate /etc/sudoers.d/mintdrivers

block=$(sed -n '/^MINT_SUDO_TOOLS=/,/^echo "Service accounts"/p' "$CH" | sed '$d')
eval "$block"

# case <name> <expected: mint N | bad | unknown | ogsudo/sudo-rs split as "A|B"> <sudoers body>
case_() {
    local name=$1 want=$2 body=$3 l ll v got
    [[ $want == *"|"* ]] && { if [ "$rs" = 1 ]; then want=${want#*|}; else want=${want%|*}; fi; }
    rm -f /etc/sudoers.d/zz-matrix
    if [ -n "$body" ]; then printf '%s\n' "$body" >/etc/sudoers.d/zz-matrix; chmod 0440 /etc/sudoers.d/zz-matrix; fi
    if ! visudo -cq >/dev/null 2>&1; then echo "skip  $name (this sudo does not take it)"; return; fi
    l=$(LC_ALL=C sudo -l -U hollow-relay 2>&1 </dev/null)
    ll=$(LC_ALL=C sudo -ll -U hollow-relay 2>/dev/null </dev/null)
    v=$(sudo_verdict hollow-relay hollow-relay yes "$l" "$ll")
    case "$want" in mint*) got=$v ;; *) got=${v%% *} ;; esac
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1)); echo "ok    $name"
    else
        fail=$((fail + 1)); echo "FAIL  $name: expected [$want], got [$(head -c 200 <<<"$v")]"
    fi
}

case_ mint_only "mint 5" ''
case_ harmless_defaults "mint 5" $'Defaults !use_pty\nDefaults:hollow-relay !lecture'
case_ mint_dup_other_file "mint 5" 'ALL ALL = NOPASSWD:/usr/bin/mint-refresh-cache'
case_ cmnd_alias_single "mint 5" $'Cmnd_Alias MINT = /usr/bin/mint-refresh-cache\nALL ALL = NOPASSWD: MINT'
case_ runas_alias_root "mint 5|bad" $'Runas_Alias R = root\nALL ALL=(R) NOPASSWD: /usr/bin/mint-refresh-cache'
# a_default_that_changes_what_a_tool_runs_fails
case_ defaults_setenv bad 'Defaults setenv'
case_ defaults_user_envkeep bad 'Defaults:hollow-relay env_keep+="PYTHONPATH BASH_ENV"'
case_ defaults_no_env_reset bad 'Defaults !env_reset'
case_ defaults_secure_path bad 'Defaults secure_path="/var/lib/hollow-relay:/usr/bin:/bin"'
case_ defaults_runas_envkeep bad 'Defaults>root env_keep+="PYTHONPATH"'
case_ defaults_cmd_setenv bad 'Defaults!/usr/bin/mint-refresh-cache setenv'
case_ defaults_runchroot bad 'Defaults runchroot=*'
case_ defaults_runcwd bad 'Defaults runcwd=*'
case_ defaults_env_check bad 'Defaults env_check+="PERL5LIB"'
# an_answer_this_check_cannot_read_fails
case_ requiretty "unknown|unknown" 'Defaults requiretty'
# rules that are not exactly one of Mint's tools
case_ cmnd_alias_mixed bad $'Cmnd_Alias MINT = /usr/bin/mint-refresh-cache, /bin/sh\nALL ALL = NOPASSWD: MINT'
case_ negation bad 'ALL ALL=(root) NOPASSWD: /usr/bin/mint-refresh-cache, !/bin/false'
case_ runas_alias bad $'Runas_Alias R = root, nobody\nALL ALL=(R) NOPASSWD: /usr/bin/mint-refresh-cache'
case_ chroot_tag bad 'ALL ALL=(root) CHROOT=* NOPASSWD: /usr/bin/mint-refresh-cache'
case_ cwd_tag bad 'ALL ALL=(root) CWD=* NOPASSWD: /usr/bin/mint-refresh-cache'
case_ sudoedit bad 'ALL ALL=(root) NOPASSWD: sudoedit /etc/shadow'
case_ setenv_tag bad 'ALL ALL=(root) NOPASSWD:SETENV: /usr/bin/mint-refresh-cache'
case_ group_only bad 'ALL ALL=(:root) NOPASSWD: /usr/bin/mint-refresh-cache'
case_ two_runas bad 'ALL ALL=(root) NOPASSWD: /usr/bin/mint-refresh-cache, (nobody) NOPASSWD: /bin/sh'
case_ empty_args bad 'ALL ALL=(root) NOPASSWD: /usr/bin/mint-refresh-cache ""'
case_ user_spec_all bad 'hollow-relay ALL=(ALL:ALL) NOPASSWD: ALL'
case_ notafter bad 'ALL ALL=(root) NOTAFTER=20991231000000Z NOPASSWD: /usr/bin/mint-refresh-cache'
case_ passwd_then_nopw bad 'ALL ALL=(root) PASSWD: /bin/sh, NOPASSWD: /usr/bin/mint-refresh-cache'
case_ intercept_tag bad 'ALL ALL=(root) NOPASSWD:NOEXEC: /usr/bin/mint-refresh-cache'
# a_tool_the_account_can_rewrite_fails: the real sudo -u test, not a stand-in.
rm -f /etc/sudoers.d/zz-matrix
chown hollow-relay /usr/bin/mint-refresh-cache
case_ tool_writable bad ''
chown root /usr/bin/mint-refresh-cache
chmod 0777 /usr/lib/linuxmint/mintUpdate
case_ tool_dir_writable bad ''
chmod 0755 /usr/lib/linuxmint/mintUpdate

echo "sudo_matrix: $pass passed, $fail failed"
[ "$fail" = 0 ]
