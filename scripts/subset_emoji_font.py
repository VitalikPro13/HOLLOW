"""Subset assets/fonts/NotoColorEmoji.ttf to emoji-only. Run after
replacing the font with a fresh upstream copy (googlefonts/noto-emoji,
fonts/NotoColorEmoji.ttf); the committed file is already subset.

The upstream font maps space, CR, digits, '#' and '*' (keycap components)
with huge bitmap advances. As a Flutter fontFamilyFallback next to a null
fontFamily it ends up serving those ASCII glyphs, exploding word spacing
(spaces + digits rendered emoji-wide). Dropping every codepoint below
U+00A9 makes it emoji-only; keycap emoji fall through to the system emoji
font (they're Emoji 3.0-era, present everywhere).

Requires: pip install fonttools
"""
import os
import sys
from fontTools import subset
from fontTools.ttLib import TTFont

src = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "assets", "fonts", "NotoColorEmoji.ttf")

font = TTFont(src)
cmap = set()
for table in font["cmap"].tables:
    cmap |= set(table.cmap.keys())
low = sorted(cp for cp in cmap if cp < 0xA9)
print("dropping low codepoints:", [hex(c) for c in low])
keep = {cp for cp in cmap if cp >= 0xA9}
print(f"keeping {len(keep)} of {len(cmap)} codepoints")

opts = subset.Options()
opts.layout_features = ["*"]
opts.name_IDs = ["*"]
opts.notdef_outline = True
opts.recalc_timestamp = False
subsetter = subset.Subsetter(opts)
subsetter.populate(unicodes=keep)
subsetter.subset(font)
font.save(src)

check = TTFont(src)
c2 = set()
for table in check["cmap"].tables:
    c2 |= set(table.cmap.keys())
bad = [hex(c) for c in c2 if c < 0xA9]
print("remaining low codepoints (should be []):", bad)
print("tables:", sorted(check.keys()))
sys.exit(0 if not bad else 1)
