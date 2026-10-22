#!/usr/bin/env python3
"""Seed corpora for the relay fuzz targets, from the test vectors both languages pin.

    python3 make_seeds.py <out_dir>    writes <out_dir>/<target>/<n> files

fuzz_snapshot_codec's seeds come from gen_snapshot_seeds.cpp (build.sh runs it).
"""
import base64
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TEST = os.path.join(HERE, "..", "test")

PEER = "12D3KooWK99VoVxNE7XzyBwXEzW7xhK7Gpv85r9F3V3fyKSUKPH5"
PEER2 = "12D3KooWAaYVakMyznsMrUbM1TPKUnduj2tCfQiM6zujqQmepeqr"
PUBKEY = "CAESIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c"
NONCE = "0123456789abcdef" * 4
SID = "00112233445566778899aabbccddeeff"
SIG = base64.b64encode(bytes(range(64))).decode()
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def load(name):
    with open(os.path.join(TEST, name), encoding="utf-8") as f:
        return json.load(f)


def dumps(v):
    return json.dumps(v, separators=(",", ":")).encode()


def auth_frames():
    base = {"type": "auth", "peer_id": PEER, "public_key": PUBKEY, "timestamp": 1790000000, "signature": SIG}
    yield dumps({"type": "auth_hello"})
    yield dumps(base)  # the 0.11 v1 frame (no `v`), which never parses
    yield dumps(dict(base, v=2, nonce=NONCE, domain="relay.example.com"))
    yield dumps(dict(base, v=2, nonce=NONCE, domain="relay.example.com", guest=True))
    yield dumps(dict(base, v=2, nonce=NONCE, domain="relay.example.com", fetch=True, license_key="KEY-1234"))
    for case in load("session_vectors.json")["auth_v3"]:
        frame = dict(base, v=3, nonce=case["nonce"], domain=case["domain"], timestamp=case["timestamp"],
                     session=case["session"], in_h=case["in_h"])
        if case["mode"] != "full":
            frame[case["mode"]] = True
        yield dumps(frame)
    for case in load("session_vectors.json")["auth_v3_shape"]:
        frame = dict(base, v=3, nonce=NONCE, domain="relay.example.com", session=case["session"], in_h=0)
        if case["mode"] != "full":
            frame[case["mode"]] = True
        yield dumps(frame)


def binary_frames():
    rooms = ["inbox:" + PEER, "fwd:" + PEER2, "a3f9c2d1e8b7a6f5c4d3e2f1a0b9c8d7", "conf:abc123"]
    for room in rooms:
        r = room.encode()
        yield b"\x02" + r + b"\0" + PEER.encode() + b"\0" + b"chunk-bytes"
        yield b"\x03" + r + b"\0" + b"ciphertext"
        yield b"\x0a" + r + b"\0"
        yield b"\x04" + r + b"\0" + PEER.encode() + b"\0" + b"olm-ciphertext"
        yield b"\x08" + r + b"\0" + PEER2.encode() + b"\0"
        yield b"\x07" + r + b"\0" + b"3f2c9a8e-1b4d-4e6f-9a0b-1c2d3e4f5a6b\0" + b"mls-frame"
        yield b"\x09" + r + b"\0" + PEER.encode() + b"\0" + b"general\0" + b"\x01" + b"payload"
    for case in load("session_vectors.json")["counted"]:
        if "binary_hex" in case:
            yield bytes.fromhex(case["binary_hex"])


def ring_frames():
    room = "0123456789abcdef0123456789abcdef01234567"
    signed = {"type": "set_topic_buffer", "room": room, "owner": "", "channels": ["3f2c9a8e-1b4d", "~join"],
              "retention_secs": 86400, "clear": False, "v": 2, "ts": 1800000000000, "sig": SIG}
    yield dumps(signed)
    yield dumps(dict(signed, clear=True, channels=[]))
    yield dumps(dict(signed, room="a3f9c2d1e8b7a6f5c4d3e2f1a0b9c8d7", owner=PEER, channels=[PEER + ".general"]))
    yield dumps({"type": "set_topic_buffer", "room": room, "channels": ["general"]})


def b58_key(rng):
    return "".join(rng.choice(B58) for _ in range(48))


def b64_chars(rng, n, url):
    alphabet = B58 + ("-_" if url else "+/")
    return "".join(rng.choice(alphabet) for _ in range(n))


def lock_frames():
    rng = random.Random(7)
    pinned = load_pinned_chain()
    yield dumps([{"type": "lock_put", "server": "8ef8bc89d3891dca86ff72c6783e396351aed5ba", "owner": "",
                  "links": pinned}])
    for genesis in (True, False):
        nonce = "00112233445566778899aabbccddeeff00112233"
        owner_key = b58_key(rng)
        server = nonce if genesis else "a3f9c2d1e8b7a6f5c4d3e2f1a0b9c8d7"
        owner = "" if genesis else owner_key
        links = [{"n": 1, "door": b64_chars(rng, 43, True), "change": b64_chars(rng, 48, False),
                  "sig": b64_chars(rng, 86, False) + "==", "owner": owner_key, "nonce": nonce}]
        for n in range(2, 5):
            links.append({"n": n, "door": b64_chars(rng, 43, True), "change": b64_chars(rng, 48, False),
                          "sig": b64_chars(rng, 86, False) + "=="})
        put = {"type": "lock_put", "server": server, "owner": owner}
        yield dumps([dict(put, links=links[:2]), dict(put, links=links[2:]), dict(put, links=links[:1])])
        yield dumps([dict(put, links=links)])


def load_pinned_chain():
    src = open(os.path.join(TEST, "test_join_lock.cpp"), encoding="utf-8").read()
    start = src.index('R"([{"n":1')
    return json.loads(src[start + 3:src.index('])"', start) + 1])


def roster_shows(limit=60):
    for case in load("roster_vectors.json")["cases"][:limit]:
        yield dumps([{"inbox": case["master"], "device": case["device"], "roster": case["held"]},
                     {"inbox": case["master"], "device": case["device"], "roster": case["shown"]}])


def kill_inputs():
    for case in load("kill_vectors.json")["cases"]:
        order = json.loads(base64.b64decode(case["blob"]))
        # The fuzz target derives a key's peer id as the key itself (fuzz_support.h), so
        # the master's key must read as its id for an order to reach the proven branch.
        order["master_pubkey_b64"] = order["master_peer_id"]
        order = json.dumps(order, separators=(",", ":"))
        yield dumps({"held": case["held"], "order": order, "issued_at_ms": case["issued_at_ms"],
                     "targets": [case["target"]]})


def client_json_texts():
    for case in load("session_vectors.json")["counted"]:
        if "text" in case:
            yield case["text"].encode()
    yield from auth_frames()
    yield from ring_frames()
    for case in load("roster_vectors.json")["cases"][:8]:
        yield dumps({"type": "join", "room": "inbox:" + case["master"], "inbox_roster": case["shown"]})


def crypto_inputs():
    sep = b"\0"
    yield PEER.encode() + sep + SIG.encode() + sep + b"hollow-ws-auth:" + PEER.encode()
    yield PUBKEY.encode() + sep + SIG.encode() + sep + b"message"
    yield b"zo060cy2M-x7cMF4FKXHbs0CloUFDTRHRboFhw5YfVk" + sep + b"rAGyIJ6GNU-4UyN7XeD0-rE8f8v0M6YcAZNpYX_s8Qs" + sep
    yield b"2001:db8::1" + sep + b"::ffff:192.0.2.1" + sep + b"relay.example.com:443"


TARGETS = {
    "fuzz_auth_frame": auth_frames,
    "fuzz_binary_frame": binary_frames,
    "fuzz_client_json": client_json_texts,
    "fuzz_ring_auth": ring_frames,
    "fuzz_join_lock": lock_frames,
    "fuzz_roster": roster_shows,
    "fuzz_kill_order": kill_inputs,
    "fuzz_crypto_inputs": crypto_inputs,
}


def main():
    out = sys.argv[1]
    for target, seeds in TARGETS.items():
        d = os.path.join(out, target)
        os.makedirs(d, exist_ok=True)
        for i, seed in enumerate(seeds()):
            with open(os.path.join(d, "seed_%03d" % i), "wb") as f:
                f.write(seed)


if __name__ == "__main__":
    main()
