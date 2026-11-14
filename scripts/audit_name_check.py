"""Lists code names a security doc cites that no longer exist in the tree.

Usage: python3 scripts/audit_name_check.py reports/*/security/audit/requirements.md ...
"""
import re, os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
blob = []
for d in ["rust/hollow_core/src", "relay-uws", "test", "lib", "scripts", "push-sidecar", "packages/flutter_webrtc"]:
    for dp, dn, fs in os.walk(os.path.join(root, d)):
        if "/target" in dp or "/build" in dp or "node_modules" in dp: continue
        for f in fs:
            if f.endswith((".rs", ".cpp", ".h", ".dart", ".sh", ".py", ".js", ".json", ".cc", ".m", ".java", ".kt", ".service")):
                try: blob.append(open(os.path.join(dp, f), errors="ignore").read())
                except Exception: pass
blob = "\n".join(blob)
for p in sys.argv[1:]:
    t = open(p).read()
    toks = set(re.findall(r"`([^`\n]+)`", t))
    miss = []
    for tok in sorted(toks):
        for part in re.split(r"[\s(),]+", tok):
            part = part.strip(".;:")
            name = part.split("::")[-1]
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) and "_" in name and len(name) >= 10:
                if name not in blob:
                    miss.append(name)
    print(os.path.basename(p), "MISSING:", sorted(set(miss)))
