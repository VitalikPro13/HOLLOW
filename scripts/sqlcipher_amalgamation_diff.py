"""Compares the sqlcipher-src crate's amalgamation (sqlcipher/sqlcipher.c) with the
official sqlcipher/sqlcipher tag source tree, file section by file section, after
normalising the rewrites amalgamation makes (include markers, storage-class macros).
Prints the sections that still differ. Run on every rusqlite/SQLCipher bump.

    python3 -I scripts/sqlcipher_amalgamation_diff.py <sqlcipher.c> <official-tree> [section...]
"""
import re, sys, os, difflib
amalg, srcroot = sys.argv[1], sys.argv[2]
b_re = re.compile(r'^/\*+ Begin file (\S+) \*+/$')
e_re = re.compile(r'^/\*+ End of (\S+) \*+/$')
c_re = re.compile(r'^/\*+ Continuing where we left off in (\S+) \*+/$')
segs = {}; stack = []
for line in open(amalg, encoding='latin-1').read().splitlines():
    m = b_re.match(line)
    if m: stack.append(m.group(1)); continue
    m = e_re.match(line)
    if m:
        if stack: stack.pop()
        continue
    m = c_re.match(line)
    if m: continue
    if stack: segs.setdefault(stack[-1], []).append(line)
idx = {}
for d, _, fs in os.walk(srcroot):
    for f in fs: idx.setdefault(f, []).append(os.path.join(d, f))
def norm(lines):
    out = []
    for l in lines:
        l = l.rstrip()
        s = l.strip()
        if not s or s.startswith('#include') or s.startswith('/* #include') or s.startswith('# include'): continue
        for tok in ('SQLITE_PRIVATE ', 'SQLITE_API ', 'SQLITE_CDECL ', 'SQLITE_STDCALL ', 'static ', 'SQLITE_APICALL '):
            l = l.replace(tok, '')
        out.append(l)
    return out
names = sys.argv[3:] or sorted(segs)
tot = 0; bad = []
for name in names:
    if name not in segs or name not in idx: 
        if sys.argv[3:]: print('skip', name)
        continue
    best = None
    for c in idx[name]:
        a = norm(open(c, encoding='latin-1').read().splitlines()); b = norm(segs[name])
        d = [l for l in difflib.unified_diff(a, b, lineterm='', n=0) if not l.startswith(('---','+++','@@'))]
        if best is None or len(d) < len(best[0]): best = (d, c)
    d = best[0]; tot += len(d)
    if d: bad.append((name, len(d), d[:10]))
print('files compared', len([n for n in names if n in segs and n in idx]), 'with diffs', len(bad), 'total diff lines', tot)
for name, n, d in bad[:40]:
    print('==', name, n)
    for l in d: print('    ', l[:150])
