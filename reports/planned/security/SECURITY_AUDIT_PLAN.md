# Hollow security audit: the method and the program

Started 2026-09-26, session 1 (research, no code). This is the security
counterpart of the design language plan: research first, then a written
method, then rules that outlive the epic (a reference doc, a skill, guards).

**Where this work lives.** Findings, fixes and the threat model go on the
LOCAL branch `security/foreign-device-list` and are pushed only with the
release that fixes them. Tooling that reveals nothing (cargo-deny, secret
scanning, Dependabot) may land on `main`. Section 7 of this file lists leads
into possible holes, so this file itself belongs on the security branch.

---

## STATE OF PLAY

- **Session 1 (2026-09-26): research done.** Five reading tracks: published
  messenger audits, audit and threat-model methodology, standards (ASVS,
  MASVS, the MLS/SFrame/Olm/Signal specs), security tooling, and free external
  audit programs. The digest is section 2. The method we adopt is section 3.
- **Phase A done the same day** (`audit/claims.md`, `audit/threat_model.md`,
  `audit/accepted_risks.md`). Drawing the device-linking flow surfaced
  **HOL-SEC-002** (the relay can decrypt every device-link snapshot, master
  key included). The claims pass surfaced a design question, AR-02 (every
  device holds the master key, so a stolen usable device can revoke its
  owner's real ones).
- **Vitalik's answers (2026-09-26):** the relay's missing message rate limits
  are AR-01 (tried, broke sync; connection caps and fair share stay). OTF is
  too strict and NLnet Restack excludes AI projects, so the external audit
  waits on the pending NLnet application. The formal model waits until the
  device-list design is frozen.
- **Second round the same day:** claims approved (C-23 withdrawn), AR-03
  accepted, AR-02 answered by design ID-1 (section 8a: the recovery phrase
  as the root of authority), all of it merged into LOCAL `main` behind a
  pre-push hook. Target release: 0.12.
- **Session 2 (2026-09-26): phase B started.** Nine enumeration passes wrote
  the evidence (`audit/phase_b_evidence/`, ~275 rows, ~200 suspicions), grouped
  by root cause in `audit/candidate_findings.md`. Confirmed and FIXED in the
  working tree, each with a test that failed first: HOL-SEC-003 (relay opens an
  Olm session as any device), HOL-SEC-005 (stranger wipes identity via the link
  flow, one-click identity theft), HOL-SEC-006 (a foreign device list claims a
  friend's master id), HOL-SEC-007 (remote panic, shard temp path). Confirmed,
  not yet fixed: HOL-SEC-004 (message rows rewritten by id through sync
  batches, channel and DM).
- **Session 3 (2026-09-26):** finding files now name the reproducing test and
  never walk through the steps (template line "Reproduction"). HOL-SEC-004 FIXED
  (one row-ownership guard for every sync item, both channel transports merged
  into one ingest function, file cards bound to the signed `file_id`). Decision 2's
  sender half built (channel backfill only from a current member who can see the
  channel); its author half is candidate E4 (a provable membership record, High,
  built with E1; decision 2a). `hollow_push_decrypt` deleted.
- **Session 4 (2026-09-27):** the live and push variants of HOL-SEC-004 (B3..B8)
  confirmed and FIXED as **HOL-SEC-008**: the sync guard is now
  `change_may_touch_row` for every change to an existing row, live DM changes take
  their signer from the row, every live channel change must name its row's own
  channel (which also closes the mute bypass C6), reactions must land where they
  say, and the Olm channel arms run the same handlers as MLS. Class B is done
  except ordering and replay (B10, B11). Then C1/C2 confirmed and FIXED:
  **HOL-SEC-009** (a stranger with the server id posted into any channel through
  plaintext public frames; posting rules and the moderation trio now hold on every
  live transport and push through one gate) and **HOL-SEC-010** (an MLS envelope
  was never bound to the group that decrypted it). Also closed: C4, C5, C13, L5.
  Found on the way, not security: the 4,000-byte text clamp cuts composer-legal
  non-Latin messages (C11, decision for Vitalik).
- **Session 5 (2026-09-27):** C11 built (**HOL-SEC-011**): one 64 KiB message
  limit in Rust and Dart, every receive path drops a longer body whole inside
  signature verification, nothing clips any more, and the composer and edit
  fields stop at it. Class C closed except C14 (moves to class K):
  **HOL-SEC-018** (C7, decided and built: a message dated more than 10 minutes
  past our clock is refused everywhere, slow mode judges fresh posts by our own
  clock),
  **HOL-SEC-012** (the dead channel probes leaked per-author watermarks to anyone
  and stalled sync; deleted), **HOL-SEC-013** (an unparseable Olm payload was
  shown as an unsigned DM; L4), **HOL-SEC-014** (guests were served deleted
  text), **HOL-SEC-015** (typing and unread hints from anyone in the room),
  **HOL-SEC-016** (a member who cannot see a restricted voice channel took a
  seat). Class D confirmed row by row; the member-level halves of D1 and D7 fixed
  as **HOL-SEC-017** (a leaf seated under another device's name), the rest is the
  class D design. New candidates: J8, J9 (sync requests and hints in plaintext),
  N3 (profile fields clipped in bytes). Class E then confirmed row by row (all
  CONFIRMED, no code changed): E1/E2 snapshot and founding-op capture, E3/E5
  replay past the 1000-op window and arrival-order registers, E6/E7 non-member
  authors and bans skipped on `MemberAdded`, E8/E9 device-id authority, E10
  retention (decided 2c: app values only, Owner only), E11/E12 moderation and ownership edges, E13 a
  one-line quick win, E14 HLC, E15 founding replay. Commits `4727b176`,
  `e17a2dea`, local only.
- **Session 6 (2026-09-27):** the quick class E fixes (**HOL-SEC-019** Olm
  CRDT arms with no sender, plus a non-security bug: at the 1000-op cap new
  remote ops were never saved, shown or passed on; **HOL-SEC-020** op clock bound
  to its author; **HOL-SEC-021** retention from the Owner only, app values
  only). Class H closed: **HOL-SEC-022** (a friend or member replaced or
  emptied someone else's file: one header gate, finished files immutable,
  `FileChunk` deleted), **HOL-SEC-023** (streams owned by their opener),
  **HOL-SEC-024** (vault shards, manifests and deletes authorised, rebuilt files
  checked against their content id, a cache path that wrote outside its
  folder), **HOL-SEC-025** (restricted-channel files kept out of the vault),
  **HOL-SEC-026** (recovery pool), **HOL-SEC-027** (share manifest replay).
  Class I: **HOL-SEC-028** (pre-auth relay crash), **HOL-SEC-029** (destroy
  orders one slot per issuer), **HOL-SEC-030** (fair-share rings, guest limits),
  **HOL-SEC-031** (revocation marks survive a restart), all DEPLOYED to the
  official relay the same day (decision 4). Accepted: AR-05..AR-08 (H20, H21,
  I9, the report half of I12). The push half of I12 turned out to be visible
  (a fallback banner) and is open as K3.
- **Session 7 (2026-09-27):** the smaller classes closed, every row re-read,
  each fix with a test that fails on the old rule. **HOL-SEC-032** (a revoked
  device re-entered through the sibling proof, and every revocation was lost at
  restart: now recorded and warmed), **HOL-SEC-033** (a carried device list was
  taken as its master without the binding), **HOL-SEC-034** (a destroy notice
  replayed after the identity returned; any list counted as the return),
  **HOL-SEC-035** (push parity: blocks, key-change notices, mentions judged from
  our own decryption, fallback banners only for known senders, no join of a
  server we do not hold; also J4), **HOL-SEC-036** (a stranger befriended us with
  an accept or accepted its own request in our name; block gaps L2/L3),
  **HOL-SEC-037** (call signals bound by call id alone; a share re-pointed by any
  participant), **HOL-SEC-038** (profile avatar bytes vs signed hash, stale
  profiles counted as saved, byte limits under the character limits),
  **HOL-SEC-039** (edit and reaction replay), **HOL-SEC-040** (room presence
  alone opened a data channel, a gossip seat and our voice presence). L6 was
  built and reverted (honest same-second KeyRequests look like replays). Moved to
  the class A design: J5, J7, the unsigned profile fields of N1. Vitalik's
  decisions: M2, only friends and our own devices ring us (built into
  HOL-SEC-037); L6 accepted as AR-09. Open: the iOS notification filtering
  entitlement (K3 residual).
- **Session 8 (2026-09-27): design D, MLS leaf identity and group authority**
  (`audit/design_D_mls_authority.md`, rules in `node/mls_authority.rs`). A leaf
  is signed by its device key and carries the master's certificate, so every
  receiver proves who holds it from the leaf alone: **HOL-SEC-041** (Critical:
  the relay could seat itself in any group, a member could appear as anyone;
  closes D1, D6, D10 and the relay halves of D7 and HOL-SEC-017). Every commit
  and Welcome is staged and judged before it changes anything: **HOL-SEC-042**
  (commits evicting members or adding outsiders), **HOL-SEC-043** (a Welcome
  from anyone replaced a live group; KeyPackages on demand, D3, D5). No failure
  drops a group any more, forks are found by an epoch-authenticator digest in
  the probe and repaired: **HOL-SEC-044** (D4). **HOL-SEC-045** (voice signaling
  over MLS credited to the relay's sender, D9). A leaf repair is now one commit.
  Existing groups rebind in place. Vitalik's decisions: a Welcome from any
  member if we asked for it; re-key in place rather than re-form. D8 closed at
  the MLS layer, its `MemberAdded` half stays E7.
- **Session 9 (2026-09-27): design E, CRDT state authority**
  (`audit/design_E_crdt_authority.md`, the fold in `crdt/fold.rs`, anchors in
  `crdt/anchor.rs`). A server's state is now a pure function of the signed ops it
  holds, folded in HLC order with each op judged against the state before it, and
  built from an anchor a joiner can prove: **HOL-SEC-046** (High: a joiner took its
  state, owner included, from whoever answered; 0.12 servers get self-certifying
  ids, older ones an owner-signed checkpoint and an `owner=` invite pin),
  **HOL-SEC-047** (High: replay past the 1000-op window and arrival-order
  outcomes), **HOL-SEC-048** (High: backfill of posts by never-members; a
  membership record), **HOL-SEC-049** (Medium: `MemberAdded` past ban, private,
  cap, owner-verify and Twitch; every member re-checks), **HOL-SEC-050** (Medium:
  strangers and device keys authored ops), **HOL-SEC-051** (Medium: device-keyed
  registers folded onto the owner), **HOL-SEC-052** (Low: moderation edges,
  ownership). Vitalik's decisions: the owner is fixed; older servers keep joining
  on trust until their owner updates; invite links pin the owner; any member admits
  with the gates re-checked. Proposed accepted risks AR-10..AR-12 (residuals R1..R3).
- **Next:** the two remaining DESIGN sessions, each at xhigh with harness tests:
  class A with J8/J9 (plaintext control messages into Olm/MLS; also I4..I6, A17,
  J5, J7, the unsigned profile fields, a signed content hash for files, the variant
  left by HOL-SEC-022/023, signed epoch probes (S-20), meeting host pinning with the
  lobby frames (S-26, S-29..S-32), and from design E the plaintext join frames
  A2, A3, A5, A10), then ID-1 with HOL-SEC-002 (also I3, I8, F3, F6, the
  stolen-device leaf certificates of HOL-SEC-041, and AR-11's author time). The
  relay traffic measurement waits for phase G.

---

## 0. TL;DR

1. Professionals do not start by reading code. They start from **what must be
   impossible**: a scope pinned to a commit, attacker profiles, a data-flow
   diagram with trust boundaries, and threats derived per element. Code review
   then verifies those threats, one work package at a time.
2. Our earlier passes checked the code against **our own written invariants**.
   That catches drift from a rule, never a rule nobody wrote down. The remote
   wipe was exactly a rule nobody wrote down: "a device list may only speak for
   its own devices".
3. The MLS RFCs say it plainly: the protocol answers **who said this**; only
   the application answers **may that person say this about that object**.
   Every Hollow handler that accepts a signed or MLS-authenticated message owns
   an authorisation decision that no library makes for it.
4. The same class has broken Signal groups, WhatsApp groups, Matrix device
   lists, Keybase sigchains and Threema. It is the most common serious bug in
   E2EE messengers, not an unlucky one.
5. The tool that fits our bug history best is not fuzzing. It is a **hostile
   peer in the multi-node harness** that signs its own messages correctly and
   tries every message type against objects it does not own.
6. The core artifact is an **authorisation matrix**: every inbound message
   type, who is allowed to say it, about which object, and the exact line that
   enforces it. An empty or "signature verified" cell is a candidate finding.
7. After every confirmed finding: **variant analysis** (hunt its siblings)
   and a regression test that failed before the fix. Our September 3 audit
   found a device-list binding bug and fixed that one instance; the wipe path
   was its sibling.
8. External audit: request the NLnet/ROS audit the moment the pending grant
   lands. An outside audit of a codebase we already cleaned is worth far more.

---

## 1. Why our earlier passes missed it

The September 3 audit (`reports/shipped/security/SECURITY_AUDIT_2026_09.md`)
was honest work that found four Criticals. Its method is also the reason the
wipe survived it:

- **Reviewers were split by domain and checked code against our invariants.**
  No threat model came first, so no reviewer was ever asked "for the device
  list, who is allowed to name which device?". A reviewer can confirm an
  invariant holds; it cannot notice that one is missing.
- **Its finding #4 was a device-list binding bug** (a list bound to whatever
  device delivered it). We fixed that path. Nobody then asked where else a
  device list is trusted for something it has no authority over. That is
  variant analysis, and it is the step professionals never skip. Project Zero
  found that at least half of 2022's in-the-wild 0-days were variants of bugs
  that had already been patched incompletely.
- **Authority was assumed to come with authentication.** Libraries verify the
  signature. RFC 9420 section 3.2: "this does not necessarily imply that any
  member is actually allowed to evict other members; groups can enforce access
  control policies on top". RFC 9750: "MLS does not itself enforce any access
  control on group operations".
- **Library audits never covered our glue.** vodozemac's and OpenMLS's audits
  explicitly excluded the application layer. Every practical Matrix attack
  (2022) landed in that application layer. Threema's commercial audit (16
  person-days) found nothing above Medium; ETH Zurich then found seven attacks
  in the protocol glue.
- **"Launch N agents and see" is open-ended search.** Project Zero's Big Sleep
  work and Trail of Bits' 2026 write-up agree: AI helps most with grounded
  tasks (verify this row, hunt variants of this diff, build this tool), and
  least with open-ended "find bugs".

---

## 2. Research digest

### 2.1 How a professional engagement runs

| Engagement | Effort | What it teaches |
|---|---|---|
| Trail of Bits, SimpleX Chat (2022) | 5 person-days | Severity and Difficulty scored separately, plus a code-maturity scorecard |
| ROS, Galene via NLnet (2025) | 5 days | "Crystal-box" (full source), a Non-Findings list, retest as future work |
| Cure53, Briar (2017) | 13 days, 6 testers | Work packages, crypto and spec review alongside the app |
| NCC Group, Olm/Megolm (2016) | 15 person-days | Source review plus fuzzing of entry points; found unknown key-share |
| Cure53, Threema apps (2020) | 16 person-days | Nothing above Medium, then academics broke the protocol |
| Quarkslab, Session (2021) | 42 person-days | Five named attacker profiles, Frida on the running apps |
| NCC Group, Keybase (2018) | 45 person-days | A proxy playing the malicious server; the server could drop revocations |
| SRLabs, OpenMLS (2025-26) | 12 weeks, 4 people | STRIDE threat model first, stateful and differential fuzzing, empty MAC accepted |

What every one of them does:

1. **Pins the scope** to exact commits and writes down what is out of scope.
2. **Names the attackers first.** Quarkslab: stolen device, remote client,
   network, compromised server, other apps. Keybase review: malicious server,
   and a malicious client with its own keys, possibly colluding.
3. **Splits the work** into packages (Cure53 WP1..WPn) with a coverage note
   per package, including "areas examined that yielded no findings".
4. **Plays the malicious server.** NCC rewrote Keybase's server responses
   through a proxy; ETH wrote a fake Threema server. For us: the harness relay.
5. **Opens an issue for every suspicion immediately**, then confirms or
   discards it (Least Authority).
6. **Writes findings in one format**: ID, title, severity, status, location,
   description, exploit scenario, recommendation (short term fix, long term
   class kill).
7. **Retests every fix** and records the result per finding.

### 2.2 The recurring bug classes in E2EE messengers

Each with the question an auditor asks. [H] = maps directly onto Hollow.

1. **Authenticated but not authorised.** [H] Valid signature, wrong signer
   for the object. Signal groups (Rösler 2018: a former member re-adds
   themselves), Matrix (key shares accepted from any device), Keybase ("must
   perform full validation of sigchain data, even if it is properly signed"),
   our wipe. *For every signed inbound type: who may sign THIS about THIS
   subject, and on which line is that enforced before state changes?*
2. **Infrastructure controls membership or device lists.** [H] Matrix
   homeservers could add devices and room members; WhatsApp group membership
   is server-controlled; the GCHQ "ghost user" proposal depends on it. *If the
   relay is fully malicious, can it make my client encrypt to, or accept state
   from, a device no legitimate authority added?* Relay presence
   (`ws_room_peers`, `RoomMembers`) must never decide E2E membership.
3. **Split view.** [H] Different state shown to different clients (Matrix
   hid a rogue device from its owner only; Keybase polyglot chains). *Does
   anything detect two honest parties holding different versions?*
4. **Withheld or rolled-back revocation.** [H] Keybase's server could drop
   revocation links (High). WhatsApp's fix: device lists expire after 35 days
   so a withheld revocation cannot work forever. Threema: replaying old group
   updates rewinds a removal. *How long does a withheld revocation keep
   working?*
5. **Identifier or key-type confusion.** [H] Matrix let a device id equal a
   master key and got it cross-signed; Threema reused one construction across
   two protocols. WhatsApp's good pattern: distinct signature prefixes per
   signature type. *Does every signature cover a unique context tag plus the
   subject id?* Our MASTER vs DEVICE ids are exactly this surface.
6. **Channel confusion.** [H] A message whose safety depends on arriving
   over channel X is accepted over Y. Matrix accepted Olm-only key messages
   over Megolm, and verified senders at DISPLAY time, so "messages that are
   never displayed but silently affect the state of the client" were never
   verified. That sentence describes a wipe order. *For each state-changing
   message, which transports can deliver it (MLS, Olm, plaintext twin, relay
   topic), and is the check identical on every one?*
7. **Unknown key-share / identity misbinding.** [H] Olm UKS (NCC 2016);
   RFC 9420 section 5.3.1 requires the application, acting as Authentication
   Service, to validate every credential when it enters the group. Our leaf
   credential is a bare device id. *At which of the RFC's entry points (Add,
   Welcome, Update, Commit) do we check the device is in its master's current
   signed, unrevoked list?*
8. **Replay, reflection, reordering, deletion.** [H] Megolm replay, Threema
   reflection, OpenMLS mis-attribution after tree changes. *What stops a
   captured valid order being replayed after a restart, reinstall or link?*
9. **Downgrade and length checks.** [H] OpenMLS accepted an EMPTY MAC
   (compared `min(len)` bytes); vodozemac MAC truncation and a V2-to-V1
   downgrade. *Can a security field be removed, shortened or versioned down
   and still accepted?* Any `Option<sig>` or `#[serde(default)]` security
   field where "absent" means "legacy, accept".
10. **Unauthenticated metadata.** [H] Fields read by the handler but outside
    the signature or MAC (Threema's metadata box, Matrix's `sender` added by
    the homeserver). *List every field the handler reads and mark which ones
    are signed.*
11. **State and key lifecycle.** [H] vodozemac burned one-time keys before
    authenticating; OpenMLS state and storage not atomic; a duplicate GroupId
    overwrote a group. *Crash between any two steps: is persisted state still
    consistent and safe?* Attacker-chosen ids like `conf:{id}` and
    `{server}#{channel}` belong here.
12. **Device linking and cloning.** [H] Russian operators phished Signal
    users with link-device QR codes; Threema ID export allowed silent cloning.
    *Can a device be added without confirmation on an existing device, and is
    everyone told?*
13. **What a stranger can trigger or observe.** WhatsApp prekey draining
    (2025), silent delivery receipts as activity trackers (2025). *What can
    someone with no relationship to the victim cause or learn?*

### 2.3 Threat modelling, the way it is actually done

- **Shostack's four questions** (and the Threat Modeling Manifesto): What are
  we working on? What can go wrong? What are we going to do about it? Did we
  do a good enough job? Q3 has four answers: mitigate, eliminate, transfer,
  accept. Q4 means: the diagram matches what we built, the threats cover it,
  and every mitigation has a test.
- **Data-flow diagram** with five element types (external interactor,
  process, data store, data flow, trust boundary). Rule that matters most
  for us: everything across a trust boundary is an external interactor,
  because "the attacker is under no obligation to use your tools or respect
  your protocols". Every peer and the relay are across a boundary.
- **STRIDE per element**: flows and stores get Tampering, Information
  disclosure, Denial of service; processes get all six; interactors get
  Spoofing and Repudiation. The E in STRIDE (elevation of privilege) is the
  authorisation letter. The grid gives a **stopping rule**: done when every
  cell has been walked.
- **LINDDUN GO** (33 privacy threat cards) for metadata: Linking and Detecting
  are the relay and push questions.
- **Attack trees** for the handful of worst outcomes (silent wipe, reading
  another user's DMs, forging an owner op, a malicious update, deanonymising
  via relay or push).
- **Every threat becomes a testable sentence**: "An attacker at [position]
  can [threat] on [element] via [flow], violating [claim]." The mitigation is
  a requirement with a named test.

### 2.4 Finding authorisation bugs systematically

- **Access-control matrix** (Lampson 1971): subjects x objects x actions.
- **Confused deputy** (Hardy 1988): a privileged program spends its OWN
  authority on a target the caller chose. ASVS 8.3.3 turns it into a
  requirement: access is decided on the originating subject's permissions.
- **Designation and authority travel together** (Miller, Yee, Shapiro 2003).
  A wipe order that names a target and carries a valid signature, verified
  without checking the signer's authority over that target, separates them.
- **Autorize-style replay**: take every request a privileged user makes and
  replay it as each lower principal; mark Enforced or Bypassed. Our version:
  replay every accepted envelope re-signed by each other principal (stranger,
  non-member, member, admin, sibling device, revoked device, another user's
  master) and assert rejection with no state change and no event.

### 2.5 Variant analysis

Project Zero's root-cause template ends every bug with: areas for variant
analysis, variants found, ideas to kill the bug class, ideas to break the
exploit flow. GitHub Security Lab turns the pattern into a query (sources,
sinks, sanitizers) and iterates away false positives. Big Sleep seeded an AI
with a fix diff and its commit message; over 40% of its 0-days were variants.
Our method: every confirmed finding gets an RCA note, a search for its
siblings (grep, semgrep, and an agent seeded with the fix diff), and a
class-killing idea (a single choke point, a type that can only be built after
the check, a CI guard).

### 2.6 Standards, and the level we map against

| Standard | Level for Hollow | Why |
|---|---|---|
| OWASP MASVS v2 | MAS-L2 + MAS-P; MAS-R out of scope | Seized devices, duress and app lock put an untrusted OS and physical access in scope; obfuscation adds nothing to open-source E2EE |
| OWASP ASVS 5.0 | L2 for V1, V2, V4.4, V5, V8, V9, V11-V17; selected L3 crypto items | ASVS is web-first, so it is a borrowed checklist; V8 (authorisation) and V9 (self-contained tokens: device lists, destroy orders, credentials, manifest) are the core |
| RFC 9420 / 9750 (MLS) | Every implementer obligation, as a checklist | Credential validation at every entry point, uniform client-side policy, commit conflicts, Welcome timing, insider replay, exporter labels |
| RFC 9605 (SFrame) | Every obligation | Nonce uniqueness per key, no per-sender authentication (members can forge each other's frames), rekey on join/leave |
| Olm, X3DH, Double Ratchet, Sesame | Security considerations as a checklist | Signed key exchange, unknown key-share, skipped-key caps; Sesame is the multi-device reference |
| OpenSSF Scorecard, Best Practices badge | Scorecard 7+, badge Passing then Silver | Cheap, public, expected of a security-positioned project |
| SLSA / NIST SSDF | SLSA Build L1 today, L2 goal; SSDF as the process frame | The updater makes the build pipeline part of the trust base |

The relay's missing per-message rate limits deviate from ASVS 17.3.1 and
RFC 9420 section 16.8; recorded as accepted risk AR-01 with the reason (they
broke sync) and the protections that remain.

EU Cyber Resilience Act: since 11 September 2026 manufacturers must report
actively exploited vulnerabilities (24 h early warning, 72 h notification).
Whether the Shop makes Hollow a "manufacturer" is a legal question. A
24/72 h runbook is prudent either way.

### 2.7 Severity and the finding format

- **CVSS 4.0** measures severity, not risk, and fits design flaws in a P2P
  app badly (the "attacker" is often a legitimate member, the "system" is a
  peer's client). Use it only for published advisories.
- **For the audit itself: NCC-style Impact x Exploitability.** Critical =
  an immediate, easily accessible threat of total compromise. Exploitability
  High = the attacker can exploit it unilaterally without special
  permissions. A remote wipe by any identity is Critical.
- **Finding template** (NCC + Trail of Bits + Cure53 + Project Zero RCA):

```
ID:              HOL-SEC-###            Status: Open | Fixed | Accepted | Retest pending
Title:           what the attacker can do, as a sentence
Severity:        Critical/High/Medium/Low/Info  (Impact H/M/L, Exploitability H/M/L)
Category:        Access control | Authentication | Crypto | Data validation | Data exposure | DoS | Timing
Component:       file::handler, trust boundary crossed
Traces to:       claim C-##, threat T-##, authz row A-##
Attacker:        profile and position
Description:     what the code does vs what the requirement says
Reproduction:    <test name>: the narrow "must be refused" test that failed before the fix
Fix:             short term (this bug) and long term (kill the class)
Variants:        what was searched, where, how, variants found
Test:            name and harness (failed before the fix, passes after)
Retest:          date, commit, result
```

### 2.8 Tooling, ranked by bugs found per hour of setup

1. **Supply chain (about 2 h).** cargo-deny replaces cargo-audit (also bans
   `openssl-sys`/`native-tls`, enforcing our webpki-roots rule mechanically;
   vodozemac, matrix-rust-sdk and rustls all use it). osv-scanner covers
   `pubspec.lock` and the vendored C/C++ nothing scans today. Dependabot for
   pub and github-actions.
2. **Secrets and workflows (about 2 h).** gitleaks in CI and pre-commit with
   custom rules for mnemonics, `.hollow` passphrases, `keys.json`, webhook
   tokens; one full-history trufflehog scan; zizmor on the workflows.
3. **The hostile harness (1-2 days, then about 30 min per row).** An
   adversary mode on `MockRelay` (drop, delay, reorder, duplicate, replay,
   rewrite `from`, deliver to non-members; `inject`, `inject_direct`,
   `inject_topic` already exist) plus a hostile node that signs its own
   messages correctly. One test per authz row per wrong principal, named
   `authz_<row>_<principal>`. This is the tool that matches our bug history,
   and it runs in the existing nextest on Windows.
4. **Authorisation properties with proptest-state-machine (2-3 days).** On
   the pure cores (`admit_remote_op` and `apply_op`, device-list merge and
   revocation, `sanitize_incoming_support_creds`, `judge_own_order`), with
   transitions where signer and claimed author differ. Invariant: an object
   owned by B changes only through a transition validly signed by B or by a
   holder of the role the model allows. No nightly needed.
5. **Fuzzing (about 2 days, Linux or WSL).** cargo-fuzz with ASan first on
   code that parses attacker bytes in C or unsafe (libwebp via `webp_anim`,
   `unsafe-libopus` screen audio, symphonia, `.hollowpack` zip, link-preview
   HTML), then the serde envelopes and `parse_ops_tolerant`. ClusterFuzzLite
   in GitHub Actions for continuous runs. Copy the shape of vodozemac's and
   openmls's targets (one decode target per wire type) and libsignal's
   stateful `interaction.rs`.
6. **Relay fuzzing (1-2 days).** libFuzzer + ASan/UBSan on
   `snapshot_codec.h`, `validate.h`, `ip_limit_key`, `device_list.cpp`, and a
   pure binary-opcode dispatcher asserting the room-membership gate.
   uWebSockets itself is already on OSS-Fuzz.
7. **Static rules (1 day).** Semgrep rules per write-gate row ("a store write
   in a handler must sit after its gate"), knowing the free version is
   intraprocedural. CodeQL default setup for Rust (GA since October 2025) and
   C++. Dart is not supported by CodeQL.
8. **Lints (1 day plus cleanup).** Clippy `unwrap_used`, `indexing_slicing`,
   `arithmetic_side_effects` ratcheted on `node/`, `crypto/`, `identity/` (a
   panic in a receive handler is a remote DoS); `#![deny(unsafe_code)]`
   outside the named FFI modules; a nightly `cargo careful test` job.
9. **A small formal model (1-3 weeks, once the design is frozen).**
   Verifpal first, then Tamarin: master-signed device list with a revoked
   set, destroy order, a relay-controlling attacker. Lemmas: no device accepts
   a list not signed by its master; a revoked device is never re-admitted; no
   wipe without the master's order. Tamarin models of Signal's multi-device
   layer found clone attacks the ratchet proofs never saw.
10. **Later.** Miri and Kani on isolated helpers, cargo-vet on the crypto
    subset, an SBOM, minisign on release artifacts, MobSF and Frida before a
    mobile release, OSS-Fuzz once the user base justifies it.

### 2.9 External audit route

- **Decided 2026-09-26:** OTF Security Lab is too strict for us and NLnet
  Restack excludes AI projects, so the route is the pending NLnet application
  and its ROS audit. The notes below stay for reference.
- **NLnet / NGI Zero:** funded projects get a free Radically Open Security
  audit through the grantee portal (typically 5-10 days, crystal-box). If our
  application is funded, request it immediately and scope it to the crypto and
  identity core, the ingest gates and relay auth. NGI Zero Commons Fund calls
  have closed; the successor **Restack** (5k to 50k EUR, security audits
  included) has its first deadline on **3 November 2026**.
- **OTF Security Lab:** free audits for internet-freedom tools by vetted
  firms (ROS, 7ASecurity, Include Security, SRLabs and others); non-US
  projects qualify; Briar and Delta Chat got theirs this way. Its US funding
  is uncertain.
- **Not for us:** Sovereign Tech Agency excludes messaging apps; Alpha-Omega
  and OSTIF target critical infrastructure; huntr is AI/ML only; Mozilla MOSS
  is dormant. The GitHub Secure Open Source Fund (10k USD, a security course,
  no audit) is an option once adoption is visible.
- **What auditors expect first** (Trail of Bits' preparation guide): a threat
  model, protocol docs, a scope with commit hashes, clean builds and tests,
  zero warnings, and past findings fixed. That list is our close-out.
- **Disclosure hygiene:** GitHub private vulnerability reporting, CVE IDs
  requested through GitHub as CNA for our private advisories, `security.txt`
  (RFC 9116) on anonlisten.com and the relay domain, and a hall-of-fame
  acknowledgments page until after the first professional audit.
- **Upstream assurance we can cite:** vodozemac (Least Authority, 2022) and
  OpenMLS (SRLabs, 2026). The lockfile pins openmls 0.9.0 and vodozemac
  0.9.0, later than the SRLabs fixes (0.8.1). SRLabs left two items to the
  application (non-atomic state vs storage, unbounded allocation), so they
  are ours to check.

---

## 3. The method we adopt

**Principle: the policy is decided by us, the evidence is gathered with
help.** AI agents enumerate handlers, fill evidence columns with file:line,
hunt variants from a seed diff, and write harness tests. Deciding who SHOULD
be allowed to do what is a design decision, made by Vitalik and me, and never
delegated.

Artifacts, all under `reports/planned/security/audit/` on the security branch:

| Artifact | IDs | Content |
|---|---|---|
| `claims.md` | C-## | 20-30 one-line promises Hollow makes to users ("only my own master can wipe my devices", "the relay cannot read or forge messages", "a removed member cannot read new channel messages", "an update runs only if signed by the offline key") |
| `threat_model.md` | T-## | Attacker profiles, assets, the DFD (Mermaid) with trust boundaries and breakouts, STRIDE per element, LINDDUN GO for metadata, attack trees for the worst outcomes |
| `authz_matrix.md` | A-## | One row per inbound state-changing message type (section 3.1) |
| `requirements.md` | R-## | Every threat as a "Verify that..." requirement, or a pointer to the accepted-risk register |
| `findings/HOL-SEC-###.md` | HOL-SEC-### | One file per finding, section 2.7 template |
| `accepted_risks.md` | AR-## | What we accept, why, who owns it, when we look again |
| `coverage.md` | | Per work package: what was examined, including non-findings |

**Attacker profiles** (from tmp4.txt, sharpened by Quarkslab and the Keybase
review): hostile relay operator; network observer; stranger who knows an id;
malicious friend; malicious server member, admin or owner; a malicious client
with its own valid keys (the profile that found the wipe); a revoked sibling
device; a stolen, seized or compelled device; a malicious update or asset
host; a push provider (FCM, UnifiedPush distributor).

### 3.1 The authorisation matrix (the step that would have caught the wipe)

For every inbound message type (envelope variants, CRDT payloads, MLS
proposals and commits, relay opcodes, sync responses, and FFI entry points fed
by remote data), one row:

| Column | Question |
|---|---|
| Message / action | What arrives and what it changes |
| Target object | Which device, list, server, channel, role, message, file, order |
| Who can SIGN it | Anyone with a key, a member, a device, a master |
| Who is AUTHORISED | The policy: who may say this about THIS object |
| Binding check | The file:line that enforces signer -> authority -> target. Empty or "signature verified" = candidate finding |
| Transports | MLS, Olm, plaintext twin, relay topic, sync backfill; is the check identical on each? |
| Freshness | Replay, reorder, restart, reinstall, link: what stops an old valid copy? |
| Absent fields | What happens when a security field is missing or empty |
| Blast radius | Irreversible (wipe, delete, revoke) first |
| Test | `authz_<row>_<principal>` in the harness |

Priority order: wipes and destroy orders, revocation and device lists,
device-to-master binding, MLS admission and credentials, deletes, bans and
kicks, roles and ownership, key changes, file writes.

**CI keeps it alive:** once the matrix exists, a guard test asserts every
envelope variant and `CrdtPayload` variant has a row, so a new message type
cannot ship without its authorisation decision. The wiki
`security_write_gates.md` becomes the evidence column of this matrix instead
of a separate list.

---

## 4. The program

Mirrors tmp4.txt steps 2 to 5. Each phase is one to three sessions.

**A. Claims and the diagram (session 2).** `claims.md`; attacker profiles;
the context DFD and breakouts (identity and devices, DMs, servers CRDT+MLS,
media, relay, push, updater, files and asset rail, local storage). Vitalik
reviews the claims: they are the promises, so they are his.

**B. The authorisation matrix (sessions 3-4).** An agent enumerates every
row with file:line evidence; I verify every evidence cell; the policy column
is decided together. Output: the matrix, and a first list of empty cells.

**C. The hostile harness (session 5).** Adversary mode on `MockRelay`, a
hostile-node helper, and `authz_*` tests for the top priority rows. The
existing wipe fix's test `a_foreign_device_list_cannot_revoke_or_claim_other_identities_devices`
becomes the first row's test.

**D. Variant analysis of what we already know (session 6).** Full RCA of the
wipe and of the September 3 finding #4, as one class. Search: every
signature-verify site whose result flows into a state change, checked for an
ownership comparison between them. Agent seeded with commit `0bb09321`'s
diff. Class-kill idea to evaluate: a single `authorize(signer, action,
target)` choke point, or verified-order types that can only be constructed
after the ownership check.

**E. STRIDE, LINDDUN and the protocol checklists (sessions 7-8).** Walk the
DFD grid to its stopping rule; LINDDUN GO on relay and push; RFC 9420/9750,
RFC 9605, Olm/Sesame obligations as checklists; the 13 classes of section 2.2
asked of every breakout.

**F. Work packages (sessions 9+), one at a time, Cure53 style.** Each gets
its DFD breakout, its matrix rows and its requirements, never just our
invariants. Reviewer prompt shape: "for each row, show the line that enforces
the policy, or construct an exploit with Alice and Mallory". Only findings
reproduced by a test count; the finding file names the test, never the steps.

| WP | Area |
|---|---|
| WP1 | Identity, devices, linking, revocation, destroy, duress |
| WP2 | DMs: Olm key exchange and sessions, friend requests and accepts, blocklist |
| WP3 | Servers: CRDT op auth and `op_allowed`, roles, MLS groups and subgroups, conferences, pending joins |
| WP4 | Relay C++: opcode gates, rings and availability cache, snapshot, auth, kill list |
| WP5 | Updater, manifest signing, release pipeline, flatpak repo |
| WP6 | Push: FCM, UnifiedPush, iOS NSE, channel push |
| WP7 | Files, at-rest encryption, asset rail, `.hollowpack`, support credentials, link previews |
| WP8 | Local: SQLCipher, keystore, app lock, logs, deep links, clipboard, notifications |
| WP9 | Media: SFrame keys and nonces, forwarder lane, call signalling |

**Tooling track, in parallel.** Section 2.8 items 1-2 whenever convenient
(they may go on `main`); item 3 is phase C; items 4-8 alongside phase F.

**G. Close-out.** Every finding fixed and retested, or in the accepted-risk
register. Then, and only then, the relay traffic work (decided 2026-09-27):
measure genuine traffic first with the fleet and the app (per-connection peaks
of frames, room joins and distinct targets, anonymous counters only, the way
the 44k-connection baseline was measured), and only on those numbers decide a
circuit breaker for clearly inhuman behaviour (close the connection, never drop
single frames; short escalating IP cooldowns, never week-long bans that hit
shared carrier addresses). It revisits AR-01, AR-06 and AR-07. Also in G, only
after Vitalik confirms Apple approved it: the iOS push work behind the
Notification Service Extension filtering entitlement (requested 2026-09-27,
the K3 residual). Add `com.apple.developer.usernotifications.filtering` to the
extension's entitlements, regenerate its profile, and have the extension show
nothing (an empty `UNNotificationContent`) for a stranger's or blocked sender's
wake and for a fetch that leaves nothing to show, with `push_enrich` returning
the verdict. `WHITEPAPER.md` security claims re-checked against `claims.md`. A
report in the professional format (`SECURITY_AUDIT_2026_10.md` or whenever it
lands): executive summary, scope with commit, method, coverage and
non-findings, findings table, maturity scorecard. Release, merge, push,
advisories with CVEs. Then the external audit application with this whole
folder as the readiness pack.

---

## 5. Secure-coding rules, version 0

What the research says to write down now. After phase E these move into
`reports/reference/HOLLOW_SECURITY_RULES.md`, a repo-tracked `hollow-security`
skill loaded before touching any ingest path, and guard tests, the same
three-part shape as the design language.

1. **A signature proves who, never may.** Every handler that acts on a signed
   or MLS-authenticated message checks the signer's authority over the object
   the message names, on the receiving side, before any state change.
2. **Designation and authority travel together.** An order that names a
   target (device, member, server, file) is honoured only if the signer owns
   or administers THAT target.
3. **Only our own master speaks for us.** Nothing signed by another identity
   may revoke, wipe, rebind or relabel our devices or our master.
4. **Relay presence is never authority.** Room membership on the relay may
   route traffic; it never decides E2E membership, key distribution or who
   is allowed to act.
5. **Same check on every transport.** A message type accepted over MLS, Olm,
   a plaintext twin, a relay topic or a sync backfill passes the identical
   gate on each.
6. **Absent means reject** for every security field (signature, version,
   album binding, requested_at when it binds authority). No "legacy, accept"
   path without a written expiry.
7. **Every signature has its own context.** Each signed type carries a
   unique domain tag and its subject id, so no signature can verify as
   another type.
8. **Old valid messages must not work twice.** Every state-changing type
   states its freshness rule (version, counter, stamp, id dedup) and survives
   restart, reinstall and relink.
9. **Verify at receipt, not at display.** State-changing messages that are
   never shown are verified exactly like the ones that are.
10. **A new ingest path ships with its matrix row and its hostile test.**
    The test signs correctly as the wrong principal and must fail before the
    gate exists.
11. **Every fixed bug gets variant analysis** before it is called done.
12. **Irreversible actions (wipe, delete, revoke) get the strictest review**
    and, where possible, a confirmation on a device the user holds.

---

## 6. Exit criteria

The audit is done when:

- every DFD element has been walked through its STRIDE cells (the stopping
  rule), with LINDDUN GO done on relay and push;
- every matrix row has verified code evidence and an `authz_*` test for each
  wrong principal;
- every requirement traces to at least one test;
- every finding is fixed and retested, or in `accepted_risks.md` with an
  owner, a reason and a review date;
- every finding has a completed variant-analysis section;
- `coverage.md` lists what each work package examined, including
  non-findings;
- the tooling items 1-5 of section 2.8 run in CI.

After the audit the matrix is permanent: re-run phases A and B for any new
message type, principal or trust boundary, enforced by the guard.

---

## 7. Leads to check (not findings)

Raised by the research, none verified. Each goes into the right work package
as a suspicion to confirm or discard.

- **L-01 SFrame nonce uniqueness (WP9).** `frame_cryptor_service.dart` uses the
  FrameCryptor in shared-key mode, not the RFC 9605 KID/CTR scheme. Nonce
  uniqueness across senders depends on the IV construction in our patched
  libwebrtc (SSRC collisions, forwarder re-sends). `failureTolerance: -1`
  also worth a look. Record RFC 9605 section 7.2 (members can forge each
  other's frames) as an accepted limitation or add signatures.
- **L-02 vodozemac non-contributory DH (WP2).** Reported February 2026: the Olm
  3DH accepted all-zero public keys; Matrix's answer is that it is prevented
  only when every key input is signed by the identity key and verified before
  session creation. Confirm our 0.9.0 behaviour and that
  `REQUIRE_SIGNED_KEY_EXCHANGE` covers every input; consider vodozemac's
  strict-signatures feature.
- **L-03 MLS credential validation (WP3).** RFC 9420 section 5.3.1 at every
  entry point: Add, Welcome, Update and Commit leaves must bind the bare
  device id to a device in its master's current signed, unrevoked list.
- **L-04 Ed25519 strictness (WP1-3).** Where a signed blob is used as an id or
  dedup key, `verify_strict` rather than `verify`.
- **L-05 Withheld revocation (WP1).** Does a device list expire, or can a relay
  withhold a revocation forever (the WhatsApp 35-day answer)?
- **L-06 Destroy order replay (WP1).** The applied stamp is in-process and never
  persisted by design; confirm what stops a replay after restart.
- **L-07 App lock PIN (WP8).** A 4-6 digit PIN through Argon2id alone falls to an
  offline search; confirm the secret is wrapped by a hardware keystore with
  attempt limits.
- **L-08 OpenMLS items left to the application (WP3).** Non-atomic group state vs
  storage (does our `CryptoStore` actor make it worse?), unbounded
  allocation.
- **L-09 Relay rate limits (WP4).** Resolved as accepted risk AR-01; flood
  behaviour still gets measured in WP4.
- **L-10 Device linking (WP1).** Became finding HOL-SEC-002. Still open from
  this lead: the Signal QR-phishing pattern (is the confirm prompt enough to
  spot a stranger's request, and are contacts told about a new device?).
- **L-11 The master key on every device (WP1).** A stolen usable device can
  revoke its owner's real devices; see threat_model.md AT-2 and AR-02.
- **L-12 Loopback media server (WP8).** Can another local process, or a web
  page through the browser, read decrypted media from `atRestMediaUrl`?

---

## 8. Decisions

Taken 2026-09-26:

1. Relay rate limits: accepted risk AR-01 (they broke sync).
2. External audit: wait on the pending NLnet application (OTF too strict,
   Restack excludes AI projects).
3. Formal model: later, once the device-list design is frozen.

Taken 2026-09-26, second round:

4. `audit/claims.md` approved, every claim still to be verified; C-23
   withdrawn.
5. AR-02 is not accepted: design ID-1 below fixes it, target 0.12.
6. AR-03 accepted: nobody mainstream signs individual call frames. Lead L-01
   (nonce uniqueness, the outsider risk) must still be verified and fixed.
7. The security branch is merged into LOCAL `main`; everything stays local
   (a pre-push hook blocks `main`) until the 0.12 release ships the fixes.

---

Taken 2026-09-26, third round (phase B, see `audit/candidate_findings.md`):

8. Every state-changing plaintext message is secured (Olm/MLS where a session
   exists, device-signed otherwise), as a breaking change.
9. Backfill only from current members who can read the channel; former
   members' rows stay, never-member authors are refused. The last part needs a
   provable membership record (every signed join/leave op kept forever), candidate
   E4, built with E1; no accepted risk, no UI label in its place (2a, session 3).
10. Device-list entries get device co-signatures, designed inside ID-1.
11. Relay fixes deploy before the 0.12 client release, the pre-auth crash first.
12. The unused `hollow_push_decrypt` export is deleted.

## 8a. Identity authority design ID-1 (agreed 2026-09-26)

**Problem.** Every device holds the master key (WP 3.6), so the master key
cannot tell the owner from a thief. Signal breaks the tie with its server and
the phone number; we have no server. **The tiebreaker we have:** the recovery
phrase, which no device stores (`api/identity.rs`: "mnemonic is not stored").

**The model in one sentence:** every device is equal, there is no primary,
and the recovery phrase is the final word.

- **ID-1.1 Recovery key.** A second key derived from the phrase with its own
  label, never written to disk, alive only while the phrase is typed. The
  master key must not reveal it (check how the master derives from the seed).
  Published once, signed by the master, pinned first-seen by contacts. New
  identities publish it at creation; existing users confirm their phrase once,
  which also proves they still have it.
- **ID-1.2 Joining.** A device joins an identity only when (a) a current
  device vouches for it (linking already runs from a current device, so it
  co-signs), or (b) the phrase is typed on it, or (c) nobody objects for 7
  days while every current device is told and can refuse. This covers linking,
  `.hollow` imports and backup restores the same way: a stolen backup file
  alone can no longer add a device silently, and a user whose only device
  died can still come back (Signal's registration lock has the same 7-day
  shape).
- **ID-1.3 Leaving.** Removing a device locks it at once (it stops working,
  contacts stop sending to it at once) and wipes it after 3 days unless the
  phrase is typed on it. The owner's real devices survive a thief's removal;
  a thief's phone is locked the moment the owner removes it.
- **ID-1.4 Recovery.** "Recover my identity" with the phrase, from any device
  or a fresh install, signs a device list with the recovery key that contacts
  treat as final: master-signed lists cannot un-revoke or override it, and new
  devices then need a vouch from a device in it. The thief is cut off; the id,
  friends and servers stay.
- **ID-1.5 Remote destroy** requires the recovery key. Duress and wiping the
  device in hand stay instant and phrase-free.
- **ID-1.6 Import today.** `import_backup` already deletes `identity.device`,
  so every restore mints its own device id: two restores of one backup are
  two siblings, never two primaries. The hole is only that the file is a
  silent new device; ID-1.2 closes it.

**Open design questions** (settle before code; the formal model of section
2.8 item 9 is worth doing on exactly this): the derivation and the proof the
master key does not yield the recovery key; first-seen pinning for identities
that already exist; what "told and can refuse" means when every device is
offline for the whole 7 days; how old clients that ignore the new fields
behave during the rollout; how the vouch binds to HOL-SEC-002's new link
handshake (same epic, WP1); and the per-entry device co-signature that makes a
device list unable to name a device, or a master, that never consented
(decision 10, the real fix for HOL-SEC-006).

---

## 9. Sources

Published audits and attacks:
- NCC Group, Olm cryptographic review (2016): https://www.nccgroup.com/media/5bspr3ie/_ncc_group_olm_cryptogrpahic_review_2016_11_01-1.pdf
- Least Authority, vodozemac (2022): https://leastauthority.com/static/publications/LeastAuthority-Matrix_vodozemac_Final_Audit_Report.pdf
- Albrecht, Celi, Dowling, Jones, Practically-exploitable Cryptographic Vulnerabilities in Matrix (IEEE S&P 2023): https://nebuchadnezzar-megolm.github.io/
- Albrecht, Dowling, Jones, Device-Oriented Group Messaging: https://eprint.iacr.org/2023/1300
- Albrecht, Dowling, Jones, Formal Analysis of Multi-device Group Messaging in WhatsApp (Eurocrypt 2025): https://eprint.iacr.org/2025/794
- Paterson, Scarlata, Truong, Three Lessons From Threema (USENIX Security 2023): https://www.usenix.org/system/files/usenixsecurity23-paterson.pdf
- Rösler, Mainka, Schwenk, More is Less (EuroS&P 2018): https://eprint.iacr.org/2017/713.pdf
- NCC Group, Keybase protocol review (2019): https://keybase.io/docs-assets/blog/NCC_Group_Keybase_KB2018_Public_Report_2019-02-27_v1.3.pdf
- Cure53, Threema (2020): https://raw.githubusercontent.com/cure53/Publications/master/pentest-report_threema.pdf
- Cure53, Briar (2017): https://raw.githubusercontent.com/cure53/Publications/master/pentest-report_briar.pdf
- Quarkslab, Session (2021): https://blog.quarkslab.com/audit-of-session-secure-messaging-application.html
- Trail of Bits, SimpleX Chat (2022): https://raw.githubusercontent.com/trailofbits/publications/master/reviews/SimpleXChat.pdf
- SRLabs, OpenMLS assessment (2026): https://blog.openmls.tech/SRL-OpenMLS_security_assurance_assessment.pdf
- Radically Open Security, Galene (2025): https://galene.org/NGICore%20Galene%20penetration%20test%20report%202025%201.0.pdf
- Gegenhuber et al., Prekey Pogo (2025): https://arxiv.org/abs/2504.07323 and Careless Whisper: https://arxiv.org/pdf/2411.11194
- Google Threat Intelligence, Russia targeting Signal linked devices: https://cloud.google.com/blog/topics/threat-intelligence/russia-targeting-signal-messenger
- Soatok on vodozemac (2026): https://soatok.blog/2026/02/17/cryptographic-issues-in-matrixs-rust-library-vodozemac/ and Matrix's analysis: https://matrix.org/blog/2026/02/analysis-of-reported-issues-in-vodozemac/

Method:
- Threat Modeling Manifesto: https://www.threatmodelingmanifesto.org/
- Shostack, threat modeling resources: https://shostack.org/resources/threat-modeling
- OWASP Threat Modeling Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html
- Hernan et al., STRIDE (MSDN 2006): https://learn.microsoft.com/en-us/archive/msdn-magazine/2006/november/uncover-security-design-flaws-using-the-stride-approach
- LINDDUN: https://linddun.org/ and LINDDUN GO: https://linddun.org/go/
- Schneier, Attack Trees: https://www.schneier.com/academic/archives/1999/12/attack_trees.html
- Hardy, The Confused Deputy: https://dl.acm.org/doi/10.1145/54289.871709
- Miller, Yee, Shapiro, Capability Myths Demolished: https://papers.agoric.com/assets/pdf/papers/capability-myths-demolished.pdf
- OWASP Authorization Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html
- OWASP WSTG authorization testing: https://wstg.owasp.org/v4.2/4-Web_Application_Security_Testing/05-Authorization_Testing
- Autorize: https://github.com/PortSwigger/autorize
- NIST SP 800-115: https://csrc.nist.gov/pubs/sp/800/115/final
- Project Zero RCA template: https://googleprojectzero.github.io/0days-in-the-wild/0day-RCAs/template.html
- Project Zero on variants (2022): https://projectzero.google/2022/06/2022-0-day-in-wild-exploitationso-far.html
- Project Zero, Big Sleep: https://projectzero.google/2024/10/from-naptime-to-big-sleep.html
- GitHub Security Lab variant analysis example: https://securitylab.github.com/research/ghostscript-type-confusion/
- Trail of Bits, auditing in the age of AI (2026): https://blog.trailofbits.com/2026/09/18/auditing-in-the-age-of-good-enough-ai/
- Trail of Bits, preparing for an audit: https://blog.trailofbits.com/2018/04/06/how-to-prepare-for-a-security-audit/
- OWASP Risk Rating: https://community.owasp.org/OWASP_Risk_Rating_Methodology
- CVSS 4.0: https://www.first.org/cvss/v4.0/specification-document

Standards:
- OWASP ASVS 5.0: https://github.com/OWASP/ASVS/tree/master/5.0/en
- OWASP MASVS: https://mas.owasp.org/MASVS/ and MASWE: https://github.com/OWASP/maswe
- RFC 9420 (MLS): https://www.rfc-editor.org/rfc/rfc9420
- RFC 9750 (MLS architecture): https://www.rfc-editor.org/rfc/rfc9750
- RFC 9605 (SFrame): https://www.rfc-editor.org/rfc/rfc9605
- RFC 3552 (security considerations): https://www.rfc-editor.org/rfc/rfc3552
- RFC 9106 (Argon2): https://www.rfc-editor.org/rfc/rfc9106
- RFC 9116 (security.txt): https://www.rfc-editor.org/rfc/rfc9116
- Olm: https://gitlab.matrix.org/matrix-org/olm/-/raw/master/docs/olm.md
- Signal X3DH, Double Ratchet, Sesame: https://signal.org/docs/
- OpenMLS credential validation: https://book.openmls.tech/user_manual/credential_validation.html
- OpenSSF Scorecard checks: https://github.com/ossf/scorecard/blob/main/docs/checks.md
- OpenSSF Best Practices criteria: https://www.bestpractices.dev/en/criteria
- SLSA build track: https://slsa.dev/spec/v1.2/build-track-basics
- EU CRA reporting: https://digital-strategy.ec.europa.eu/en/policies/cra-reporting

Tooling:
- Trail of Bits Testing Handbook: https://appsec.guide/
- Rust Fuzz Book: https://rust-fuzz.github.io/book/
- ClusterFuzzLite: https://google.github.io/clusterfuzzlite/
- proptest state machines: https://proptest-rs.github.io/proptest/proptest/state-machine.html
- cargo-deny: https://embarkstudios.github.io/cargo-deny/
- osv-scanner: https://google.github.io/osv-scanner/
- Semgrep taint mode: https://docs.semgrep.dev/writing-rules/data-flow/taint-mode/overview
- CodeQL Rust GA: https://github.blog/changelog/2025-10-14-codeql-scanning-rust-and-c-c-without-builds-is-now-generally-available/
- Verifpal: https://verifpal.com/ and Tamarin Sesame analysis: https://eprint.iacr.org/2022/1710
- libsignal fuzz targets: https://github.com/signalapp/libsignal/tree/main/rust/protocol/fuzz/fuzz_targets

External audits:
- NLnet NGI0 services: https://nlnet.nl/NGI0/services/ and Restack: https://nlnet.nl/restack/
- OTF Security Lab: https://www.opentech.fund/labs/security-lab/
- GitHub private vulnerability reporting: https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository
- OpenSSF disclosure guide: https://github.com/ossf/oss-vulnerability-guide/blob/main/maintainer-guide.md
