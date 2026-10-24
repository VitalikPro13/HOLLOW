#!/usr/bin/env bash
# Render the security audit report to PDF: Markdown -> Typst (pandoc) -> PDF (typst).
#
# The Markdown is the one canonical source (its # line becomes the title, its own
# numbered ## sections the chapters); the PDF is always rebuilt from it and
# never edited by hand. Needs pandoc >= 3.6 and typst >= 0.13 (brew install pandoc typst).
#
#   scripts/build_audit_report.sh [report.md] [out.pdf]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$root/reports/planned/security/SECURITY_AUDIT_2026_10.md}"
out="${2:-$root/build/security_audit/$(basename "${src%.md}").pdf}"
style="$root/scripts/audit_report/style.typ"

mkdir -p "$(dirname "$out")"
typ="${out%.pdf}.typ"
# Typst resolves the include relative to the generated file, so copy the style next to it.
cp "$style" "$(dirname "$out")/style.typ"

pandoc "$src" \
  --from markdown-smart \
  --to typst \
  --standalone \
  --include-in-header "$style" \
  -V papersize=a4 \
  -V fontsize=10pt \
  -V margin.x=2cm -V margin.y=2.2cm \
  --shift-heading-level-by=-1 \
  -o "$typ"

# The cover block (everything up to the first rule) stays on the title page; the
# contents follow on their own page.
python3 - "$typ" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
rule = "#divider()\n"
assert rule in text, "the report needs a --- rule after its cover block"
text = text.replace(rule, "#pagebreak()\n#outline(depth: 1)\n#pagebreak()\n", 1)
open(path, "w", encoding="utf-8").write(text)
PY

typst compile --root "$(dirname "$typ")" "$typ" "$out"
echo "OK: $out"
