# HOL-SEC-074: Every local account could read the relay's TLS key and secrets

```
ID:          HOL-SEC-074                 Status: Fixed and DEPLOYED (relay box, 2026-09-30); self-hosting docs and scripts fixed
Severity:    Medium                      (Impact H: the TLS private key lets a holder pose as the
                                          relay, the TURN secret mints TURN credentials, the push
                                          token lets a local process send pushes through the sidecar;
                                          Exploitability L: needs code running as some account on the
                                          box first, such as a compromised coturn or proxy)
Category:    Information disclosure
Component:   /etc/letsencrypt/renewal-hooks/deploy (box); relay-uws/deploy/hollow-relay.service,
             renewal-hook.sh, coturn/coturn-start.sh, SELF_HOSTING.md; push-sidecar/hollow-push.service
Boundary:    the relay host (between local accounts)
Traces to:   HOL-SEC-073
Attacker:    code running as any other account on the relay host (a compromised coturn or proxy)
Found:       2026-09-30 (session 19, surveying the box before sandboxing)
```

## Description

A certbot deploy hook ran `chmod 644` on every certificate file after each renewal, so
every TLS private key under `/etc/letsencrypt/archive` was world-readable (confirmed by
reading it as `nobody`). `TURN_SECRET`, `HOLLOW_PUSH_TOKEN` and the sidecar's
`PUSH_TOKEN` were `Environment=` lines, which any local account reads with
`systemctl show` (the `0600` drop-in file hid nothing). The Firebase service account was
`0644` in the home of the account the relay ran as. On self-hosted relays the TURN
secret sat on coturn's command line, visible to `ps` on the host, a Docker host included.

## Fix

Private keys are `0640 root:ssl-cert` (coturn's group). The relay reads a root-owned
copy through its own group (`/etc/hollow-relay/privkey.pem`, `0640 root:hollow-relay`)
and still hot-reloads it within a minute; the new hook (`deploy/renewal-hook.sh`)
writes those modes and nothing wider. Secrets live in root-only `EnvironmentFile`s
(`/etc/hollow-relay/relay.env`, `/etc/hollow-push/push.env`) that systemd reads before
dropping privileges. The Firebase credential is root-only under `/etc/hollow-push` and
reaches the sidecar through `LoadCredential=` (a private RAM directory). The coturn
start script writes the secret into a `0600` file in its runtime directory (or a
private `mktemp -d`) and passes `-c`. `SELF_HOSTING.md` uses the same pattern. Stale
key copies from the July HAProxy spike are deleted.

## Test

`check-host.sh` (Secrets and Private keys sections): no secret name in any unit's
`Environment`, every `EnvironmentFile` `600 root`, no key or secret file readable by
everyone, no renewal hook that widens permissions, coturn's secret off its command
line. It fails on the old unit shape. The start script ran on the box on spare ports:
secret on no command line, file `0600`, the right secret allocates and a wrong one is
refused. The hook ran as certbot runs it: coturn restarted on the new modes, the relay
logged `TLS certificate reloaded`, TURN and TLS on 5349 still answer.
