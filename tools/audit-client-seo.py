#!/usr/bin/env python3
"""A client deployment must never claim the vendor's site as its canonical page.

V12.72 — both schools shipped `<link rel="canonical"
href="https://schoolconnectportal.vercel.app/...">` on suite.html and
ecosystem.html. That tells a search engine the authoritative copy of the
school's own page is the vendor's site, so the school's page is indexed as a
duplicate and loses its ranking to us. A wrong canonical is worse than none.
"""
import re
import sys
from pathlib import Path

GEN = Path(__file__).resolve().parents[1]
ROOT = GEN.parent
CLIENTS = [d for d in ('gosaportal', 'schoolconnectdemo') if (ROOT / d).exists()]
VENDOR = 'schoolconnectportal.vercel.app'
CANON = re.compile(r'<link[^>]+rel="canonical"[^>]*>', re.I)

bad = []
for client in CLIENTS:
    for page in sorted((ROOT / client).glob('*.html')):
        text = page.read_text(encoding='utf-8', errors='ignore')
        for m in CANON.finditer(text):
            if VENDOR in m.group(0):
                bad.append(f'{client}/{page.name}: {m.group(0)[:90]}')

if bad:
    print('  FAIL: a client deployment names the vendor site as its canonical page.')
    for b in bad:
        print('    - ' + b)
    print('  A search engine will treat the school page as a duplicate of the vendor.')
    sys.exit(1)

total = sum(len(list((ROOT / c).glob('*.html'))) for c in CLIENTS)
print(f'  ALL PASS — no canonical link on any of {total} client page(s) points at the vendor.')
