"""Writes the album fleet scenario's fixtures into build/album_fixtures.

Three flat-colour stills and one large noisy animated GIF. The GIF's animated
WebP encode is far slower than a still's, which is what exposed album items
reordering by conversion time (fleet scenario album_dm). Needs Pillow.
"""
import pathlib
import random

from PIL import Image

out = pathlib.Path(__file__).resolve().parent.parent / "build" / "album_fixtures"
out.mkdir(parents=True, exist_ok=True)

Image.new("RGB", (640, 480), (220, 30, 30)).save(out / "red.png")
Image.new("RGB", (480, 640), (30, 60, 220)).save(out / "blue.png")
Image.new("RGB", (500, 500), (240, 200, 20)).save(out / "yellow.png")

random.seed(7)
frames = []
for _ in range(40):
    frame = Image.new("RGB", (480, 360))
    px = frame.load()
    for y in range(360):
        for x in range(480):
            px[x, y] = (0, random.randint(80, 255), random.randint(0, 60))
    frames.append(frame)
frames[0].save(out / "green_noise.gif", save_all=True, append_images=frames[1:],
               duration=60, loop=0)
print(f"wrote fixtures to {out}")
