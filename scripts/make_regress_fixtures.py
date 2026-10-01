"""Writes the regress fleet scenarios' fixtures into build/regress_fixtures.

regress_media.json sends four files over a DM:

  regress_clip.mp4      4 s, 640x360 H.264, no audio track: the video bubble.
  regress_gate_6mb.bin  6 MiB of random bytes: the auto-download gate, under the
                        34 MiB direct-transfer cap. The card reads "6.0 MB".
  regress_big_40mb.bin  40 MiB of random bytes: over the 34 MiB cap, so it rides a
                        Hollow Share. The card reads "40.0 MB".
  Voice message.ogg     3 s of a quiet tone as Opus in Ogg. The exact name is what
                        marks a voice note on the wire, so it must not change.

The .bin files need only the standard library. The clip needs an ffmpeg with
libx264 and the voice note one with libopus, looked up in this order: the FFMPEG
environment variable, ffmpeg on PATH, C:/ffmpeg/bin/ffmpeg.exe, then the repo's
vendor/ffmpeg build (libopus only). With no libx264 the clip falls back to a copy
of build/mopup_fixtures/probe_clip.mp4, which carries an AAC tone. Needs Pillow.
"""
import math
import os
import pathlib
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import wave

from PIL import Image, ImageDraw

REPO = pathlib.Path(__file__).resolve().parent.parent
OUT = REPO / "build" / "regress_fixtures"
MIB = 1024 * 1024


def write_random(path, size, seed):
    rng = random.Random(seed)
    with open(path, "wb") as f:
        left = size
        while left:
            n = min(left, MIB)
            f.write(rng.randbytes(n))
            left -= n


def ffmpeg_candidates():
    found = []
    for c in (
        os.environ.get("FFMPEG"),
        shutil.which("ffmpeg"),
        "C:/ffmpeg/bin/ffmpeg.exe",
        str(REPO / "vendor" / "ffmpeg" / "ffmpeg-win-x64.exe"),
    ):
        if c and pathlib.Path(c).is_file() and c not in found:
            found.append(c)
    return found


def ffmpeg_with(encoder):
    for ffmpeg in ffmpeg_candidates():
        try:
            listing = subprocess.run(
                [ffmpeg, "-hide_banner", "-encoders"],
                capture_output=True, encoding="utf-8", errors="replace", timeout=60,
            ).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        if re.search(rf"\s{re.escape(encoder)}\s", listing):
            return ffmpeg
    return None


def run(cmd):
    result = subprocess.run(cmd, capture_output=True, encoding="utf-8", errors="replace")
    if result.returncode != 0:
        raise RuntimeError(f"{cmd[0]} failed: {result.stderr.strip()[-600:]}")


def make_clip(path):
    ffmpeg = ffmpeg_with("libx264")
    if ffmpeg:
        with tempfile.TemporaryDirectory() as tmp:
            for i in range(120):
                frame = Image.new("RGB", (640, 360), (24, 24, 32))
                draw = ImageDraw.Draw(frame)
                x = int(i * (640 - 96) / 119)
                draw.rectangle([x, 132, x + 96, 228], fill=(220, 70, 70))
                draw.text((16, 16), f"regress clip {i:03d}", fill=(235, 235, 235))
                frame.save(os.path.join(tmp, f"f{i:03d}.png"))
            run([
                ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
                "-framerate", "30", "-i", os.path.join(tmp, "f%03d.png"),
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                "-an", str(path),
            ])
        return f"encoded with {ffmpeg}"
    fallback = REPO / "build" / "mopup_fixtures" / "probe_clip.mp4"
    if fallback.is_file():
        shutil.copyfile(fallback, path)
        return f"copied {fallback} (no libx264 found; this clip has an audio track)"
    return None


def make_voice_note(path):
    ffmpeg = ffmpeg_with("libopus")
    if not ffmpeg:
        return None
    rate = 48000
    with tempfile.TemporaryDirectory() as tmp:
        tone = os.path.join(tmp, "tone.wav")
        samples = bytearray()
        for n in range(rate * 3):
            # About -40 dBFS: audible proof of playback, never loud on a shared machine.
            samples += struct.pack("<h", int(320 * math.sin(2 * math.pi * 330 * n / rate)))
        with wave.open(tone, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(bytes(samples))
        run([
            ffmpeg, "-y", "-hide_banner", "-loglevel", "error", "-i", tone,
            "-c:a", "libopus", "-b:a", "24k", "-ac", "1", "-ar", "48000", str(path),
        ])
    return f"encoded with {ffmpeg}"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    missing = []

    write_random(OUT / "regress_gate_6mb.bin", 6 * MIB, seed=6)
    write_random(OUT / "regress_big_40mb.bin", 40 * MIB, seed=40)
    print("wrote regress_gate_6mb.bin and regress_big_40mb.bin")

    how = make_clip(OUT / "regress_clip.mp4")
    if how:
        print(f"wrote regress_clip.mp4 ({how})")
    else:
        missing.append("regress_clip.mp4 (needs an ffmpeg with libx264, or build/mopup_fixtures/probe_clip.mp4)")

    how = make_voice_note(OUT / "Voice message.ogg")
    if how:
        print(f"wrote Voice message.ogg ({how})")
    else:
        missing.append("Voice message.ogg (needs an ffmpeg with libopus)")

    print(f"fixtures in {OUT}")
    if missing:
        print("NOT written: " + "; ".join(missing), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
