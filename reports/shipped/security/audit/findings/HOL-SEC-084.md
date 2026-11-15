# HOL-SEC-084: A removed device still committed to MLS groups

```
ID:          HOL-SEC-084                 Status: Fixed on local main (2026-10-02), retest at
                                          release
Severity:    Low                         (Impact L: it could remove its own identity's other
                                          leaves until a coordinator swept it, a repair
                                          follows; Exploitability M: a removed device that
                                          still holds a leaf)
Category:    MLS / Authorization
Component:   rust/hollow_core/src/node/mls_authority.rs (commit_verdict)
Boundary:    TB-4 (server members)
Traces to:   C-03, C-19; HOL-SEC-042 (design D), HOL-SEC-077 (design ID-1)
Attacker:    a device its roster removed or never counted, still holding a leaf
Found:       2026-10-02 (phase B re-check, mls A-10)
```

## Description

`commit_verdict` refused adds of a revoked or disowned device, but never asked the same of
the committer. A removed device that still held a leaf was accepted as committer, and a
committer may always remove its own identity's other leaves, so it could evict the
owner's current devices from every group it was in until a coordinator swept its leaf.
A legacy leaf could also rebind as such a device.

## Fix

A commit from a revoked or disowned leaf is refused, and so is a rebind into one.

## Test

Unit `a_removed_disowned_or_bare_master_leaf_neither_commits_nor_is_added` (failed before
the fix); mutation pass 2/2.
