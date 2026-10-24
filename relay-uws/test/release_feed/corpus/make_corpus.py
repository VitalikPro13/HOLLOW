#!/usr/bin/env python3
"""Writes the shared corpus of crafted relay tarballs: the signer's tests
(rust/hollow_manifest) and the installer library's suite
(relay-uws/test/release_feed) each read cases.txt and must agree on every case.
Each tarball is for version 0.12.2 build 0, commit "a" * 40, linux-x86_64.

    python3 make_corpus.py <dir>     (the corpus is committed; rerun only to change it)
"""
import gzip
import os
import sys

COMMIT = "a" * 40
ELF = bytes([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0] + [0] * 8 + [3, 0, 0x3E, 0]) + b"\x55" * 64
MTIME = 1761134400


def octal(n, width):
    return b"%0*o\0" % (width - 1, n)


def header(name, size, mode=0o644, typ=b"0", mtime=MTIME, size_field=None, link=b"", b256=False):
    h = bytearray(512)
    h[0:len(name)] = name.encode()
    h[100:108] = octal(mode, 8)
    h[108:116] = octal(0, 8)
    h[116:124] = octal(0, 8)
    h[124:136] = octal(size if size_field is None else size_field, 12)
    if b256 or mtime >= 8 ** 11:
        h[136:148] = b"\x80" + mtime.to_bytes(11, "big")
    else:
        h[136:148] = octal(mtime, 12)
    h[148:156] = b" " * 8
    h[156:157] = typ
    h[157:157 + len(link)] = link
    h[257:263] = b"ustar\0"
    h[263:265] = b"00"
    h[148:156] = b"%06o\0 " % sum(h)
    return bytes(h)


def pad(body):
    return body + b"\0" * ((-len(body)) % 512)


def member(name, body, **kw):
    return header(name, len(body), **kw) + pad(body)


def pax(name, records, body, size_field=None, mode=0o644):
    recs = b""
    for key, value in records:
        line = (" %s=%s\n" % (key, value)).encode()
        n = len(line)
        while len(str(n).encode() + line) != n:
            n = len(str(n).encode() + line)
        recs += str(n).encode() + line
    return (header("PaxHeaders/" + name.split("/")[-1], len(recs), typ=b"x") + pad(recs)
            + header(name, len(body), mode=mode, size_field=size_field) + pad(body))


INSTALL = b'#!/bin/bash\n. "$DEPLOY/lib/common.sh"\n. "$DEPLOY/lib/release_feed.sh"\n. "$DEPLOY/lib/ui.sh"\n'
SETUP = [
    ("setup/install.sh", INSTALL, 0o755),
    ("setup/deploy/lib/common.sh", b"# common\n", 0o644),
    ("setup/deploy/lib/release_feed.sh", b"# feed\n", 0o644),
    ("setup/deploy/lib/ui.sh", b"# ui\n", 0o644),
    ("setup/push-sidecar/package.json", b"{}\n", 0o644),
    ("setup/push-sidecar/package-lock.json", b"{}\n", 0o644),
    ("setup/deploy/turn-port-lock.sh", b"# lock\n", 0o755),
    ("setup/deploy/hollow-turn-port-lock.service", b"# unit\n", 0o644),
    ("setup/deploy/hollow-turn-port-lock-refresh.service", b"# unit\n", 0o644),
    ("setup/deploy/hollow-turn-port-lock-refresh.timer", b"# timer\n", 0o644),
    ("setup/deploy/coturn-port-lock.conf", b"# drop-in\n", 0o644),
]


def base(mtime=MTIME, drop=(), extra=b"", install=INSTALL, b256=False):
    out = member("VERSION", b"version=0.12.2\nbuild=0\ncommit=%s\n" % COMMIT.encode(), mtime=mtime, b256=b256)
    out += member("hollow-forwarder", ELF, mode=0o755) + member("hollow-relay", ELF, mode=0o755)
    for name, body, mode in SETUP:
        if name in drop:
            continue
        out += member(name, install if name == "setup/install.sh" else body, mode=mode)
    return out + extra


END = b"\0" * 1024


def gz(raw):
    return gzip.compress(raw, compresslevel=9, mtime=0)


BIG = b"#" * (2 * 1024 * 1024)
CASES = [
    ("control", "accept", "the three programs and a setup copy with every file its install.sh sources", gz(base() + END)),
    ("pax_size_over_cap", "refuse", "a setup file whose pax size (2 MiB) is over the setup cap while its header says 16",
     gz(base(extra=pax("setup/deploy/big.txt", [("size", len(BIG))], BIG, size_field=16)) + END)),
    ("pax_size_honoured", "accept", "a setup file whose header size is 0 and whose pax size is its real size",
     gz(base(extra=pax("setup/deploy/p.sh", [("size", 9)], b"# pax ok\n", size_field=0)) + END)),
    ("trailing_bytes", "refuse", "bytes that are not gzip after the gzip stream", gz(base() + END) + b"GARBAGE-NOT-GZIP"),
    ("trailing_zeros", "refuse", "zero bytes after the gzip stream", gz(base() + END) + b"\0" * 64),
    ("second_member_link", "refuse", "a second gzip member carrying a symlink",
     gz(base()) + gz(member("setup/deploy/lnk", b"", typ=b"2", link=b"/etc/shadow") + END)),
    ("second_member_file", "refuse", "a second gzip member carrying a plain setup file the first never names",
     gz(base()) + gz(member("setup/deploy/lib/evil.sh", b"echo evil\n") + END)),
    ("empty_last_member", "refuse", "an empty gzip member after the tarball", gz(base() + END) + gz(b"")),
    ("empty_first_member", "accept", "an empty gzip member before the tarball, read as one stream",
     gz(b"") + gz(base() + END)),
    ("mtime_unlistable", "refuse", "an mtime of 2^62, which tar -tv cannot write as a date", gz(base(mtime=2 ** 62) + END)),
    ("mtime_last_ok", "accept", "an mtime of 2^33 - 1, the last second installers list", gz(base(mtime=2 ** 33 - 1) + END)),
    ("mtime_first_over", "refuse", "an mtime of 2^33", gz(base(mtime=2 ** 33) + END)),
    ("mtime_base256", "accept", "an mtime in the base-256 form, within the bound",
     gz(base(b256=True) + END)),
    ("pax_mtime_over", "refuse", "a pax mtime of 2^33 on a setup file",
     gz(base(extra=pax("setup/deploy/m.sh", [("mtime", 2 ** 33)], b"# m\n")) + END)),
    ("pax_mtime_fraction", "accept", "a pax mtime with a fraction",
     gz(base(extra=pax("setup/deploy/m.sh", [("mtime", "1761134400.25")], b"# m\n")) + END)),
    ("pax_mtime_bad_fraction", "refuse", "a pax mtime whose fraction is not digits",
     gz(base(extra=pax("setup/deploy/m.sh", [("mtime", "1761134400.ab")], b"# m\n")) + END)),
    ("pax_mtime_negative", "refuse", "a negative pax mtime", gz(base(extra=pax("setup/deploy/m.sh", [("mtime", "-5")], b"# m\n")) + END)),
    ("missing_sourced_lib", "refuse", "install.sh sources deploy/lib/ui.sh, which the copy lacks",
     gz(base(drop=("setup/deploy/lib/ui.sh",)) + END)),
    ("unsourced_lib_missing_ok", "accept", "a library install.sh does not source may be left out",
     gz(base(drop=("setup/deploy/lib/ui.sh",), install=INSTALL.replace(b'. "$DEPLOY/lib/ui.sh"\n', b'# . "$DEPLOY/lib/ui.sh"\n')) + END)),
    ("missing_lockfile", "refuse", "the push sender's package-lock.json is missing",
     gz(base(drop=("setup/push-sidecar/package-lock.json",)) + END)),
    ("missing_package_json", "refuse", "the push sender's package.json is missing",
     gz(base(drop=("setup/push-sidecar/package.json",)) + END)),
    ("missing_port_lock", "refuse", "the TURN port lock's deploy/turn-port-lock.sh is missing",
     gz(base(drop=("setup/deploy/turn-port-lock.sh",)) + END)),
]


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    lines = []
    for name, want, why, data in CASES:
        with open(os.path.join(out, name + ".tar.gz"), "wb") as f:
            f.write(data)
        lines.append("%s %s %s" % (name, want, why))
    with open(os.path.join(out, "cases.txt"), "w") as f:
        f.write("# <case> <accept|refuse> <what it is>; <case>.tar.gz is the tarball.\n")
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
