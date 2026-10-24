#!/bin/bash
# The Docker setup: the compose stack from relay-uws/docker-compose.yml, run
# from a root-owned copy so its .env (which holds secrets) is root's alone.
# Sourced by install.sh.

DOCKER_DIR=/opt/hollow-relay-docker
STACK_DIR=$DOCKER_DIR/relay-uws
COMPOSE_PROJECT=hollow-relay

compose() {
    docker compose --project-name "$COMPOSE_PROJECT" --project-directory "$STACK_DIR" \
        -f "$STACK_DIR/docker-compose.yml" "$@"
}

docker_install() {
    if have docker && docker compose version >/dev/null 2>&1; then return 0; fi
    step "Installing Docker"
    say "  from Docker's own signed apt repository"
    local id codename
    id=$(kv_get /etc/os-release ID)
    codename=$(kv_get /etc/os-release VERSION_CODENAME)
    if [ "$DRY_RUN" = 1 ]; then
        say "  would add download.docker.com/linux/$id ($codename) with its key in /etc/apt/keyrings and install docker-ce with the compose plugin"
        return 0
    fi
    apt_install ca-certificates curl
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL --proto '=https' "https://download.docker.com/linux/$id/gpg" -o /etc/apt/keyrings/docker.asc ||
        die "could not download Docker's signing key."
    chmod 0644 /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$id $codename stable" |
        put_file /etc/apt/sources.list.d/docker.list 0644 root root
    APT_UPDATED=0
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ||
        die "Docker could not be installed."
    systemctl enable --now docker >/dev/null 2>&1 || true
}

# Whether install.sh runs from a copy of the repository, which can build the
# containers, rather than from the setup's own copy, which only manages them.
docker_have_sources() { [ -f "$REPO/relay-uws/src/main.cpp" ]; }

# Sets DOCKER_REBUILD=1 when the containers are to be built from new sources.
DOCKER_REBUILD=1
docker_copy_stack() {
    DOCKER_REBUILD=1
    if ! docker_have_sources; then
        # The setup's own copy: the stack and its sources stay as they are, and
        # only the settings change.
        [ -f "$STACK_DIR/docker-compose.yml" ] || die "there is no Docker setup in $DOCKER_DIR and no relay sources next to this installer. Run install.sh from your copy of the repository."
        if [ "$CFG_FORWARDER" = yes ] && [ ! -f "$DOCKER_DIR/rust/hollow_core/Cargo.toml" ]; then
            die "the media forwarder has to be built, and its sources are not in $DOCKER_DIR. Run install.sh from your copy of the repository to turn it on."
        fi
        DOCKER_REBUILD=0
        say "  keeping the containers' sources in $DOCKER_DIR as they are"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        say "  would copy the relay sources and the compose files to $DOCKER_DIR"
        return 0
    fi
    [ -f "$REPO/relay-uws/uWebSockets/src/App.h" ] || die "the relay's submodules are missing. Run: git submodule update --init --recursive, in your copy of the repository."
    install -d -m 0700 -o root -g root "$DOCKER_DIR"
    local parts=(relay-uws/CMakeLists.txt relay-uws/src relay-uws/uWebSockets relay-uws/uSockets
        relay-uws/Dockerfile relay-uws/Dockerfile.forwarder relay-uws/Dockerfile.forwarder.dockerignore
        relay-uws/docker-compose.yml relay-uws/deploy push-sidecar)
    [ "$CFG_FORWARDER" = yes ] && parts+=(rust/hollow_core rust/hollow_dfn)
    local tmp
    tmp=$(mktemp -d "$DOCKER_DIR/new.XXXXXX")
    tar -C "$REPO" "${SOURCE_EXCLUDES[@]}" -cf - "${parts[@]}" | tar -C "$tmp" -xf -
    # .env, the keys and the volumes stay; the code is replaced.
    [ -f "$STACK_DIR/.env" ] && cp -p "$STACK_DIR/.env" "$tmp/relay-uws/.env"
    [ -d "$STACK_DIR/keys" ] && cp -Rp "$STACK_DIR/keys" "$tmp/relay-uws/keys"
    rm -rf "$DOCKER_DIR/relay-uws" "$DOCKER_DIR/push-sidecar" "$DOCKER_DIR/rust"
    mv "$tmp"/* "$DOCKER_DIR/"
    rmdir "$tmp"
    chown -R root:root "$DOCKER_DIR"
}

# coturn's container uid, TURN_UID in deploy/certbot/lib.sh, which the certbot
# containers read too.
docker_turn_uid() {
    sed -n 's/^TURN_UID=\([0-9][0-9]*\)$/\1/p' "$DEPLOY/certbot/lib.sh" | head -n 1
}

# compose_turn_user <compose file>: the user its coturn service runs as.
compose_turn_user() {
    awk '/^[^ #]/ { svc = "" } /^  [^ #]/ { svc = $1 } svc == "coturn:" && $1 == "user:" { gsub(/"/, "", $2); print $2; exit }' "$1"
}

# The .env lines the setup writes; every other line is the operator's.
DOCKER_ENV_KEYS="RELAY_HOST DUCKDNS_TOKEN DUCKDNS_IP TURN_SECRET COMPOSE_PROFILES PUBLIC_IP PUBLIC_IPV6 LOCAL_IP
HOLLOW_MEM_LIMIT OWN_CERT_DIR SESSION_GRACE_SECS HOLLOW_CONN_RATE_EXEMPT CERTBOT_STAGING FORWARDER_PEER_ID
FWD_LICENSE_KEY PUBLIC_STATS"

docker_env() {
    local env=$STACK_DIR/.env turn_secret="" profiles=() exempt fwd_id own kept
    if [ "$CFG_TURN" = yes ]; then
        turn_secret=$(keep_or_new "$env" TURN_SECRET "${SEED_TURN_SECRET:-}")
        profiles+=(turn)
    fi
    [ "$CFG_FORWARDER" = yes ] && profiles+=(forwarder)
    exempt=$(kv_get "$env" HOLLOW_CONN_RATE_EXEMPT)
    [ -n "$exempt" ] || exempt=${SEED_EXEMPT:-}
    fwd_id=""
    if [ "$CFG_FORWARDER" = yes ]; then
        fwd_id=$(kv_get "$env" FORWARDER_PEER_ID)
        [ -n "$fwd_id" ] || fwd_id=${SEED_FWD_ID:-}
    fi
    # A certificate the person renews themselves, which a relay taken over may use.
    own=$(kv_get "$env" OWN_CERT_DIR)
    [ -n "$own" ] || own=${SEED_OWN_CERT_DIR:-}
    local staging=""
    [ "$CFG_STAGING" = yes ] && staging=1
    # shellcheck disable=SC2086 # one word per key
    kept=$(env_kept_block "$env" "${SEED_ENV_FILES:-}" $DOCKER_ENV_KEYS)
    local IFS=,
    {
        echo "# Written by install.sh. Root only: it holds the TURN secret and the DuckDNS token."
        printf 'RELAY_HOST=%s\n' "$CFG_HOST"
        printf 'DUCKDNS_TOKEN=%s\n' "$CFG_DUCKDNS_TOKEN"
        printf 'DUCKDNS_IP=%s\n' "$CFG_DUCKDNS_IP"
        printf 'TURN_SECRET=%s\n' "$turn_secret"
        printf 'COMPOSE_PROFILES=%s\n' "${profiles[*]}"
        printf 'PUBLIC_IP=%s\n' "$CFG_PUBLIC_IP"
        printf 'PUBLIC_IPV6=%s\n' "$CFG_PUBLIC_IPV6"
        printf 'LOCAL_IP=%s\n' "${PF_LOCAL_IP:-}"
        printf 'HOLLOW_MEM_LIMIT=%sm\n' "$(mem_mb)"
        printf 'OWN_CERT_DIR=%s\n' "$own"
        printf 'SESSION_GRACE_SECS=%s\n' "$CFG_GRACE_SECS"
        printf 'HOLLOW_CONN_RATE_EXEMPT=%s\n' "$exempt"
        printf 'CERTBOT_STAGING=%s\n' "$staging"
        printf 'FORWARDER_PEER_ID=%s\n' "$fwd_id"
        printf 'FWD_LICENSE_KEY=%s\n' "$FWD_KEY"
        printf 'PUBLIC_STATS=%s\n' "$(public_stats_norm "${CFG_PUBLIC_STATS:-on}")"
        if [ -n "$kept" ]; then printf '\n%s\n' "$kept"; fi
    } | put_file "$env" 0600 root root
}

docker_keys() {
    ensure_dir "$STACK_DIR/keys" 0750 root 999
    # In the Docker setup the forwarder's key sits in .env as FWD_LICENSE_KEY.
    plan_member_keys "$STACK_DIR/keys/keys.json" "$STACK_DIR/.env" FWD_LICENSE_KEY
    local all=("${MEMBER_KEYS[@]}")
    [ -n "$FWD_KEY" ] && all+=("$FWD_KEY")
    local enabled=false
    [ "$CFG_MEMBERS_ONLY" = yes ] && enabled=true
    keys_json "$enabled" "${all[@]}" | put_file "$STACK_DIR/keys/keys.json" 0640 root 999
}

docker_apply() {
    APPLY_STARTED=1
    step "Packages"
    apt_install curl ca-certificates openssl ufw
    step "Hardening the machine (deploy/harden-host.sh)"
    [ "$DRY_RUN" = 1 ] || hollow_apt_wait || die "the system's automatic updates still hold the package lock. Wait until they finish, then run the setup again."
    local http=no
    [ "$CFG_ADDRESS" = duckdns ] || http=yes
    local hargs=(--http "$http" --turn "$CFG_TURN" --forwarder "$CFG_FORWARDER" --no-ssh)
    [ "$DRY_RUN" = 1 ] && hargs+=(--print)
    run_logged sh "$DEPLOY/harden-host.sh" "${hargs[@]}" || die "the hardening step failed."
    # A relay taken over keeps its name where it points.
    [ "$CFG_ADDRESS" = duckdns ] && [ "${ADOPT_KIND:-none}" = none ] && duckdns_point_now
    docker_install
    install_installer_copy
    step "The compose stack in $DOCKER_DIR"
    docker_copy_stack
    # The keys first: they decide the forwarder's key that .env carries.
    docker_keys
    docker_env
    # Before coturn's container starts.
    if [ "$CFG_TURN" = yes ]; then
        local turn_uid who
        turn_uid=$(docker_turn_uid)
        [ -n "$turn_uid" ] || die "$DEPLOY/certbot/lib.sh names no TURN_UID for coturn's container."
        # A lock on another uid than the one coturn runs as would hold nothing.
        if [ "$DRY_RUN" != 1 ] && [ "$(compose_turn_user "$STACK_DIR/docker-compose.yml")" != "$turn_uid:$turn_uid" ]; then
            die "coturn in $STACK_DIR/docker-compose.yml does not run as uid $turn_uid, the uid the TURN port lock holds. Run install.sh from your copy of the repository."
        fi
        # The package's own coturn would take TURN's ports beside the container, unlocked.
        if [ "$(systemctl show -p LoadState --value coturn 2>/dev/null)" = loaded ]; then
            run_ok systemctl disable --now coturn
            run systemctl mask --quiet coturn
        fi
        who=$(getent passwd "$turn_uid" 2>/dev/null | cut -d: -f1 || true)
        [ -z "$who" ] || warn "coturn's container runs as uid $turn_uid, which on this machine is also the account $who. The TURN port lock holds that uid, so $who can now send UDP to this machine's own addresses only on the TURN ports."
        turn_lock_apply "$turn_uid" no
    else
        turn_lock_remove
    fi
    if [ "$DRY_RUN" = 1 ]; then
        say "  would run docker compose up -d --build (profiles: turn=$CFG_TURN forwarder=$CFG_FORWARDER)"
        conf_save
        return 0
    fi
    step "Building and starting the containers"
    if [ "$DOCKER_REBUILD" = 0 ]; then
        say "  no new sources, so only a container that is missing gets built"
    elif [ "$CFG_FORWARDER" = yes ]; then
        say "  building the relay, the push sender and the media forwarder. The forwarder is the whole Hollow core library, so on a small machine this takes up to an hour or two."
        build_swap_on 4096
    else
        say "  building the relay and the push sender. This takes a few minutes."
        build_swap_on 1500
    fi
    if [ "$DOCKER_REBUILD" = 1 ]; then
        local t0 t1
        t0=$(date +%s)
        run_logged compose build || { build_swap_off; die "the containers did not build."; }
        build_swap_off
        t1=$(date +%s)
        say "  built in $(( (t1 - t0) / 60 )) min $(( (t1 - t0) % 60 )) s"
    fi
    adopt_step docker_switch
    # Leftover services from options that are off now.
    run_logged compose up -d --remove-orphans || die "the containers did not start. See: docker compose -p $COMPOSE_PROJECT logs"
    # compose keeps a container whose settings did not change, and a running one
    # still sees the deploy folder the copy replaced: the renewal loop would call
    # hooks that are gone, and every renewal after an update would fail.
    if [ "$DOCKER_REBUILD" = 1 ]; then
        run_logged compose up -d --no-deps --force-recreate certbot-renew duckdns ||
            die "the certificate renewal did not restart. See: docker compose -p $COMPOSE_PROJECT logs certbot-renew"
    fi
    if [ "$CFG_TURN" != yes ]; then run_ok compose rm -sf coturn; fi
    if [ "$CFG_FORWARDER" = yes ]; then
        local id=""
        for _ in $(seq 1 60); do
            id=$(compose run --rm --no-deps -T forwarder --print-peer-id 2>/dev/null | tr -d '\r' | tail -n 1) &&
                [[ "$id" =~ ^12D3KooW[1-9A-HJ-NP-Za-km-z]+$ ]] && break
            id=""
            sleep 2
        done
        [ -n "$id" ] || die "the forwarder did not start. See: docker compose -p $COMPOSE_PROJECT logs forwarder"
        say "  the forwarder's id is $id"
        if [ "$(kv_get "$STACK_DIR/.env" FORWARDER_PEER_ID)" != "$id" ]; then
            sed -i "s/^FORWARDER_PEER_ID=.*/FORWARDER_PEER_ID=$id/" "$STACK_DIR/.env"
            run_logged compose up -d relay || die "the relay did not restart with the forwarder's id."
        fi
    else
        run_ok compose rm -sf forwarder
    fi
    conf_save
    step "Checking the relay answers"
    wait_for_relay || die "the relay did not answer on 127.0.0.1. See: docker compose -p $COMPOSE_PROJECT logs relay"
    say "  /health: $(local_get /health)"
    say "  /relay-status: $(local_get /relay-status)"
}

docker_uninstall() {
    local keep=$1
    APPLY_STARTED=1
    step "Removing the Hollow relay containers"
    if [ -f "$STACK_DIR/docker-compose.yml" ]; then
        if [ "$keep" = yes ]; then
            run_logged compose --profile turn --profile forwarder down --remove-orphans || true
            say "  kept the volumes (certificate, report counts, forwarder identity). docker volume ls lists them."
        else
            run_logged compose --profile turn --profile forwarder down -v --remove-orphans || true
        fi
    fi
    turn_lock_remove
    if [ "$(systemctl show -p LoadState --value coturn 2>/dev/null)" = masked ]; then run_ok systemctl unmask coturn; fi
    run rm -rf "$DOCKER_DIR" /etc/hollow-relay /usr/local/sbin/hollow-relay-setup "$STATE_DIR"
    local rule
    for rule in 443/tcp $HOLLOW_FW_OPTIONAL; do run_ok ufw delete allow "$rule"; done
    run rm -f "$MEMBER_KEYS_OUT"
    run rm -rf "$LIB_DIR"
}
