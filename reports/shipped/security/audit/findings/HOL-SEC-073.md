# HOL-SEC-073: The relay, push sender and forwarder ran as an account with root

```
ID:          HOL-SEC-073                 Status: Fixed and DEPLOYED (relay box, 2026-09-30)
Severity:    High                        (Impact H: root on the relay box, which holds the TLS key,
                                          the TURN secret and the Firebase credential that can push
                                          to every Hollow phone; Exploitability M: needs one
                                          memory-safety bug in the C++ relay or a bug in the other
                                          two network-facing services)
Category:    Privilege management
Component:   relay-uws/deploy/hollow-relay.service, hollow-forwarder.service, coturn-sandbox.conf,
             check-host.sh, harden-host.sh; push-sidecar/hollow-push.service; the relay box
             (units, accounts, /usr/local/bin, /opt/hollow-push, /etc/hollow-*, /var/lib/hollow-*)
Boundary:    TB-1 (client <-> relay), the relay host itself
Traces to:   SECURITY_AUDIT_PLAN.md section 4 "H"; C-26 (the Firebase credential)
Attacker:    any client or stranger reaching a service on the box, who becomes P-01 through one bug
Found:       2026-09-29 (session 18: `systemd-analyze security hollow-relay` = 9.2 UNSAFE)
```

## Description

All three services ran as `ubuntu`, which has passwordless sudo, with no sandbox (9.2
UNSAFE measured for the relay and the forwarder; the sidecar's unit had the same shape). The relay's binary sat in `ubuntu`'s home, writable by the account
that ran it, so a compromise also survived restarts. coturn (8.8 EXPOSED) had no
sandbox either, and an abandoned Xray proxy from the anti-censorship experiment still
listened on 8443 as `nobody` with CAP_NET_ADMIN.

## Fix

Each service runs as its own system account with no sudo and no admin group
(`hollow-relay`, `hollow-push`, `hollow-fwd`), from root-owned binaries
(`/usr/local/bin`, `/opt/hollow-push`), with state in `StateDirectory` and settings in
`/etc/hollow-*`. The relay holds only CAP_NET_BIND_SERVICE (ambient, no file capability);
the others hold none. Every unit carries a full systemd sandbox (`ProtectSystem=strict`,
`ProtectHome`, `PrivateDevices`, `PrivateIPC`, `ProtectKernel*`, `ProtectProc=invisible`,
`RestrictAddressFamilies`, `RestrictNamespaces`, `SystemCallFilter=@system-service` minus
`@privileged`, `MemoryDenyWriteExecute` except for Node.js, `InaccessiblePaths` over the
other services' secrets). Denied system calls return EPERM, never a kill: an abnormal
exit skips the restart snapshot. Exposure now: relay 1.4, push 1.2, forwarder 1.1,
coturn 1.2 (drop-in). The restart handoff (memfd into the fd store) works unchanged
inside the sandbox. Xray, shadowsocks and HAProxy are removed and 8443 is closed. SSH
takes keys only, as `ubuntu` only, no root login. The Docker path runs every container
without capabilities, with `no-new-privileges` and a read-only root; the relay binds
443 through its own network namespace's `ip_unprivileged_port_start`, no `setcap`.

## Test

`sudo bash relay-uws/deploy/check-host.sh`: every service account, binary write access
and sandbox score. It passes on the box, and FAILS on a unit shaped like the old one
(runs as a sudo account, can rewrite its binary, 9.2, core dumps allowed). The
canary run: the sandboxed relay on a local port passed the live probe, sent a push to
the sidecar from inside the sandbox, and handed 1 DM frame and 1 push token through a
restart; production then restored every buffer (3 DM frames, 74 topic frames in 328
rings, 310 opt-ins, 28 push tokens, 17 push prefs) and the live probe passed 8/8.
Docker: the hardened compose stack built and ran on the Linux VM (relay healthy with
zero capabilities, TURN allocation, secret absent from `ps`).

## Residual

`ubuntu` keeps passwordless sudo: it is the admin account, reachable only by SSH key.
A kernel bug reachable through the allowed system calls would still escape the
sandbox; unattended security updates cover the kernel, reboots are manual.
