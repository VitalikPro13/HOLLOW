#!/usr/bin/env python3
"""Live probe of door-proof server rooms (design D1) on a 0.14 relay: the join lock
takes only links a device the relay's roster fold counts made (hollow-lock-dev1,
judged by the roster's server authority), a member proving the newest door sees the
room, an outsider sees nobody and is shown to nobody, public frames reach it, directs
reach it, and after a lock move a member that does not prove the new door drops out
when the grace ends. Throwaway identities only.

It WRITES relay state that outlives the run: a join lock for a random server id and
the throwaway owner's roster (RAM tables a relay restart keeps in its memfd snapshot,
bounded and evicted fairly). Run it against a canary or a test relay, never against a
production relay's own process.

Usage: door_probe.py <wss url> <auth domain> [connect host:port]
  e.g. door_probe.py wss://relay.anonlisten.com:8443/ws relay.anonlisten.com   (deploy canary)
       door_probe.py wss://hollowtest.duckdns.org/ws hollowtest.duckdns.org 192.168.18.13:443
"""
import asyncio
import base64
import hashlib
import hmac
import json
import os
import ssl
import sys
import time

import nacl.signing
import websockets
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives import serialization

if len(sys.argv) < 3:
    sys.exit(__doc__)
URL, DOMAIN = sys.argv[1], sys.argv[2]
CONNECT = sys.argv[3].rsplit(":", 1) if len(sys.argv) > 3 else None
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
GRACE_S = 60
results = []


def b58(data: bytes) -> str:
    n = int.from_bytes(data, "big")
    out = ""
    while n:
        n, r = divmod(n, 58)
        out = B58[r] + out
    pad = len(data) - len(data.lstrip(b"\0"))
    return "1" * pad + out


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64url(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class Ident:
    def __init__(self):
        self.sk = nacl.signing.SigningKey.generate()
        proto = bytes([0x08, 0x01, 0x12, 0x20]) + bytes(self.sk.verify_key)
        self.pub_b64 = base64.b64encode(proto).decode()
        self.peer = b58(bytes([0x00, 0x24]) + proto)

    def sign(self, msg: str) -> str:
        return base64.b64encode(self.sk.sign(msg.encode()).signature).decode()


class Door:
    def __init__(self):
        self.sk = X25519PrivateKey.generate()
        self.text = b64url(self.sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))


class Sock:
    def __init__(self, ident, ws, nonce, relay_key):
        self.ident, self.ws, self.nonce, self.relay_key = ident, ws, nonce, relay_key
        self.inbox = []

    def proof(self, room, door):
        shared = door.sk.exchange(X25519PublicKey.from_public_bytes(unb64url(self.relay_key)))
        msg = "\n".join(["hollow-door1", DOMAIN, self.nonce, self.ident.peer, room, door.text, self.relay_key])
        return b64url(hmac.new(shared, msg.encode(), hashlib.sha256).digest())

    async def join(self, room, door=None):
        j = {"type": "join", "room": room}
        if door:
            j["door_proof"] = self.proof(room, door)
        await self.ws.send(json.dumps(j))

    async def drain(self, secs):
        end = time.time() + secs
        while time.time() < end:
            try:
                m = await asyncio.wait_for(self.ws.recv(), timeout=max(0.05, end - time.time()))
            except asyncio.TimeoutError:
                break
            self.inbox.append(json.loads(m) if isinstance(m, str) else m)
        got, self.inbox = self.inbox, []
        return got


def check(label, ok):
    results.append((label, ok))
    print(("  ok   " if ok else "  FAIL ") + label, flush=True)


async def connect(ident):
    extra = {"host": CONNECT[0], "port": int(CONNECT[1]), "server_hostname": DOMAIN} if CONNECT else {}
    ws = await websockets.connect(URL, ssl=ssl.create_default_context(), max_size=None, **extra)
    await ws.send(json.dumps({"type": "auth_hello"}))
    ch = json.loads(await ws.recv())
    nonce = ch["nonce"]
    ts = int(time.time())
    msg = f"hollow-ws-auth2\n{DOMAIN}\n{nonce}\n{ident.peer}\n{ts}\nfull\n"
    await ws.send(json.dumps({"type": "auth", "v": 2, "peer_id": ident.peer, "public_key": ident.pub_b64,
                              "timestamp": ts, "nonce": nonce, "domain": DOMAIN, "signature": ident.sign(msg)}))
    r = json.loads(await ws.recv())
    assert r.get("type") == "auth_ok", r
    return Sock(ident, ws, nonce, ch.get("door_key", ""))


# -- Roster statements, byte for byte identity/roster.rs (as inbox_probe.py) --

def consent(m, d):
    return {"device": d.peer, "sig": d.sign(f"hollow-id1-join:{m.peer}:{d.peer}")}


def legacy(m, d):
    return {"device": d.peer, "sig_m": m.sign(f"hollow-id1-legacy:{m.peer}:{d.peer}")}


def roster(m, devices):
    """A roster whose server authority counts `devices`: each consents, the master admits it."""
    return {"master": m.peer, "r_pub": "", "recoveries": [], "phrase_admits": [], "vouches": [], "pendings": [],
            "removals": [], "consents": [consent(m, d) for d in devices], "legacy": [legacy(m, d) for d in devices]}


def link(server, n, door, change, signer, base=None, dev=None):
    """A lock link (join_lock.rs); `dev` = (device, its master) signs the 0.14 device proof."""
    head = f"hollow-lock1\n{server}\n{n}\n{door.text}\n{change.pub_b64}\n"
    payload = head + (f"base\n{base[0].pub_b64}\n{base[1]}" if base else "next")
    out = {"n": n, "door": door.text, "change": change.pub_b64, "sig": signer.sign(payload)}
    if base:
        out["owner"], out["nonce"] = base[0].pub_b64, base[1]
    if dev:
        device, master = dev
        proof = device.sign(f"hollow-lock-dev1\n{master.peer}\n{payload}")
        out["dev"] = {"device": device.pub_b64, "master": master.peer, "sig": proof}
    return out


def frame(op, room, payload, target=None):
    out = bytes([op]) + room.encode() + b"\0"
    if target:
        out += target.encode() + b"\0"
    return out + payload


def of(events, kind, room=None):
    return [e for e in events if isinstance(e, dict) and e.get("type") == kind and (room is None or e.get("room") == room)]


def binaries(events, op):
    return [e for e in events if isinstance(e, bytes) and e[:1] == bytes([op])]


async def main():
    owner, owner_device, change1, change2 = Ident(), Ident(), Ident(), Ident()
    nonce = os.urandom(16).hex()
    server = hashlib.sha256(f"hollow-server1:{owner.peer}:{nonce}".encode()).hexdigest()[:40]
    door1, door2 = Door(), Door()

    # m1 is the owner's device (a fresh install's device is never its master).
    m1, m2, x = await connect(owner_device), await connect(Ident()), await connect(Ident())
    check("the challenge carries the relay's door key", len(m1.relay_key) == 43)

    # The relay's verdict, None when it sent none: a refusal counts only as an actual
    # `put: false`, never silence, a timeout or a dropped socket.
    async def put(links):
        await m1.ws.send(json.dumps({"type": "lock_put", "server": server, "owner": "", "links": links}))
        got = [e for e in of(await m1.drain(1.5), "lock_chain") if e.get("server") == server and "put" in e]
        return got[0]["put"] if got else None

    inbox = f"inbox:{owner.peer}"
    await m1.ws.send(json.dumps({"type": "join", "room": inbox, "inbox_roster": roster(owner, [owner_device])}))
    shown = of(await m1.drain(1.0), "members", inbox)
    check("the relay folds the owner's roster", bool(shown) and owner_device.peer in shown[-1]["peers"])
    base = (owner, nonce)
    check("a master-only (0.13) first lock is refused",
          await put([link(server, 1, door1, change1, owner, base)]) is False)
    check("a first lock from a device the fold does not count is refused",
          await put([link(server, 1, door1, change1, owner, base, dev=(Ident(), owner))]) is False)
    check("the relay takes the server's first lock from the owner's counted device",
          await put([link(server, 1, door1, change1, owner, base, dev=(owner_device, owner))]) is True)

    await m1.join(server, door1)
    ev = await m1.drain(1.0)
    check("a member proving the door is told so", any(e.get("proved") is True for e in of(ev, "members", server)))
    await m2.join(server, door1)
    ev2, ev1 = await m2.drain(1.0), await m1.drain(0.5)
    members2 = of(ev2, "members", server)
    check("a second member sees the first", bool(members2) and m1.ident.peer in members2[-1]["peers"])
    check("and is announced to it", any(e.get("peer_id") == m2.ident.peer for e in of(ev1, "peer_joined", server)))

    await x.join(server)
    evx, ev1, ev2 = await x.drain(1.0), await m1.drain(0.3), await m2.drain(0.3)
    mx = of(evx, "members", server)
    check("an outsider sees itself alone", bool(mx) and mx[-1]["peers"] == [x.ident.peer] and mx[-1].get("proved") is False)
    check("and is announced to nobody", not of(ev1 + ev2, "peer_joined", server))
    bad = await connect(Ident())
    await bad.join(server, Door())
    evb = await bad.drain(1.0)
    check("a wrong door proves nothing", any(e.get("proved") is False for e in of(evb, "members", server)))

    await m1.ws.send(frame(0x03, server, b"members-only"))
    ev2, evx = await m2.drain(1.0), await x.drain(0.3)
    check("a member's broadcast reaches a member", any(b.endswith(b"members-only") for b in binaries(ev2, 0x05)))
    check("and not the outsider", not binaries(evx, 0x05))
    await m1.ws.send(frame(0x0A, server, b"public-post"))
    ev2, evx = await m2.drain(1.0), await x.drain(0.5)
    check("a public frame reaches the outsider as a broadcast", any(b.endswith(b"public-post") for b in binaries(evx, 0x05)))
    check("and the members", any(b.endswith(b"public-post") for b in binaries(ev2, 0x05)))
    evb = await bad.drain(0.3)
    check("another outsider got the member's public post too", any(b.endswith(b"public-post") for b in binaries(evb, 0x05)))
    await x.ws.send(frame(0x0A, server, b"outsider-public"))
    evb = await bad.drain(1.0)
    check("an outsider's public frame reaches no other outsider",
          not any(b.endswith(b"outsider-public") for b in binaries(evb, 0x05)))
    await x.ws.send(frame(0x03, server, b"join-ask"))
    ev1 = await m1.drain(1.0)
    check("the members hear an outsider's broadcast (a join ask)", any(b.endswith(b"join-ask") for b in binaries(ev1, 0x05)))
    await m1.ws.send(frame(0x04, server, b"answer", target=x.ident.peer))
    evx = await x.drain(1.0)
    check("a member's direct reaches the outsider", any(b.endswith(b"answer") for b in binaries(evx, 0x06)))
    await x.ws.send(json.dumps({"type": "discover_peers", "room": server}))
    d = of(await x.drain(1.0), "discovered_peers")
    check("discovery names nobody to the outsider", bool(d) and d[-1]["peers"] == [])
    await x.ws.send(json.dumps({"type": "check_peers", "peers": [m1.ident.peer, m2.ident.peer], "rooms": []}))
    s = of(await x.drain(1.0), "peer_status")
    check("check_peers says nothing of the members", bool(s) and s[-1]["online"] == [])

    check("a move with no device proof is refused", await put([link(server, 2, door2, change2, change1)]) is False)
    check("the lock moves", await put([link(server, 2, door2, change2, change1, dev=(owner_device, owner))]) is True)
    await m1.join(server, door2)
    ev1 = await m1.drain(1.0)
    check("a member proving the new door is told so", any(e.get("proved") is True for e in of(ev1, "members", server)))
    ev2 = await m2.drain(0.5)
    check("a member that has not yet keeps seeing during the grace", not of(ev2, "members", server))
    print(f"  ..   waiting out the {GRACE_S} s grace", flush=True)
    ev1, ev2 = await asyncio.gather(m1.drain(GRACE_S + 8), m2.drain(GRACE_S + 8))
    check("the others see it leave when the grace ends",
          any(e.get("peer_id") == m2.ident.peer for e in of(ev1, "peer_left", server)))
    hidden = of(ev2, "members", server)
    check("and it is told it sees nothing", bool(hidden) and hidden[-1]["peers"] == [m2.ident.peer]
          and hidden[-1].get("proved") is False)
    await m1.ws.send(frame(0x03, server, b"after-the-move"))
    ev2 = await m2.drain(1.0)
    check("it hears no broadcast any more", not binaries(ev2, 0x05))

    for s in (m1, m2, x, bad):
        await s.ws.close()
    failed = [l for l, ok in results if not ok]
    print(f"{len(results) - len(failed)}/{len(results)} passed", flush=True)
    sys.exit(1 if failed else 0)


asyncio.run(main())
