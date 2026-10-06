#!/usr/bin/env python3
"""Generate every Hollow app icon from assets/branding/hollow_mark.svg.

The mark is the single source. Sizes from 20 px up are the vector rendered at
that size; 32 and 16 px are drawn pixel by pixel below, because a shrunk
vector blurs the shackle opening and the keyhole into a smudge there.

Needs ImageMagick with librsvg (`magick`) and Pillow.

Usage: python scripts/make_app_icons.py
Then:  dart run flutter_launcher_icons        (Android, from the pubspec)
       python scripts/make_tray_unread_icon.py
"""

import io
import re
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
MARK = ROOT / "assets" / "branding" / "hollow_mark.svg"

TEAL = "#00BFA6"
WHITE = "#FFFFFF"
BG = "#0B0C10"  # the app's chrome surface
MARK_HEIGHT = 0.64  # the mark's share of its tile's height
RADIUS = 0.2237  # a rounded tile's corner radius, as a share of its side

_src = MARK.read_text(encoding="utf-8")
_, _, MW, MH = (float(v) for v in re.search(r'viewBox="([^"]+)"', _src).group(1).split())
D = re.search(r' d="([^"]+)"', _src).group(1)

# '#' mark, '+' half mark, 'o' keyhole, 'x' half keyhole, '.' tile.
# Each grid is (left, top, rows) on its tile and mirror-symmetric.
PX32 = (6, 5, [
    "+#+..............+#+",
    "###....+####+....###",
    "###...+######+...###",
    "###...###..###...###",
    *["###...##+..+##...###"] * 3,
    "###..+########+..###",
    "###..##########..###",
    "#####" + "####oo####" + "#####",
    "#####" + "####oo####" + "#####",
    "#####" + "####xx####" + "#####",
    "###.." + "##########" + "..###",
    "###.." + "+########+" + "..###",
    *["###" + "." * 14 + "###"] * 7,
    "+#+..............+#+",
])
PX16 = (2, 2, [
    "##........##",
    "##..+##+..##",
    "##..#..#..##",
    "##..#..#..##",
    "##.+####+.##",
    "#####oo#####",
    "#####xx#####",
    "##.+####+.##",
    *["##........##"] * 4,
])


def svg(w, h, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:g} {h:g}" '
            f'width="{w:g}" height="{h:g}">\n  {body}\n</svg>\n')


def mark(cx, cy, height, fill=TEAL):
    k = height / MH
    return (f'<path transform="translate({cx - MW * k / 2:.3f} {cy - height / 2:.3f}) '
            f'scale({k:.6f})" fill="{fill}" fill-rule="evenodd" d="{D}"/>')


def tile_svg(side=1024, inset=0.0, rounded=True, height=MARK_HEIGHT, bg=BG, fill=TEAL):
    """A tile with the mark centred; `inset` leaves a transparent margin (macOS)."""
    t = side * (1 - 2 * inset)
    o = side * inset
    body = ""
    if bg:
        rx = f' rx="{t * RADIUS:.2f}"' if rounded else ""
        body = f'<rect x="{o:g}" y="{o:g}" width="{t:g}" height="{t:g}"{rx} fill="{bg}"/>\n  '
    return svg(side, side, body + mark(side / 2, side / 2, t * height, fill))


def render(svg_text, width):
    """Rasterise at the target size, so edges are anti-aliased once, not resampled."""
    native = float(re.search(r'width="([\d.]+)"', svg_text).group(1))
    out = subprocess.run(
        ["magick", "-background", "none", "-density", f"{96 * width / native:.6f}",
         "svg:-", "png:-"],
        input=svg_text.encode(), capture_output=True, check=True).stdout
    img = Image.open(io.BytesIO(out)).convert("RGBA")
    assert img.width == width, (img.size, width)
    return img


def _rgb(hx):
    return tuple(int(hx[i:i + 2], 16) for i in (1, 3, 5))


def _mix(a, b, k):
    return tuple(round(a[i] * (1 - k) + b[i] * k) for i in range(3))


def pixel_tile(size, spec):
    ox, oy, rows = spec
    for row in rows:
        plain = row.replace("+", "#").replace("x", "o")
        assert len(row) == len(rows[0]) and plain == plain[::-1], row
    ss = 8
    corners = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(corners).rounded_rectangle(
        [0, 0, size * ss - 1, size * ss - 1], radius=round(size * RADIUS * ss), fill=255)
    bg, fg = _rgb(BG), _rgb(TEAL)
    paint = {"#": fg, "+": _mix(bg, fg, 0.5), "o": bg, "x": _mix(fg, bg, 0.55)}
    img = Image.new("RGBA", (size, size), bg + (255,))
    px = img.load()
    for j, row in enumerate(rows):
        for i, ch in enumerate(row):
            if ch in paint:
                px[ox + i, oy + j] = paint[ch] + (255,)
    img.putalpha(corners.resize((size, size), Image.LANCZOS))
    return img


def write_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    print("wrote", path.relative_to(ROOT))


def save(img, path, **kw):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, **kw)
    print("wrote", path.relative_to(ROOT))


def tile(size):
    if size == 32:
        return pixel_tile(32, PX32)
    if size == 16:
        return pixel_tile(16, PX16)
    return render(tile_svg(), size)


def windows():
    sizes = [256, 128, 64, 48, 32, 24, 20, 16]
    frames = [tile(s) for s in sizes]
    for dst in (ROOT / "assets" / "app_icon.ico",
                ROOT / "windows" / "runner" / "resources" / "app_icon.ico"):
        save(frames[0], dst, format="ICO", sizes=[(s, s) for s in sizes],
             append_images=frames[1:])


def android():
    a = ROOT / "assets"
    save(render(tile_svg(rounded=False), 1024), a / "hollow_icon_android.png")
    # The launcher insets the foreground 16%, which lands the mark inside the
    # 66 dp safe circle.
    save(render(tile_svg(rounded=False, bg=None), 1024), a / "hollow_icon_android_foreground.png")
    save(render(tile_svg(rounded=False, bg=None, fill=WHITE), 1024),
         a / "hollow_icon_android_monochrome.png")
    side = MH * 24 / 20  # the mark 20 dp tall on the 24 dp status-bar canvas
    write_text(ROOT / "android/app/src/main/res/drawable/ic_stat_hollow.xml", f'''\
<?xml version="1.0" encoding="utf-8"?>
<!--
  Status-bar notification icon, generated by scripts/make_app_icons.py. Android
  keeps only the alpha of a notification icon and draws it as a flat silhouette.
  Pointed at by AndroidInitializationSettings('@drawable/ic_stat_hollow').
-->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="{side:g}"
    android:viewportHeight="{side:g}"
    android:tint="#FFFFFF">
    <group
        android:translateX="{(side - MW) / 2:g}"
        android:translateY="{(side - MH) / 2:g}">
        <path
            android:fillColor="#FFFFFF"
            android:fillType="evenOdd"
            android:pathData="{D}" />
    </group>
</vector>
''')


def apple():
    mac = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for s in (16, 32, 64, 128, 256, 512, 1024):
        # Apple's macOS grid: an 824 px tile on the 1024 px canvas.
        save(render(tile_svg(inset=100 / 1024), s), mac / f"app_icon_{s}.png")
    ios = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for f in sorted(ios.glob("Icon-App-*.png")):
        pt, scale = re.match(r"Icon-App-([\d.]+)x[\d.]+@(\d)x\.png", f.name).groups()
        s = round(float(pt) * int(scale))
        # iOS masks the corners itself and rejects an icon with alpha.
        save(render(tile_svg(rounded=False), s).convert("RGB"), f)


def web():
    w = ROOT / "web"
    save(pixel_tile(16, PX16), w / "favicon.png")
    for s in (192, 512):
        save(render(tile_svg(), s), w / "icons" / f"Icon-{s}.png")
        # Maskable icons keep everything inside the central 80% circle.
        save(render(tile_svg(rounded=False, height=0.56), s), w / "icons" / f"Icon-maskable-{s}.png")


def shared():
    a = ROOT / "assets"
    write_text(a / "hollow_main_logo.svg", tile_svg(rounded=False))
    write_text(a / "hollow_icon_foreground.svg", tile_svg(rounded=False, bg=None))
    # README, the About and Welcome dialogs, the Linux window and its desktop icon.
    save(render(tile_svg(side=1000), 1000), a / "hollow_logo_rounded.png")


def installer():
    i = ROOT / "installer" / "assets"
    small = svg(110, 110, mark(55, 55, 110 * 0.84))
    write_text(i / "wizard_small.svg", small)
    save(render(small, 55), i / "wizard_small.png")
    save(render(small, 110), i / "wizard_small@2x.png")
    banner = svg(328, 628, f'<rect width="328" height="628" fill="{BG}"/>\n  '
                 + mark(164, 314, 190))
    write_text(i / "wizard_banner.svg", banner)
    save(render(banner, 328).convert("RGB"), i / "wizard_banner.bmp")


if __name__ == "__main__":
    shared()
    windows()
    android()
    apple()
    web()
    installer()
