"""Token usage and API-equivalent cost of Claude Code sessions, lead plus every subagent.

Usage: python3 -I scripts/usage_report.py [<session-id> | --latest] [--json out.json]
       python3 -I scripts/usage_report.py --all [--since YYYY-MM-DD]

One session prints a row per agent ("ctx now" times a builder's handoff); --all prints every
session of this project by role, for comparing waves. Both end with the habits that drive cost,
because every request re-reads the whole context: tool calls per request, single read-only
lookups, wait requests. Transcripts hold less than `/usage` bills, so `/usage` stays the ground
truth for totals; compare shares and per-agent numbers here.
"""
import json
import re
import statistics
import sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PROJECT = Path.home() / ".claude" / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(REPO))

# $/MTok: input, output, 5m cache write, 1h cache write, cache read (pricing page, 2026-11-03).
PRICES = {
    "claude-fable-5-2": (8, 40, 10, 16, 0.20),
    "claude-fable-5-1": (10, 50, 12.5, 20, 0.25),
    "claude-opus-5-5": (4, 20, 5, 8, 0.20),
    "claude-opus-5": (5, 25, 6.25, 10, 0.50),
    "claude-opus-4-8": (5, 25, 6.25, 10, 0.50),
    "claude-sonnet-5-5": (2, 10, 2.5, 4, 0.10),
    "claude-sonnet-5": (2, 10, 2.5, 4, 0.20),
}
# Haiku 5.5 reprices the whole request above a 100K-token prompt.
HAIKU_55 = ((0.10, 0.50, 0.125, 0.20, 0.01), (0.50, 2.50, 0.625, 1.0, 0.05))
COLD_REWRITE_MIN = 100_000
LOOKUP = re.compile(r"\s*(cd [^;&]+(&&|;)\s*)?(sed -n|cat |grep |rg |head |tail |ls |wc |find |git (diff|log|show|status|grep))")
WAIT = re.compile(r"\bsleep\b|until \[|while \[|while !")


def prices_for(model, prompt_tokens):
    if model.startswith("claude-haiku-5-5"):
        return HAIKU_55[prompt_tokens > 100_000]
    return next((p for name, p in PRICES.items() if model.startswith(name)), None)


def requests(path):
    """One record per API request (streaming writes a line per content block), and the latest effort."""
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
            r = seen.setdefault(m.get("id") or d.get("uuid"), {"calls": []})
            r.update(ts=d.get("timestamp") or "", model=m["model"], usage=m["usage"])
            for c in m.get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    r["calls"].append((c.get("name"), (c.get("input") or {}).get("command") or ""))
    return sorted(seen.values(), key=lambda r: r["ts"]), effort


def is_lookup(calls):
    """A request spent on one read-only look, the kind that batches with its neighbours."""
    if len(calls) != 1:
        return False
    name, cmd = calls[0]
    return name in ("Read", "Grep", "Glob") or (
        name == "Bash" and bool(LOOKUP.match(cmd)) and not re.search(r">\s*\S|\btee\b", cmd[:400]))


def summarize(path):
    s = dict(requests=0, cw5m=0, cw1h=0, cache_read=0, cost=0.0, read_cost=0.0, write_cost=0.0, out_cost=0.0,
             ctx_now=0, ctx_max=0, cold=0, cold_cost=0.0, over_100k=0, models=set(), first=None, last=None,
             calls=0, lookups=0, waits=0)
    reqs, s["effort"] = requests(path)
    for r in reqs:
        ts, model, u = r["ts"], r["model"], r["usage"]
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
        s["calls"] += len(r["calls"])
        s["lookups"] += is_lookup(r["calls"])
        s["waits"] += any(name == "Bash" and WAIT.search(cmd) for name, cmd in r["calls"])
        p = prices_for(model, ctx)
        if p is None:
            continue
        s["cost"] += (inp * p[0] + out * p[1] + cw5 * p[2] + cw1 * p[3] + cr * p[4]) / 1e6
        s["read_cost"] += cr * p[4] / 1e6
        s["write_cost"] += (cw5 * p[2] + cw1 * p[3]) / 1e6
        s["out_cost"] += out * p[1] / 1e6
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


def session_agents(sid):
    """(agent id, transcript, meta) of every subagent of a session, in launch order."""
    sub = PROJECT / sid / "subagents"
    out = []
    for t in sorted(sub.glob("agent-*.jsonl"), key=lambda p: p.stat().st_mtime) if sub.is_dir() else []:
        meta_path = t.with_name(t.stem + ".meta.json")
        meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
        out.append((t.stem.removeprefix("agent-"), t, meta))
    return out


def habits(rows):
    """The cost habits of the agents that pay full price for a request (Haiku ones barely do)."""
    paid = [s for s in rows if s["requests"] and not all(m.startswith("haiku") for m in s["models"])]
    n = sum(s["requests"] for s in paid) or 1
    return (f"habits (non-Haiku agents): {sum(s['calls'] for s in paid) / n:.2f} tool calls per request, "
            f"{sum(s['lookups'] for s in paid)} single lookups ({100 * sum(s['lookups'] for s in paid) / n:.0f}% of "
            f"requests), {sum(s['waits'] for s in paid)} wait requests")


def totals(rows):
    return (f"TOTAL API-equivalent ${sum(s['cost'] for s in rows):.2f}: cache reads "
            f"${sum(s['read_cost'] for s in rows):.2f}, cache writes ${sum(s['write_cost'] for s in rows):.2f} "
            f"(cold-rewrite surcharge ${sum(s['cold_cost'] for s in rows):.2f}), output "
            f"${sum(s['out_cost'] for s in rows):.2f}")


def report_session(sid, args):
    rows = [("lead", summarize(PROJECT / f"{sid}.jsonl"))]
    agents = {aid: (t, meta) for aid, t, meta in session_agents(sid)}
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
    print(totals(all_s))
    print(habits(all_s))
    if "--json" in args:
        dest = Path(args[args.index("--json") + 1])
        dest.write_text(json.dumps([{"who": w, **s} for w, s in rows], indent=1), encoding="utf-8")


def report_all(since):
    by_role, sessions = {}, []
    for lead in sorted(PROJECT.glob("*.jsonl"), key=lambda p: p.stat().st_mtime):
        rows = [("lead", summarize(lead))] + [(meta.get("agentType") or "?", summarize(t))
                                               for _, t, meta in session_agents(lead.stem)]
        rows = [(role, s) for role, s in rows if s["requests"]]
        start = min((s["first"] for _, s in rows), default="")
        if not rows or start[:10] < since:
            continue
        for role, s in rows:
            by_role.setdefault(role, []).append(s)
        sessions.append((start[:10], lead.stem[:8], sum(s["cost"] for _, s in rows), len(rows) - 1))
    all_s = [s for group in by_role.values() for s in group]
    grand = sum(s["cost"] for s in all_s) or 1
    print(f"{len(sessions)} sessions since {since or 'the start'}")
    hdr = (f"{'role':16} {'agents':>6} {'$ API':>8} {'share':>6} {'$/agent':>8} {'reqs':>7} {'calls/req':>9} "
           f"{'lookup %':>8} {'waits':>6} {'med max':>8} {'cold':>4}")
    print(hdr)
    print("-" * len(hdr))
    for role, group in sorted(by_role.items(), key=lambda kv: -sum(s["cost"] for s in kv[1])):
        cost, n = sum(s["cost"] for s in group), sum(s["requests"] for s in group)
        print(f"{role[:16]:16} {len(group):6} {cost:8.0f} {100 * cost / grand:5.1f}% {cost / len(group):8.2f} {n:7} "
              f"{sum(s['calls'] for s in group) / n:9.2f} {100 * sum(s['lookups'] for s in group) / n:7.0f}% "
              f"{sum(s['waits'] for s in group):6} {statistics.median(s['ctx_max'] for s in group) / 1e3:7.0f}k "
              f"{sum(s['cold'] for s in group):4}")
    print("-" * len(hdr))
    print(totals(all_s))
    print(habits(all_s))
    print("sessions: " + "  ".join(f"{day[5:]} {sid} ${cost:.0f} ({n} agents)" for day, sid, cost, n in sessions))


def main():
    args = sys.argv[1:]
    if "--all" in args:
        report_all(args[args.index("--since") + 1] if "--since" in args else "")
    elif not args or args[0] == "--latest":
        report_session(max(PROJECT.glob("*.jsonl"), key=lambda p: p.stat().st_mtime).stem, args)
    else:
        report_session(args[0], args)


if __name__ == "__main__":
    main()
