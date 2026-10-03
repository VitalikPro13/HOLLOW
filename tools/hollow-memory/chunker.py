import hashlib
import re
import subprocess
from pathlib import Path

from config import (
    CLAUDE_MD_PATH, CODE_EXTENSIONS, CODE_ROOTS, CODE_SKIP_NAMES, CODE_SKIP_PREFIXES, HOLLOW_PLAN_PATH,
    MAX_CHUNK_CHARS, MEMORY_DIR, PROJECT_ROOT, REPORTS_DIR, REPORTS_SKIP, WHITEPAPER_PATH, WIKI_DIR,
)


def _hash(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def list_doc_files() -> list[tuple[Path, str, str]]:
    """(path, source label, kind) for every doc the index covers."""
    files = []
    if MEMORY_DIR.exists():
        files += [(f, f"memory/{f.name}", "memory") for f in sorted(MEMORY_DIR.glob("*.md")) if f.name != "MEMORY.md"]
    for path, kind in [(HOLLOW_PLAN_PATH, "plan"), (WHITEPAPER_PATH, "whitepaper"), (CLAUDE_MD_PATH, "claude-md")]:
        if path.exists():
            files.append((path, path.name, kind))
    if WIKI_DIR.exists():
        files += [(f, f"wiki/{f.name}", "wiki") for f in sorted(WIKI_DIR.glob("*.md"))]
    if REPORTS_DIR.exists():
        files += [(f, f.relative_to(PROJECT_ROOT).as_posix(), "report")
                  for f in sorted(REPORTS_DIR.rglob("*.md")) if f.name not in REPORTS_SKIP]
    return files


def list_code_files() -> list[tuple[Path, str, str]]:
    # Inheriting the MCP stdin pipe deadlocks on Windows while the transport thread blocks reading it.
    out = subprocess.run(["git", "ls-files", *CODE_ROOTS], cwd=PROJECT_ROOT, stdin=subprocess.DEVNULL,
                         capture_output=True, text=True, encoding="utf-8").stdout.splitlines()
    return [(PROJECT_ROOT / rel, rel, "code") for rel in out
            if rel.endswith(CODE_EXTENSIONS) and not rel.startswith(CODE_SKIP_PREFIXES)
            and rel.rsplit("/", 1)[-1] not in CODE_SKIP_NAMES]


def _sections(lines, level):
    """Split numbered lines at one heading level: [(heading, [(lineno, text), ...])]."""
    out, head, buf = [], "", []
    for ln in lines:
        if ln[1].startswith(level) and not ln[1].startswith(level + "#"):
            if buf:
                out.append((head, buf))
            head, buf = ln[1].lstrip("#").strip(), [ln]
        else:
            buf.append(ln)
    if buf:
        out.append((head, buf))
    return out


def _size(lines):
    return sum(len(t) + 1 for _, t in lines)


def _windows(lines, limit=MAX_CHUNK_CHARS):
    """Cut at blank lines once a piece passes the limit, hard cut at 1.5x."""
    pieces, cur, size = [], [], 0
    for ln in lines:
        if cur and size + len(ln[1]) > limit and (not ln[1].strip() or size > limit * 1.5):
            pieces.append(cur)
            cur, size = [], 0
        cur.append(ln)
        size += len(ln[1]) + 1
    if cur:
        pieces.append(cur)
    return pieces


def _chunk(source, kind, heading, lines, prefix):
    body = "\n".join(t for _, t in lines).strip()
    content = f"{prefix}\n\n{body}"
    return {"source": source, "kind": kind, "heading": heading, "start_line": lines[0][0],
            "end_line": lines[-1][0], "content": content, "content_hash": _hash(content)}


def _markdown_chunks(text, source, kind, title):
    """## sections, then ### when a section is too big, then paragraph windows."""
    chunks = []
    lines = list(enumerate(text.splitlines(), 1))
    for h2, body2 in _sections(lines, "## "):
        if _size(body2) <= MAX_CHUNK_CHARS:
            parts = [(h2, body2)]
        else:
            parts = [((f"{h2} > {h3}" if h2 and h3 else h3 or h2), b3) for h3, b3 in _sections(body2, "### ")]
        for head, body in parts:
            if len("".join(t for _, t in body).strip()) < 50:
                continue
            label = head or title
            pieces = [body] if _size(body) <= MAX_CHUNK_CHARS else _windows(body)
            for i, piece in enumerate(pieces):
                heading = label + (f" ({i + 1})" if len(pieces) > 1 else "")
                chunks.append(_chunk(source, kind, heading, piece, f"{title} > {heading}"))
    return chunks


def _memory_chunks(text, source):
    meta, body_start = {}, 0
    lines = text.splitlines()
    if lines and lines[0].strip() == "---":
        for i, line in enumerate(lines[1:], 1):
            if line.strip() == "---":
                body_start = i + 1
                break
            if ":" in line:
                key, val = line.split(":", 1)
                meta[key.strip()] = val.strip()
    name = meta.get("name", Path(source).stem)
    kind = f"memory-{meta.get('type', 'unknown')}"
    prefix = f"{name}: {meta['description']}" if meta.get("description") else name
    numbered = [(i + 1, t) for i, t in enumerate(lines)][body_start:]
    if not numbered:
        return []
    pieces = [numbered] if _size(numbered) <= MAX_CHUNK_CHARS else _windows(numbered)
    return [_chunk(source, kind, name + (f" ({i + 1})" if len(pieces) > 1 else ""), p, prefix)
            for i, p in enumerate(pieces)]


def chunk_doc(path: Path, source: str, kind: str) -> list[dict]:
    text = path.read_text(encoding="utf-8", errors="replace")
    if kind == "memory":
        return _memory_chunks(text, source)
    first = text.split("\n", 1)[0]
    title = first.lstrip("# ").strip() if first.startswith("# ") else path.stem.replace("_", " ")
    return _markdown_chunks(text, source, kind, title)


_CODE_BOUNDARY = re.compile(
    r"^\s{0,4}(pub(\([a-z]+\))?\s+)?(async\s+)?(unsafe\s+)?(fn|impl|struct|enum|trait|mod|const|static|type)\b"
    r"|^\s{0,2}(class|mixin|extension|enum|typedef|abstract class|final class|sealed class)\b"
    r"|^\s{0,2}[A-Za-z_<>?, ]+\s+[a-zA-Z_]\w*\s*(<[^>]*>)?\(.*\)\s*(async\s*)?(\{|=>)"
    r"|^\s{0,2}(static|inline|bool|void|int|std::|uint\d+_t|struct|class|namespace|template)\b.*[({]\s*$")
_ATTACHED = ("///", "#[", "@")


def chunk_code(path: Path, source: str, kind: str = "code", min_lines=25, max_lines=90) -> list[dict]:
    """Windows of 25-90 lines, cut where a top-level item starts, keeping its doc comment attached."""
    lines = list(enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1))
    chunks, start = [], 0
    for i in range(len(lines)):
        size = i - start
        prev = lines[i - 1][1].lstrip() if i else ""
        boundary = (size >= min_lines and _CODE_BOUNDARY.match(lines[i][1])
                    and (not prev or prev.startswith(("//", "#[", "@"))))
        if boundary or size >= max_lines:
            cut = i
            if boundary:
                while cut > start and lines[cut - 1][1].lstrip().startswith(_ATTACHED):
                    cut -= 1
            if cut > start:
                chunks.append(_chunk(source, kind, f"{source}:{lines[start][0]}", lines[start:cut], f"// {source}"))
                start = cut
    if start < len(lines):
        chunks.append(_chunk(source, kind, f"{source}:{lines[start][0]}", lines[start:], f"// {source}"))
    return [c for c in chunks if c["content"].strip()]


CORPORA = {
    "docs": (list_doc_files, chunk_doc),
    "code": (list_code_files, chunk_code),
}
