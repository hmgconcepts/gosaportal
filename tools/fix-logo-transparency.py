#!/usr/bin/env python3
"""Give a school's on-page logo a genuinely transparent background.

WHY THIS EXISTS
---------------
V12.73 item 16/17: the God of Seed Academy sidebar and install banner showed the
crest inside a BLACK SQUARE. The cause was not styling — it was the file.

  assets/img/logo-512.jpg is a JPEG. JPEG has no alpha channel.

The crest had been exported with a transparent field, flattened to JPEG for use
as a favicon and PWA icon, and then used as the page-header <img> as well. Every
transparent pixel became black, so 44,171 pixels around the crest rendered as a
black tile. No CSS fix is possible: the data is already lost in that file.

THE FIX
-------
Two files, two jobs, and pages must use the right one:

  logo-512.png  RGBA, crest on a transparent field  -> every on-page <img>
  logo-512.jpg  the same crest floored on WHITE      -> favicon, PWA icon,
                                                       og:image (a social card
                                                       needs an opaque tile,
                                                       but it must not be black)

A black icon tile reads as a broken image on a phone home screen; white reads
as intentional and matches every other icon the platform ships.

Run from the repo root. Idempotent: re-running re-derives both from logo.png.
"""
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print('  SKIP — Pillow is not installed (pip install pillow)')
    sys.exit(0)

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'assets' / 'img' / 'logo.png'

if not SRC.exists():
    print(f'  SKIP — no {SRC.name} to derive from')
    sys.exit(0)

src = Image.open(SRC).convert('RGBA')
# A square crest is the normal case. A wide logo (the demo college's banner) is
# already opaque and needs no circular mask, so leave its own alpha alone.
if src.size[0] != src.size[1] or src.getchannel('A').getextrema() == (255, 255):
    print(f'  KEEP — {SRC.name} is {src.size[0]}x{src.size[1]} and opaque; nothing to unflatten')
    sys.exit(0)

import numpy as np
a = np.array(src).astype(np.int16)
H, W, _ = a.shape
cy, cx = (H - 1) / 2, (W - 1) / 2
r = min(H, W) / 2 - 1
yy, xx = np.mgrid[0:H, 0:W]
d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
alpha = np.clip((r - d) / 1.2 + 0.5, 0, 1)
a[:, :, 3] = (alpha * 255).astype(np.int16)

png = Image.fromarray(a.astype(np.uint8), 'RGBA')
png.save(ROOT / 'assets' / 'img' / 'logo-512.png')

tiled = Image.new('RGBA', png.size, (255, 255, 255, 255))
tiled.alpha_composite(png)
tiled.convert('RGB').save(ROOT / 'assets' / 'img' / 'logo-512.jpg', quality=92)

print(f'  DONE — transparent logo-512.png + white-tile logo-512.jpg from {SRC.name}')
