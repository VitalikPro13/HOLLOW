# Hollow: Legal Research

*Last updated: Jun 21, 2026*

Research into age verification laws, illegal-content/CSAM, encryption regulations, and legal liability for encrypted messaging infrastructure providers. Covers the US, UK, and EU.

> **This is not legal advice.** It is research. A qualified attorney should validate jurisdiction-specific current status before any operational reliance.

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [United States](#united-states)
   - [KOSA (Kids Online Safety Act)](#kosa-kids-online-safety-act)
   - [State Age Verification Laws](#state-age-verification-laws)
   - [App Store Accountability Acts](#app-store-accountability-acts)
   - [Legal Classification of Hollow](#legal-classification-of-hollow-us)
3. [United Kingdom](#united-kingdom)
   - [Online Safety Act 2023](#online-safety-act-2023)
   - [Section 122: Client-Side Scanning](#section-122-client-side-scanning)
   - [Investigatory Powers Act (IPA)](#investigatory-powers-act-ipa)
   - [Enforcement to Date](#uk-enforcement-to-date)
4. [European Union](#european-union)
   - [Chat Control (CSAR)](#chat-control-csar)
   - [Digital Services Act (DSA)](#digital-services-act-dsa)
   - [GDPR for Zero-Data Services](#gdpr-for-zero-data-services)
   - [EU Stance on Encryption](#eu-stance-on-encryption)
   - [National Age Verification Efforts](#eu-national-age-verification-efforts)
5. [Key Legal Precedents](#key-legal-precedents)
   - [Windscribe VPN (Greece, 2025)](#windscribe-vpn-greece-2025)
   - [Signal Subpoenas (US, 2016-2025)](#signal-subpoenas-us-2016-2025)
   - [Podchasov v. Russia (ECHR, 2024)](#podchasov-v-russia-echr-2024)
   - [Bernstein v. DOJ (US, 1999)](#bernstein-v-doj-us-1999)
   - [Phil Zimmermann / PGP (1996)](#phil-zimmermann--pgp-1996)
   - [Lavabit (2013)](#lavabit-2013)
   - [Tornado Cash (2024-2025)](#tornado-cash-2024-2025)
   - [The Tor Project](#the-tor-project)
6. [How E2EE Peers Are Handling This](#how-e2ee-peers-are-handling-this)
7. [Illegal Content and CSAM Liability](#illegal-content-and-csam-liability)
   - [US: The Reporting Duty (§ 2258A)](#united-states-the-reporting-duty-18-usc--2258a)
   - [US: The Criminal CSAM Statutes (§ 2252 / § 2252A)](#united-states-the-criminal-csam-statutes--2252--2252a)
   - [US: Section 230 Does Not Change This](#united-states-section-230-does-not-change-this-and-doesnt-need-to)
   - [US: The EARN IT Act](#united-states-the-earn-it-act-forward-looking-threat)
   - [Client-Side Scanning: The Trap, Not the Solution](#client-side-scanning-the-trap-not-the-solution)
   - [UK: OSA §121/§122 (Dormant)](#united-kingdom-osa-121122-dormant)
   - [EU: The "Mere Conduit" Shield](#european-union-the-mere-conduit-shield)
   - [Precedent: Knowledge and Control, Not "Encryption"](#precedent-the-line-is-knowledge-and-control-not-encryption)
   - [No Capability ≠ Willful Blindness](#staying-on-the-safe-side-no-capability--willful-blindness)
8. [Hollow's Legal Position](#hollows-legal-position)
9. [Recommendations](#recommendations)
10. [Sources](#sources)

---

## Executive Summary

As of May 2026, **no end-to-end encrypted messaging app has been banned, fined, or forced to add backdoors in the US, UK, or EU.** Not Signal, not Session, not SimpleX, not Briar. The law is broadly favorable for encrypted, zero-knowledge infrastructure.

Hollow's architecture (E2EE with per-user Ed25519 keys, a RAM-only relay that cannot decrypt content, zero metadata storage, no accounts, no phone numbers) places it in the lightest regulatory tier under every existing legal framework.

Age verification laws target **social media platforms**: services with public user-generated content, algorithmic recommendation, and community forums. Encrypted private messaging apps have explicit carve-outs or are excluded by definition in every major law.

The strongest legal protections come from:
- **Podchasov v. Russia (ECHR, 2024):** Encryption backdoors violate fundamental human rights. Binding on 46 countries. [34]
- **Section 230 (US):** Conduit providers are not liable for transmitted content. [18]
- **EU E-Commerce Directive, Article 12:** "Mere conduit" providers are not liable for content they didn't initiate, select, or modify. [46]
- **Windscribe (2025):** RAM-only, no-logs infrastructure operator acquitted. [28][29]
- **Signal subpoenas:** "We designed it so we cannot comply" accepted by US courts. [31][32]

---

## United States

### KOSA (Kids Online Safety Act)

**Status: NOT law.** The Senate passed KOSA 91-3 in July 2024, but it died in the 118th Congress without a House vote. It was reintroduced in the 119th Congress (S.1748, May 2025) [1]. A House companion (KIDS Act, H.R.6484) advanced from subcommittee in March 2026 but gutted the Senate version's "duty of care" provision [2][3]. As of May 2026, it is not signed into law.

**What it would require (Senate version):**
- Platforms must provide minors with options to protect their information
- Duty of care to prevent and mitigate specific harms to minors
- FTC enforcement with rulemaking authority
- Threshold: 10M+ monthly active US users providing community forums for user-generated content [4]

**Critical: Direct messaging services are explicitly exempt** as long as they focus on private communication (not public posting) and are not a component of a broader platform [1][4]. A pure E2EE messaging app like Hollow falls within this exemption.

### State Age Verification Laws

Roughly half of US states have enacted some form of age verification law [5][6]. **All target "social media platforms,"** defined as services that:
- Allow users to create public profiles
- Publish user-generated content to an audience
- Use algorithmic recommendation/curation
- Provide community forums

Key states with active laws:

| State | Law | Target | Status |
|-------|-----|--------|--------|
| Louisiana | Act 440 | Adult content sites | Active (Jan 2024) |
| Texas | HB 1181 | Adult content sites | Upheld by SCOTUS (June 2025) [11] |
| Utah | SB 287 | Social media | Active (March 2024) |
| Florida | HB 3 | Social media | Active (Jan 2025) |
| Virginia | SB 854 | Social media | Active (July 2025) |
| California | SB 976 | Social media | Active, AV by Dec 2026 |
| Mississippi | HB 1126 | Social media | Active, SCOTUS refused to block [12] |
| Tennessee | HB 1891 | Social media | Active (2024) |
| Alabama | HB 235 | Social media | Active (2025) |

**No E2EE messaging app has been required to implement age verification in any US state.** Signal's terms require users to be 13+ (self-declared), with no additional verification mandated by any jurisdiction.

**The Nevada exception to watch:** Nevada's AG sought a court order to prohibit Meta from enabling E2EE in Facebook Messenger for users under 18. The court described E2EE as "an essential tool of child predators." The EFF and ACLU filed a brief in January 2026 arguing encryption is essential for children's safety [14]. This case is specific to Meta, a social media company adding E2EE on top, not to dedicated E2EE messaging apps.

### App Store Accountability Acts

A newer generation of laws that push age verification to app stores (Apple/Google), not app developers [7][8]:

| State | Law | Effective | Notes |
|-------|-----|-----------|-------|
| Utah | SB 142 | May 2026 | Active |
| Texas | SB 2420 | Jan 2026 | **Enjoined** on First Amendment grounds |
| Louisiana | Act 481 | July 2026 | No safe harbor for developers |
| Alabama | HB 161 | Feb 2026 | Active |
| California | AB 1043 (DAAA) | Jan 2027 | Pending [9][10] |

How they work: Apple and Google verify user age at the OS/app store level and provide an "age signal" to developers. The burden falls primarily on the stores. Apple has already begun implementing this in Utah, Louisiana, and Australia [13]. App developers don't need to build their own age verification.

### Legal Classification of Hollow (US)

US law uses several overlapping classifications:

1. **Interactive Computer Service (Section 230):** Broad enough to cover most online services. Provides liability immunity for third-party content. [18]

2. **Electronic Communications Service (ECPA):** Services that enable sending/receiving electronic communications. E2EE services that cannot access content have minimal disclosure obligations. [19]

3. **The three-tier hierarchy for age verification laws:**
   - **Social media platforms** (Instagram, TikTok, Discord): primary targets of all age verification laws
   - **Communications services** (Signal, Session, Hollow): generally exempt due to "direct messaging" carve-outs [1]
   - **Infrastructure providers** (ISPs, VPNs, relay servers): explicitly excluded from social media laws

**Hollow's relay is an infrastructure provider.** Hollow the app is a private communications service. Neither matches any "social media platform" definition in any existing state or federal law.

---

## United Kingdom

### Online Safety Act 2023

Received Royal Assent October 2023, phased in through 2024-2026 [20]. Regulates **"user-to-user services,"** meaning any internet service where user-generated content can be encountered by other users. This technically includes messaging apps.

**Age verification is required only for:**
- Services hosting pornographic content
- Services that do not prohibit "primary priority content" (suicide, self-harm promotion, etc.)
- Categorised services (Ofcom's Register, pushed back to July 2026 [25])

**Categorisation thresholds are high:**
- **Category 1** (most duties): 34M UK users + content recommender system, or 7M UK users + content resharing. Estimated 12-16 services only. [25][26]
- **Categories 2A/2B:** Lesser duties. Estimated 35-60 services total.

All regulated services must conduct illegal content risk assessments and have reporting mechanisms [21]. But **small, low-risk services** need only "basic but important measures" if risk assessment shows low risk.

**Messaging apps are technically in scope,** but the practical enforcement risk for a small E2EE app with zero user data is currently very low. SimpleX Chat, the closest comparable to Hollow (no user IDs, no metadata, UK-registered company), has received **zero enforcement actions or data requests** [47].

### Section 122: Client-Side Scanning

The most controversial provision. It empowers Ofcom to issue notices requiring services to scan private messages for CSAM/terrorism content, even on E2EE platforms (client-side scanning) [22][23].

**Status: DORMANT.** The UK government admitted no technology exists to do this without breaking encryption [24]. The clause remains in the law but:
- No "accredited technology" has been designated
- Ofcom has shown little appetite to activate it
- Signal and WhatsApp both threatened to leave the UK rather than comply [21]
- Neither has been asked to do anything, and both still operate in the UK
- Privacy advocates call it a "sword of Damocles": a dormant power that could theoretically be activated [22]

### Investigatory Powers Act (IPA)

Separate from the OSA. Allows the Home Office to issue secret **Technical Capability Notices (TCN)** demanding backdoor access to communications.

**The Apple case:**
- Late 2024: Home Office issued a TCN to Apple demanding backdoor access to iCloud data protected by Advanced Data Protection (ADP) [48]
- Apple withdrew ADP from UK users entirely (February 2025) rather than comply [49]
- Apple appealed to the Investigatory Powers Tribunal [50]
- Under US diplomatic pressure, the UK reportedly withdrew the demand [51]
- A separate challenge by Privacy International and Liberty continues

This is the scarier law, but it targets companies with infrastructure or presence in the UK. It has only been used against Apple so far.

### UK Enforcement to Date

All OSA fines issued as of May 2026 have targeted [26][27]:

| Target | Fine | Reason |
|--------|------|--------|
| AVS Group Ltd | 1M GBP | Adult websites without age verification |
| Kick | 800K GBP | Age assurance failures |
| 4chan | 20K GBP + 100/day | Failing to respond to Ofcom |
| Im.ge | 20K GBP | Failing to respond to Ofcom |
| Itai | 50K GBP | Age assurance failures |

**Zero fines against any encrypted messaging service.** Maximum penalty is 18M GBP or 10% of global revenue, but this has never been applied to messaging.

---

## European Union

### Chat Control (CSAR)

Proposed regulation to combat CSAM online. Would require messaging services, including E2EE, to scan messages [38].

**Status as of May 2026:**
- **Chat Control 1.0 (voluntary scanning derogation): DEAD.** European Parliament voted 311-228 to reject extending the ePrivacy derogation on March 26, 2026. It expired April 3, 2026 [39][40]. Platforms can no longer voluntarily scan messages in the EU.
- **Chat Control 2.0 (permanent CSAR): In trilogue negotiations.** Council reached a position in November 2025 (dropped mandatory E2EE scanning) [37]. Political trilogues are ongoing, targeted for a July 2026 deal [52].
- **Parliament vs. Council split:** Parliament excludes E2EE from scanning, rejects mandatory age verification, and demands judicial warrants. Council allows voluntary scanning and age verification [39][53].

**Current practical impact: NONE.** There is no legal requirement to scan messages in the EU. The voluntary basis expired. The permanent regulation is still under negotiation.

### Digital Services Act (DSA)

In force since February 2024. Creates a tiered regulatory framework [44][45]:

**Tier 1, Intermediary Services (lightest obligations):**
- **Mere conduit:** Transmits or provides access to a communication network. Examples: ISPs, VPNs, DNS, VoIP. Not liable for transmitted content if they didn't initiate, select, or modify it. **Hollow's relay fits here.** [46]
- **Caching:** Temporary storage for transmission efficiency.
- **Hosting:** Stores information at user request.

**Tier 2, Online Platforms (enhanced obligations):**
- Subset of hosting that stores AND disseminates information to the public.
- **Private messaging services are explicitly excluded:** "Interpersonal communication services, such as emails or private messaging services, fall outside the scope of the definition of online platforms as they are used for interpersonal communication between a finite number of persons determined by the sender." [44]

**Tier 3, Very Large Online Platforms (VLOPs, heaviest):**
- 45M+ monthly active EU users.
- Currently designated: Google, Meta, Amazon, Apple, TikTok, X, Wikipedia, Booking.com [43].
- WhatsApp is designated a VLOP only for its "Channels" feature; private messaging is excluded [43].

**Note on public channels:** If Hollow's public channels disseminate content to unlimited recipients, those specific features could partially fall under "online platform" scope. The private messaging portion remains excluded regardless.

### GDPR for Zero-Data Services

GDPR applies to "processing of personal data." If Hollow in fact processes no personal data [54][55]:
- **IP addresses are personal data under GDPR.** But if the relay never logs IPs (not even in access logs), this trigger is removed.
- **Transient RAM processing** (e.g., per-IP rate limiting held in memory only, never persisted) is a gray area. Many lawyers argue it technically counts, but enforcement against ephemeral non-logged processing is practically impossible.
- **Anonymized data** (truly anonymized beyond re-identification) is outside GDPR scope.
- A privacy policy stating "we collect nothing" is still recommended for transparency compliance even if no data is processed.
- **Data Protection Impact Assessment (DPIA):** Only required when processing creates "high risk," which a zero-data service wouldn't trigger.

### EU Stance on Encryption

Contradictory and actively contested:

**Pro-backdoor (ProtectEU, April 2025):**
- European Commission's "ProtectEU" Internal Security Strategy includes a roadmap for "lawful and effective access to data" [41][56]
- Technology Roadmap on encryption planned for 2026
- Europol to develop "next generation decryption capability" from 2030
- 89 tech industry signatories signed an open letter against this [42]

**Against backdoors (ECHR ruling + Parliament):**
- **Podchasov v. Russia (ECHR, Feb 2024):** Encryption backdoors violate Article 8 (right to private life). Binding on all 46 Council of Europe member states including all EU members plus the UK. [34][35]
- Parliament's CSAR mandate explicitly excludes E2EE from scanning [39].
- Council dropped mandatory E2EE scanning in its November 2025 compromise [37].

**Net assessment:** The Commission wants backdoors. The Parliament and the ECHR oppose them. No backdoor mandate has been enacted. The ECHR precedent currently protects E2EE.

### EU National Age Verification Efforts

No EU country has targeted E2EE messaging apps with age verification [57]:
- **France:** Age verification for social media planned by September 2026.
- **Spain:** Banning social media for under-16, mandatory age verification.
- **Germany:** Considering banning minors from social media, decision postponed to mid-2026.

All target social media platforms (Instagram, TikTok, Snapchat), not encrypted messaging.

The EU Age Verification Blueprint (published July 2025, "feature ready" April 2026) uses zero-knowledge proofs via the EU Digital Identity Wallet [58]. It is built for social media and adult content, not private communications.

---

## Key Legal Precedents

### Windscribe VPN (Greece, 2025)

**Facts:** In 2023, a Windscribe server in Finland was allegedly used to breach a Greek computer system. Greek authorities traced the IP to Windscribe infrastructure and filed criminal charges against CEO Yegor Sak personally for "illegal access to electronic data." [28]

**Ruling (April 11, 2025):** Athens Court dismissed all charges for lack of evidence. Windscribe's RAM-only servers and no-logs policy meant zero user data existed. [29][30]

**Confirmed again (February 2026):** Dutch authorities seized a Windscribe server and found only a stock Ubuntu install, nothing to extract. [29]

**Relevance to Hollow:** Strongest direct precedent for a zero-data infrastructure provider. A RAM-only relay with no logs cannot be compelled to produce data that doesn't exist. However, note that Sak endured a 2-year legal battle before acquittal; the risk is harassment, not liability.

### Signal Subpoenas (US, 2016-2025)

Signal provides exactly **two data points** in response to subpoenas: (1) date account was created, (2) date it last connected. No message content, no contacts, no groups, no profiles. [31]

Notable cases:
- **Central District of California (2016):** Grand jury subpoena. Two timestamps. No further action. [31]
- **Central District of California (2021):** Same result. [31]
- **District of Columbia (2021-2025):** Grand jury subpoena with gag order. ACLU fought the gag order. Response: two timestamps only. [31]

Published at [signal.org/bigbrother](https://signal.org/bigbrother/).

**Relevance to Hollow:** "We designed it so we cannot comply" is accepted by US courts. Hollow has even less data than Signal (no phone numbers, no account creation dates, no last-connection timestamps). [32][33]

### Podchasov v. Russia (ECHR, 2024)

**Ruling (February 13, 2024):** The European Court of Human Rights held that encryption backdoor mandates violate Article 8 (right to private life) of the European Convention on Human Rights. [34]

Key quotes:
- Breaking E2EE "would extend beyond targeting specific individuals, affecting all users inclusively"
- Backdoors "could facilitate indiscriminate surveillance practices"

**This is the first time an international court explicitly upheld the necessity of E2EE.** Binding on all 46 Council of Europe member states (all EU members plus the UK and others). [34][35]

### Bernstein v. DOJ (US, 1999)

**Ruling:** Judge Patel (1996 district court) ruled encryption source code is protected speech under the First Amendment. Ninth Circuit panel upheld 2-1 in May 1999. [59][60]

**Current status:** The Ninth Circuit's en banc opinion was **vacated by the Supreme Court in 2000 due to mootness** after Clinton relaxed export controls. It is **persuasive but not binding precedent**: courts can cite it but aren't required to follow it. No subsequent court has overturned the core principle that source code is expressive speech. [60][61]

### Phil Zimmermann / PGP (1996)

Zimmermann faced a three-year federal criminal investigation for releasing PGP encryption software. The DOJ dropped all charges in January 1996 without filing. The investigation collapsed under the absurdity of prosecuting free software, global availability of strong crypto, and political opposition to mandatory backdoors. [62]

**Relevance:** Publishing encryption software is legal. No developer has been prosecuted for releasing general-purpose encryption tools since.

### Lavabit (2013)

**Facts:** FBI obtained a pen register order targeting one user (Edward Snowden). They demanded Lavabit's **SSL/TLS private key**, which would decrypt ALL 410,000 users' communications. [63]

**What happened:**
1. Founder Ladar Levison provided the key as 11 pages of 4-point type (deliberate defiance)
2. Court held him in contempt ($5,000/day fine)
3. Levison shut down the entire service on August 8, 2013
4. Fourth Circuit upheld contempt on procedural grounds but **did not rule** on whether government can compel encryption key disclosure [64][65]

**Critical lesson for Hollow:** Lavabit's fatal flaw was a single SSL key that could decrypt all traffic. Hollow has no equivalent. Each user has their own Ed25519 keypair, and the relay has no decryption capability at all. No master key means no Lavabit problem.

### Tornado Cash (2024-2025)

The critical distinction between "writing code" and "operating a service":

- **Alexey Pertsev (Netherlands):** Convicted May 2024, 64 months. Released February 2025 pending appeal. Court found he was not merely writing code but operating infrastructure he knew was used for money laundering. [36]
- **Roman Storm (US):** Mixed verdict August 2025. Convicted of operating an unlicensed money transmitter. Jury deadlocked on money laundering/sanctions. [36]
- **Fifth Circuit (November 2024):** Ruled that immutable smart contracts ("lines of code without ownership") are not sanctionable property, protecting the code itself while allowing prosecution of operators. [66]

**Relevance to Hollow:** An open-source developer publishing encryption tools is in a fundamentally different position from operating a mixing service. The relay is a dumb pipe, not a custodial financial service. No court has held an OSS developer liable for how users use general-purpose encryption software.

### The Tor Project

**The Tor Project has never been prosecuted, fined, or held liable.** Running Tor relays is legal under US law. [67]

However:
- Relay operators face police scrutiny (German police raided Artikel 5 eV in August 2024) [68]
- One Austrian exit relay operator (2013) was convicted for underlying content, not for operating the relay
- No Tor Project developer has ever faced criminal charges for building the software

**Relevance to Hollow:** Privacy infrastructure development is legal. Hollow's relay is lower-risk than Tor exit relays because it's authenticated (Ed25519 signatures) and doesn't act as an open proxy.

---

## How E2EE Peers Are Handling This

| App | Architecture | Age Verification | Legal Challenges | Status |
|-----|-------------|-----------------|-----------------|--------|
| **Signal** | E2EE, phone number required, central servers | Self-declared 13+ only | Subpoenas (provides 2 timestamps) [31] | Operates globally |
| **Session** | E2EE, no phone/email, decentralized (Lokinet) | None | None found | Operates globally |
| **SimpleX** | E2EE, no user IDs at all, decentralized relays | None | UK-registered, zero data requests [47] | Operates globally |
| **Briar** | E2EE, peer-to-peer via Tor, no central servers | None | None found | Operates globally |
| **Element/Matrix** | E2EE optional, federated servers | None | None found | Operates globally |
| **Hollow** | E2EE, Ed25519 keys only, RAM-only relay | None needed | None | Pre-launch |

None of these have implemented age verification. None have been fined or banned. None have been forced to add backdoors.

---

## Illegal Content and CSAM Liability

Age verification is a *regulatory* question (who counts as a regulated platform). Illegal content, above all CSAM (child sexual abuse material) but also terrorism content, drug trafficking, and illegal marketplaces, is a *criminal liability* question, and it has a different and harsher legal structure. It does not ask "are you a platform?" It asks three narrower questions:

1. **Do you knowingly transmit, store, or facilitate it?**
2. **Do you have actual knowledge and fail to report?**
3. **Are you under a specific legal duty to detect it?**

The short answer for a service like Hollow is that **every operative criminal and reporting statute in the US, UK, and EU hinges on *knowledge* or *control* that an operator of a no-content, no-decryption relay cannot have.** A relay that routes only opaque ciphertext it cannot read is in the same legal posture as a telephone switch, an ISP carrying TLS traffic, or Signal: none of which scan, and none of which has been charged for content they could not see.

This section documents the law behind that conclusion, and, just as importantly, why the most-suggested "solution" (voluntary client-side CSAM scanning) would *destroy* this posture rather than strengthen it.

### United States: The Reporting Duty (18 U.S.C. § 2258A)

The central US statute is **18 U.S.C. § 2258A**, the law that requires providers to report CSAM to NCMEC's CyberTipline. Two features of it answer the question directly:

1. **The duty is triggered only by *actual knowledge*.** § 2258A(a) requires a provider to report only when it "obtains actual knowledge of any facts or circumstances" indicating an apparent violation [74]. A provider that handles only encrypted blobs it cannot decrypt never obtains that knowledge, and so never triggers the duty. (If a provider *does* somehow learn of CSAM, e.g. through a user abuse report it can act on, it must then report it. Hollow's relay has no content to act on; the report path is the AUP/abuse channel, see below.)

2. **There is NO affirmative duty to monitor, search, or scan.** § 2258A(f) ("Protection of Privacy") states that nothing in the section requires a provider to "monitor any user... monitor the content of any communication... or affirmatively search, screen, or scan for" facts or circumstances [74]. **Congress wrote the no-duty-to-scan rule directly into the statute.** You are not legally required to look.

The penalty in § 2258A(e) attaches only to a provider that **"knowingly and willfully fails to make a report"** it was required to make: first violation up to $600,000 (under 100M monthly active users) or $850,000 (100M+); subsequent violations higher [74]. A provider with no actual knowledge has no report to make and so cannot incur this penalty.

A major law firm's plain-language summary matches the statute exactly: "online service providers have no affirmative obligation to scan for CSAM, but if they choose to or otherwise learn of CSAM on their service, they must report it under federal law (18 U.S.C. § 2258A)." [75]

### United States: The Criminal CSAM Statutes (§ 2252 / § 2252A)

The underlying crimes are in **18 U.S.C. § 2252 and § 2252A**, and every operative subsection requires a **"knowing"** mental state:

- § 2252A(a)(1): **knowingly** mails, transports, or ships CSAM
- § 2252A(a)(2): **knowingly** receives or distributes CSAM
- § 2252A(a)(5): **knowingly** possesses, or knowingly accesses with intent to view, CSAM [76]

Knowledge of the actual content is therefore a required element of every offense. **A relay that transmits ciphertext it cannot decrypt cannot "knowingly" receive, distribute, or possess the content.** It has no knowledge of, and no possession of, the underlying material. This is the conduit/common-carrier posture: a phone company that carries a call in which a crime is discussed has not "knowingly" committed the crime. The relay is even further removed, since it cannot even perceive the content, encrypted or not.

### United States: Section 230 Does Not Change This (and Doesn't Need To)

Section 230's immunity does **not** extend to federal criminal law. § 230(e)(1) carves it out, so the government may still bring federal criminal CSAM prosecutions [77]. This is sometimes raised as a gotcha, but it changes nothing for a no-knowledge conduit: **the protection comes from the underlying statute's "knowing" mens rea, not from Section 230.** Courts have read the § 230(e)(1) carve-out to preserve federal criminal *prosecution* (not to open the door to civil suits premised on federal criminal law) [77]. A conduit with no knowledge is protected at the level of the crime's own elements, with or without Section 230.

### United States: The EARN IT Act (Forward-Looking Threat)

The one US development worth tracking is the **EARN IT Act** (Eliminating Abusive and Rampant Neglect of Interactive Technologies Act). It has been introduced three times (2020, 2022, and most recently as **S.1207 in April 2023**, by Sens. Graham and Blumenthal) and **has died in committee every time. It is not law as of mid-2026** [78][79].

Why it matters if it ever passes:

- It **strips Section 230 immunity** specifically for child-sexual-exploitation claims, enabling state criminal prosecutions and private plaintiff lawsuits against providers [78][80].
- It effectively **lowers the liability threshold** from the federal "knowing" standard toward state-law negligence/recklessness standards, by letting state laws reach providers [79]. Stanford's Riana Pfefferkorn described the mechanism as "opening the courthouse door and lowering the threshold to get through that door" [78].
- **Encryption-as-evidence problem.** A 2020 amendment says offering encryption cannot be an *independent* basis for liability, but critics (CDT, CyberScoop) note it still allows the *offering of E2EE* to be used as **evidence of negligence**. The practical effect, per CDT, is that an encrypted provider would face "lengthy and expensive litigation to prove they were not liable for content they could not have known about because of their encryption design" [79][78].

The risk EARN IT poses is therefore not a clean ban. It is **litigation cost and the reframing of encryption itself as suspect.** This is the same wedge as Chat Control and UK §122 (below): the danger is not a court order Hollow can't satisfy, but a legal climate that treats "we built it so we can't see content" as recklessness rather than principle. The defense remains the architecture itself plus the absence of any scanning capability to point to.

### Client-Side Scanning: The Trap, Not the Solution

The most common proposal, including from people who mean well, is to voluntarily add **client-side CSAM scanning**: hash-match each image on the device against a known-CSAM database (the Apple NeuralHash / Microsoft PhotoDNA model) before it is encrypted. **For a privacy tool this is the single most damaging thing you could build, and the legal reasons are as strong as the ethical ones.**

1. **It manufactures the capability you currently lack.** Today, "we cannot comply, we have no ability to see content" is a complete answer, the same answer Signal gives. The moment you ship scanning, you have *proven* the capability exists. Every future demand ("scan for this too," "expand the hash list," "report these matches") now has a mechanism to attach to, and the "we can't" defense is gone. You would be voluntarily building the exact pre-condition that EU Chat Control and UK §122 are trying to force.

2. **The hash databases are access-restricted, so an independent developer cannot legally obtain them.** The IWF Image Hash List and PhotoDNA hashes are distributed only to **vetted, licensed members** who pass IWF vetting checks; access is membership-gated and contractually controlled, with the lists served through NCMEC/IWF member channels [81]. A small independent project cannot lawfully hold them. So client-side scanning is not even an option Hollow *could* legitimately implement, and that very inaccessibility reinforces the "no capability to scan" position.

3. **It doesn't even work reliably, and Apple proved this publicly.** Apple announced on-device NeuralHash scanning of iCloud Photos in **August 2021** and **abandoned it entirely on December 7, 2022**, concluding child protection is achievable "without companies combing through personal data" [82]. Within days of the 2021 announcement, researchers reverse-engineered NeuralHash out of iOS and **produced a hash collision** (two different images with the same hash), demonstrating the false-positive/false-accusation surface that makes on-device matching a surveillance and framing risk, not a safety feature [83]. The most resourced company on earth tried this, got it wrong, and walked it back.

The principled position, and the legally strongest one, is the one Signal, Session, SimpleX, and Briar all take: **do not scan.** For a privacy tool, not scanning is not a loophole; it is the foundation that the entire legal and ethical case rests on.

### United Kingdom: OSA §121/§122 (Dormant)

The UK Online Safety Act 2023 imposes **CSEA (child sexual exploitation and abuse) and illegal-content duties** on user-to-user services, and **§121** ("Notices to deal with terrorism content or CSEA content") gives Ofcom a *conditional* power to require "accredited technology" to identify such content, including, under §121(2)(a)(iii), in **private** communications (the provision that implicates E2EE) [84]. This is the same power often referred to as the "§122 spy clause."

Crucially, it is a **conditional notice power, exercisable only where Ofcom considers it "necessary and proportionate"** (not an automatic scanning mandate), and **the statutory text says nothing about how private-communication scanning is to be achieved without breaking encryption** [84]. As documented in the UK section above, the power remains **dormant**: no "accredited technology" has been designated, the government conceded no technology exists to do this without breaking encryption, and Signal and WhatsApp both said they would leave the UK rather than comply. Hollow would face the same choice, but so far the clause has never been activated against anyone.

### European Union: The "Mere Conduit" Shield

The EU gives a transit-only encrypted relay two layers of direct protection:

- **e-Commerce Directive (2000/31/EC), Article 12, "Mere Conduit":** a provider that transmits information is **not liable** for that information, provided it (a) does not initiate the transmission, (b) does not select the receiver, and (c) does not select or modify the information [85]. A RAM-only relay routing opaque blobs satisfies all three conditions by design, since it cannot even *read* the content, let alone select or modify it. This protection is carried forward by the **DSA's "mere conduit" provisions** (Art. 4) for transit-only intermediaries.
- **e-Commerce Directive, Article 15(1), No General Monitoring:** Member States **may not impose** on conduit/caching/hosting providers any general obligation to monitor what they transmit, or to actively seek facts indicating illegal activity [85].

On the scanning mandate itself, the **CSA Regulation ("Chat Control")**, see the EU section above: the voluntary derogation expired April 2026, the permanent regulation remains in contested trilogue with Parliament excluding E2EE from any scanning, and no EU scanning mandate is in force.

### Precedent: The Line Is Knowledge and Control, Not "Encryption"

The real-world prosecutions that people point to all turned on **actual knowledge, operational control, and refusal to cooperate,** not on the mere fact of running an encrypted or privacy-preserving service.

- **Pavel Durov / Telegram (France, August 2024).** Durov was arrested on **24 August 2024** and indicted on **28 August 2024** on twelve counts including complicity in distributing child exploitation material, drug trafficking, money laundering, and fraud [86]. The charges rested on **platform negligence, "insufficient moderation," and refusal to cooperate with legal requests,** not on offering encryption. Critically, **Telegram is not end-to-end encrypted by default**: it has moderation capability and access to most content, which is exactly what gives it the *knowledge and control* (and therefore the exposure) that a no-knowledge conduit does not have. Telegram is the *opposite* of Hollow's posture, not a comparable.
- **Roman Storm / Tornado Cash (US, 2025).** Storm was convicted of operating an unlicensed money-transmitting business; the DOJ's theory was that he **"continued to provide this service with knowledge"** that it was moving criminal proceeds and was "personally aware of numerous instances" of criminal use [87]. Again: liability flowed from *knowing facilitation*, the precise opposite of a service that cannot know its content.

By contrast, **no operator of a default-E2EE, no-content-storage messaging service (Signal, Session, SimpleX, Briar) has been criminally charged or held liable for CSAM or other illegal content transmitted by its users.** The doctrinal line is clear:

| Posture | Example | Liable? |
|---------|---------|---------|
| **No technical capability to know** (cannot decrypt, stores nothing) | Signal, Hollow | The lawful conduit position |
| **Willful blindness** (deliberately structuring to avoid knowledge of *specific known* activity) | — | Risk zone |
| **Knowingly facilitating** (has knowledge/control, continues anyway) | Tornado Cash, Telegram | Charged |

### Staying on the Safe Side: No Capability ≠ Willful Blindness

The one thing to get right is the difference between **"no capability to know"** (lawful) and **"willful blindness"** (deliberately avoiding knowledge of specific activity you've been alerted to). A no-content relay is on the safe side *by architecture*: it isn't avoiding knowledge, it structurally cannot obtain it. The way to make that unambiguous, and to demonstrate good faith rather than evasion, is:

1. **A clear Acceptable Use Policy / Terms** explicitly prohibiting CSAM and illegal content. (Hollow's Terms of Use already do this; CSAM is named.)
2. **A reachable abuse/legal contact**, so the project is demonstrably *willing* to act on anything it can act on, rather than structured to dodge all contact. A no-content service that *still* offers an abuse channel is the gold standard: it answers the "willful blindness" question before it is asked.
3. **No mechanism that creates knowledge or capability.** The strength is the *absence* of capability. Don't add scanning, logging, accounts, or content access; protect the thing that makes the defense real.

(Doctrinally, the "AUP + abuse contact establishes good faith" framing is a reasonable inference from how the willful-blindness line is drawn in the precedents above rather than a single black-letter rule; it is the consistent practice of the lawful E2EE peers and the conservative posture.)

---

## Hollow's Legal Position

### Why Hollow Is in the Clear

1. **The relay is infrastructure, not a platform.** It transmits encrypted blobs it cannot read. It stores nothing to disk. It's the digital equivalent of a telephone switch or postal sorting facility. [46]

2. **No master key exists.** Unlike Lavabit [63], there is no single key that decrypts all traffic. Each user has their own Ed25519 keypair. The relay literally cannot comply with a decryption order.

3. **Zero metadata.** No accounts, no emails, no phone numbers, no IP logging, no connection timestamps. Less data than Signal, which at least has phone numbers and two timestamps [31].

4. **Explicit legal carve-outs protect private messaging.** KOSA exempts direct messaging services [1]. The DSA excludes interpersonal communication from "online platform" definitions [44]. State age verification laws target social media with algorithmic curation [5][6].

5. **Open source (AGPL-3.0) provides transparency.** Anyone can verify the relay stores nothing. This is stronger than any privacy policy claim.

6. **Strong precedent.** Windscribe (RAM-only, acquitted) [28][29], Signal (cannot comply, accepted by courts) [31], Podchasov (backdoors violate human rights) [34], Bernstein (encryption is speech) [59].

### Potential Risks

1. **UK's Section 122 activation.** If Ofcom ever designates "accredited technology" for E2EE scanning, they could theoretically issue a notice [22]. Signal and WhatsApp have said they'd leave the UK [21]. Hollow would face the same choice.

2. **UK Investigatory Powers Act TCN.** Secret notices can demand backdoor access [48]. So far only used against Apple. Would require Hollow to have some UK nexus (servers, company registration, significant UK user base).

3. **EU Chat Control 2.0.** If the final regulation includes E2EE scanning mandates (Parliament opposes [39], Council retreated [37]), it could affect EU operations. Still under negotiation.

4. **Legal harassment.** Even with perfect legal standing, a provider can be dragged through proceedings (Windscribe: 2 years before acquittal [28]). This is the realistic risk: not liability, but cost of defense.

5. **Public channels feature.** Content visible to unlimited recipients could partially fall under "online platform" definitions in the DSA [44]. The private messaging portion remains excluded.

6. **Future legislation.** The law could change. Maintaining zero-knowledge architecture is the best hedge.

### The "Dumb Pipe" Defense

Hollow's relay has protection under both US and EU law:

**US, Section 230:** "No provider or user of an interactive computer service shall be treated as the publisher or speaker of any information provided by another information content provider." [18] A relay transmitting encrypted blobs it cannot read is the textbook conduit.

**EU, E-Commerce Directive, Article 12 ("Mere Conduit"):** A service provider is not liable for transmitted information when it [46]:
1. Did not initiate the transmission
2. Did not select the receiver
3. Did not select or modify the information

Hollow's relay meets all three conditions by design. It cannot even inspect the information, let alone select or modify it.

---

## Recommendations

1. **Transparency report page on hollow.anonlisten.com.** "We have received 0 legal requests. Our relay architecture stores no user data." Signal does this [31]; it's cheap credibility and the single best response to skeptics.

2. **Keep the Terms of Use and Privacy Policy updated.** They should clearly state the relay stores nothing and content cannot be accessed by anyone other than the intended recipients.

3. **Maintain the zero-knowledge architecture.** The technical design is the strongest legal protection. Don't add logging, accounts, or metadata storage.

4. **Don't implement age verification proactively.** No comparable peer (Signal, Session, SimpleX) has. Doing so could increase legal obligations by implying acceptance of platform-level duties.

5. **Standard response template for legal requests:** "Hollow's relay is a transit-only service that does not store, log, or have the ability to decrypt any user communications. We have no data to provide. Please see our architecture documentation."

6. **Monitor legislative developments.** Key dates:
   - EU CSAR trilogue: targeted July 2026 [52]
   - UK Ofcom Categorisation Register: July 2026 [25]
   - California DAAA: January 2027 [10]
   - EU ProtectEU encryption roadmap: 2026 [56]

7. **If ever served with a legal request,** the Windscribe/Signal playbook applies: "We designed it so we cannot comply. Here is the architecture. Here is the source code. We have nothing to hand over."

---

## Sources

[1] S.1748 - 119th Congress KOSA Text. https://www.congress.gov/bill/119th-congress/senate-bill/1748/text

[2] House Republicans gut KOSA as they advance new child safety bill — Biometric Update, March 2026. https://www.biometricupdate.com/202603/house-republicans-gut-kosa-as-they-advance-new-child-safety-bill

[3] Kids online safety bills move forward from Senate, House panel — Roll Call, March 2026. https://rollcall.com/2026/03/06/kids-online-safety-bills-move-forward-from-senate-house-panel/

[4] What is KOSA? The Kids Online Safety Act Explained — LegalClarity. https://legalclarity.org/what-is-kosa-the-kids-online-safety-act-explained/

[5] Social media age verification laws in the United States — Wikipedia. https://en.wikipedia.org/wiki/Social_media_age_verification_laws_in_the_United_States

[6] US State Age Assurance Laws for Social Media — AVPA. https://avpassociation.com/us-state-age-assurance-laws-for-social-media/

[7] State App Store Accountability Acts Introduce New Obligations for App Developers — Wiley. https://www.wiley.law/alert-State-App-Store-Accountability-Acts-Introduce-New-Obligations-for-App-Developers

[8] New App Developer Compliance Requirements — Venable. https://www.venable.com/insights/publications/2025/12/new-app-developer-compliance-requirements

[9] California Enacts Digital Age Verification Law — Alston Privacy Blog. https://www.alstonprivacy.com/california-enacts-digital-age-verification-law/

[10] California Introduces New Age Verification Requirements for Software Applications — Hunton Privacy Blog. https://www.hunton.com/privacy-and-information-security-law/california-introduces-new-age-verification-requirements-for-software-applications

[11] SCOTUS Decision on Age Verification Tramples Free Speech — EFF. https://www.eff.org/pages/supreme-courts-decision-age-verification-tramples-free-speech-and-undermines-privacy

[12] Supreme Court Allows Mississippi to Require Age Verification on Social Media — Free Speech Center, Aug 2025. https://firstamendment.mtsu.edu/post/supreme-court-allows-miss-to-require-age-verification-on-social-media-for-now/

[13] Apple Introduces Age Verification for Apps in Utah, Louisiana, and Australia — Engadget. https://www.engadget.com/apps/apple-introduces-age-verification-for-apps-in-utah-louisiana-and-australia-080855449.html

[14] Reject Nevada's Attack on Encrypted Messaging, EFF Tells Court — EFF, January 2026. https://www.eff.org/press/releases/reject-nevadas-attack-encrypted-messaging-eff-tells-court

[15] The Year States Chose Surveillance Over Safety — EFF 2025 Year in Review. https://www.eff.org/deeplinks/2025/12/year-states-chose-surveillance-over-safety-2025-review

[16] Google Play Age Verification USA State Laws — QAwerk. https://qawerk.com/blog/google-play-age-verification-usa-state-laws/

[17] Content Neutrality for Kids: Intermediate Scrutiny for Social Media Age Verification Laws — Harvard Law Review. https://harvardlawreview.org/print/vol-139/content-neutrality-for-kids-intermediate-scrutiny-for-social-media-age-verification-laws/

[18] Section 230 of the Communications Decency Act — Wikipedia. https://en.wikipedia.org/wiki/Section_230

[19] CRS Report: Section 230 Overview (R46751). https://www.congress.gov/crs-product/R46751

[20] The UK's Online Safety Act Explained — Computer Weekly. https://www.computerweekly.com/feature/The-UKs-Online-Safety-Act-explained-what-you-need-to-know

[21] The Record — UK Passes Online Safety Bill. https://therecord.media/online-safety-bill-uk-end-to-end-encryption

[22] UK Spy Clause — Online Safety Bill Could Lead to Mass Surveillance — Amnesty International UK. https://www.amnesty.org.uk/press-releases/uk-spy-clause-online-safety-bill-could-lead-mass-surveillance

[23] UK Scraps Online Safety Bill Spy Clause 122 — Cybernews. https://cybernews.com/privacy/uk-online-safety-bill-spy-clause-122-big-tech/

[24] ITPro — State of End-to-End Encryption in the UK After the Online Safety Bill. https://www.itpro.com/security/privacy/explained-the-state-of-end-to-end-encryption-in-the-uk-now-the-online-safety-bill-saga-is-over

[25] Online Safety Act Categorisation Register Pushed Back to July 2026 — techUK. https://www.techuk.org/resource/online-safety-act-categorisation-register-pushed-back-to-july-2026-in-new-timeline.html

[26] Ofcom and the Online Safety Act in 2026 — Burges Salmon. https://www.burges-salmon.com/articles/102mi1g/ofcom-and-the-online-safety-act-in-2026/

[27] Ofcom Fines Online File-Sharing Service £20,000 — Ofcom. https://www.ofcom.org.uk/online-safety/illegal-and-harmful-content/ofcom-fines-online-file-sharing-service-20000

[28] Court Dismisses Criminal Charges Against Windscribe Executive, Affirms No-Log Policy — PR Newswire. https://www.prnewswire.com/news-releases/court-dismisses-criminal-charges-against-windscribe-executive-affirms-no-log-policy-302439924.html

[29] Case Dismissed: Windscribe Wins Landmark No-Log VPN Lawsuit in Greece — TechRadar. https://www.techradar.com/vpn/vpn-services/case-dismissed-windscribe-wins-landmark-no-log-vpn-lawsuit-in-greece

[30] Windscribe Acquitted on Charges of Not Collecting Users' Data — Schneier on Security. https://www.schneier.com/blog/archives/2025/04/windscribe-acquitted-on-charges-of-not-collecting-users-data.html

[31] Signal Big Brother Page — Government Requests. https://signal.org/bigbrother/

[32] Signal Privacy Is Not Merely a Buzzword — Criminal Legal News. https://www.criminallegalnews.org/news/2024/aug/1/signal-privacy-not-merely-buzzword/

[33] Signal Provides Only Two Timestamps in Response to Grand Jury Subpoena — SecurityWeek. https://www.securityweek.com/signal-provides-only-two-timestamps-response-grand-jury-subpoena/

[34] European Court of Human Rights Confirms: Undermining Encryption Violates Fundamental Rights — EFF. https://www.eff.org/deeplinks/2024/03/european-court-human-rights-confirms-undermining-encryption-violates-fundamental

[35] The European Court of Human Rights Concludes Encryption Backdoor Mandates Violate the Right to Private Life — CDT. https://cdt.org/insights/the-european-court-of-human-rights-concludes-encryption-backdoor-mandates-violate-the-right-to-private-life-of-all-users-online/

[36] The Tornado Cash Trials: Mixed Verdict, Implications for Developer Liability — Mayer Brown. https://www.mayerbrown.com/en/insights/publications/2025/08/the-tornado-cash-trials-mixed-verdict-implications-for-developer-liability

[37] Child Sexual Abuse: Council Reaches Position on Law Protecting Children from Online Abuse — EU Council, November 2025. https://www.consilium.europa.eu/en/press/press-releases/2025/11/26/child-sexual-abuse-council-reaches-position-on-law-protecting-children-from-online-abuse/

[38] Chat Control — Wikipedia. https://en.wikipedia.org/wiki/Chat_Control

[39] EU Parliament Blocks Mass-Scanning of Our Chats — EFF. https://www.eff.org/deeplinks/2026/04/eu-parliament-blocks-mass-scanning-our-chats-whats-next

[40] Chat Control Dies Tomorrow — State of Surveillance. https://stateofsurveillance.org/news/eu-chat-control-voluntary-scanning-expires-april-3-2026/

[41] EU Pushes for Backdoors in End-to-End Encryption — BankInfoSecurity. https://www.bankinfosecurity.com/eu-pushes-for-backdoors-in-end-to-end-encryption-a-27920

[42] Experts Deeply Concerned by the EU Plan to Weaken Encryption — TechRadar. https://www.techradar.com/computing/cyber-security/experts-deeply-concerned-by-the-eu-plan-to-weaken-encryption

[43] VLOPs and VLOSEs Designated Under the DSA — European Commission. https://digital-strategy.ec.europa.eu/en/policies/dsa-vlops

[44] DSA Decoded: The Art of Scoping — Which Intermediary Are You? — Freshfields. https://technologyquotient.freshfields.com/post/102jqey/dsa-decoded-2-the-art-of-scoping-which-intermediary-are-you

[45] Guide to the Digital Services Act for Online Intermediaries — Pinsent Masons. https://www.pinsentmasons.com/out-law/guides/guide-digital-services-act-for-online-intermediaries

[46] EU E-Commerce Directive 2000/31/EC, Article 12 — EUR-Lex. https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32000L0031

[47] SimpleX Chat Transparency Reports. https://simplex.chat/transparency/

[48] UK Encryption Legal Challenge Tracker 2026 — State of Surveillance. https://stateofsurveillance.org/articles/government/uk-encryption-legal-challenge-tracker-2026/

[49] Apple Support — Advanced Data Protection No Longer Available in the UK. https://support.apple.com/en-us/122234

[50] Apple's Appeal to the Investigatory Powers Tribunal — Computer Weekly. https://www.computerweekly.com/opinion/Apples-appeal-to-the-Investigatory-Powers-Tribunal-over-the-UKs-encryption-back-door-explained

[51] UK Government Drops Demand for Apple iCloud Backdoor After US Pressure — Panda Security. https://www.pandasecurity.com/en/mediacenter/ukgovernment-drops-demand-for-apple-icloud-backdoor-after-us-pressure/

[52] Chat Control 2.0 Trilogue Status — Factually. https://factually.co/fact-checks/technology/eu-chat-control-proposal-trilogue-status-january-2026-a9d422

[53] Chat Control Age Verification Criticism — Tuta. https://tuta.com/blog/chat-control-criticism

[54] GDPR When No Data Collection — Free Privacy Policy. https://www.freeprivacypolicy.com/blog/gdpr-no-data-collection/

[55] GDPR Exemptions — Usercentrics. https://usercentrics.com/knowledge-hub/gdpr-exemptions-2/

[56] Commission Presents Roadmap for Effective and Lawful Access to Data for Law Enforcement — European Commission. https://home-affairs.ec.europa.eu/news/commission-presents-roadmap-effective-and-lawful-access-data-law-enforcement-2025-06-24_en

[57] Should Kids Be on Social Media? Europe Moves Toward Age Limits — Euronews. https://www.euronews.com/my-europe/2026/04/20/should-kids-be-on-social-media-europe-moves-toward-age-limits

[58] EU Age Verification Blueprint — European Commission Digital Strategy. https://digital-strategy.ec.europa.eu/en/policies/eu-age-verification

[59] Bernstein v. United States Department of Justice — EFF. https://www.eff.org/cases/bernstein-v-us-dept-justice

[60] Bernstein v. United States — Wikipedia. https://en.wikipedia.org/wiki/Bernstein_v._United_States

[61] Bernstein v. Department of Justice — Columbia Global Freedom of Expression. https://globalfreedomofexpression.columbia.edu/cases/bernstein-v-department-of-justice/

[62] Phil Zimmermann — PGP Case Dropped. https://philzimmermann.com/EN/news/PRZ_case_dropped.html

[63] Lavabit — EFF Case Page. https://www.eff.org/cases/lavabit

[64] Fourth Circuit Upholds Lavabit Contempt Finding — Just Security. https://www.justsecurity.org/9417/fourth-circuit-upholds-contempt-lavabit-doesnt-decide-govt-access-encryption-keys/

[65] Fourth Circuit Affirms Lavabit Contempt Finding — Washington Post / Volokh Conspiracy. https://www.washingtonpost.com/news/volokh-conspiracy/wp/2014/04/16/fourth-circuit-affirms-lavabit-contempt-finding/

[66] Freedom of Speech and Tornado Cash — Cointelegraph. https://cointelegraph.com/news/freedom-of-speech-tornado-cash-court

[67] Tor Legal FAQ — Tor Project Community. https://community.torproject.org/relay/community-resources/eff-tor-legal-faq/

[68] Tor Exit Node Operator Raided in Germany — Cybernews. https://cybernews.com/privacy/tor-exit-node-operator-raided-germany/

[69] Defending Encryption in the US and Abroad: 2025 Year in Review — EFF. https://www.eff.org/deeplinks/2025/12/defending-encryption-us-and-abroad-2025-review

[70] Governments Continue Losing Efforts to Gain Backdoor Access to Secure Communications — Stanford CyberLaw. https://cyberlaw.stanford.edu/blog/2025/05/governments-continue-losing-efforts-to-gain-backdoor-access-to-secure-communications/

[71] The Online Safety Act Doesn't Protect Encryption, But Ofcom Can — Proton Blog. https://proton.me/blog/online-safety-act

[72] Online Safety Act Explained Q&A — Ofcom (PDF). https://www.ofcom.org.uk/siteassets/resources/documents/online-safety/information-for-industry/other/online-safety-act-explained-qa-web.pdf

[73] Questioning the Conventional Wisdom on Liability and Open Source Software — Lawfare. https://www.lawfaremedia.org/article/questioning-the-conventional-wisdom-on-liability-and-open-source-software

[74] 18 U.S.C. § 2258A — Reporting requirements of providers (full text, incl. (a) actual-knowledge trigger, (e) penalties, (f) Protection of Privacy / no duty to monitor or scan) — Cornell Legal Information Institute. https://www.law.cornell.edu/uscode/text/18/2258A

[75] Federal Legislation Seeks to Change Online Child Safety Reporting Obligations — Perkins Coie. https://perkinscoie.com/insights/update/federal-legislation-seeks-change-online-child-safety-reporting-obligations-and

[76] 18 U.S.C. § 2252A — Certain activities relating to material constituting or containing child pornography ("knowingly" mens rea in (a)(1)/(a)(2)/(a)(5)) — Cornell Legal Information Institute. https://www.law.cornell.edu/uscode/text/18/2252A

[77] CRS Report R46751 — Section 230 Overview (§ 230(e)(1) federal-criminal-law carve-out) — Congressional Research Service. https://www.congress.gov/crs-product/R46751

[78] EARN IT Act Returns, Still Threatening Encryption and Privacy — CyberScoop (quotes Riana Pfefferkorn, Stanford). https://cyberscoop.com/earn-it-stop-csam-encryption-privacy/

[79] The New EARN IT Act Still Threatens Encryption and Child Exploitation Prosecutions — Center for Democracy & Technology (CDT). https://cdt.org/insights/the-new-earn-it-act-still-threatens-encryption-and-child-exploitation-prosecutions/

[80] EARN IT Act — Wikipedia (introduction history 2020/2022/2023, died in committee, not law). https://en.wikipedia.org/wiki/EARN_IT_Act

[81] Image Hash List — Internet Watch Foundation (membership-gated, vetted access; PhotoDNA via Microsoft / NCMEC member channels). https://www.iwf.org.uk/our-technology/our-services/image-hash-list/

[82] Apple Abandons Its Controversial Plans to Detect Known CSAM in iCloud Photos — MacRumors, December 7, 2022. https://www.macrumors.com/2022/12/07/apple-abandons-icloud-csam-detection/

[83] Apple Explains How NeuralHash Collisions Don't Compromise Its CSAM System (researchers reverse-engineered NeuralHash and produced a hash collision) — MacRumors, August 18, 2021. https://www.macrumors.com/2021/08/18/apple-explains-neuralhash-collisions-not-csam-system/

[84] Online Safety Act 2023, Section 121 — Notices to deal with terrorism content or CSEA content (conditional Ofcom "accredited technology" power, incl. private communications) — legislation.gov.uk. https://www.legislation.gov.uk/ukpga/2023/50/section/121

[85] EU E-Commerce Directive 2000/31/EC, Article 12 ("Mere Conduit") and Article 15 (No General Obligation to Monitor) — EUR-Lex. https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32000L0031

[86] Arrest and Indictment of Pavel Durov (twelve counts, Aug 24/28 2024; complicity, insufficient moderation, refusal to cooperate) — Wikipedia. https://en.wikipedia.org/wiki/Arrest_and_indictment_of_Pavel_Durov

[87] Founder of Tornado Cash Crypto Mixing Service Convicted of Knowingly Transmitting Criminal Proceeds — U.S. Attorney's Office, SDNY (DOJ). https://www.justice.gov/usao-sdny/pr/founder-tornado-cash-crypto-mixing-service-convicted-knowingly-transmitting-criminal
