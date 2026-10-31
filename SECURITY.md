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

## Disclosure

We follow coordinated disclosure. Once a fix is ready, we:

1. Release a patched version
2. Credit the reporter (unless they'd rather stay anonymous)
3. Publish a short advisory describing the issue and the fix
