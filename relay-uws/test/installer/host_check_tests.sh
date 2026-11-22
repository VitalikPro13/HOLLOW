# check-host's service-account sudo check (#153): Linux Mint's own maintenance tools pass
# under NoNewPrivileges, anything else fails and names its rule and file. Fed with real
# sudo output (fixtures/sudo: sudo 1.9.15 on Mint 22, 1.9.9 on Mint 21, which names no
# file). Sourced by run_tests.sh, whose helpers it uses.
# shellcheck shell=bash disable=SC2034,SC2317,SC2016,SC2329

echo "check-host: sudo rules of the service accounts"
t_host_sudo() {
    local block fx=$T/fixtures/sudo out etc=$TMP/sudoers_etc
    block=$(sed -n '/^MINT_SUDO_TOOLS=/,/^echo "Service accounts"/p' "$DEPLOY/check-host.sh" | sed '$d')
    has "check-host has the sudo verdict" "$block" "sudo_verdict()"
    eval "$block"
    v() { sudo_verdict hollow-relay "${ACCT:-nobody}" "${NNP-yes}" "$1" "$2"; }
    # The paths the account may write, instead of asking sudo -u.
    account_writes() { [[ " ${WRITABLE:-} " == *" $2 "* ]]; }
    SUDOERS_ETC=$TMP/no_sudoers

    # mint_stock_sudo_rules_pass_under_no_new_privileges
    eq "Mint 22's five tools pass" "$(v "$(cat "$fx/mint22_l.txt")" "$(cat "$fx/mint22_ll.txt")")" "mint 5"
    eq "Mint 21's four (sudo naming no file) pass" "$(v "$(cat "$fx/mint21_l.txt")" "$(cat "$fx/mint21_ll.txt")")" "mint 4"
    eq "no rule at all says nothing" "$(v "User nobody is not allowed to run sudo on box." "")" ""

    # mint_rules_fail_without_no_new_privileges
    out=$(NNP=no v "$(cat "$fx/mint22_l.txt")" "$(cat "$fx/mint22_ll.txt")")
    eq "without NoNewPrivileges the same rules fail" "${out%% *}" bad
    has "every one of them named" "$out" "; (root) NOPASSWD: /usr/bin/mint-refresh-cache; "
    has "naming the files" "$out" "(in /etc/sudoers.d/mintdrivers /etc/sudoers.d/mintupdate)"
    has "and the missing setting" "$out" "hollow-relay does not set NoNewPrivileges=yes"
    out=$(NNP="" v "$(cat "$fx/mint22_l.txt")" "$(cat "$fx/mint22_ll.txt")")
    has "nor does an unknown setting pass" "$out" "bad "

    # another_rule_beside_mints_fails_and_names_only_itself
    out=$(v "$(cat "$fx/mint22_l_extra.txt")" "$(cat "$fx/mint22_ll_extra.txt")")
    eq "an extra rule fails, naming it and its file alone" "$out" "bad (root) NOPASSWD: /usr/bin/true (in /etc/sudoers.d/zz-extra)"
    # an_old_sudo_that_names_no_file_has_the_file_found
    rm -rf "$etc" && mkdir -p "$etc/sudoers.d"
    printf 'Defaults env_reset\nroot ALL=(ALL:ALL) ALL\n%%sudo ALL=(ALL:ALL) ALL\n@includedir /etc/sudoers.d\n' >"$etc/sudoers"
    printf '# Allow any user\nALL ALL = NOPASSWD:/usr/bin/mint-refresh-cache\n' >"$etc/sudoers.d/mintupdate"
    printf 'ALL ALL=(root) NOPASSWD: /usr/bin/t\\\nrue\n' >"$etc/sudoers.d/zz-extra"
    printf 'ALL ALL=(root) NOPASSWD: /usr/bin/true\n' >"$etc/sudoers.d/skipped.conf"
    printf 'someone ALL=(ALL) ALL\n' >"$etc/sudoers.d/other"
    out=$(SUDOERS_ETC=$etc v "$(cat "$fx/mint21_l_extra.txt")" "$(cat "$fx/mint21_ll_extra.txt")")
    has "on sudo 1.9.9 the extra rule fails too" "$out" "bad (root) NOPASSWD: /usr/bin/true (in "
    has "naming only the file whose rule is not Mint's" "$out" "(in $etc/sudoers.d/zz-extra)"
    has "and every file without NoNewPrivileges" "$(NNP=no SUDOERS_ETC=$etc v "$(cat "$fx/mint21_l_extra.txt")" "$(cat "$fx/mint21_ll_extra.txt")")" \
        "(in $etc/sudoers.d/mintupdate $etc/sudoers.d/zz-extra)"
    lacks "never a file sudo skips" "$out" "skipped.conf"
    lacks "nor one for another account" "$out" "sudoers.d/other"
    eq "a rule for the account's group is found" "$(printf '%%%s ALL=(ALL) ALL\n' "$(id -gn nobody)" >"$etc/sudoers.d/grp"; SUDOERS_ETC=$etc sudoers_files_for nobody all | grep -c 'sudoers.d/grp')" 1

    # each_view_of_sudo_judges_alone: the short list and the long entries are each enough
    # to fail a rule that is not exactly one of Mint's.
    local l ll
    l=$(cat "$fx/mint22_l.txt") ll=$(cat "$fx/mint22_ll.txt")
    has "another run-as user fails (short view)" "$(v "${l/(root) NOPASSWD: \/usr\/bin\/mint-refresh-cache/(ALL) NOPASSWD: /usr/bin/mint-refresh-cache}" "$ll")" "bad (ALL) NOPASSWD: /usr/bin/mint-refresh-cache"
    has "a password rule fails (short view)" "$(v "${l/(root) NOPASSWD: \/usr\/bin\/mint-refresh-cache/(root) /usr/bin/mint-refresh-cache}" "$ll")" "bad (root) /usr/bin/mint-refresh-cache"
    has "arguments fail (short view)" "$(v "${l/mint-refresh-cache/mint-refresh-cache --use-synaptic 1}" "$ll")" "bad (root) NOPASSWD: /usr/bin/mint-refresh-cache --use-synaptic 1"
    has "a wildcard fails (short view)" "$(v "${l/mint-refresh-cache/mint-*}" "$ll")" "bad (root) NOPASSWD: /usr/bin/mint-*"
    has "ALL fails (short view)" "$(v "${l/\/usr\/bin\/mint-refresh-cache/ALL}" "$ll")" "bad (root) NOPASSWD: ALL"
    has "two tools on one line fail (short view)" "$(v "${l/mint-refresh-cache/mint-refresh-cache, \/usr\/bin\/mintdrivers-remove-live-media}" "$ll")" "bad "
    has "another run-as user fails (long view)" "$(v "$l" "${ll/RunAsUsers: root/RunAsUsers: ALL}")" "(in /etc/sudoers.d/mintdrivers)"
    has "a run-as group fails (long view)" "$(v "$l" "${ll/    Options: !authenticate/    RunAsGroups: root
    Options: !authenticate}")" "bad "
    has "an entry without its run-as fails (long view)" "$(v "$l" "${ll/    RunAsUsers: root
/}")" "bad "
    has "an option beyond NOPASSWD fails (long view)" "$(v "$l" "${ll/Options: !authenticate/Options: !authenticate, setenv}")" "bad "
    has "a password rule fails (long view)" "$(v "$l" "${ll/    Options: !authenticate
/}")" "bad "
    has "arguments fail (long view)" "$(v "$l" "${ll/mint-refresh-cache
/mint-refresh-cache --use-synaptic 1
}")" "(in /etc/sudoers.d/mintupdate)"
    has "two tools packed in one entry pass only as two tools" "$(v "$l" "${ll/	\/usr\/bin\/mint-refresh-cache/	/usr/bin/mint-refresh-cache /usr/bin/mintdrivers-remove-live-media}")" "bad "
    has "a field this check does not know fails (long view)" "$(v "$l" "${ll/    Commands:/    Cwd: \/tmp
    Commands:}")" "bad "
    has "no long view at all fails" "$(v "$l" "")" "bad "
    has "a long view with no entry under its header fails" "$(v "$l" "User hollow-relay may run the following commands on box:
")" "bad "
    has "command-specific defaults fail" "$(v "${l/User hollow-relay/Runas and Command-specific defaults for hollow-relay:
    Defaults!\/usr\/bin\/mint-refresh-cache env_keep+=PYTHONPATH

User hollow-relay}" "$ll")" "bad "
    has "the account is named in the hint when no file is found" "$(SUDOERS_ETC=$TMP/none v "$(cat "$fx/mint21_l_extra.txt")" "$(cat "$fx/mint21_ll_extra.txt")")" "sudo -ll -U nobody shows where"

    # the_check_reads_sudo_in_english_and_keeps_every_account_line
    has "sudo is asked in the C locale" "$(cat "$DEPLOY/check-host.sh")" 'LC_ALL=C sudo -l -U "$user"'
    has "for both views" "$(cat "$DEPLOY/check-host.sh")" 'LC_ALL=C sudo -ll -U "$user"'
    lacks "check-host's sudo lines carry no em dash" "$block" "$(printf '\342\200\224')"

    # an_answer_this_check_cannot_read_fails (#153 review): requiretty, no output, LDAP roles.
    eq "requiretty's refusal is no answer" "$(v "sudo: sorry, you must have a tty to run sudo" "")" "unknown sudo: sorry, you must have a tty to run sudo"
    eq "nor is no output" "$(v "" "")" "unknown no output"
    has "a role block in the long view is not Mint's" "$(v "$l" "${ll/Sudoers entry: \/etc\/sudoers.d\/mintdrivers/LDAP Role: admins
    RunAsUsers: root
    Commands:
	ALL

Sudoers entry: /etc/sudoers.d/mintdrivers}")" "bad "
    # mint_tools_are_counted_once (#153 review)
    eq "a tool allowed twice counts once" "$(v "$l
    (root) NOPASSWD: /usr/bin/mint-refresh-cache" "$ll")" "mint 5"
    # a_default_that_changes_what_a_tool_runs_fails (#153 review)
    local d
    for d in setenv '!env_reset' 'env_keep+="PYTHONPATH BASH_ENV"' 'env_check+=PERL5LIB' 'env_file=/tmp/e' \
        'runchroot=*' 'runcwd=*' '!secure_path' 'secure_path=/var/lib/hollow-relay\:/usr/bin\:/bin'; do
        has "the default $d fails" "$(v "${l/use_pty, pwfeedback/use_pty, pwfeedback, $d}" "$ll")" "under the sudo defaults $d"
    done
    eq "harmless defaults pass" "$(v "${l/use_pty, pwfeedback/use_pty, pwfeedback, !lecture, !use_pty}" "$ll")" "mint 5"
    eq "Debian's own secure_path passes" "$(v "${l/\\:\/snap\/bin/}" "$ll")" "mint 5"
    # on_sudo_rs_the_sudoers_defaults_count (#153 review): sudo-rs lists no defaults.
    local rs=$TMP/rs_etc
    rm -rf "$rs" && mkdir -p "$rs/sudoers.d"
    printf 'Defaults env_reset\nDefaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' >"$rs/sudoers"
    l=$(sed '/^Matching Defaults entries/,/^$/d' "$fx/mint22_l.txt")
    eq "stock sudo-rs defaults pass" "$(SUDOERS_ETC=$rs v "$l" "$ll")" "mint 5"
    printf 'Defaults!/usr/bin/mint-refresh-cache setenv\n' >"$rs/sudoers.d/zz"
    has "a command's setenv fails, named with its file" "$(SUDOERS_ETC=$rs v "$l" "$ll")" "under the sudo defaults setenv (in $rs/sudoers.d/zz)"
    printf 'Defaults:hollow-relay env_keep+="PYTHONPATH"\n' >"$rs/sudoers.d/zz"
    has "an account's env_keep fails" "$(SUDOERS_ETC=$rs v "$l" "$ll")" "env_keep+=\"PYTHONPATH\" (in $rs/sudoers.d/zz)"
    l=$(cat "$fx/mint22_l.txt")
    # a_tool_the_account_can_rewrite_fails (#153 review)
    has "a tool the account can rewrite fails" "$(WRITABLE=/usr/bin/mint-refresh-cache v "$l" "$ll")" \
        "nobody can change /usr/bin/mint-refresh-cache, so it could replace a tool sudo runs as root"
    has "so does its directory" "$(WRITABLE=/usr/lib/linuxmint/mintUpdate v "$l" "$ll")" \
        "nobody can change /usr/lib/linuxmint/mintUpdate, so it could replace"
    rm -rf "$etc" "$rs"
}
in_sub t_host_sudo

echo "check-host: the programs' libraries"
# check_host_names_a_missing_library (#153): a program that cannot load a library
# fails by the library's name, and one that finds them all passes.
t_host_libs() {
    local block F=$TMP/fake_hostlibs out
    block=$(sed -n '/^# The programs the services start find every library/,/^echo "Service accounts"/p' "$DEPLOY/check-host.sh" | sed '$d')
    has "check-host reads the programs' libraries" "$block" 'echo "Programs"'
    mkfake "$F" ldd 'for l in $MISSING_LIBS; do printf "\t%s => not found\n" "$l"; done; printf "\tlibc.so.6 => /lib/libc.so.6 (0x00007f)\n"'
    : >"$F/relaybin"; : >"$F/fwdbin"
    host_libs() { # <units...>
        local units=("$@")
        ok() { echo "ok $1"; }
        bad() { echo "FAIL $1"; }
        systemctl() {
            case "$5" in
            hollow-relay) echo "{ path=$F/relaybin ; argv[]=$F/relaybin --denylist-file /x ; ignore_errors=no }" ;;
            hollow-forwarder) echo "{ path=$F/fwdbin ; argv[]=$F/fwdbin --config /y ; ignore_errors=no }" ;;
            esac
        }
        PATH=$F:$PATH
        eval "$block"
    }
    out=$(MISSING_LIBS="" host_libs hollow-relay hollow-forwarder)
    has "the relay finds its libraries" "$out" "ok hollow-relay's program $F/relaybin finds every library it needs"
    has "and the forwarder" "$out" "ok hollow-forwarder's program $F/fwdbin finds every library it needs"
    lacks "nothing fails" "$out" FAIL
    out=$(MISSING_LIBS="libsodium.so.23" host_libs hollow-relay)
    has "a missing library fails by name" "$out" "FAIL hollow-relay cannot start: $F/relaybin needs libsodium.so.23, which this system does not have"
    has "and says how to build the programs here" "$out" "sudo bash relay-uws/install.sh"
    out=$(MISSING_LIBS="libsodium.so.23 libssl.so.3" host_libs hollow-relay)
    has "every missing one is named" "$out" "needs libsodium.so.23 libssl.so.3,"
    out=$(MISSING_LIBS="" host_libs hollow-push)
    lacks "nothing to say without the relay or forwarder" "$out" "Programs"
    rm -f "$F/fwdbin"
    out=$(MISSING_LIBS="" host_libs hollow-forwarder)
    has "a program that is not there fails" "$out" "FAIL hollow-forwarder starts $F/fwdbin, which is not there"
}
in_sub t_host_libs

# sshd_settings_read_in_any_case (#153): OpenSSH 10.5 on Ubuntu 26.10 prints
# PasswordAuthentication as sshd_config spells it.
echo "check-host: SSH settings"
t_host_ssh() {
    local block out
    block=$(sed -n '/^echo "SSH"$/,/permitrootlogin yes/p' "$DEPLOY/check-host.sh")
    has "check-host has the SSH section" "$block" "sshd -T"
    run_ssh() {
        ok() { echo "ok $*"; }
        bad() { echo "FAIL $*"; }
        sshd() { [ "$1" = -T ] && printf '%s\n' "$SSHD_OUT"; }
        eval "$block"
    }
    out=$(SSHD_OUT=$(sed 's/^PasswordAuthentication yes$/PasswordAuthentication no/' "$T/fixtures/sshd/openssh-10.5-ubuntu-26.10.txt") run_ssh)
    has "OpenSSH 10.5's keys-only setting passes" "$out" "ok password logins off"
    lacks "and nothing fails" "$out" FAIL
    out=$(SSHD_OUT=$(cat "$T/fixtures/sshd/openssh-10.5-ubuntu-26.10.txt") run_ssh)
    has "its password logins fail" "$out" "FAIL SSH password logins are on"
    out=$(SSHD_OUT=$'PermitRootLogin yes\nPasswordAuthentication no' run_ssh)
    has "and so does root's password login" "$out" "FAIL root may log in over SSH with a password"
    out=$(SSHD_OUT=$'permitrootlogin no\npasswordauthentication no' run_ssh)
    lacks "older OpenSSH's lower case still passes" "$out" FAIL
}
in_sub t_host_ssh
