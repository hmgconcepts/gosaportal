#!/usr/bin/env python3
"""
Asset branding audit — did one deployment's images replace another's?

WHY THIS EXISTS
---------------
Reported defect (V12.71, item 1): "in assets/img of the gosa portal repo, some
files from the school connect demo have replaced some image files of the gosa
portal."

That was exactly right, and it was worse than it looked:

  gosaportal/assets/img/logo-512.jpg was byte-identical to the demo site's copy
  — a generic "graduation cap" app icon — while the real God of Seed Academy
  crest lived only in logo.png. 105 pages used logo-512.jpg as the school's own
  logo (a page-header <img>), and another set used it as the favicon and the
  og:image. So the client's portal displayed the DEMO's logo on every page, and
  every shared link to their site previewed somebody else's badge.

WHY A CHECK IS NEEDED RATHER THAN A FIX
---------------------------------------
The sync tool copies pages between deployments; a careless copy of an image
folder can silently re-pollute them, and nothing in the test suite compared
binary assets between deployments. Nothing would have caught it twice.

WHAT "POLLUTED" MEANS HERE
--------------------------
Not "the files differ" — logos are SUPPOSED to differ. Pollution is the
specific, detectable mistake: a BRAND-CRITICAL asset that is byte-identical
across two deployments. If two different schools ship the same bytes for the
asset that carries their identity, at most one of them can be right.

Brand-neutral assets (product marketing, shared signature graphics, ecosystem
flyers) are exempt because they are genuinely the same everywhere.
"""
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUITE = ROOT.parent
DEPLOYMENTS = [d for d in (ROOT, SUITE / 'gosaportal', SUITE / 'schoolconnectdemo') if d.exists()]

# Files that carry a school's IDENTITY. Two different schools must never share
# these byte-for-byte.
BRAND_CRITICAL = {
    'logo-512.jpg', 'logo-512.png', 'logo.png', 'logo.jpg', 'logo.webp',
    'favicon.svg', 'favicon.png', 'favicon.ico', 'apple-touch-icon.png',
}
# Brand-neutral by design: product marketing and shared graphics.
BRAND_NEUTRAL = {
    'og-cover.svg',            # "School Connect" product card, same for everyone
    'demo-signature.svg',      # signature-pad sample
    'hmg-technologies.svg',    # the vendor's mark
    'founder-adewale.jpg',     # vendor's founder photo
}

problems = []
digests = {}

for dep in DEPLOYMENTS:
    img = dep / 'assets' / 'img'
    if not img.is_dir():
        continue
    for f in sorted(img.iterdir()):
        if not f.is_file() or f.name in BRAND_NEUTRAL:
            continue
        digest = hashlib.md5(f.read_bytes()).hexdigest()
        digests.setdefault(f.name, {})[dep.name] = digest

# Report brand-critical assets shared across deployments
for name, per_dep in sorted(digests.items()):
    if name not in BRAND_CRITICAL:
        continue
    if len(per_dep) < 2:
        continue
    values = set(per_dep.values())
    if len(values) == 1:
        problems.append(
            f'{name}: byte-identical in {", ".join(sorted(per_dep))} — '
            f'a school identity asset cannot be shared; at most one deployment is correct'
        )

# A brand-critical file present in one deployment and missing from another is
# fine (not every deployment ships every format) — only sharing is a defect.

print(f"\nAsset branding audit: {len(digests)} asset(s) compared across {len(DEPLOYMENTS)} deployment(s)")
if problems:
    print(f"  {len(problems)} problem(s):")
    for p in problems:
        print('   -', p)
    sys.exit(1)

print("  ALL PASS — no school-identity asset is shared between deployments.")
sys.exit(0)
