#!/usr/bin/env python3
"""V12.76 — vendor every third-party script the product loads from a CDN.

THE PROBLEM
-----------
Every page pulled its runtime from `cdn.jsdelivr.net`:
`@supabase/supabase-js@2` on 184 pages, `chart.js` on 151, `jsqr` and `jszip`
on a handful. Three consequences, all of them the school's:

1. **No internet, no school.** A school with a flaky link — which is most of
   them — gets a blank page, because the whole app is inert until the CDN
   answers. The product calls itself self-contained; a CDN reference is the one
   thing that can still make it fail.
2. **The library can change under their feet.** `@supabase/supabase-js@2` is a
   floating major: the file served today is not the file served last term, with
   no SRI hash pinning it. A bad release would arrive unannounced.
3. **A CDN is a single point of failure shared by every school.**

WHAT THIS DOES
--------------
Downloads each library once, pins it by exact version into `assets/vendor/`,
and rewrites every reference — root pages, page templates, and shared scripts —
to the local file. It also strips the `integrity`/`crossorigin` attributes that
belonged to the CDN copy, and reports every file it touched.

    python3 tools/vendor-cdn-libs.py            # report only
    python3 tools/vendor-cdn-libs.py --apply    # download + rewrite
"""
from __future__ import annotations

import argparse
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'assets' / 'vendor'

# (local file name, download url, list of CDN URLs it replaces)
LIBS = [
    ('supabase-js-2.58.0.js',
     'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.58.0/dist/umd/supabase.js',
     ['https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',
      'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js',
      'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.58.0/dist/umd/supabase.js']),
    ('chart.umd.js',
     'https://cdn.jsdelivr.net/npm/chart.js@4.4.7/dist/chart.umd.js',
     ['https://cdn.jsdelivr.net/npm/chart.js',
      'https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.js',
      'https://cdn.jsdelivr.net/npm/chart.js@4.4.7/dist/chart.umd.js']),
    ('jsqr.min.js',
     'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js',
     ['https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.min.js',
      'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js']),
    ('jszip.min.js',
     'https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js',
     ['https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js']),
]

SCAN_SUFFIXES = ('.html', '.js', '.mjs')


def iter_files():
    for p in ROOT.rglob('*'):
        if not p.is_file() or p.suffix not in SCAN_SUFFIXES:
            continue
        parts = set(p.relative_to(ROOT).parts)
        if parts & {'node_modules', '.git', 'vendor', '__pycache__'}:
            continue
        yield p


def depth_prefix(p: Path) -> str:
    """Relative path from the page's own directory back to the repo root.

    `assets/templates/pages/*.html` is the exception: those files live three
    directories down but are EMITTED AT THE SITE ROOT by the generator, so the
    day this tool wrote `../../../assets/vendor/...` into them it produced 65
    templates whose output pointed outside the site. Templates therefore answer
    '' — root — exactly like the root pages they become.
    """
    rel = p.relative_to(ROOT)
    if rel.parts[:3] == ('assets', 'templates', 'pages'):
        return ''
    return '../' * (len(rel.parts) - 1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--apply', action='store_true')
    args = ap.parse_args()

    if args.apply:
        VENDOR.mkdir(parents=True, exist_ok=True)
        for name, url, _ in LIBS:
            dest = VENDOR / name
            if dest.exists() and dest.stat().st_size > 1000:
                print(f'  have  {name} ({dest.stat().st_size:,} B)')
                continue
            req = urllib.request.Request(url, headers={'User-Agent': 'schoolconnect-vendor/1'})
            with urllib.request.urlopen(req, timeout=60) as r:
                blob = r.read()
            if len(blob) < 1000:
                print(f'  FAIL  {name}: only {len(blob)} bytes from {url}')
                return 2
            dest.write_bytes(blob)
            print(f'  fetch {name} ({len(blob):,} B)')

    changed, refs = [], 0
    for p in iter_files():
        try:
            src = p.read_text(encoding='utf-8')
        except (UnicodeDecodeError, OSError):
            continue
        if 'cdn.jsdelivr.net' not in src and 'unpkg.com' not in src:
            continue
        out = src
        prefix = depth_prefix(p)
        for name, _url, aliases in LIBS:
            for alias in aliases:
                if alias not in out:
                    continue
                refs += out.count(alias)
                out = out.replace(alias, prefix + 'assets/vendor/' + name)
        if out == src:
            continue
        # the CDN copy's integrity hash must go with the CDN copy
        out = re.sub(r'\s+integrity="[^"]*"', '', out)
        out = re.sub(r'\s+crossorigin="(anonymous|use-credentials)"', '', out)
        changed.append(str(p.relative_to(ROOT)))
        if args.apply:
            p.write_text(out, encoding='utf-8')

    print(f'\n  CDN references found : {refs}')
    print(f'  files rewritten      : {len(changed)}')
    for c in changed[:12]:
        print(f'    {c}')
    if len(changed) > 12:
        print(f'    … and {len(changed) - 12} more')
    if not args.apply:
        print('\n  dry run — pass --apply to download and rewrite\n')
        return 0
    leftover = [str(p.relative_to(ROOT)) for p in iter_files()
                if 'cdn.jsdelivr.net' in p.read_text(encoding='utf-8', errors='ignore')]
    print(f'\n  remaining CDN references: {len(leftover)}')
    for f in leftover[:10]:
        print(f'    {f}')
    return 0 if not leftover else 1


if __name__ == '__main__':
    sys.exit(main())
