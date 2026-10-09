"""Input-side token usage and API-equivalent cost of one Claude Code session, lead plus every subagent.

Usage: python -I scripts/usage_report.py [<session-id> | --latest] [--json out.json]

Reads only the `usage` blocks of the session transcript and its subagents/ folder. Output and
thinking tokens are not in transcripts (stream-start snapshots only), so `/usage` stays the ground
truth for that side. "ctx now" is each agent's latest context, for timing a builder's handoff.
"""
import json
import re
import sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PROJECT = Path.home() / ".claude" / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(REPO))

# $/MTok: input, output, 5m cache write, 1h cache write, cache read (pricing page, 2026-10-08).
PRICES = {
    "claude-fable-5-1": (10, 50, 12.5, 20, 0.25),
    "claude-opus-5-5": (4, 20, 5, 8, 0.20),
    "claude-opus-5": (5, 25, 6.25, 10, 0.50),
    "claude-sonnet-5-5": (2, 10, 2.5, 4, 0.10),
    "claude-sonnet-5": (2, 10, 2.5, 4, 0.20),
}
# Haiku 5.5 reprices the whole request above a 100K-token prompt.
HAIKU_55 = ((0.10, 0.50, 0.125, 0.20, 0.01), (0.50, 2.50, 0.625, 1.0, 0.05))
COLD_REWRITE_MIN = 100_000


def prices_for(model, prompt_tokens):
    if model.startswith("claude-haiku-5-5"):
        return HAIKU_55[prompt_tokens > 100_000]
    return next((p for name, p in PRICES.items() if model.startswith(name)), None)


def requests(path):
    """Last usage record per message id (streaming writes one line per content block), and the latest effort."""
    seen, effort = {}, ""
    for line in path.open(encoding="utf-8"):
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(d.get("perTurnEffort"), str):
            effort = d["perTurnEffort"]
        m = d.get("message")
        if isinstance(m, dict) and m.get("usage") and m.get("model") != "<synthetic>":
            seen[m.get("id") or d.get("uuid")] = (d.get("timestamp") or "", m["model"], m["usage"])
    return sorted(seen.values(), key=lambda r: r[0]), effort


def summarize(path):
    s = dict(requests=0, cw5m=0, cw1h=0, cache_read=0, cost=0.0, read_cost=0.0, write_cost=0.0,
             ctx_now=0, ctx_max=0, cold=0, cold_cost=0.0, over_100k=0, models=set(), first=None, last=None)
    reqs, s["effort"] = requests(path)
    for ts, model, u in reqs:
        cc = u.get("cache_creation") or {}
        cw5 = cc.get("ephemeral_5m_input_tokens", 0) if cc else u.get("cache_creation_input_tokens", 0)
        cw1 = cc.get("ephemeral_1h_input_tokens", 0)
        inp, out, cr = u.get("input_tokens", 0), u.get("output_tokens", 0), u.get("cache_read_input_tokens", 0)
        ctx = inp + cw5 + cw1 + cr
        s["requests"] += 1
        s["models"].add(model)
        s["cw5m"] += cw5
        s["cw1h"] += cw1
        s["cache_read"] += cr
        s["ctx_now"] = ctx
        s["ctx_max"] = max(s["ctx_max"], ctx)
        s["over_100k"] += ctx > 100_000
        s["first"] = s["first"] or ts
        s["last"] = ts
        p = prices_for(model, ctx)
        if p is None:
            continue
        s["cost"] += (inp * p[0] + out * p[1] + cw5 * p[2] + cw1 * p[3] + cr * p[4]) / 1e6
        s["read_cost"] += cr * p[4] / 1e6
        s["write_cost"] += (cw5 * p[2] + cw1 * p[3]) / 1e6
        # A big context written almost whole means its cache had expired.
        if cw5 + cw1 > COLD_REWRITE_MIN and cw5 + cw1 > 0.8 * ctx:
            s["cold"] += 1
            s["cold_cost"] += (cw5 * p[2] + cw1 * p[3] - (cw5 + cw1) * p[4]) / 1e6
    s["models"] = sorted(m.replace("claude-", "") for m in s["models"])
    return s


def hours(s):
    if not s["first"] or not s["last"]:
        return 0.0
    t = lambda x: datetime.fromisoformat(x.replace("Z", "+00:00"))
    return (t(s["last"]) - t(s["first"])).total_seconds() / 3600


def main():
    args = sys.argv[1:]
    if not args or args[0] == "--latest":
        sid = max(PROJECT.glob("*.jsonl"), key=lambda p: p.stat().st_mtime).stem
    else:
        sid = args[0]
    rows = [("lead", summarize(PROJECT / f"{sid}.jsonl"))]
    sub = PROJECT / sid / "subagents"
    agents = {}
    for t in sorted(sub.glob("agent-*.jsonl"), key=lambda p: p.stat().st_mtime) if sub.is_dir() else []:
        meta_path = t.with_name(t.stem + ".meta.json")
        meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
        agents[t.stem.removeprefix("agent-")] = (t, meta)
    children = {}
    for aid, (_, meta) in agents.items():
        parent = meta.get("parentAgentId")
        children.setdefault(parent if parent in agents else None, []).append(aid)

    # Each runner listed under the agent that launched it, in launch order.
    def add(aid, depth):
        t, meta = agents[aid]
        rows.append(("  " * depth + (meta.get("description") or meta.get("agentType") or t.stem), summarize(t)))
        for child in children.get(aid, []):
            add(child, depth + 1)

    for aid in children.get(None, []):
        add(aid, 0)

    print(f"session {sid}")
    hdr = (f"{'who':40} {'effort':6} {'model':14} {'reqs':>5} {'ctx now':>7} {'ctx max':>7} "
           f"{'read M':>7} {'write M':>7} {'1h %':>5} {'cold':>4} {'>100k':>5} {'hours':>5} {'$ API':>8}")
    print(hdr)
    print("-" * len(hdr))
    for who, s in rows:
        writes = s["cw5m"] + s["cw1h"]
        print(f"{who[:40]:40} {s['effort']:6} {','.join(s['models'])[:14]:14} {s['requests']:5} "
              f"{s['ctx_now'] / 1e3:6.0f}k {s['ctx_max'] / 1e3:6.0f}k {s['cache_read'] / 1e6:7.1f} "
              f"{writes / 1e6:7.2f} {100 * s['cw1h'] / writes if writes else 0:5.0f} {s['cold']:4} "
              f"{s['over_100k']:5} {hours(s):5.1f} {s['cost']:8.2f}")
    print("-" * len(hdr))
    all_s = [s for _, s in rows]
    print(f"TOTAL API-equivalent input side ${sum(s['cost'] for s in all_s):.2f}: cache reads "
          f"${sum(s['read_cost'] for s in all_s):.2f}, cache writes ${sum(s['write_cost'] for s in all_s):.2f}, "
          f"of which cold-rewrite surcharge ${sum(s['cold_cost'] for s in all_s):.2f}")
    if "--json" in args:
        dest = Path(args[args.index("--json") + 1])
        dest.write_text(json.dumps([{"who": w, **s} for w, s in rows], indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
