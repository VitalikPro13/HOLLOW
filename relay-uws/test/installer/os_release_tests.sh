#!/bin/bash
# Which systems the setup accepts, from os-release files: Ubuntu, Debian and
# the systems built on them (#148). Sourced by run_tests.sh after host.sh,
# preflight.sh and docker.sh; needs nothing of the machine it runs on.
# shellcheck disable=SC2034,SC2317,SC2329

OSR=$T/fixtures/os-release

# os_case <fixture> <base> <version> <codename> <derived> <supported yes|no>
os_case() {
    hollow_os_base "$OSR/$1"
    eq "$1: base" "$HOLLOW_OS_BASE" "$2"
    eq "$1: base version" "$HOLLOW_OS_BASE_VER" "$3"
    eq "$1: base codename" "$HOLLOW_OS_BASE_CODENAME" "$4"
    eq "$1: derived" "$HOLLOW_OS_DERIVED" "$5"
    if [ "$6" = yes ]; then yes_ os_supported "$HOLLOW_OS_BASE" "$HOLLOW_OS_BASE_VER"
    else no_ os_supported "$HOLLOW_OS_BASE" "$HOLLOW_OS_BASE_VER"; fi
}

echo "systems built on Ubuntu or Debian"
os_case ubuntu-24.04 ubuntu 24.04 noble 0 yes
os_case ubuntu-25.10 ubuntu 25.10 questing 0 yes
os_case ubuntu-26.04 ubuntu 26.04 resolute 0 yes
os_case ubuntu-26.10 ubuntu 26.10 stonking 0 yes
os_case debian-12 debian 12 bookworm 0 yes
os_case mint-22 ubuntu 24.04 noble 1 yes
os_case pop-22.04 ubuntu 22.04 jammy 1 yes
os_case zorin-17 ubuntu 22.04 jammy 1 yes
os_case lmde-6 debian 12 bookworm 1 yes
os_case mint-20.3 ubuntu 20.04 focal 1 no
# Debian-like with no base release named, an unknown codename, and no base at all.
os_case kali-rolling "" "" "" 0 no
os_case fake-like-ubuntu "" "" "" 0 no
os_case fedora-40 "" "" "" 0 no
# Built on Ubuntu, which is itself Debian-like: the Ubuntu release decides.
os_case both-codenames ubuntu 24.04 noble 1 yes
# A codename alone is not a claim to be built on Ubuntu.
os_case codename-without-like "" "" "" 0 no
# An Ubuntu release this setup does not know is refused, never judged by the
# Debian release under it.
os_case ubuntu-derivative-unknown-release "" "" "" 0 no
os_case id-like-tab-separated ubuntu 24.04 noble 1 yes
# Testing has no release number yet: a derivative of it is judged like Debian
# testing itself.
os_case debian-testing debian "" forky 0 no
os_case debian-testing-derivative "" "" "" 0 no
hollow_os_base "$OSR/mint-22"
eq "Mint names its base" "$HOLLOW_OS_BASE_NAME" "Ubuntu 24.04"
hollow_os_base "$TMP/no-such-os-release"
eq "no os-release, no base" "$HOLLOW_OS_BASE" ""
no_ os_supported "$HOLLOW_OS_BASE" "$HOLLOW_OS_BASE_VER"
eq "an Ubuntu codename" "$(hollow_base_version ubuntu resolute)" 26.04
eq "a Debian codename" "$(hollow_base_version debian trixie)" 13
eq "Ubuntu 26.10's codename" "$(hollow_base_version ubuntu stonking)" 26.10
eq "an Ubuntu codename is not Debian's" "$(hollow_base_version debian noble)" ""

echo "a derivative's security updates"
out=$(hollow_base_security_dropin ubuntu noble)
has "Ubuntu's security archive" "$out" '"origin=Ubuntu,archive=noble-security,label=Ubuntu";'
out=$(hollow_base_security_dropin debian bookworm)
has "Debian's security archive" "$out" '"origin=Debian,codename=bookworm-security,label=Debian-Security";'
out=$(HOLLOW_OS_RELEASE=$OSR/mint-22 sh "$DEPLOY/harden-host.sh" --print --no-ssh --no-firewall 2>&1 || true)
has "harden-host allows Ubuntu's archive on Mint" "$out" "would write: /etc/apt/apt.conf.d/52hollow-base-security"
has "with the noble pattern" "$out" "origin=Ubuntu,archive=noble-security,label=Ubuntu"
out=$(HOLLOW_OS_RELEASE=$OSR/ubuntu-24.04 sh "$DEPLOY/harden-host.sh" --print --no-ssh --no-firewall 2>&1 || true)
lacks "and adds nothing on Ubuntu itself" "$out" "52hollow-base-security"

echo "a software source for the base's security archive"
t_base_security_served() {
    local pol
    apt-cache() { printf '%s\n' "$pol"; }
    pol=' 500 http://security.ubuntu.com/ubuntu noble-security/main amd64 Packages
     release v=24.04,o=Ubuntu,a=noble-security,n=noble,l=Ubuntu,c=main,b=amd64'
    yes_ hollow_base_security_served ubuntu noble
    no_ hollow_base_security_served ubuntu jammy
    pol=' 500 http://packages.linuxmint.com wilma/main amd64 Packages
     release v=22,o=linuxmint,a=wilma,n=wilma,l=linuxmint,c=main,b=amd64
 500 http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages
     release v=24.04,o=Ubuntu,a=noble-updates,n=noble,l=Ubuntu,c=main,b=amd64'
    no_ hollow_base_security_served ubuntu noble
    pol=' 500 http://security.debian.org/debian-security bookworm-security/main amd64 Packages
     release v=12,o=Debian,a=stable-security,n=bookworm-security,l=Debian-Security,c=main,b=amd64'
    yes_ hollow_base_security_served debian bookworm
    no_ hollow_base_security_served debian trixie
    pol=' 500 http://deb.debian.org/debian bookworm/main amd64 Packages
     release v=12.8,o=Debian,a=stable,n=bookworm,l=Debian,c=main,b=amd64'
    no_ hollow_base_security_served debian bookworm
}
in_sub t_base_security_served

echo "check-host: a derivative's security updates"
t_check_host_base_security() {
    local block pol dump out
    block=$(sed -n '/^check_base_security() {/,/^}/p' "$DEPLOY/check-host.sh")
    has "check-host has the check" "$block" "hollow_base_security_served"
    has "and runs it" "$(cat "$DEPLOY/check-host.sh")" "        check_base_security"
    eval "$block"
    # check-host's own line printers, kept apart from this file's counters.
    check() ( ok() { echo "ok $1"; }; bad() { echo "FAIL $1"; }; check_base_security )
    apt-config() { printf '%s\n' "$dump"; }
    apt-cache() { printf '%s\n' "$pol"; }
    HOLLOW_OS_RELEASE=$OSR/mint-22
    dump='Unattended-Upgrade::Origins-Pattern "";
Unattended-Upgrade::Origins-Pattern:: "origin=Ubuntu,archive=noble-security,label=Ubuntu";'
    pol='     release v=24.04,o=Ubuntu,a=noble-security,n=noble,l=Ubuntu,c=main,b=amd64'
    out=$(check)
    lacks "Mint with the setting and a source: nothing fails" "$out" "FAIL"
    has "and says the source is there" "$out" "ok a software source serves Ubuntu 24.04's security archive (noble-security)"
    pol='     release v=22,o=linuxmint,a=wilma,n=wilma,l=linuxmint,c=main,b=amd64'
    out=$(check)
    has "Mint with no source for noble-security fails" "$out" "FAIL no software source serves Ubuntu 24.04's security archive"
    HOLLOW_OS_RELEASE=$OSR/ubuntu-24.04
    eq "Ubuntu itself is not checked here" "$(check)" ""
}
in_sub t_check_host_base_security

echo "harden-host: a derivative with no source for the security archive"
t_harden_warns_without_source() {
    local bin=$TMP/hh_bin out
    mkfake "$bin" apt-cache 'echo "     release v=24.04,o=Ubuntu,a=noble-security,n=noble,l=Ubuntu,c=main,b=amd64"'
    out=$(PATH="$bin:$PATH" HOLLOW_OS_RELEASE=$OSR/mint-22 sh "$DEPLOY/harden-host.sh" --print --no-ssh --no-firewall 2>&1 || true)
    lacks "a source for noble-security: no warning" "$out" "no software source here serves"
    mkfake "$bin" apt-cache 'echo "     release v=22,o=linuxmint,a=wilma,n=wilma,l=linuxmint,c=main,b=amd64"'
    out=$(PATH="$bin:$PATH" HOLLOW_OS_RELEASE=$OSR/mint-22 sh "$DEPLOY/harden-host.sh" --print --no-ssh --no-firewall 2>&1 || true)
    has "none: harden-host says so" "$out" "no software source here serves Ubuntu 24.04's security archive (noble-security)"
}
in_sub t_harden_warns_without_source

echo "uninstall: a derivative's security-archive setting"
t_uninstall_takes_back_base_security() {
    local conf=$TMP/un_apt out
    UI_MODE=answers DRY_RUN=0 CFG_MODE=native
    native_uninstall() { echo "NATIVE-UNINSTALL $1"; }
    docker_uninstall() { echo "DOCKER-UNINSTALL $1"; }
    adopt_backups() { :; }
    mkdir -p "$conf"; HOLLOW_APT_CONF_D=$conf
    hollow_base_security_dropin ubuntu noble >"$conf/52hollow-base-security"
    HOLLOW_OS_RELEASE=$OSR/mint-22
    # The screen wraps its lines.
    out=$(declare -gA ANS=([confirm]=no [keep_data]=yes); manage_uninstall 2>&1 | tr -s ' \n' '  ')
    has "the removal screen names the setting on Mint" "$out" "the setting that has unattended-upgrades install Ubuntu 24.04's security updates, so updates go back to how Linux Mint sets them up"
    yes_ test -e "$conf/52hollow-base-security"
    out=$(declare -gA ANS=([confirm]=yes [keep_data]=yes); manage_uninstall 2>&1)
    no_ test -e "$conf/52hollow-base-security"
    has "and says it went" "$out" "removed $conf/52hollow-base-security"
    HOLLOW_OS_RELEASE=$OSR/ubuntu-24.04
    out=$(declare -gA ANS=([confirm]=no [keep_data]=yes); manage_uninstall 2>&1)
    lacks "Ubuntu itself: nothing to name" "$out" "unattended-upgrades install"
}
in_sub t_uninstall_takes_back_base_security

echo "Docker's repository on a derivative"
t_docker_base() {
    have() { [ "$1" != docker ] && command -v "$1" >/dev/null; }
    DRY_RUN=1
    out=$(HOLLOW_OS_RELEASE=$OSR/mint-22 docker_install 2>&1)
    has "Mint takes Ubuntu's repository" "$out" "download.docker.com/linux/ubuntu (noble)"
    out=$(HOLLOW_OS_RELEASE=$OSR/lmde-6 docker_install 2>&1)
    has "LMDE takes Debian's" "$out" "download.docker.com/linux/debian (bookworm)"
    out=$(HOLLOW_OS_RELEASE=$OSR/debian-12 docker_install 2>&1)
    has "Debian keeps its own" "$out" "download.docker.com/linux/debian (bookworm)"
}
in_sub t_docker_base

echo "the machine check names the base"
t_preflight_base() {
    port_busy() { return 1; }
    clock_synced() { return 0; }
    mem_mb() { echo 1987; }
    disk_free_mb() { echo 20000; }
    vgs() { return 5; }
    public_ipv4() { echo 203.0.113.7; }
    public_ipv6() { return 1; }
    local_ipv4() { echo 203.0.113.7; }
    systemd-detect-virt() { echo kvm; }
    uname() { echo x86_64; }
    HOLLOW_OS_RELEASE=$OSR/mint-22
    preflight_run >/dev/null 2>&1
    has "Mint passes, based on Ubuntu 24.04" "$PF_TEXT" "System: Linux Mint 22, based on Ubuntu 24.04 on x86_64, which is supported."
    HOLLOW_OS_RELEASE=$OSR/ubuntu-24.04
    preflight_run >/dev/null 2>&1
    has "Ubuntu says only its name" "$PF_TEXT" "System: Ubuntu 24.04.3 LTS on x86_64, which is supported."
    HOLLOW_OS_RELEASE=$OSR/mint-20.3
    preflight_run >/dev/null 2>&1
    eq "an old Mint stops" "$PF_VERDICT" no
    has "and says its base" "$PF_TEXT" "This is Linux Mint 20.3, based on Ubuntu 20.04."
    HOLLOW_OS_RELEASE=$OSR/kali-rolling
    preflight_run >/dev/null 2>&1
    eq "an unknown base stops" "$PF_VERDICT" no
    has "and names the system" "$PF_TEXT" "This is Kali GNU/Linux Rolling. The setup supports"
}
in_sub t_preflight_base
