# Security Policy

Hollow is an end-to-end encrypted messenger, so a security bug can expose exactly what people chose to keep private. Please report one privately.

## Reporting a vulnerability

**Don't open a public GitHub issue for a security vulnerability.**

Report it in one of two ways:

- Through GitHub: the repository's **Security** tab, then **Report a vulnerability**. This opens a private advisory only the maintainers can see.
- By email to **privacy@anonlisten.com**.

Include:

- what the vulnerability is
- how to reproduce it, if you can
- what an attacker could do with it
- a suggested fix, if you have one (optional, but welcome)

You'll get an acknowledgment within 48 hours. We'll work with you to understand the issue, fix it and agree on when to disclose it.

## Scope

In scope:

- Weaknesses in the Olm, MLS or SFrame implementations, or in key exchange
- Ways around Ed25519 signature checks, and flaws in key derivation
- Unauthorized access to a relay, message interception, or relay compromise
- Unencrypted data leaving the client, and metadata exposure
- Ways around SQLCipher, keys stored in plain text, and unsafe file handling

Out of scope:

- Denial of service against self-hosted relays (that's the operator's responsibility)
- Social engineering
- Bugs in upstream dependencies that don't affect Hollow specifically (please report those upstream)

## Supported versions

| Version | Supported |
|---------|-----------|
| Latest beta | Yes |
| Older builds | Best effort |

## Verifying a release

Every release since 0.14.0 has a signed Git tag, named `vX.Y.Z-beta`. Older tags are not signed. To check a tag before you build from it:

```bash
git clone --recurse-submodules https://github.com/VitalikPro13/HOLLOW.git
cd HOLLOW
git -c gpg.ssh.allowedSignersFile=.github/allowed_signers verify-tag v0.14.0-beta
git checkout v0.14.0-beta
```

A good tag prints a line starting with `Good "git" signature` and the release tag key's fingerprint. The command trusts the keys in `.github/allowed_signers` from the same checkout, so compare the fingerprint it prints with the list below.

| Key | Fingerprint |
|-----|-------------|
| Release tags | `SHA256:S474PF7v/QSTHwpXexCX4EzKFsNfDajUtcfP71jO+R4` |
| Release tags, recovery (kept offline, used only if the main key has to be replaced) | `SHA256:t2SgLyt37RDVcPNofDMdPPJYrbfH6GmLso+bAGLHDF0` |
| Commits on `main` | `SHA256:g92cPD7LGn7PROHB2c0rwWUuOaICuYcNjzqufzBm+7Q` |

Commits are signed with their own key. `.github/allowed_signers` lists only the tag keys, so it doesn't include this one; GitHub shows commits signed with it as Verified.

If a check fails or prints a different key, don't build from that copy. Report it as described above.

## Disclosure

We follow coordinated disclosure. Once a fix is ready, we:

1. Release a patched version
2. Credit the reporter (unless they'd rather stay anonymous)
3. Publish a short advisory describing the issue and the fix
