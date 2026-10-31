#!/usr/bin/env python3
"""Writes the macOS DMG window layout into scripts/macos_dmg/layout, once, offline.

    python3 make_layout.py BACKGROUND_PNG BACKGROUND_2X_PNG APP_ICON_ICNS

Run on a Mac by a person, never in CI: the release (scripts/build_macos_release.sh)
only copies the committed files, so no layout code runs next to a signing key.
Needs `ds-store` and `mac-alias` (pip, pinned in make_layout.requirements.txt).

The .DS_Store points at the background by an alias that names the volume, so the
release DMG must keep the volume name VOLUME below.
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

from ds_store import DSStore
from mac_alias import Alias

VOLUME = "Hollow"
WINDOW = (660, 400)
ICON_SIZE = 160
APP_POS = (180, 170)
APPLICATIONS_POS = (480, 170)
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "layout")


def run(*cmd):
    subprocess.run(cmd, check=True)


def main(bg, bg2x, icns):
    work = tempfile.mkdtemp(prefix="hollow-dmg-layout.")
    image = os.path.join(work, "layout.dmg")
    mnt = os.path.join(work, "mnt")
    os.mkdir(mnt)
    tiff = os.path.join(work, "background.tiff")
    run("tiffutil", "-cathidpicheck", bg, bg2x, "-out", tiff)
    run("hdiutil", "create", "-quiet", "-size", "20m", "-fs", "HFS+", "-volname", VOLUME, image)
    run("hdiutil", "attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mnt, image)
    try:
        os.mkdir(os.path.join(mnt, ".background"))
        shutil.copyfile(tiff, os.path.join(mnt, ".background", "background.tiff"))
        alias = Alias.for_file(os.path.join(mnt, ".background", "background.tiff"))
        with DSStore.open(os.path.join(mnt, ".DS_Store"), "w+") as d:
            d["."]["bwsp"] = {
                "ShowStatusBar": False,
                "WindowBounds": "{{200, 120}, {%d, %d}}" % WINDOW,
                "ContainerShowSidebar": False,
                "PreviewPaneVisibility": False,
                "SidebarWidth": 180,
                "ShowTabView": False,
                "ShowToolbar": False,
                "ShowPathbar": False,
                "ShowSidebar": False,
            }
            d["."]["icvp"] = {
                "viewOptionsVersion": 1,
                "backgroundType": 2,
                "backgroundImageAlias": alias.to_bytes(),
                "backgroundColorRed": 1.0,
                "backgroundColorGreen": 1.0,
                "backgroundColorBlue": 1.0,
                "gridOffsetX": 0.0,
                "gridOffsetY": 0.0,
                "gridSpacing": 100.0,
                "arrangeBy": "none",
                "showIconPreview": False,
                "showItemInfo": False,
                "labelOnBottom": True,
                "textSize": 12.0,
                "iconSize": float(ICON_SIZE),
                "scrollPositionX": 0.0,
                "scrollPositionY": 0.0,
            }
            d["."]["vSrn"] = ("long", 1)
            d["."]["icvl"] = ("type", b"icnv")
            d["Hollow.app"]["Iloc"] = APP_POS
            d["Applications"]["Iloc"] = APPLICATIONS_POS
        os.makedirs(OUT, exist_ok=True)
        shutil.copyfile(os.path.join(mnt, ".DS_Store"), os.path.join(OUT, "DS_Store"))
    finally:
        run("hdiutil", "detach", "-quiet", mnt)
    shutil.copyfile(tiff, os.path.join(OUT, "background.tiff"))
    shutil.copyfile(icns, os.path.join(OUT, "VolumeIcon.icns"))
    shutil.rmtree(work)
    with open(os.path.join(HERE, "layout.sha256"), "w") as f:
        for name in sorted(os.listdir(OUT)):
            with open(os.path.join(OUT, name), "rb") as g:
                f.write("%s  %s\n" % (hashlib.sha256(g.read()).hexdigest(), name))
    print("wrote", OUT, "and layout.sha256")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*(os.path.abspath(a) for a in sys.argv[1:]))
