# Dependency Security Audit — Hollow (June 2026)

**Date:** 2026-06-25
**Scope:** Every security-relevant Rust crate (`rust/hollow_core/Cargo.lock`) and Flutter/Dart
package (`pubspec.yaml`) — crypto primitives, at-rest encryption, TLS/transport, and
untrusted-input parsers. Versions checked against latest stable on crates.io / pub.dev with
changelogs, plus the RustSec advisory DB (`github.com/rustsec/advisory-db`) and upstream CVE
trackers.

**Method:** Resolved versions read from the lockfile (not the loose `Cargo.toml` constraints),
then cross-checked against latest stable + advisories. No code was changed.

---

## TL;DR

- **`cargo audit` is clean** — no crate has an *active* advisory against its currently-resolved
  version. Our library choices (vodozemac over libolm, openmls, dalek, aes-gcm, argon2) are all
  either on latest stable or clean with every known CVE fixed in a release we already ship past.
- **The one finding `cargo audit` cannot see:** the *bundled* SQLite (3.49.1, statically linked
  via `libsqlite3-sys`) carries 3 unpatched upstream memory-corruption CVEs. RustSec does not
  track bundled C libraries, so the green checkmark hides this. **One of the three
  (CVE-2025-7709) is genuinely reachable** through our FTS5 message-text indexing.
- **Three free, non-breaking hygiene bumps** exist (rustls, getrandom, scraper).
- **Everything design-level** (key-verification UX / MITM, relay metadata) is deliberately
  **deferred to the planned NLnet professional audit** — not addressed here.

---

## Priority actions

| # | Action | Type | Risk to take | Status |
|---|--------|------|--------------|--------|
| 1 | Bump **rusqlite 0.34 → 0.40.1** / **libsqlite3-sys 0.32 → 0.38.1** (SQLite 3.49.1 → 3.53.2) | Security (reachable) | Breaking: rusqlite 0.38 disabled default `u64`/`usize` `ToSql`/`FromSql`; needs harness run | **Schedule — dedicated pass** |
| 2 | Bump **rustls 0.23.36 → 0.23.41** | Hygiene | None (same minor; lifts TLS under reqwest + tungstenite in one bump) | Freebie |
| 3 | `cargo update -p getrandom@0.4.1` → **0.4.3** | Hygiene | None (patch) | Freebie |
| 4 | Bump **scraper 0.26 → 0.27** | Hygiene | Minimal (possible explicit feature flag) | Freebie |
| 5 | Everything else | — | — | Defer to NLnet / leave as-is |

---

## Finding 1 (the real one): bundled SQLite carries reachable CVEs

`libsqlite3-sys 0.32.0` (under `rusqlite 0.34.0`, `bundled-sqlcipher` feature) statically bundles
**SQLite 3.49.1** via the SQLCipher 4.7.0 amalgamation — ~1 year / 4 minors behind upstream.
Because the C library is bundled, **RustSec does not track it**: `cargo audit` reports clean while
we ship three unpatched upstream memory-corruption CVEs.

| CVE | Class | Fixed upstream in | Reachability in Hollow |
|-----|-------|-------------------|------------------------|
| **CVE-2025-7709** | FTS5 integer overflow → **OOB read** | SQLite 3.50.3 | **Reachable.** Needs only attacker-influenced FTS5 content (not SQL injection) — i.e. a message someone sends you, which we index. |
| CVE-2026-11822 | FTS5 heap **write** overflow | SQLite 3.53.2 | Low. SQL-injection-gated; all our queries are parameterized via rusqlite. |
| CVE-2025-6965 | integer overflow → array read | SQLite 3.50.2 | Low. Injection-gated. |

**Why CVE-2025-7709 is the one that matters:** Hollow runs FTS5 over decrypted message text in
both DMs and channels. Confirmed in `rust/hollow_core/src/storage/messages.rs`:

- `messages_fts` + `search_dm_messages()` (~L3253) — `WHERE fts.text MATCH ?`
- `channel_messages_fts` + `search_channel_messages()` (~L3198) — `WHERE fts.text MATCH ?`

Incoming message text is indexed into FTS5, which is exactly the surface this CVE targets. It is
**not** SQL-injection-gated, so the other two CVEs' "we parameterize everything" mitigation does
not cover it.

**Calibration (do not over-alarm):**
- It is an out-of-bounds **read** (info-disclosure / crash / DoS class), not RCE. Realistic worst
  case is a crash or small memory read.
- It requires *carefully crafted hostile input*, not a trivially-triggered path.
- Mitigating factor: data is decrypted **before** it reaches SQLite, so the attacker must be a
  peer you have already accepted (a contact / shared-server member) — not an arbitrary network
  party. That narrows the threat set substantially.

**Verdict:** This is the single most concrete, reachable security improvement in the whole sweep,
and precisely the kind of thing the green `cargo audit` checkmark would lull us into missing.
**Move from "defer" to "schedule deliberately, sooner rather than later."**

**Fix + cost:** Bump to **rusqlite 0.40.1 / libsqlite3-sys 0.38.1** (SQLite 3.53.2) — closes all
three CVEs at once. Migration cost:
- rusqlite **0.38.0** disabled default `u64`/`usize` `ToSql`/`FromSql` impls → re-enable the
  feature flag or add explicit casts at timestamp/id bind & read sites in the message store.
- Run the multi-node harness (touches the persistence layer).
- **Verify** the SQLCipher amalgamation at `libsqlite3-sys 0.38.1` actually carries SQLite ≥
  3.53.2 *before* committing — SQLCipher sometimes lags upstream SQLite.
- Android cross-compile story (`bundled-sqlcipher` + `openssl-sys`) is unchanged.

**Cheap interim hardening** if a bump can't be scheduled near a release: enable
`SQLITE_DBCONFIG_DEFENSIVE`, confirm all SQL is parameterized (it is), and confirm FTS5 content
exposure is limited to accepted peers.

---

## Findings 2–4: free hygiene bumps (non-breaking)

- **rustls 0.23.36 → 0.23.41** — same minor, non-breaking. Both historical advisories
  (RUSTSEC-2024-0336 complete_io loop; RUSTSEC-2024-0399 Acceptor panic, fixed 0.23.18) predate
  0.23.36, so current is already clean — this is a patch uplift (includes an SNI-padding fix).
  One workspace bump lifts the TLS layer under **both** `reqwest` and `tokio-tungstenite`
  (verify with `cargo tree -i rustls`).
- **getrandom 0.4.1 → 0.4.3** — pure patch, no API change. Picks up corrected `errno` reading and
  Windows `ProcessPrng` return-value validation. (The three coexisting getrandom versions
  0.2/0.3/0.4 in the tree are normal semver-separate transitive pulls, **not** a risk; do not try
  to collapse them.)
- **scraper 0.26 → 0.27** — refreshes the CSS/HTML parsing deps (`selectors`/`cssparser`) that
  touch fetched link-preview HTML. Minimal breakage risk (an implicit-feature rename may need an
  explicit flag).

---

## Explicitly NOT worth bumping (skip / already optimal)

| Crate | Resolved | Why skip |
|-------|----------|----------|
| **vodozemac** | 0.9.0 | 0.10.0 is **breaking** (new `SessionConfig` arg, fallible DH, strict-signatures now default) and fixes **no** security issue. The three libolm CVEs (45191/45192/45193) are in the **old C library** — vodozemac (the Rust rewrite) was never affected; its only two historical advisories were fixed pre-0.9.0. Worthwhile hardening eventually, but needs a DM-handshake harness re-run → defer to a dedicated pass. |
| **openmls** (+ companions) | 0.8.1 / 0.5.x | Already latest. 0.8.1 pulls the fixed transitive deps (hpke-rs ≥ 0.6.0, libcrux ≥ 0.0.6). On any future `cargo update`, keep verifying those two stay satisfied — they are the security-load-bearing transitives. |
| **ed25519-dalek** | 2.2.0 | Latest stable (3.0 is RC only). RUSTSEC-2022-0093 (double-pubkey oracle) affects < 2.0 — long past. |
| **curve25519-dalek** | 4.1.3 | Latest stable + **patched**: RUSTSEC-2024-0344 (Scalar timing) fixed exactly at 4.1.3. Do not move to 5.0 (prerelease, breaking, no security benefit). |
| **x25519-dalek** | 2.0.1 | Latest stable; no advisory ever filed. |
| **aes-gcm** | 0.10.3 | Already the patched max stable (RUSTSEC-2023-0096 fixed at 0.10.3). 0.11 is RC only. |
| **aes** | 0.8.4 | No advisory; 0.9 only worth taking alongside an aes-gcm 0.11 bump. |
| **argon2** | 0.5.3 | Latest stable (0.6 RC only); no advisory; RustCrypto uses constant-time compare. |
| **sha2 / hkdf** | 0.10.9 / 0.12.4 | Successors (0.11 / 0.13) need a coordinated `digest 0.11` migration with no security payoff. |
| **image** | 0.25.10 | Already current. Keep tracking 0.25.x patches — decoder panics on malformed images are a DoS surface for untrusted message images. |
| **zip** | 2.4.2 | CVE-2025-29787 (symlink zip-slip) was patched at 2.3.0 — we're past it. 7.x adds defense-in-depth path canonicalization; optional if our restore path extracts attacker-supplied `.hollow` archives. |
| **bip39 / bs58 / reqwest / tokio-tungstenite** | — | No active advisory; bumps are breaking or cosmetic with no security driver. |
| **flutter_secure_storage / local_auth** | 10.3.1 / 3.0.1 | Already latest; carry the relevant security improvements (RSA-OAEP + AES-GCM; structured exceptions). |
| **firebase_messaging / firebase_core** | 15.2.10 / 3.15.2 | Top of their allowed lines. **No security fix is stranded above the iOS-13 pins** (16.0 / 4.0). Pins confirmed correct — do not bump. |
| **super_clipboard / url_launcher / flutter_svg** | — | All current except flutter_svg (2.0.17 → 2.3.0, carries a parser buffer-access fix) which is **gated on Flutter ≥ 3.35 / Dart ≥ 3.9** — hold until SDK floor permits. |

---

## Standing tech-debt watch (not a bump — flag for the auditor)

- **reed-solomon-erasure 6.0.0** (vault erasure coding) is **de facto unmaintained** (repo title:
  "Looking for new owners/maintainers", no release since Sept 2022) with a C-SIMD `unsafe`/FFI
  surface. No proven vulnerability and nothing to bump *to*. Backlog item: evaluate migrating to
  the actively-maintained pure-Rust successor **`reed-solomon-simd`** (a code migration, not a
  version bump). Good thing to raise with the NLnet auditor.

---

## Deferred to NLnet (out of scope for this dependency sweep)

These are design / trust-model questions, not dependency versions, and are intentionally left for
the professional audit:

- **Key verification / MITM resistance UX** — the `verified_peers` mechanism + `get_olm_fingerprint()`
  exist; the open question is whether out-of-band fingerprint verification is surfaced strongly
  enough to be the default expectation. (MLS handles the group-membership equivalent.)
- **Relay social-graph residual** — the relay terminates TLS and therefore sees live, pseudonymous
  room membership + peer IDs + timing **in RAM** (never logged, lost on restart). Pseudonymous
  gibberish IDs, not phone numbers; compromise requires taking over the running process. Honestly
  stated in the whitepaper threat model; closing it fully would need a heavier architecture
  (onion routing / cover traffic).
- **Backup-password entropy** — `.hollow` backups use Argon2id + AES-256-GCM, but a weak
  user-chosen passphrase recreates the "256-bit → ~41-bit" collapse. A password-entropy nudge on
  export would close it.

---

*Sources cited during research: crates.io / pub.dev release pages, rustsec.org advisory + package
pages, github.com/rustsec/advisory-db, sqlite.org/cves.html, NVD (CVE-2025-7709 / CVE-2025-6965 /
CVE-2026-11822 / CVE-2025-29787), GitHub Security Advisories, and upstream CHANGELOGs for
vodozemac, openmls, rustls, and the dalek crates.*
