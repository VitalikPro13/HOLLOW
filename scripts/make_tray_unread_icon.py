#!/usr/bin/env python3
"""Generate assets/app_icon_unread.ico — the tray icon with a red unread dot.

Composites a notification dot onto the bottom-right corner of every frame of
assets/app_icon.ico. The dot is drawn per-size (not downscaled from one big
frame) so it stays crisp at the 16px size Windows actually shows in the tray.
A transparent ring is cut out of the logo behind the dot so it reads as a
badge instead of blending into the artwork.

Usage: python scripts/make_tray_unread_icon.py
Rerun whenever assets/app_icon.ico changes.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "app_icon.ico"
DST = ROOT / "assets" / "app_icon_unread.ico"

DOT_COLOR = (242, 63, 66, 255)  # notification red
SIZES = [16, 24, 32, 48, 64, 128, 256]
SS = 4  # supersampling factor for smooth circle edges at tiny sizes


def badge(base: Image.Image, size: int) -> Image.Image:
    img = base.resize((size, size), Image.LANCZOS).convert("RGBA")
    w = size * SS
    d = round(size * 0.42) * SS  # dot diameter ~42% of icon
    ring = max(SS, round(d * 0.14))  # transparent gap around the dot

    # Cut a transparent circle (dot + ring) out of the bottom-right corner.
    cut = Image.new("L", (w, w), 0)
    ImageDraw.Draw(cut).ellipse([w - d - 2 * ring, w - d - 2 * ring, w, w], fill=255)
    img.paste((0, 0, 0, 0), (0, 0), cut.resize((size, size), Image.LANCZOS))

    # Draw the red dot centred in the cutout.
    dot = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    ImageDraw.Draw(dot).ellipse(
        [w - d - ring, w - d - ring, w - ring, w - ring], fill=DOT_COLOR
    )
    img.alpha_composite(dot.resize((size, size), Image.LANCZOS))
    return img


def main() -> None:
    base = Image.open(SRC).convert("RGBA")  # opens the largest frame
    frames = [badge(base, s) for s in SIZES]
    frames[-1].save(
        DST,
        format="ICO",
        append_images=frames[:-1],
        sizes=[(s, s) for s in SIZES],
    )
    print(f"Wrote {DST} ({DST.stat().st_size} bytes) with sizes {SIZES}")


if __name__ == "__main__":
    main()
