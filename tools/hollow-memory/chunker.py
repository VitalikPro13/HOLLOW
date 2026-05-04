import hashlib
import re
from pathlib import Path

from config import MEMORY_DIR, HOLLOW_PLAN_PATH, WHITEPAPER_PATH, CLAUDE_MD_PATH, WIKI_DIR


def _hash(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def _parse_yaml_frontmatter(content: str) -> tuple[dict, str]:
    """Extract YAML frontmatter and body from a markdown file."""
    meta = {}
    body = content
    if content.startswith("---"):
        parts = content.split("---", 2)
        if len(parts) >= 3:
            for line in parts[1].strip().splitlines():
                if ":" in line:
                    key, val = line.split(":", 1)
                    meta[key.strip()] = val.strip()
            body = parts[2].strip()
    return meta, body


def _split_by_headings(content: str, level: str = "## ") -> list[tuple[str, str]]:
    """Split markdown by heading level. Returns [(heading, section_text), ...]."""
    sections = []
    current_heading = ""
    current_lines = []

    for line in content.splitlines():
        if line.startswith(level) and not line.startswith(level + "#"):
            if current_lines:
                sections.append((current_heading, "\n".join(current_lines).strip()))
            current_heading = line.lstrip("#").strip()
            current_lines = [line]
        else:
            current_lines.append(line)

    if current_lines:
        sections.append((current_heading, "\n".join(current_lines).strip()))

    return sections


def chunk_memory_files() -> list[dict]:
    """Read all memory markdown files and return as chunks."""
    chunks = []
    if not MEMORY_DIR.exists():
        return chunks

    for f in sorted(MEMORY_DIR.glob("*.md")):
        if f.name == "MEMORY.md":
            continue  # Skip the index file — it's just pointers

        content = f.read_text(encoding="utf-8", errors="replace")
        meta, body = _parse_yaml_frontmatter(content)

        name = meta.get("name", f.stem)
        description = meta.get("description", "")
        mem_type = meta.get("type", "unknown")

        # Prepend name+description for better embedding quality
        embed_text = f"{name}: {description}\n\n{body}" if description else f"{name}\n\n{body}"

        chunks.append({
            "source": f"memory/{f.name}",
            "heading": name,
            "chunk_type": f"memory-{mem_type}",
            "name": name,
            "description": description,
            "content": embed_text,
            "content_hash": _hash(embed_text),
        })

    return chunks


def chunk_plan() -> list[dict]:
    """Split HOLLOW_PLAN.md into chunks by sections and phases."""
    if not HOLLOW_PLAN_PATH.exists():
        return []

    content = HOLLOW_PLAN_PATH.read_text(encoding="utf-8", errors="replace")
    chunks = []

    sections = _split_by_headings(content, "## ")

    for heading, section_text in sections:
        if not heading:
            continue

        # Section 13 (Development Phases) is massive — sub-chunk by ### Phase
        if "phase" in heading.lower() and "milestone" in heading.lower():
            phase_sections = _split_by_headings(section_text, "### ")
            for phase_heading, phase_text in phase_sections:
                if not phase_heading:
                    continue
                # Further sub-chunk if a phase section is too large (>4000 chars)
                if len(phase_text) > 4000:
                    sub_sections = _split_by_headings(phase_text, "#### ")
                    for sub_heading, sub_text in sub_sections:
                        if not sub_heading or len(sub_text.strip()) < 50:
                            continue
                        full_heading = f"{phase_heading} > {sub_heading}"
                        chunks.append({
                            "source": "HOLLOW_PLAN.md",
                            "heading": full_heading,
                            "chunk_type": "plan-phase",
                            "name": full_heading,
                            "description": f"Phase sub-section from HOLLOW_PLAN.md",
                            "content": f"{full_heading}\n\n{sub_text}",
                            "content_hash": _hash(sub_text),
                        })
                else:
                    chunks.append({
                        "source": "HOLLOW_PLAN.md",
                        "heading": phase_heading,
                        "chunk_type": "plan-phase",
                        "name": phase_heading,
                        "description": f"Development phase from HOLLOW_PLAN.md",
                        "content": f"{phase_heading}\n\n{phase_text}",
                        "content_hash": _hash(phase_text),
                    })
        else:
            chunks.append({
                "source": "HOLLOW_PLAN.md",
                "heading": heading,
                "chunk_type": "plan-section",
                "name": heading,
                "description": f"Architecture section from HOLLOW_PLAN.md",
                "content": f"{heading}\n\n{section_text}",
                "content_hash": _hash(section_text),
            })

    return chunks


def chunk_whitepaper() -> list[dict]:
    """Split WHITEPAPER.md by ## headings."""
    if not WHITEPAPER_PATH.exists():
        return []

    content = WHITEPAPER_PATH.read_text(encoding="utf-8", errors="replace")
    chunks = []

    sections = _split_by_headings(content, "## ")
    for heading, section_text in sections:
        if not heading or len(section_text.strip()) < 50:
            continue
        chunks.append({
            "source": "WHITEPAPER.md",
            "heading": heading,
            "chunk_type": "whitepaper",
            "name": heading,
            "description": f"Whitepaper section",
            "content": f"{heading}\n\n{section_text}",
            "content_hash": _hash(section_text),
        })

    return chunks


def chunk_claude_md() -> list[dict]:
    """CLAUDE.md as a single chunk."""
    if not CLAUDE_MD_PATH.exists():
        return []

    content = CLAUDE_MD_PATH.read_text(encoding="utf-8", errors="replace")
    return [{
        "source": "CLAUDE.md",
        "heading": "Project Instructions",
        "chunk_type": "claude-md",
        "name": "CLAUDE.md — Project Instructions",
        "description": "Coding conventions, build commands, architecture notes",
        "content": content,
        "content_hash": _hash(content),
    }]


def chunk_wiki_files() -> list[dict]:
    """Split wiki markdown files by ## headings into searchable chunks."""
    chunks = []
    if not WIKI_DIR.exists():
        return chunks

    for f in sorted(WIKI_DIR.glob("*.md")):
        content = f.read_text(encoding="utf-8", errors="replace")

        title = f.stem.replace("_", " ").title()
        first_line = content.split("\n", 1)[0]
        if first_line.startswith("# "):
            title = first_line.lstrip("# ").strip()

        sections = _split_by_headings(content, "## ")
        for heading, section_text in sections:
            if not heading or len(section_text.strip()) < 50:
                continue
            embed_text = f"{title} > {heading}\n\n{section_text}"
            chunks.append({
                "source": f"wiki/{f.name}",
                "heading": heading,
                "chunk_type": "wiki",
                "name": f"{title} > {heading}",
                "description": f"Wiki: {title}",
                "content": embed_text,
                "content_hash": _hash(embed_text),
            })

    return chunks


def get_all_chunks() -> list[dict]:
    """Get all chunks from all sources."""
    chunks = []
    chunks.extend(chunk_memory_files())
    chunks.extend(chunk_plan())
    chunks.extend(chunk_whitepaper())
    chunks.extend(chunk_claude_md())
    chunks.extend(chunk_wiki_files())
    return chunks
