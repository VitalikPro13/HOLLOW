#!/bin/bash
# A re-run of install.sh on a machine it already set up: the status screen and
# what it offers (update, change a setting, the members-only keys, the checks,
# uninstall). Sourced by install.sh.

CONF_FILE=/etc/hollow-relay/install.conf
CONF_KEYS="mode binaries address host duckdns_name public_ip public_ip_fixed public_ipv6 staging
turn push forwarder members_only member_keys grace_secs public_stats"

conf_save() {
    local k v
    if [ "$CFG_MODE" = docker ]; then ensure_dir /etc/hollow-relay 0700 root root
    else ensure_dir /etc/hollow-relay 0750 root hollow-relay; fi
    {
        echo "# Written by install.sh: the answers, and no secrets. Those live in"
        echo "# root-only files beside the services they belong to."
        for k in $CONF_KEYS; do
            v=CFG_${k^^}
            printf '%s=%s\n' "$k" "${!v:-}"
        done
    } | put_file "$CONF_FILE" 0600 root root
}

conf_load() {
    local k v
    for k in $CONF_KEYS; do
        v=$(kv_get "$CONF_FILE" "$k")
        printf -v "CFG_${k^^}" '%s' "$v"
    done
    CFG_DUCKDNS_IP=""
    [ "$CFG_PUBLIC_IP_FIXED" = yes ] && CFG_DUCKDNS_IP=$CFG_PUBLIC_IP
    if [ "$CFG_MODE" = docker ]; then
        CFG_DUCKDNS_TOKEN=$(kv_get "$STACK_DIR/.env" DUCKDNS_TOKEN)
    else
        CFG_DUCKDNS_TOKEN=$(kv_get "$DDNS_ETC/duckdns.env" DUCKDNS_TOKEN)
    fi
    # A setup from before the question: what the relay reads now.
    if [ -z "$CFG_PUBLIC_STATS" ]; then
        if [ "$CFG_MODE" = docker ]; then CFG_PUBLIC_STATS=$(kv_get "$STACK_DIR/.env" PUBLIC_STATS)
        else CFG_PUBLIC_STATS=$(kv_get "$RELAY_ETC/relay.env" PUBLIC_STATS); fi
    fi
    CFG_PUBLIC_STATS=$(public_stats_norm "$CFG_PUBLIC_STATS")
}

svc_state() {
    local s
    s=$(systemctl is-active "$1" 2>/dev/null) || true
    case "$s" in
    active) echo "running" ;;
    activating) echo "starting" ;;
    failed) echo "FAILED (journalctl -u $1)" ;;
    *) echo "stopped" ;;
    esac
}

docker_state() {
    local st
    st=$(compose ps --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null | awk -v s="$1" '$1 == s {print $2, $3}' || true)
    case "$st" in
    "running healthy"|"running ") echo running ;;
    running*) echo "running (${st#running })" ;;
    "") echo stopped ;;
    *) echo "$st" ;;
    esac
}

# The certificate the relay serves right now, whichever way it runs.
served_cert_expiry() {
    echo | openssl s_client -connect 127.0.0.1:443 -servername "$CFG_HOST" 2>/dev/null |
        openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//'
}

status_text() {
    local relay_v t
    relay_v=$(local_get /relay-status 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' || true)
    t="Address: $CFG_HOST"
    if [ "$CFG_MODE" = docker ]; then
        t="$t
Setup: Docker, in $DOCKER_DIR
Relay: $(docker_state relay)${relay_v:+, version $relay_v}
TURN: $( [ "$CFG_TURN" = yes ] && docker_state coturn || echo off)$( [ "$CFG_TURN" != yes ] || printf '\nTURN port lock: %s' "$(lock_state)")
Push sender: $(docker_state push)
Media forwarder: $( [ "$CFG_FORWARDER" = yes ] && docker_state forwarder || echo off)"
        [ "$CFG_ADDRESS" = duckdns ] && t="$t
DuckDNS updates: $(docker_state duckdns)"
    else
        local how="ready-made"
        [ "$(installed_source)" = source ] && how="built from source"
        t="$t
Setup: full setup under systemd
Relay: $(svc_state hollow-relay)${relay_v:+, version $relay_v} ($how, build $(installed_build)$(c=$(kv_get "$VERSION_FILE" commit); [ -n "$c" ] && printf ', commit %s' "${c:0:8}"))
TURN: $( [ "$CFG_TURN" = yes ] && svc_state hollow-coturn || echo off)$( [ "$CFG_TURN" != yes ] || printf '\nTURN port lock: %s' "$(lock_state)")
Push sender: $( [ "$CFG_PUSH" = yes ] && svc_state hollow-push || echo off)
Media forwarder: $( [ "$CFG_FORWARDER" = yes ] && svc_state hollow-forwarder || echo off)"
        [ "$CFG_ADDRESS" = duckdns ] && t="$t
DuckDNS updates: $(svc_state hollow-duckdns.timer)"
    fi
    if [ "$CFG_MEMBERS_ONLY" = yes ]; then
        t="$t
Members-only: on, $(member_count) keys"
    else
        t="$t
Members-only: off, anyone with the address can connect"
    fi
    t="$t
Public stats page: $(public_stats_text)
Wait for dropped connections: ${CFG_GRACE_SECS:-120} seconds
Certificate: $(served_cert_expiry || echo unknown)$( [ "$CFG_STAGING" = yes ] && echo ", from the Let's Encrypt staging service, which the app does not trust")
Updates: $UPDATE_TEXT"
    printf '%s' "$t"
}

member_keys_file() {
    if [ "$CFG_MODE" = docker ]; then echo "$STACK_DIR/keys/keys.json"; else echo "$RELAY_ETC/keys.json"; fi
}

fwd_key_now() {
    if [ "$CFG_MODE" = docker ]; then kv_get "$STACK_DIR/.env" FWD_LICENSE_KEY
    else kv_get "$FWD_ETC/forwarder.env" HOLLOW_FWD_LICENSE_KEY; fi
}

member_list() {
    local fk k
    fk=$(fwd_key_now)
    for k in $(member_keys_read "$(member_keys_file)"); do
        [ "$k" = "$fk" ] || echo "$k"
    done
}

member_count() { member_list | grep -c . || true; }

# The keys for the screen. An unattended run's output often lands in a log
# (cloud-init keeps one), so there they go to a file only root can read.
MEMBER_KEYS_OUT=/root/hollow-relay-member-keys.txt
member_keys_shown() {
    if [ "$UI_MODE" != answers ]; then
        printf 'The keys to hand out, one per person:\n%s' "$(member_list | sed 's/^/  /')"
        return 0
    fi
    if [ "$DRY_RUN" = 0 ]; then
        member_list | put_file "$MEMBER_KEYS_OUT" 0600 root root
    fi
    printf 'The keys to hand out, one per person, are in %s, which only root can read.' "$MEMBER_KEYS_OUT"
}

# Whether this run's copy of the repository differs from the build that runs
# here: another relay version, another commit, or a commit either side cannot
# name. Sets SOURCE_LABEL to what this copy holds.
source_differs() {
    local v c iv ic
    v=$(relay_source_version "$REPO")
    c=$(source_commit "$REPO")
    iv=$(kv_get "$VERSION_FILE" version)
    ic=$(kv_get "$VERSION_FILE" commit)
    SOURCE_LABEL="version $v${c:+ (commit ${c:0:8})}"
    [ "$v" != "$iv" ] || [ -z "$c" ] || [ -z "$ic" ] || [ "$c" != "$ic" ]
}

update_check() {
    UPDATE_AVAILABLE=0
    REBUILD_AVAILABLE=0
    FINISH_PENDING=0
    UPDATE_TEXT=""
    if [ "$CFG_MODE" = docker ]; then
        if docker_have_sources; then
            REBUILD_AVAILABLE=1
            UPDATE_TEXT="built from source here. To update, pull this copy of the repository, then choose to rebuild the containers from it."
        else
            UPDATE_TEXT="built from source here. To update, pull your copy of the repository and run sudo bash relay-uws/install.sh from it. That screen offers the rebuild."
        fi
        return 0
    fi
    if [ "$(installed_source)" = source ]; then
        if ! [ -f "$REPO/relay-uws/src/main.cpp" ]; then
            UPDATE_TEXT="built from source here. To update, pull your copy of the repository and run sudo bash relay-uws/install.sh from it. That screen offers the rebuild."
        elif source_differs; then
            REBUILD_AVAILABLE=1
            UPDATE_TEXT="built from source here. This copy of the repository holds $SOURCE_LABEL, which differs from the build running here, so you can rebuild from it."
        else
            UPDATE_TEXT="built from this copy of the repository, which has nothing newer. Pull it and run the setup from it again to update."
        fi
        return 0
    fi
    if ! feed_lib_present; then
        UPDATE_TEXT="cannot check, this copy of the installer has no release feed helper."
        return 0
    fi
    if [ "$DRY_RUN" = 1 ] && [ "$(id -u)" != 0 ]; then
        UPDATE_TEXT="not checked in a dry run without sudo."
        return 0
    fi
    DOWNGRADE_AVAILABLE=0
    # An update that stopped part of the way is finished with the same release.
    if update_pending; then
        local pv pb
        pv=$(kv_get "$UPDATE_MARK" version) pb=$(kv_get "$UPDATE_MARK" build)
        if prebuilt_available "$VERSION_FILE" allow-downgrade && [ "$FEED_CHECKED" = 1 ] &&
           [ "$FEED_VERSION" = "$pv" ] && [ "$FEED_BUILD" = "$pb" ]; then
            UPDATE_AVAILABLE=1 FINISH_PENDING=1
            UPDATE_TEXT="the update to version $pv (build $pb) stopped part of the way. Finishing it puts that release's setup and settings in place."
            return 0
        fi
        UPDATE_TEXT="the update to version $pv (build $pb) stopped part of the way, and the signed release list does not name it now. "
    fi
    if ! prebuilt_available "$VERSION_FILE"; then
        if [ "$PREBUILT_RC" = 3 ]; then
            UPDATE_TEXT="${UPDATE_TEXT:-}up to date. The relay here is newer than the signed release list."
            # Checked again only to name the older release; nothing installs
            # unless the person picks it by name.
            if prebuilt_available "$VERSION_FILE" allow-downgrade && [ "$FEED_CHECKED" = 1 ]; then
                DOWNGRADE_AVAILABLE=1
                UPDATE_TEXT="$UPDATE_TEXT It names the older version $FEED_VERSION (build $FEED_BUILD)."
            fi
        else
            UPDATE_TEXT="${UPDATE_TEXT:-}cannot check right now (${PREBUILT_WHY})."
        fi
        return 0
    fi
    if [ "$FEED_CHECKED" != 1 ]; then
        UPDATE_TEXT="cannot check yet, because jq, curl or openssl is missing. sudo apt install jq curl openssl adds them."
        return 0
    fi
    if hollow_feed_installed "$VERSION_FILE" 2>/dev/null &&
       hollow_feed_newer "$INSTALLED_VERSION" "$INSTALLED_BUILD"; then
        UPDATE_AVAILABLE=1
        UPDATE_TEXT="${UPDATE_TEXT:-}version $FEED_VERSION (build $FEED_BUILD) is available, signed and ready to install."
    else
        UPDATE_TEXT="${UPDATE_TEXT:-}up to date, the signed release list has nothing newer."
    fi
}

restart_relay_pair() {
    if [ "$CFG_FORWARDER" = yes ]; then systemctl restart hollow-forwarder; fi
    systemctl restart hollow-relay
}

# version_older <a> <b>: a three-part version a comes before b.
version_older() {
    local x y i
    IFS=. read -r -a x <<<"$1"
    IFS=. read -r -a y <<<"$2"
    for i in 0 1 2; do
        [ "$((10#${x[$i]:-0}))" -lt "$((10#${y[$i]:-0}))" ] && return 0
        [ "$((10#${x[$i]:-0}))" -gt "$((10#${y[$i]:-0}))" ] && return 1
    done
    return 1
}

# The restart handoff only reads its own format or an older one, so going back
# may drop what the relay holds.
SNAPSHOT_LOSS="An older relay may not be able to read the restart handoff of a newer one, so messages waiting for people who are offline and destroy orders waiting for an offline device may be lost."

manage_downgrade() {
    local older="" installed
    installed=$(installed_version)
    if [ -n "$installed" ] && version_older "$FEED_VERSION" "$installed"; then
        older="

Version $FEED_VERSION is older than the $installed running here, so that loss is likely."
    fi
    ui_yesno confirm "Go back to an older version" \
"The relay here is newer than the signed release list. I can replace it with the older version $FEED_VERSION (build $FEED_BUILD) from that list, for example if the newer one misbehaves.

We recommend no unless you know why you want the older one. The relay restarts, and this setup stays at its current version. $SNAPSHOT_LOSS$older" no || return 0
    DOWNGRADE=1
    manage_update
}

manage_update() {
    if [ "$UPDATE_AVAILABLE" != 1 ] && [ "${DOWNGRADE:-0}" != 1 ]; then
        ui_msg "Nothing to update" "Updates: $UPDATE_TEXT"
        return 0
    fi
    if [ "${FINISH_PENDING:-0}" = 1 ]; then
        ui_yesno confirm "Finish the update" \
"The update to version $FEED_VERSION (build $FEED_BUILD) stopped part of the way. I will download it again, check it against the signed release list and finish putting it in place. Then this relay's settings are applied again and the relay restarts. If anything fails, everything goes back to how it was before the update." yes || return 0
    elif [ "${DOWNGRADE:-0}" != 1 ]; then
        ui_yesno confirm "Update the relay" \
"I will download version $FEED_VERSION (build $FEED_BUILD), check it against the signed release list and install it with the new version of this setup it carries. The new setup then applies this relay's settings again, as a settings change does, and restarts the relay and the forwarder. If anything fails, everything goes back to how it was.

Offline messages and dropped connections carry across the restart, and connected apps pick up where they were within about 10 seconds." yes || return 0
    fi
    APPLY_STARTED=1
    FORCE_PROGRAMS=1
    RESTART_UNITS=()
    EXPECT_VERSION=$FEED_VERSION EXPECT_BUILD=$FEED_BUILD
    SETUP_CHANGE=none
    SETUP_FROM_RELEASE=1
    # An older release's setup never replaces a newer one, and finishing an
    # update takes the setup the way it started.
    [ "${DOWNGRADE:-0}" = 1 ] && SETUP_FROM_RELEASE=0
    if [ "${FINISH_PENDING:-0}" = 1 ] && [ "$(kv_get "$UPDATE_MARK" setup)" = keep ]; then SETUP_FROM_RELEASE=0; fi
    UPDATE_RUNNING=1
    programs_prebuilt
    [ "$DRY_RUN" = 0 ] || return 0
    if ! update_after; then
        update_rollback
        return 0
    fi
    update_done
    say "  the relay answers: $(local_get /relay-status)"
    say "  $(setup_change_text)"
}

# The update's last step, in the copy now in place, holding this run's lock
# (descriptor 9): every setting applied again, and the relay restarted.
update_after() {
    step "Applying this relay's settings with the new setup"
    bash "$INSTALLER_COPY/install.sh" --after-update
}

# install.sh --after-update: the settings this machine has, applied again by
# the setup that just went live, with the programs the update brought.
after_update_main() {
    [ -r "$CONF_FILE" ] || die "there is no relay set up here to update."
    conf_load
    [ "$CFG_MODE" = native ] || die "an update's last step is for the full setup only."
    # As the menu run found it: coturn's address and the TURN port lock's peers.
    PF_LOCAL_IP=$(local_ipv4)
    PROGRAMS_CHANGED=1
    native_apply
}

# A failed update puts back the programs, the setup's copy and the settings it
# kept, restarts the services as they ran, and forgets the update.
update_rollback() {
    warn "the update did not finish, so I am putting the previous version back."
    restore_previous_programs || die "the update did not finish, and there is no previous version to go back to. See: journalctl -u hollow-relay -e"
    local setup_back=""
    if setup_copy_rollback; then
        setup_back=" The setup is back to its earlier version too."
    fi
    update_settings_restore || warn "some of the earlier settings could not be put back. See: systemctl status 'hollow-*'"
    # The failed release may have restarted the relay many times already.
    systemctl reset-failed hollow-relay hollow-forwarder >/dev/null 2>&1 || true
    restart_relay_pair || true
    # The previous release is back either way, so a next run never offers to
    # finish the one that failed.
    if ! wait_for_relay; then
        update_done
        die "the previous version does not start either. See: journalctl -u hollow-relay -e"
    fi
    update_done
    ui_msg "Update undone" "Version $EXPECT_VERSION build $EXPECT_BUILD did not start or could not apply this relay's settings, so the previous version runs again, with its settings.$setup_back $SNAPSHOT_LOSS The relay's journal says why: journalctl -u hollow-relay -e"
}

# One line on what an update did to the setup itself.
setup_change_text() {
    case "$SETUP_CHANGE" in
    replaced) echo "the setup itself was updated too. The next sudo hollow-relay-setup runs the new version." ;;
    absent) echo "this release does not carry a new version of the setup, so the setup stays as it was." ;;
    failed) echo "the setup stays as it was, because its new version could not be put in place." ;;
    *) echo "the setup stays as it was, because going back to an older release keeps the newer setup." ;;
    esac
}

# A build from the copy of the repository this run comes from.
manage_rebuild() {
    if [ "$CFG_MODE" = docker ]; then
        ui_yesno confirm "Rebuild the containers" \
"I will copy this repository's relay sources to $DOCKER_DIR, build the containers again and restart them. $( [ "$CFG_FORWARDER" = yes ] && echo "The forwarder is part of it, which takes up to an hour or two on a small machine. ")The relay is down only for the restart at the end, and every restart of the relay container drops what is in its memory." yes || return 0
        apply_all
        summary_screen
        return 0
    fi
    ui_yesno confirm "Rebuild the relay" \
"I will build $SOURCE_LABEL from this copy of the repository, install it and restart the relay$( [ "$CFG_FORWARDER" = yes ] && echo " and the forwarder. Building the forwarder takes up to an hour or two on a small machine"). The relay keeps running during the build.

Offline messages and dropped connections carry across the restart when the version goes up. $SNAPSHOT_LOSS" yes || return 0
    APPLY_STARTED=1
    FORCE_PROGRAMS=1
    RESTART_UNITS=()
    CFG_BINARIES=source
    install_installer_copy
    programs_source
    [ "$DRY_RUN" = 0 ] || return 0
    restart_relay_pair
    if ! wait_for_relay; then
        warn "the relay did not come back after the rebuild, so I am putting the previous build back."
        restore_previous_programs || die "the relay did not come back after the rebuild, and there is no previous build to go back to. See: journalctl -u hollow-relay -e"
        restart_relay_pair
        wait_for_relay || die "the previous build does not start either. See: journalctl -u hollow-relay -e"
        ui_msg "Rebuild undone" "The new build did not start, so the previous one runs again. $SNAPSHOT_LOSS The relay's journal says why: journalctl -u hollow-relay -e"
        return 0
    fi
    say "  the relay answers: $(local_get /relay-status)"
}

# Puts the chosen option's screen up again, then applies everything.
manage_change() {
    # The settings an unfinished update kept for its rollback would undo a change.
    if update_pending; then
        ui_msg "Finish the update first" "The update to version $(kv_get "$UPDATE_MARK" version) (build $(kv_get "$UPDATE_MARK" build)) stopped part of the way. Finish it from the menu first, then change the setting."
        return 0
    fi
    local items=(turn "TURN for calls: $CFG_TURN")
    [ "$CFG_MODE" = native ] && items+=(push "Push sender for Android: $CFG_PUSH")
    items+=(forwarder "Media forwarder: $CFG_FORWARDER"
        members "Members-only: $CFG_MEMBERS_ONLY")
    if [ "$CFG_MEMBERS_ONLY" = yes ]; then
        items+=(addkey "Add a members-only key" removekey "Remove a members-only key")
    fi
    items+=(public_stats "Public stats page: $(public_stats_norm "${CFG_PUBLIC_STATS:-on}")"
        grace "Wait for dropped connections: ${CFG_GRACE_SECS:-120} seconds"
        address "The relay's address: $CFG_HOST")
    ui_menu change "Change a setting" "Which setting? I show its screen again, then apply the change. Everything else stays as it is." turn "${items[@]}"
    case "$UI_REPLY" in
    turn) ask_turn ;;
    push) ask_push ;;
    forwarder) ask_forwarder ;;
    members) ask_members ;;
    addkey) CFG_MEMBER_KEYS=$(( $(member_count) + 1 )) ;;
    removekey)
        local k keys=() list=() i
        mapfile -t keys < <(member_list)
        [ ${#keys[@]} -gt 0 ] || { ui_msg "No keys" "There are no members-only keys to remove."; return 0; }
        if [ "$UI_MODE" = answers ]; then
            # An answer file names the whole key.
            REMOVE_KEY=$(ans_get remove_key)
            case " ${keys[*]} " in *" $REMOVE_KEY "*) ;; *) die "the answer file's remove_key is not one of this relay's keys." ;; esac
        else
            # Only the end of each key goes on whiptail's command line, which ps shows to every local account.
            for i in "${!keys[@]}"; do list+=("$((i + 1))" "the key ending in ${keys[$i]##*-}"); done
            ui_menu remove_key "Remove a key" "Which key? Each one is named by its last four characters. The status menu's \"Show the members-only keys\" lists them in full. Whoever uses the key is disconnected within 30 seconds." 1 "${list[@]}"
            REMOVE_KEY=${keys[$((UI_REPLY - 1))]}
        fi
        CFG_MEMBER_KEYS=$(( ${#keys[@]} - 1 )) ;;
    public_stats) ask_public_stats ;;
    grace) ask_grace ;;
    address) preflight_run; ask_address; address_prepare ;;
    esac
    ssh_firewall_guard
    apply_all
    summary_screen
}

manage_keys() {
    if [ "$CFG_MEMBERS_ONLY" != yes ]; then
        ui_msg "Members-only keys" "This relay is open: anyone with the address can connect, so there are no keys to hand out. Change a setting to make it members-only."
        return 0
    fi
    ui_msg_keys "Members-only keys" "$(manage_keys_text)"
}

manage_keys_text() {
    printf 'Give one key to each person. One key admits up to 5 devices. The app asks for it the first time it connects, on a screen titled \"This relay needs an access key\".\n\n%s\n' "$(member_keys_shown)"
    [ -n "$(fwd_key_now)" ] && printf '\nThe media forwarder has a key of its own, which is not on this list.\n'
    return 0
}

manage_check() {
    step "Checking the machine"
    if [ "$CFG_MODE" = native ] || [ "$DRY_RUN" = 0 ]; then
        bash "$DEPLOY/check-host.sh" || true
    fi
    if wait_for_relay; then
        say "  /relay-status: $(local_get /relay-status 2>/dev/null)"
    else
        say "  the relay does not answer on this machine"
    fi
}

manage_uninstall() {
    local keeps
    if [ "$CFG_MODE" = docker ]; then
        keeps="the Docker volumes with the certificate, the report counts and the forwarder's identity, if you choose to keep them"
    else
        keeps="the forwarder's identity and the report counts, copied to $BACKUP_DIR if you choose to keep them, so a reinstall picks them up again
- the certificate in /etc/letsencrypt, so a reinstall does not need a new one. Its renewal stops, because the setup's renewal hooks are removed with it, and a reinstall turns it back on. sudo certbot delete --cert-name relay removes it."
    fi
    ui_msg "Remove the relay" \
"This removes:
- the relay and every service the setup added, their accounts, settings and secrets
- the relay programs and the setup's own copy in $LIB_DIR
- the firewall rules for the relay's ports. The firewall stays on, with SSH open.

It keeps:
- $keeps
- the hardening (firewall, journal in memory, no swap, no core dumps, SSH settings)
- the packages it installed, such as coturn, Node.js, certbot and Docker
- your copy of the repository

Messages waiting for people who are offline are lost."
    if ui_yesno keep_data "Keep the identity and report counts?" \
"Keep the forwarder's identity and the report counts, so a reinstall picks them up again? We recommend yes." yes; then
        UNINSTALL_KEEP=yes
    else
        UNINSTALL_KEEP=no
    fi
    ui_yesno confirm "Remove the relay now?" "Remove the Hollow relay from this machine?" no || { say "Nothing was removed."; return 0; }
    if [ "$CFG_MODE" = docker ]; then docker_uninstall "$UNINSTALL_KEEP"; else native_uninstall "$UNINSTALL_KEEP"; fi
    say ""
    say "The relay is removed. To set it up again, run install.sh from your copy of the repository."
    exit 0
}

# A run from a clone that holds an older setup than the one a release put
# here, or one it cannot compare, asks before replacing it, and by default
# leaves everything as it is.
setup_clone_gate() {
    local verdict how
    verdict=$(setup_clone_verdict)
    case "$verdict" in free | newer | same) return 0 ;; esac
    how="an older version of the setup ($(relay_source_version "$REPO" 2>/dev/null || true))"
    [ "$verdict" = unknown ] && how="a setup I cannot compare with it"
    if ui_yesno replace_setup "A newer setup is installed" \
"The setup on this machine came with version $(kv_get "$INSTALLER_COPY/$SETUP_SOURCE" version) (build $(kv_get "$INSTALLER_COPY/$SETUP_SOURCE" build)) of the relay, from a signed release. This copy of the repository holds $how.

Replace the installed setup with this copy? We recommend no. Run sudo hollow-relay-setup instead, which uses the installed one." no; then
        SETUP_REPLACE_OK=1
        return 0
    fi
    say "Nothing changed. Run sudo hollow-relay-setup to use the setup installed here."
    exit 0
}

manage_main() {
    conf_load
    setup_clone_gate
    PF_LOCAL_IP=$(local_ipv4)
    case "$(ip4_class "${PF_LOCAL_IP:-none}")" in private|cgnat) PF_BEHIND_NAT=1 ;; esac
    update_check
    local action
    ui_msg "Hollow relay status" "$(status_text)"
    if [ "$UI_MODE" = answers ] && [ "$(ans_get action exit)" = status ]; then return 0; fi
    local items=()
    if [ "${FINISH_PENDING:-0}" = 1 ]; then items+=(update "Finish the update to version $FEED_VERSION")
    elif [ "$UPDATE_AVAILABLE" = 1 ]; then items+=(update "Update to version $FEED_VERSION"); fi
    [ "${DOWNGRADE_AVAILABLE:-0}" = 1 ] && items+=(downgrade "Go back to the older version $FEED_VERSION build $FEED_BUILD")
    if [ "${REBUILD_AVAILABLE:-0}" = 1 ]; then
        if [ "$CFG_MODE" = docker ]; then items+=(rebuild "Rebuild the containers from this copy")
        else items+=(rebuild "Rebuild from this copy ($SOURCE_LABEL)"); fi
    fi
    items+=(change "Change a setting")
    [ "$CFG_MEMBERS_ONLY" = yes ] && items+=(keys "Show the members-only keys")
    ssh_passwords_on && items+=(ssh "Turn SSH password logins off")
    items+=(sshkey "Add another computer's SSH key")
    items+=(check "Check the machine again" uninstall "Remove the relay" exit "Leave everything as it is")
    ui_menu action "What next?" "The relay is set up on this machine. What would you like to do?" exit "${items[@]}"
    action=$UI_REPLY
    case "$action" in
    update) manage_update ;;
    downgrade) manage_downgrade ;;
    rebuild) manage_rebuild ;;
    change) manage_change ;;
    keys) manage_keys ;;
    check) manage_check ;;
    ssh)
        SSH_PLAN=guide
        ssh_run
        if [ "$DRY_RUN" != 1 ] && ! ssh_passwords_on; then
            ui_msg "SSH" "$SSH_RESULT

$(ssh_backup_note)"
        else
            ui_msg "SSH" "$SSH_RESULT"
        fi ;;
    sshkey)
        ssh_add_key_run
        ui_msg "SSH" "$SSH_RESULT" ;;
    uninstall) manage_uninstall ;;
    exit) say "Nothing changed." ;;
    esac
}
