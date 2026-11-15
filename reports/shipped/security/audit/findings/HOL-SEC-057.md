# HOL-SEC-057: A full profile went to anyone who asked

```
ID:          HOL-SEC-057                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Low                         (Impact M: avatar, banner and showcase bytes to strangers, and
                                          an oracle for "does this device know that person"; Exploitability
                                          H: anyone who can reach a room we are in, such as our inbox)
Category:    Missing authorization
Component:   rust/hollow_core/src/node/social.rs :: profile_request_allowed;
             node/swarm.rs :: ProfileRequest, ProfileRequestFor arms
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-24; dm_identity inventory (ProfileRequest, ProfileRequestFor)
Attacker:    P-06 stranger
Found:       2026-09-27, design A inventories
```

## Description

`ProfileRequest` was answered with the full profile, blobs included, for any
sender. `ProfileRequestFor` relayed any cached third-party profile to any sender.

## Reproduction

`authz_a_full_profile_goes_only_to_someone_we_know` (node/test_harness.rs).

## Fix

A full profile goes only to our own devices, friends, members of a server we
share and people we asked to be friends. A relayed profile goes only to a member
who shares a server with its subject. The light presence announce to room peers
is decision A-D5.

## Test

The test fails with the old rule put back and passes with the fix.
