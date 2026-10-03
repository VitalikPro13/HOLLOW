import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("hollow-memory")


def _refresh(corpus: str, budget: int | None):
    from chunker import CORPORA
    from embedder import embed
    from store import refresh

    list_files, chunk_file = CORPORA[corpus]
    return refresh(corpus, list_files, chunk_file, embed, budget)


def _search(corpus: str, query: str, limit: int, prompt: str):
    from config import SEARCH_REFRESH_BUDGET
    from embedder import embed
    from store import looks_like_identifier, search

    status = _refresh(corpus, SEARCH_REFRESH_BUDGET)
    # Keyword ranking helps docs everywhere but drags plain-English code queries down (85% -> 67% top-5).
    lex = 1.0 if corpus == "docs" or looks_like_identifier(query) else 0.0
    results = search(corpus, embed([query], prompt)[0], query, limit, lex)
    note = ""
    if status["files_pending"]:
        note = f"\n_Index catching up: {status['files_pending']} changed files not yet re-embedded; search again or run memory_reindex()._"
    return results, note


@mcp.tool()
def memory_search(query: str, limit: int = 6) -> str:
    """Search Hollow's knowledge by meaning and keywords: memory files, wiki, reports/ (plans, audits, findings,
    shipped designs), HOLLOW_PLAN.md, WHITEPAPER.md and CLAUDE.md.

    The index refreshes changed files on every call. Each result names `source:line` so you can Read that spot.

    Args:
        query: A question or topic ("why a 50k member server keeps MLS") or an identifier ("HOL-SEC-079").
        limit: Number of results (default 6).
    """
    from config import DOC_QUERY_PROMPT

    results, note = _search("docs", query, limit, DOC_QUERY_PROMPT)
    if not results:
        return "No results found." + note
    lines = [f"**{len(results)} results for:** \"{query}\"\n"]
    for i, r in enumerate(results, 1):
        body = r["content"].split("\n\n", 1)[-1]
        snippet = " ".join(body[:500].split()) + ("..." if len(body) > 500 else "")
        lines.append(f"### {i}. {r['heading']}")
        lines.append(f"`{r['source']}:{r['start_line']}` | {r['kind']}")
        lines.append(f"> {snippet}\n")
    return "\n".join(lines) + note


@mcp.tool()
def code_search(query: str, limit: int = 8) -> str:
    """Find code in rust/hollow_core, lib/ and relay-uws/src by what it does, when you do not know the symbol name.

    A starting point only: it never proves completeness. For every call site or every arm of a rule, use Grep or
    LSP findReferences. Each result is `path:start-end` plus its first lines.

    Args:
        query: What the code does ("refuse a file header from someone other than the owner").
        limit: Number of results (default 8).
    """
    from config import CODE_QUERY_PROMPT

    results, note = _search("code", query, limit, CODE_QUERY_PROMPT)
    if not results:
        return "No results found." + note
    lines = [f"**{len(results)} results for:** \"{query}\"\n"]
    for i, r in enumerate(results, 1):
        body = [l for l in r["content"].split("\n")[1:] if l.strip()][:8]
        lines.append(f"### {i}. `{r['source']}:{r['start_line']}-{r['end_line']}`")
        lines.append("```\n" + "\n".join(l[:160] for l in body) + "\n```")
    return "\n".join(lines) + note


@mcp.tool()
def memory_reindex(force: bool = False) -> str:
    """Bring the docs and code indexes fully up to date (searches already refresh changed files in small batches).

    Args:
        force: Drop everything and re-embed from scratch (minutes on the GPU).
    """
    from store import clear_all

    if force:
        clear_all()
    parts = []
    for corpus in ("docs", "code"):
        s = _refresh(corpus, None)
        parts.append(f"{corpus}: {s['files_updated']} files updated, {s['files_removed']} removed, "
                     f"{s['chunks_embedded']} chunks embedded")
    return "Reindex complete. " + "; ".join(parts)


@mcp.tool()
def memory_stats() -> str:
    """Show what the search indexes hold."""
    from store import get_stats

    s = get_stats()
    lines = ["**Hollow Memory Index**", f"Database: {s['db_path']}", f"Files: {s['files']}"]
    lines += [f"{k}: {v}" for k, v in sorted(s["meta"].items())]
    lines += ["", "**Chunks by kind:**"] + [f"  - {k}: {v}" for k, v in s["by_kind"].items()]
    return "\n".join(lines)


if __name__ == "__main__":
    import chunker  # noqa: F401
    from embedder import embed
    from store import init_db

    init_db()
    if "--reindex" in sys.argv:
        print(memory_reindex(force="--force" in sys.argv))
    else:
        # On Windows a DLL load deadlocks once the stdio thread blocks reading stdin, so every heavy import and
        # the first CUDA kernels load before serving; a later reload after an idle unload loads no new DLLs.
        embed(["warm up"])
        mcp.run()
