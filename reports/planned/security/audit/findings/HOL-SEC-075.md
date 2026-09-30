# HOL-SEC-075: Push token prefixes and client addresses were written to the relay's disk

```
ID:          HOL-SEC-075                 Status: Fixed and DEPLOYED (relay box, 2026-09-30), old logs scrubbed
Severity:    Medium                      (Impact M: the privacy policy promises push tokens never
                                          reach disk and the relay logs no IP address; the disk held
                                          token prefixes with send times, client addresses, share
                                          activity, and the address of every connection to the
                                          anti-censorship proxy; Exploitability M: anyone who seizes
                                          or images the disk)
Category:    Information disclosure (logging)
Component:   /etc/rsyslog.d/00-hollow-privacy.conf, ufw logging (box);
             rust/hollow_core/src/forwarder/mod.rs :: run; relay-uws/deploy/harden-host.sh,
             hollow-forwarder.service, check-host.sh; push-sidecar/hollow-push.service
Boundary:    the relay host's disk
Traces to:   C-37, legal/PRIVACY_POLICY.md (relay, push tokens, TURN)
Attacker:    P-09 applied to the relay host (a seized disk, a provider snapshot)
Found:       2026-09-30 (session 19)
```

## Description

The journal is RAM-only, but rsyslog copied it into `/var/log/syslog`, and its privacy
filter dropped only `hollow-relay` and `turnserver`. The push sidecar logs as `node`, so
its lines reached the disk: before session 18 each push logged a token prefix and a
message id (50 such lines in the rotated files). The firewall logged every blocked
packet with its source address; the late packets of closed relay connections are
blocked too, so real clients' addresses sat among 79,000 scanner lines. The forwarder
wrote its own `hollow_debug.log` (4,631 lines of timestamped share activity). Xray
logged the address of every connection to 8443 since July (107,000 lines).

## Fix

rsyslog drops every `hollow-*` program and coturn; the sidecar runs with
`SyslogIdentifier=hollow-push`. The firewall logs nothing (`ufw logging off`). The
forwarder's `hollow_debug.log` is a symlink to `/dev/null` on the box, and from 0.12 the
headless forwarder never opens a log file. Xray is removed. `harden-host.sh` applies the
rsyslog rule and `ufw logging off` for self-hosters. The old lines are scrubbed from
`syslog*`, `kern.log*` and `ufw.log*`, and the forwarder and Xray logs are deleted.

## Test

`check-host.sh` (Disk section): a `hollow-*` line sent through `logger` must not appear
in `/var/log/syslog` while a control line does, and ufw logging must be off; it fails
without the rule. `the_headless_forwarder_opens_no_log_file` (forwarder/mod.rs, with
`--features forwarder`): fails with the old `log::init()` put back.

## Residual

`auth.log` keeps SSH login attempts with their addresses (attackers and the admin, never
users), which fail2ban needs. sysstat keeps whole-box network totals, no per-client data.
