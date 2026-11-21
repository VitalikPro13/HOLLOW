# HOL-SEC-214: A self-hosted relay kept its old public address in TURN after the address changed

```
ID:          HOL-SEC-214                 Status: Fixed in the relay setup (track fix-214,
                                          2026-11-20), live to self-hosters on push
Severity:    Low                         (Impact L: UDP from the relay's coturn to
                                          49152-65535 on one address that is no longer
                                          the operator's, plus TURN and forwarder calls
                                          broken until someone reruns the setup;
                                          Exploitability L: needs the old address to be
                                          handed to someone else, and any identity with
                                          TURN credentials from that relay)
Category:    Configuration / Stale authorization
Component:   relay-uws/deploy/lib/native.sh (render_turn_env, render_turn_lock_env,
             render_forwarder_toml), relay-uws/deploy/lib/docker.sh (docker_env)
Boundary:    TB-4 (relay host and its operator)
Traces to:   AR-32 (the TURN port lock), R-RS-21
Attacker:    whoever is next given the relay's old address, with any user of the relay
Found:       2026-11-20 (fix-153 investigation of a home relay on a dynamic address)
Affected:    every relay set up by install.sh with a DuckDNS name or its own domain,
             from the setup's first release through 0.14.1
Fix commit:  pending (track fix-214)
Disclosure:  private until the setup change is pushed
```

## Description

The setup wrote the machine's public address once, at install, into coturn's settings
(`PUBLIC_IP`, which becomes `--external-ip` and `--allowed-peer-ip`), the TURN port lock's
`TURN_PEERS` and the media forwarder's `public_ip`. Home relays on a dynamic address keep
their name current through DuckDNS (the setup's timer only updates the DNS record) or a
router's or a container's dynamic DNS, so chat followed a new address while TURN and the
forwarder did not. Calls through them failed, and the old address stayed an allowed TURN
peer: an allocation could still send UDP into ports 49152 to 65535 of whoever was given
that address next. Only the menu's "Change a setting, then the address" rewrote the
fields.

## Fix

An address follower (`relay-uws/deploy/address-follow.sh`, `hollow-address-follow.service`
and `.timer`, every five minutes) for relays with a DuckDNS name or a domain that run TURN
or the forwarder. It looks the relay's own name up (A, and AAAA only for an IPv6 address the
setup already uses) through this machine's DNS servers, asked as DNS
(`deploy/address-probe.py dns`: `resolvectl query --cache=no --synthesize=no` where
systemd-resolved runs, else one query to the nameservers in `/etc/resolv.conf`). No third
party resolves anything; `/etc/hosts`, nss-myhostname and resolved's synthesized records
(Debian's and Ubuntu's `127.0.1.1 <fqdn>` line) never answer, and an answer naming any
private address (a router's or a Pi-hole's local entry) counts for nothing, for taking and
for dropping alike.

A new address counts only once it is proven to be this machine: an address on one of its
interfaces, or one where BOTH a TLS handshake for the relay's name completes with the public
key this machine's relay serves on 127.0.0.1:443 (`curl --pinnedpubkey`; the far end has to
hold the relay's private key) AND, with TURN on, coturn there answers an authenticated
Allocate whose MESSAGE-INTEGRITY verifies under a five-minute REST credential root derives
from `TURN_SECRET` (`address-probe.py turn`; the probe account never sees the secret, and
an echoed request is refused because only a response class counts). The second proof stops
a passthrough proxy for port 443, such as a front HAProxy on another machine the name
points at, from becoming coturn's external address. Private addresses are never taken.
Every probe runs as the `hollow-addr` account under `timeout 8`.

What the follower decides lives in install.conf's own keys, `turn_public_ip` and
`turn_public_ipv6`; `public_ip` stays the setup's answer, which DuckDNS and every later
setup run use, and a new answer to the setup's address question clears the follower's
keys. Every renderer (coturn's settings, the Docker setup's `.env`, the port lock's peers,
`forwarder.toml`) reads the follower's address when set. A change rewrites exactly those
fields in one rename each, with mode and owner kept, and restarts coturn, the forwarder and
the lock only when a file changed. The lock takes the new peers beside the old ones (and
must load them) before coturn's settings change; a restart or reload a renamed file owes is
noted in RAM before the rename, retried on every look until it works, and only a look in
which every write, restart and reload worked, with nothing owed, drops the old peers. So a
failed `try-restart`, a failed `docker compose up` or a run killed between a rename and its
restart never leaves coturn allowing a peer the loaded rule does not cover; check-host fails
while anything is owed. Changes are at least ten minutes apart. The follower takes the
setup's lock only around its writes, reads install.conf again once it holds it and writes
nothing if a setup run changed it during the look; a run killed mid-write leaves no
temporary file, and the next run sweeps any a power cut left.

A router without NAT loopback cannot carry the proof from inside. Then nothing new is
trusted, and the current IPv4 is dropped for the machine's own LAN address only when every
look across at least 30 minutes and at least six looks in a row shows all of: the address
is on none of this machine's interfaces; a pinned handshake there fails (a relay that still
proves there is never dropped, and a relay that does not answer on 127.0.0.1 judges
nothing); DNS gave the same non-empty set of public addresses each time, never containing
the current one; and the LAN address is on an interface and differs from the current one.
A failed handshake alone means nothing behind a router without NAT loopback, where it
always fails, so evidence beyond DNS is required. For a domain, a pinned handshake to the
machine's own current address must have worked since boot (a steady-state look pins until
one does; a pin-proven move counts), else the domain is never dropped and check-host fails
naming both addresses. For a DuckDNS name that follows the machine, DuckDNS's own answer is
the evidence: the updater asks with `verbose=true` over HTTPS and keeps the address DuckDNS saw in RAM
(`/run/hollow-duckdns/seen`), and that address must be fresh (15 minutes), public, not the
current one and in the DNS set. Any other look (no answer, SERVFAIL, NXDOMAIN, a private
answer, an answer naming the current address, a changed set) starts the window again. The
window lives in RAM. A dropped address is never taken back on the resolver's word alone; it
needs the interface or the two proofs like any other. Dropping an allowed peer opens
nothing, and TURN through the name no longer reached the old address in any case. An IPv6
address the machine no longer holds and that no longer proves goes after the same window.
check-host's "Public address" section names any file whose address the name does not point
at, skips (never fails) a private or missing DNS answer (on a network whose DNS answers the
name with a LAN address, one line says the follower can't follow there), fails while a
restart is owed, and fails when the follower is off or its unit is weakened (a protection
removed or a capability added).

The setup's own DNS check (`dns_points_at`) treats an answer of only LAN addresses as one it
cannot judge from inside a split-horizon network: it says so and lets the certificate step
judge, instead of asking for a public record that may be right. On a fresh DuckDNS install
the address DuckDNS saw the update come from must equal the address measured in the same
run, or the setup stops naming both; only an address kept from install.conf gives way to
DuckDNS's.

Failure modes that remain, documented in SELF_HOSTING.md: behind a router without NAT
loopback a changed DuckDNS address leaves TURN on the LAN address after half an hour, and a
changed domain address leaves TURN on the old address, until the operator confirms the new
one (Change a setting, then the address); a router or Pi-hole
answering the name with a LAN address freezes the follower (nothing moves, nothing drops);
a name pointing at a proxy in front of the server is never taken; a forwarder-only relay
proves an address with the TLS pin alone, since no TURN server answers there. The follower
also puts hand edits of these address fields back within five minutes.

A bare IP address or a LAN address typed for a relay only the home network uses gets no
follower, since there is no name to follow; the setup says a bare IP needs a fixed address.

Tests: `relay-uws/test/installer/address_follow_box_test.sh`, run by
`run_systemd_tests.sh` in Ubuntu 24.04 and Debian 12 boxes against a fake DNS server
(`fake_dns.py`):
`a_proven_change_rewrites_all_three_and_drops_the_old_peer`,
`an_impostor_address_rewrites_nothing`, `a_passthrough_proxy_for_443_alone_is_not_taken`,
`an_echo_of_our_own_turn_request_is_not_taken`,
`a_turn_server_without_this_relays_secret_is_not_taken`, `every_probe_has_a_time_limit`,
`the_lock_holds_old_and_new_peers_while_coturn_restarts`, `the_probes_run_as_hollow_addr`,
`a_failed_coturn_restart_keeps_the_old_peer_locked_and_retries`,
`a_run_killed_before_coturn_restarts_restarts_it_on_the_next_look`,
`a_lock_that_does_not_load_keeps_coturn_where_it_was`,
`a_settings_file_that_cannot_be_written_keeps_the_old_peer`,
`a_coturn_our_restart_left_failed_starts_again`,
`a_failed_compose_up_keeps_the_old_peer_locked_and_retries`,
`a_domain_behind_a_router_without_loopback_is_not_dropped_on_dns_alone`,
`the_follower_says_once_that_it_cannot_follow_on_a_split_horizon_network`,
`no_change_restarts_nothing`, `a_private_address_is_never_taken`,
`etc_hosts_and_the_hosts_own_name_never_answer`,
`a_resolved_machine_is_asked_without_hosts_cache_or_synthesis`,
`no_drop_without_an_address_of_its_own_to_fall_back_on`, `a_second_change_within_ten_minutes_waits`,
`a_stale_address_drops_only_after_six_looks_over_half_an_hour`,
`a_full_window_drops_the_old_address_and_leaves_the_setups_answer`,
`a_dropped_address_is_never_taken_back_on_dns_alone`,
`duckdns_mode_drops_only_when_duckdns_saw_this_machine_move`,
`an_update_after_a_drop_keeps_the_setups_answer`,
`a_setup_address_change_clears_the_followers_address`,
`an_ipv6_address_this_machine_holds_is_proven_and_taken`,
`a_v6_address_this_machine_no_longer_has_drops_after_the_window`,
`the_follower_writes_nothing_while_the_setup_runs`,
`the_follower_reads_install_conf_again_once_it_holds_the_lock`,
`a_run_killed_mid_rewrite_leaves_no_temporary_and_old_ones_are_swept`,
`hand_edits_of_the_address_fields_are_put_back`, `a_relay_that_hangs_on_loopback_stops_no_look`,
`the_follower_unit_follows_inside_its_sandbox`,
`check_host_fails_a_follower_given_another_capability`,
`the_docker_setup_follows_through_compose`, `no_follower_for_a_bare_ip_or_a_lan_relay`,
`uninstall_removes_the_follower`; `adopt_box_test.sh`
`the_follower_follows_a_real_docker_stack_under_its_unit` (docker) and
`adopt_rollback_removes_the_follower` (rollback, docker-rollback); `run_tests.sh`
`the_setup_explains_a_lan_answer_for_its_own_name`,
`a_fresh_duckdns_install_stops_when_duckdns_and_the_echo_disagree`.
