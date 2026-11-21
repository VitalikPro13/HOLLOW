#!/usr/bin/env python3
"""Network probes for deploy/address-follow.sh and the setup's DNS checks (HOL-SEC-214).

Standard library only, so it runs on any Debian or Ubuntu with python3.

  address-probe.py dns <name> <A|AAAA>    this machine's DNS servers, asked as DNS: never
                                          /etc/hosts, a synthesized record, a cache or a
                                          third party's resolver. Prints rcode=<n|fail> and
                                          then one address per line.
  address-probe.py turn-cred <env file>   (root) a TURN REST credential for five minutes,
                                          from the file's TURN_SECRET: user, then password.
  address-probe.py turn <address> [port]  an authenticated TURN Allocate there with
                                          TURN_USER and TURN_PASS from the environment;
                                          exit 0 only when the answer's MESSAGE-INTEGRITY
                                          verifies, so the far end holds the TURN secret.
"""
import base64
import hashlib
import hmac
import ipaddress
import os
import re
import secrets
import socket
import struct
import subprocess
import sys
import time

RESOLVED_SOCKET = "/run/systemd/resolve/io.systemd.Resolve"
STUBS = {"127.0.0.53", "127.0.0.54"}
TYPES = {"A": 1, "AAAA": 28}


def out(line):
    sys.stdout.write(line + "\n")


# ---------------------------------------------------------------- DNS

def resolved_query(name, qtype):
    """systemd-resolved over its own API, with its cache, /etc/hosts and synthesized
    records (the host's own name, 127.0.1.1 lines) all off."""
    try:
        r = subprocess.run(
            ["resolvectl", "query", "--legend=no", "--cache=no", "--synthesize=no", "--zone=no",
             "--protocol=dns", "-t", qtype, "--", name],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=9, check=False, env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError):
        out("rcode=fail")
        return
    if r.returncode != 0:
        out(resolved_failure(name, r.stderr.decode("ascii", "replace")))
        return
    out("rcode=0")
    for line in r.stdout.decode("ascii", "replace").splitlines()[:64]:
        f = line.split()
        if len(f) >= 4 and f[1] == "IN" and f[2] == qtype:
            out(f[3])


def resolved_failure(name, err):
    """resolvectl's verdict line for a failed query: a name that does not exist (rcode=3)
    and one without records of the type (rcode=0, nothing after it) are answers; anything
    else (SERVFAIL, a timeout, resolved itself failing) is no answer at all."""
    quoted = "name '" + re.escape(name.rstrip(".")) + r"\.?' "
    if re.search(quoted + "not found", err, re.I):
        return "rcode=3"
    if re.search(quoted + "does not have any rr of the requested type", err, re.I):
        return "rcode=0"
    return "rcode=fail"


def nameservers():
    def read(path):
        found = []
        try:
            with open(path, encoding="ascii", errors="replace") as fh:
                for line in fh.read(65536).splitlines():
                    f = line.split()
                    if len(f) >= 2 and f[0] == "nameserver":
                        found.append(f[1].split("%")[0])
        except OSError:
            pass
        return found
    servers = [s for s in read("/etc/resolv.conf") if s not in STUBS]
    if not servers:
        servers = [s for s in read("/run/systemd/resolve/resolv.conf") if s not in STUBS]
    good = []
    for s in servers:
        try:
            good.append(str(ipaddress.ip_address(s)))
        except ValueError:
            continue
    return good[:3]


def encode_name(name):
    labels = name.rstrip(".").split(".")
    b = b""
    for label in labels:
        raw = label.encode("ascii")
        if not 0 < len(raw) < 64:
            raise ValueError("bad label")
        b += bytes([len(raw)]) + raw
    return b + b"\x00"


def skip_name(msg, i):
    """The offset after a (possibly compressed) name at i."""
    for _ in range(128):
        if i >= len(msg):
            raise ValueError("short name")
        n = msg[i]
        if n == 0:
            return i + 1
        if n & 0xC0 == 0xC0:
            return i + 2
        i += 1 + n
    raise ValueError("name too long")


def ask_server(server, query, qid, qname, qtype):
    fam = socket.AF_INET6 if ":" in server else socket.AF_INET
    msg = None
    with socket.socket(fam, socket.SOCK_DGRAM) as s:
        s.settimeout(2.5)
        s.connect((server, 53))
        s.send(query)
        deadline = time.monotonic() + 2.5
        while time.monotonic() < deadline:
            data = s.recv(4096)
            if len(data) >= 12 and struct.unpack(">H", data[:2])[0] == qid:
                msg = data
                break
    if msg is not None and msg[2] & 0x02:
        # Truncated: the same question over TCP.
        with socket.create_connection((server, 53), timeout=3) as t:
            t.sendall(struct.pack(">H", len(query)) + query)
            buf = b""
            while len(buf) < 2 or len(buf) < 2 + struct.unpack(">H", buf[:2])[0]:
                chunk = t.recv(4096)
                if not chunk or len(buf) > 70000:
                    raise OSError("short TCP answer")
                buf += chunk
            msg = buf[2:2 + struct.unpack(">H", buf[:2])[0]]
    if msg is None:
        raise OSError("no answer")
    return parse_answer(msg, qid, qname, qtype)


def parse_answer(msg, qid, qname, qtype):
    qid_got, flags, qd, an = struct.unpack(">HHHH", msg[:8])
    if qid_got != qid or not flags & 0x8000 or qd != 1:
        raise ValueError("not our answer")
    i = 12
    end = skip_name(msg, i)
    # The question must come back as asked (case aside), or it answers something else.
    if msg[i:end].lower() != qname.lower() or msg[end:end + 4] != struct.pack(">HH", qtype, 1):
        raise ValueError("another question")
    i = end + 4
    rcode = flags & 0x000F
    addrs = []
    for _ in range(min(an, 64)):
        i = skip_name(msg, i)
        if i + 10 > len(msg):
            raise ValueError("short record")
        rtype, rclass, _ttl, rdlen = struct.unpack(">HHIH", msg[i:i + 10])
        i += 10
        rdata = msg[i:i + rdlen]
        if len(rdata) != rdlen:
            raise ValueError("short data")
        i += rdlen
        if rtype == qtype and rclass == 1:
            if qtype == 1 and rdlen == 4:
                addrs.append(socket.inet_ntop(socket.AF_INET, rdata))
            elif qtype == 28 and rdlen == 16:
                addrs.append(socket.inet_ntop(socket.AF_INET6, rdata))
    return rcode, addrs


def dns(name, qtype_name):
    qtype = TYPES[qtype_name]
    if os.path.exists(RESOLVED_SOCKET):
        resolved_query(name, qtype_name)
        return 0
    try:
        qname = encode_name(name)
    except (ValueError, UnicodeEncodeError):
        out("rcode=fail")
        return 0
    for server in nameservers():
        qid = secrets.randbits(16)
        query = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + qname + struct.pack(">HH", qtype, 1)
        try:
            rcode, addrs = ask_server(server, query, qid, qname, qtype)
        except (OSError, ValueError, struct.error):
            continue
        out("rcode=%d" % rcode)
        for a in addrs:
            out(a)
        return 0
    out("rcode=fail")
    return 0


# ---------------------------------------------------------------- TURN

MAGIC = 0x2112A442
ALLOCATE, REFRESH = 0x0003, 0x0004
A_USERNAME, A_MI, A_ERROR, A_LIFETIME, A_REALM, A_NONCE, A_TRANSPORT = 0x0006, 0x0008, 0x0009, 0x000D, 0x0014, 0x0015, 0x0019


def attr(t, v):
    pad = (4 - len(v) % 4) % 4
    return struct.pack(">HH", t, len(v)) + v + b"\x00" * pad


def stun(method, tid, attrs, key=None):
    body = b"".join(attrs)
    if key is None:
        return struct.pack(">HHI", method, len(body), MAGIC) + tid + body
    # MESSAGE-INTEGRITY covers the header with its length already counting itself.
    head = struct.pack(">HHI", method, len(body) + 24, MAGIC) + tid
    mac = hmac.new(key, head + body, hashlib.sha1).digest()
    return head + body + attr(A_MI, mac)


def parse_stun(msg, tid):
    if len(msg) < 20:
        return None
    mtype, mlen, magic = struct.unpack(">HHI", msg[:8])
    if magic != MAGIC or msg[8:20] != tid or 20 + mlen != len(msg):
        return None
    attrs, i = [], 20
    while i + 4 <= len(msg):
        t, n = struct.unpack(">HH", msg[i:i + 4])
        v = msg[i + 4:i + 4 + n]
        if len(v) != n:
            return None
        attrs.append((t, v, i))
        i += 4 + n + (4 - n % 4) % 4
    return mtype, attrs


def integrity_ok(msg, attrs, key):
    for t, v, off in attrs:
        if t == A_MI:
            if len(v) != 20:
                return False
            head = msg[:2] + struct.pack(">H", off + 24 - 20) + msg[4:20]
            want = hmac.new(key, head + msg[20:off], hashlib.sha1).digest()
            return hmac.compare_digest(want, v)
    return False


def exchange(sock, packet, tid):
    for _ in range(3):
        sock.send(packet)
        deadline = time.monotonic() + 1.5
        while time.monotonic() < deadline:
            sock.settimeout(max(0.05, deadline - time.monotonic()))
            try:
                data = sock.recv(2048)
            except socket.timeout:
                break
            got = parse_stun(data, tid)
            if got is not None:
                return data, got
    return None, None


def turn(address, port):
    user = os.environ.get("TURN_USER", "").encode()
    password = os.environ.get("TURN_PASS", "").encode()
    if not user or not password:
        return 2
    ip = ipaddress.ip_address(address)
    fam = socket.AF_INET6 if ip.version == 6 else socket.AF_INET
    transport = attr(A_TRANSPORT, bytes([17, 0, 0, 0]))
    with socket.socket(fam, socket.SOCK_DGRAM) as s:
        # From one of coturn's relay ports: the TURN port lock lets coturn answer this
        # machine's own addresses on those alone.
        for _ in range(8):
            try:
                s.bind(("::" if ip.version == 6 else "0.0.0.0", 49152 + secrets.randbelow(16384)))
                break
            except OSError:
                continue
        s.connect((str(ip), port))
        tid = secrets.token_bytes(12)
        _, got = exchange(s, stun(ALLOCATE, tid, [transport]), tid)
        if got is None:
            return 1
        realm = nonce = None
        for t, v, _off in got[1]:
            if t == A_REALM:
                realm = v
            elif t == A_NONCE:
                nonce = v
        if realm is None or nonce is None or len(realm) > 763 or len(nonce) > 763:
            return 1
        key = hashlib.md5(user + b":" + realm + b":" + password).digest()
        tid = secrets.token_bytes(12)
        auth = [attr(A_USERNAME, user), attr(A_REALM, realm), attr(A_NONCE, nonce)]
        data, got = exchange(s, stun(ALLOCATE, tid, [transport] + auth, key), tid)
        # Only a key holder can sign an answer to this transaction; a success or an
        # error alike proves it. Never a request: an echo would hand ours back signed.
        if data is None or got[0] not in (0x0103, 0x0113) or not integrity_ok(data, got[1], key):
            return 1
        if got[0] == 0x0103:
            tid = secrets.token_bytes(12)
            exchange(s, stun(REFRESH, tid, [attr(A_LIFETIME, b"\x00\x00\x00\x00")] + auth, key), tid)
    return 0


def turn_cred(path):
    secret = ""
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh.read(65536).splitlines():
            key, sep, value = line.partition("=")
            if sep and key.strip() == "TURN_SECRET":
                secret = value.strip().strip('"').strip("'")
    if not secret:
        return 1
    user = "%d:hollow-address-follow" % (int(time.time()) + 300)
    password = base64.b64encode(hmac.new(secret.encode(), user.encode(), hashlib.sha1).digest()).decode()
    out(user)
    out(password)
    return 0


def main(argv):
    try:
        if len(argv) == 3 and argv[0] == "dns" and argv[2] in TYPES:
            return dns(argv[1], argv[2])
        if len(argv) in (2, 3) and argv[0] == "turn":
            return turn(argv[1], int(argv[2]) if len(argv) == 3 else 3478)
        if len(argv) == 2 and argv[0] == "turn-cred":
            return turn_cred(argv[1])
    except (OSError, ValueError):
        return 1
    sys.stderr.write("usage: address-probe.py dns <name> <A|AAAA> | turn <address> [port] | turn-cred <env file>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
