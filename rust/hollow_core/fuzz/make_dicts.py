#!/usr/bin/env python3
"""libFuzzer dictionaries for the JSON targets, from the wire types as they stand.

    python3 make_dicts.py <out_dir>    writes <out_dir>/<target>.dict

The variant names and field names of HavenMessage, MessageEnvelope and CrdtPayload
change with the code, so the nightly run writes these fresh from the source tree.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src")

JSON = ['"{"', '"}"', '"["', '"]"', '":"', '","', '"null"', '"true"', '"false"', '"0"', '"-1"',
        '"18446744073709551615"', '"9223372036854775807"', '"\\\\u0000"', '"\\\\"', '"1e999"']


def read(rel):
    with open(os.path.join(SRC, rel), encoding="utf-8") as f:
        return f.read()


def enum_body(src, name):
    m = re.search(r"pub(?:\(crate\))? enum " + name + r" \{", src)
    if not m:
        return ""
    depth, i = 0, m.end() - 1
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[m.end():i]
        i += 1
    return ""


def tokens(body, tag):
    out = set()
    renames = re.findall(r'#\[serde\(rename = "([^"]+)"\)\]\s*\n\s*([A-Z]\w*)', body)
    renamed = {v for _, v in renames}
    for r, _ in renames:
        out.add(f'"\\"{tag}\\":\\"{r}\\""')
    for v in re.findall(r"^    ([A-Z]\w*)\s*[{(,]", body, re.M):
        if v not in renamed:
            out.add(f'"\\"{tag}\\":\\"{v}\\""' if tag else f'"\\"{v}\\""')
    for f in re.findall(r"^\s+(?:pub )?([a-z_][a-z0-9_]*):", body, re.M):
        out.add(f'"\\"{f}\\""')
    return out


def write(out_dir, target, toks):
    with open(os.path.join(out_dir, target + ".dict"), "w", encoding="utf-8") as f:
        for t in sorted(toks) + JSON:
            f.write(t + "\n")


def main():
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    types = read("node/types.rs")
    ops = read("crdt/operations.rs")
    haven = tokens(enum_body(types, "HavenMessage"), "type")
    envelope = tokens(enum_body(types, "MessageEnvelope"), "t")
    crdt = tokens(enum_body(ops, "CrdtPayload"), "")
    crdt |= {'"\\"$0\\""', '"\\"$1\\""', '"\\"$2\\""', '"\\"$3\\""', '"\\"$4\\""', '"\\"$S\\""', '"\\"Owner\\""',
             '"\\"Admin\\""', '"\\"Moderator\\""', '"\\"Member\\""', '"\\"ask\\""', '"\\"at\\""'}
    write(out_dir, "haven_message", haven)
    write(out_dir, "message_envelope", envelope)
    write(out_dir, "crdt_fold", crdt)
    write(out_dir, "crdt_ops", crdt | {'"\\"server_id\\""', '"\\"hlc\\""', '"\\"physical_ms\\""', '"\\"counter\\""',
                                       '"\\"actor\\""', '"\\"author\\""', '"\\"payload\\""', '"\\"auth\\""', '"\\"sig\\""',
                                       '"\\"pk\\""', '"\\"dev\\""', '"\\"device\\""'})
    write(out_dir, "relay_frames", haven | {'"\\"room\\""', '"\\"peer_id\\""', '"\\"peers\\""', '"\\"members\\""',
                                            '"\\"kill_signal\\""', '"\\"lock_chain\\""', '"\\"links\\""',
                                            '"\\"auth_ok\\""', '"\\"auth_failed\\""', '"\\"hb_ack\\""',
                                            '"\\"resumed\\""', '"\\"reconnect\\""', '"\\"peer_joined\\""',
                                            '"\\"peer_left\\""', '"\\"blob\\""'})
    for t in ("roster", "kill_order", "join_lock", "profile_card", "push_wake", "crdt_digest", "link_preview"):
        write(out_dir, t, set())


if __name__ == "__main__":
    main()
