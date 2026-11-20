#!/usr/bin/env python3
"""A DNS server for address_follow_box_test.sh: answers A and AAAA questions from
<dir>/dns-A and <dir>/dns-AAAA, one address per line, or one of the words NXDOMAIN,
SERVFAIL or DROP (no answer at all). A missing file answers NXDOMAIN. Before an
answer it runs <dir>/hook once, if present, then removes it.

  fake_dns.py <dir> [address] [port]
"""
import os
import socket
import struct
import subprocess
import sys

DIR = sys.argv[1]
ADDR = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 53


def answer(q):
    qid, _flags, qd = struct.unpack(">HHH", q[:6])
    i = 12
    while q[i] != 0:
        i += 1 + q[i]
    qtype, _qclass = struct.unpack(">HH", q[i + 1:i + 5])
    question = q[12:i + 5]
    name = {1: "A", 28: "AAAA"}.get(qtype)
    lines = []
    if name:
        try:
            with open(os.path.join(DIR, "dns-" + name)) as fh:
                lines = [l.strip() for l in fh if l.strip()]
        except OSError:
            lines = ["NXDOMAIN"]
    rcode, records = 0, []
    if lines[:1] == ["DROP"]:
        return None
    if lines[:1] == ["NXDOMAIN"]:
        rcode = 3
    elif lines[:1] == ["SERVFAIL"]:
        rcode = 2
    else:
        for a in lines:
            fam = socket.AF_INET6 if ":" in a else socket.AF_INET
            rdata = socket.inet_pton(fam, a)
            rtype = 28 if fam == socket.AF_INET6 else 1
            if rtype == qtype:
                records.append(b"\xc0\x0c" + struct.pack(">HHIH", rtype, 1, 60, len(rdata)) + rdata)
    head = struct.pack(">HHHHHH", qid, 0x8180 | rcode, qd, len(records), 0, 0)
    return head + question + b"".join(records)


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((ADDR, PORT))
    while True:
        q, peer = s.recvfrom(4096)
        hook = os.path.join(DIR, "hook")
        if os.path.exists(hook):
            subprocess.run(["bash", hook], check=False)
            os.remove(hook)
        try:
            a = answer(q)
        except (IndexError, struct.error, OSError, ValueError):
            continue
        if a is not None:
            s.sendto(a, peer)


main()
