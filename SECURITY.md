# Security Policy

Hollow is an end-to-end encrypted communication platform. Security vulnerabilities directly impact user privacy. We take every report seriously.

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, email **privacy@anonlisten.com** with:

- A description of the vulnerability
- Steps to reproduce it (if applicable)
- The potential impact
- Any suggested fix (optional, but appreciated)

You will receive an acknowledgment within 48 hours. We will work with you to understand the issue, develop a fix, and coordinate disclosure.

## Scope

The following are in scope:

- **Cryptographic issues** -- weaknesses in Olm, MLS, SFrame, or key exchange implementations
- **Authentication/identity** -- Ed25519 signature bypass, key derivation flaws
- **Relay security** -- unauthorized access, message interception, or relay compromise
- **Data leakage** -- unencrypted data leaving the client, metadata exposure
- **Local storage** -- SQLCipher bypass, plaintext key storage, insecure file handling

Out of scope:

- Denial of service against self-hosted relays (that's the operator's responsibility)
- Social engineering attacks
- Issues in upstream dependencies with no Hollow-specific impact (report those upstream)

## Supported versions

| Version | Supported |
|---------|-----------|
| Latest beta | Yes |
| Older builds | Best effort |

## Disclosure

We follow coordinated disclosure. Once a fix is ready, we will:

1. Release a patched version
2. Credit the reporter (unless they prefer to remain anonymous)
3. Publish a brief advisory describing the issue and the fix

Thank you for helping keep Hollow and its users safe.
