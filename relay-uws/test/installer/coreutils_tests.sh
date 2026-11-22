#!/bin/bash
# The coreutils forms the setup and its services use, each with the answer it
# needs, so a box whose coreutils are uutils (most of them on Ubuntu 25.10 and
# 26.04, all of them on 26.10) shows what GNU's show (#153). Sourced by
# run_tests.sh, whose helpers it uses.
# Changes nothing outside $TMP.
# shellcheck shell=bash disable=SC2034,SC2317,SC2016,SC2329

echo "coreutils: $(readlink -f "$(command -v stat)" | sed 's|.*/cargo/.*|uutils|; s|^/.*|gnu or busybox|') ($(stat --version 2>&1 | head -n 1))"
CU=$TMP/coreutils
mkdir -p "$CU"

t_coreutils_disk() {
    local got want
    # disk_free_mb_reads_on_uutils_df: uutils df takes no -m.
    got=$(disk_free_mb /)
    [[ "$got" =~ ^[0-9]+$ ]] && ok || bad "disk_free_mb / printed [$got], not a number of MB"
    want=$(python3 -I -c 'import os; s = os.statvfs("/"); print(s.f_bavail * s.f_frsize // 1048576)')
    if [[ "$got" =~ ^[0-9]+$ ]] && [ $((got > want ? got - want : want - got)) -le 64 ]; then ok
    else bad "disk_free_mb / printed [$got], the file system says $want MB"; fi
    got=$(disk_free_mb "$CU")
    [[ "$got" =~ ^[0-9]+$ ]] && ok || bad "disk_free_mb on a folder printed [$got]"
}
in_sub t_coreutils_disk

t_coreutils_stat() {
    local f=$CU/stat_f d=$CU/stat_d l=$CU/stat_l
    : >"$f"; chmod 0640 "$f"; mkdir -p "$d"; chmod 0750 "$d"; ln -sfn "$f" "$l"
    eq "stat %a %U %G" "$(stat -c '%a %U %G' "$f")" "640 $(id -un) $(id -gn)"
    eq "stat %a on a folder" "$(stat -c %a "$d")" 750
    eq "stat %u --" "$(stat -c %u -- "$f")" "$(id -u)"
    eq "stat %U %h --" "$(stat -c '%U %h' -- "$f")" "$(id -un) 1"
    eq "stat -L follows the link" "$(stat -L -c '%h %a %U %G' "$l")" "1 640 $(id -un) $(id -gn)"
    eq "stat %s" "$(printf 'abcde' >"$f"; stat -c %s -- "$f")" 5
    eq "stat %i is the inode" "$(stat -c %i "$f")" "$(ls -i "$f" | awk '{print $1}')"
    touch -d @1700000000 "$f"
    eq "stat %Y" "$(stat -c %Y "$f")" 1700000000
    eq "stat %a %U:%G" "$(stat -c '%a %U:%G' "$f")" "640 $(id -un):$(id -gn)"
    eq "stat %u %a" "$(stat -c '%u %a' "$d")" "$(id -u) 750"
}
in_sub t_coreutils_stat

t_coreutils_date() {
    local pem=$CU/cert.pem end ts
    eq "date +%s is a number" "$(date +%s | grep -cxE '[0-9]{10,}')" 1
    eq "date -d @N with a format" "$(TZ=UTC date -d @1700000000 +%H:%M:%S)" "22:13:20"
    eq "date +%Y%m%d-%H%M%S" "$(date +%Y%m%d-%H%M%S | grep -cxE '[0-9]{8}-[0-9]{6}')" 1
    # cert_facts reads openssl's notAfter (two spaces before a one-digit day).
    eq "date -d an openssl end date" "$(TZ=UTC date -d 'Mar  5 12:00:00 2027 GMT' +'%-d %b %Y')" "5 Mar 2027"
    eq "date -d an openssl end date, two digits" "$(TZ=UTC date -d 'Nov 21 08:09:10 2026 GMT' +%s)" 1795248550
    if have openssl; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=t \
            -keyout "$CU/k.pem" -out "$pem" >/dev/null 2>&1
        end=$(openssl x509 -in "$pem" -noout -enddate | sed 's/^notAfter=//')
        eq "the cert's end date reads" "$(date -d "$end" +%s >/dev/null 2>&1 && echo yes)" yes
        cert_facts "$pem"
        has "cert_facts names the day" "$OLD_CERT_TEXT" "valid until $(date -d "$end" +'%-d %b %Y')"
        lacks "not the raw openssl date" "$OLD_CERT_TEXT" "GMT"
    fi
    # adopt_started_since reads systemd's ExecMainStartTimestamp.
    eq "date -d a systemd timestamp" "$(date -d 'Sat 2026-11-21 08:09:10 UTC' +%s)" 1795248550
    if [ -e /usr/share/zoneinfo/Europe/Berlin ]; then
        ts=$(TZ=Europe/Berlin date -d @1795248550 '+%a %Y-%m-%d %H:%M:%S %Z')
        eq "date -d a systemd timestamp in a named zone ($ts)" "$(TZ=Europe/Berlin date -d "$ts" +%s)" 1795248550
    fi
    ADOPT_BACKUP=$CU/adopt
    mkdir -p "$ADOPT_BACKUP"
    echo 1795248000 >"$ADOPT_BACKUP/t0"
    systemctl() { echo "Sat 2026-11-21 08:09:10 UTC"; }
    yes_ adopt_started_since x.service
    echo 1795249000 >"$ADOPT_BACKUP/t0"
    no_ adopt_started_since x.service
    unset -f systemctl
}
in_sub t_coreutils_date

t_coreutils_bytes() {
    local f=$CU/bytes h
    h=$(gen_hex 32)
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] && ok || bad "gen_hex 32 printed [$h]"
    h=$(gen_hex 8)
    [[ "$h" =~ ^[0-9a-f]{16}$ ]] && ok || bad "gen_hex 8 printed [$h]"
    h=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    [[ "$h" =~ ^[0-9a-f]{16}$ ]] && ok || bad "check-host's tag printed [$h]"
    eq "od -tu1 gives 32 numbers" "$(od -An -N32 -tu1 /dev/urandom | wc -w | tr -d ' ')" 32
    [[ "$(gen_member_key)" =~ ^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$ ]] && ok || bad "gen_member_key: $(gen_member_key)"
    printf 'abcdefgh\x10\x27\x00\x00' >"$f"
    eq "gzip's size field: tail -c 4 | od --endian=little" "$(tail -c 4 -- "$f" | od -An -tu4 --endian=little | tr -d ' \n')" 10000
    eq "od -tx1 -N20 --" "$(od -An -tx1 -N4 -- "$f" | tr -d ' \n')" 61626364
    eq "head -c" "$(head -c 3 "$f")" abc
    printf 'x\n' >"$f"
    eq "tail -c 1 | wc -l on a closed line" "$(tail -c 1 "$f" | wc -l | tr -d ' ')" 1
    printf 'x' >"$f"
    eq "tail -c 1 | wc -l on an open line" "$(tail -c 1 "$f" | wc -l | tr -d ' ')" 0
    eq "wc -c" "$(printf 'abcd' | wc -c | tr -d ' ')" 4
    eq "base64 -d" "$(printf 'aGVsbG8=' | base64 -d)" hello
    eq "tr -cd" "$(printf 'a1-b2,c' | tr -cd '0-9,')" "12,"
}
in_sub t_coreutils_bytes

t_coreutils_sums() {
    local d=$CU/sums
    mkdir -p "$d"
    printf 'hello\n' >"$d/rustup-init"
    eq "sha256sum --" "$(sha256sum -- "$d/rustup-init" | cut -d' ' -f1)" 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
    eq "sha256sum of stdin" "$(sha256sum <"$d/rustup-init" | cut -d' ' -f1)" 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
    printf '5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03 *rustup-init\n' >"$d/rustup-init.sha256"
    # rust_toolchain's check, as written there.
    yes_ sh -c "cd '$d' && echo \"\$(cut -d' ' -f1 rustup-init.sha256)  rustup-init\" | sha256sum -c --quiet >/dev/null"
    printf 'tampered\n' >"$d/rustup-init"
    no_ sh -c "cd '$d' && echo \"\$(cut -d' ' -f1 rustup-init.sha256)  rustup-init\" | sha256sum -c --quiet >/dev/null 2>&1"
}
in_sub t_coreutils_sums

t_coreutils_files() {
    local d=$CU/files src dst
    rm -rf "$d"; mkdir -p "$d/a/b"
    printf 'one\n' >"$d/a/b/f"
    # put_file's mktemp, compare and swap.
    DRY_RUN=0
    printf 'body\n' | put_file "$d/put" 0640 "$(id -un)" "$(id -gn)"
    eq "put_file writes" "$(cat "$d/put")" body
    eq "put_file's mode" "$(stat -c %a "$d/put")" 640
    eq "no temporary file left" "$(find "$d" -maxdepth 1 -name 'put.new.*' | wc -l | tr -d ' ')" 0
    install -d -m 0750 -o "$(id -un)" -g "$(id -gn)" "$d/made"
    eq "ensure_dir's install -d -m -o -g" "$(stat -c '%a %U' "$d/made")" "750 $(id -un)"
    install -D -m 0755 "$d/a/b/f" "$d/deep/er/hook"
    eq "install -D makes the folders" "$(stat -c %a "$d/deep/er/hook")" 755
    # mv -T renames a folder to a free name, never into one.
    mv -T -- "$d/a" "$d/a2"
    yes_ test -f "$d/a2/b/f"
    mkdir -p "$d/full/x"
    no_ mv -T -- "$d/a2" "$d/full" 2>/dev/null
    yes_ test -d "$d/a2"
    printf 'new\n' >"$d/n"; printf 'old\n' >"$d/o"
    mv -fT -- "$d/n" "$d/o"
    eq "mv -fT replaces a file" "$(cat "$d/o")" new
    # The update snapshot copies each file or folder under its whole path, a
    # mode and a link kept, and puts it back the same way (uutils' cp refuses
    # a folder with --parents, so the setup makes the parents itself).
    chmod 0700 "$d/a2/b/f"
    ln -sfn f "$d/a2/b/l"
    UPDATE_SNAP=$d/snap UNIT_DIR=$d/no-units UPDATE_SNAP_PATHS="$d/a2 $d/a2/b/f $d/missing"
    yes_ update_settings_keep
    eq "a folder is kept with its tree and modes" "$(stat -c %a "$d/snap/tree$d/a2/b/f")" 700
    eq "and its links as links" "$(readlink "$d/snap/tree$d/a2/b/l")" f
    has "a path that is not there is noted" "$(cat "$d/snap/absent")" "$d/missing"
    cp -a -- "$d/snap/tree$d/a2/b/f" "$d/back"
    eq "cp -a -- keeps the mode" "$(stat -c %a "$d/back")" 700
    mkdir -p "$d/folder/in"; printf 'x\n' >"$d/folder/in/x"; chmod 0710 "$d/folder"
    cp -a -- "$d/folder" "$d/folder2"
    eq "cp -a -- copies a folder to a new name" "$(stat -c %a "$d/folder2"; cat "$d/folder2/in/x")" "710
x"
    # release_feed's kept copy: a hard link, else a copy that keeps a link a link.
    ln -P -- "$d/a2/b/f" "$d/hard"
    eq "ln -P makes a second name" "$(stat -c %h "$d/a2/b/f")" 2
    cp -P -p -- "$d/a2/b/l" "$d/lcopy"
    eq "cp -P keeps a link" "$(readlink "$d/lcopy")" f
    cp -R -P -- "$d/a2" "$d/tree"
    eq "cp -R -P keeps links in a tree" "$(readlink "$d/tree/b/l")" f
    cp -Rp "$d/a2" "$d/tree2"
    eq "cp -Rp keeps modes" "$(stat -c %a "$d/tree2/b/f")" 700
    # ln -sfn replaces a link to a folder instead of going into it.
    mkdir -p "$d/t1" "$d/t2"
    ln -sfn "$d/t1" "$d/cur"
    ln -sfn "$d/t2" "$d/cur"
    eq "ln -sfn replaces the link" "$(readlink "$d/cur")" "$d/t2"
    no_ test -e "$d/t1/t2"
    # address-follow's and adopt's copies of an owner and mode.
    printf 'x\n' >"$d/ref"; chmod 0604 "$d/ref"; printf 'y\n' >"$d/tgt"; chmod 0600 "$d/tgt"
    chown --reference="$d/ref" "$d/tgt" && chmod --reference="$d/ref" -- "$d/tgt"
    eq "chmod --reference" "$(stat -c %a "$d/tgt")" 604
    # shred -z -n 0 leaves only zeros (GNU's and uutils' alike round up to a block).
    printf 'secretsecret' >"$d/sh"
    shred -z -n 0 "$d/sh"
    yes_ test "$(stat -c %s "$d/sh")" -ge 12
    eq "shred -z -n 0 zeroes it" "$(tr -d '\000' <"$d/sh" | wc -c | tr -d ' ')" 0
    # readlink -f through a link, and the setup's own place.
    ln -sfn "$d/a2" "$d/via"
    eq "readlink -f --" "$(readlink -f -- "$d/via/b/f")" "$(cd "$d/a2/b" && pwd -P)/f"
    exec 7<"$d/a2/b/f"
    eq "readlink of an open fd" "$(readlink /proc/self/fd/7)" "$(readlink -f "$d/a2/b/f")"
    exec 7<&-
    src=$(mktemp "$d/put.new.XXXXXX")
    [[ "${src##*/}" =~ ^put\.new\.[A-Za-z0-9]{6}$ ]] && ok || bad "mktemp template gave ${src##*/}"
    dst=$(mktemp -d "$d/stage.XXXXXX")
    yes_ test -d "$dst"
    eq "mktemp -d is private" "$(stat -c %a "$dst")" 700
    eq "ls -A of an empty folder" "$(ls -A "$dst")" ""
    touch "$dst/m"
    eq "ls -A sees a file" "$(ls -A "$dst")" m
}
in_sub t_coreutils_files

t_coreutils_text() {
    local tab
    tab=$(printf '\t')
    eq "sort -u" "$(printf 'b\na\nb\n' | sort -u | paste -sd, -)" "a,b"
    eq "sort -un" "$(printf '443\n80\n443\n22\n' | sort -un | tr '\n' ' ')" "22 80 443 "
    eq "sort -t TAB -k1,1 | cut -f2" "$(printf '20\tb\n10\ta\n30\tc\n' | LC_ALL=C sort -t "$tab" -k1,1 | cut -f2 | paste -sd' ' -)" "a b c"
    eq "uniq -d" "$(printf 'a\na\nb\n' | uniq -d)" a
    eq "paste -sd';'" "$(printf 'x\ny\n' | paste -sd';' -)" "x;y"
    eq "cut -d: -f6" "$(echo 'u:x:1:2:g:/home/u:/bin/sh' | cut -d: -f6)" /home/u
    eq "cut -d= -f2" "$(echo 'pid=42' | cut -d= -f2)" 42
    eq "fold -s -w" "$(printf 'aaa bbb ccc' | fold -s -w 8 | head -n 1)" "aaa bbb "
    eq "seq" "$(seq 1 3 | paste -sd' ' -)" "1 2 3"
    eq "timeout ends a hung command with 124" "$(timeout 1 sleep 5; echo $?)" 124
    eq "timeout passes the exit code on" "$(timeout 5 sh -c 'exit 3'; echo $?)" 3
    eq "id -u --" "$(id -u -- root)" 0
    has "id -nG" "$(id -nG root)" root
    has "id -G" " $(id -G root) " " 0 "
    eq "id -g" "$(id -g root)" 0
    eq "uname -s" "$(uname -s)" Linux
    eq "nproc is a number" "$(nproc | grep -cxE '[0-9]+')" 1
    eq "env -i" "$(env -i A=1 sh -c 'echo "$A ${HOME:-none}"')" "1 none"
}
in_sub t_coreutils_text
