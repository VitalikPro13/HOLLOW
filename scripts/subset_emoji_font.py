"""Subset assets/fonts/NotoColorEmoji.ttf to emoji-only and derive
assets/fonts/NotoColorEmojiFlags.ttf from it. Run after replacing the font
with a fresh upstream copy (googlefonts/noto-emoji, 2D/fonts/NotoColorEmoji.ttf);
the committed files are already subset.

The upstream font maps space, CR, digits, '#' and '*' (keycap components)
with huge bitmap advances. As a Flutter fontFamilyFallback next to a null
fontFamily it ends up serving those ASCII glyphs, exploding word spacing
(spaces + digits rendered emoji-wide). Dropping every codepoint below
U+00A9 makes it emoji-only; keycap emoji fall through to the system emoji
font (they're Emoji 3.0-era, present everywhere).

The flags file holds only regional indicators, the black flag and the tag
characters (country and subdivision flags). Windows puts it ahead of the
system Segoe UI Emoji (#104), which has no flags and would otherwise draw a
flag as two letters.

Requires: pip install fonttools
usage: subset_emoji_font.py [font dir, default assets/fonts]
"""
import os
import sys
from fontTools import subset
from fontTools.ttLib import TTFont

FLAG_CODEPOINTS = (set(range(0x1F1E6, 0x1F200))  # regional indicators
                   | {0x1F3F4}                    # black flag
                   | set(range(0xE0020, 0xE0080)))  # tag characters


def codepoints(path):
    cmap = set()
    for table in TTFont(path)["cmap"].tables:
        cmap |= set(table.cmap.keys())
    return cmap


def subset_to(src, dst, unicodes):
    font = TTFont(src)
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    opts.recalc_timestamp = False
    subsetter = subset.Subsetter(opts)
    subsetter.populate(unicodes=unicodes)
    subsetter.subset(font)
    font.save(dst)


root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "fonts")
src = os.path.join(root, "NotoColorEmoji.ttf")
flags = os.path.join(root, "NotoColorEmojiFlags.ttf")

cmap = codepoints(src)
low = sorted(cp for cp in cmap if cp < 0xA9)
print("dropping low codepoints:", [hex(c) for c in low])
keep = {cp for cp in cmap if cp >= 0xA9}
print(f"keeping {len(keep)} of {len(cmap)} codepoints")
if low:
    subset_to(src, src, keep)
else:
    print("already emoji-only, left as is")

subset_to(src, flags, FLAG_CODEPOINTS & keep)

bad = [hex(c) for c in codepoints(src) | codepoints(flags) if c < 0xA9]
print("remaining low codepoints (should be []):", bad)
print("flags file codepoints:", len(codepoints(flags)))
print("tables:", sorted(TTFont(src).keys()))
sys.exit(0 if not bad else 1)
