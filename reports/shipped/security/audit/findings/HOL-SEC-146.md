# HOL-SEC-146: Links someone else chose opened with any scheme, and a preview card showed a domain its sender picked

```
ID:          HOL-SEC-146                 Status: Fixed (2026-10-04, session 34)
Severity:    Medium (Impact M: on Windows the OS launcher opens file:, UNC paths and any registered protocol handler; a card can say one site and open another; Exploitability M: any peer who can post to us and a click, or whoever controls the website feeds)
Category:    Data validation
Component:   lib/src/core/services/untrusted_link.dart, link_preview_card.dart, system_status_banner.dart, news_post_dialog.dart, rust/hollow_core/src/api/network.rs
Boundary:    TB-2, TB-5, TB-8
Traces to:   phase E+F distribution C-DIST-01 (and the lead's preview-card variant)
Attacker:    P-04/P-05 peers, P-10 feed host
Found:       2026-10-04 (merged phase E+F pass, session 34)
```

## Description

Chat links, link cards (their url and shown domain are both sender-chosen), the status
banner, news links, game-card, shop and Twitch links went to
`launchUrl(externalApplication)` with no scheme check, and `hollow://` round-tripped through
the OS.

## Fix

One helper, `openUntrustedUrl`, for every URL our code did not build: https (http where real
links need it), `hollow://` handled in-app through `DeepLinkService`, everything else
refused; a card's domain is derived from its url and a non-web card has no tap target (the
FFI blanks such urls).

## Test

`untrusted_link_test.dart`, `link_preview_card_test.dart` "LinkPreviewCard links",
`a_card_url_and_domain_are_judged_on_the_way_to_dart`. Mutation Rust 23/23, Dart 13/13 with
HOL-SEC-147, -148, -151.
