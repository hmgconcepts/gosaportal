#!/usr/bin/env python3
"""Fail when a page template has fallen behind the root page it mirrors.

V12.72 shipped with cbt-exam.html, cbt.html and profile.html behind their
templates. The sync tool warned about it, the warning scrolled past, and two of
the five Round-16 items reached the generator but never reached a client.
A warning is not a gate. This is.
"""
import sys
from pathlib import Path

GEN = Path(__file__).resolve().parents[1]
TPL = GEN / 'assets' / 'templates' / 'pages'

# Deliberate forks: the root page is the VENDOR's page, the template is the
# SCHOOL's page. Copying one over the other would rebrand a school's sign-in
# page as the vendor's homepage.
FORKED = {'index.html', 'login.html'}

# Some templates are renamed on the way out. The sync tool maps
# `ecosystem-products.html` to `ecosystem.html` for the client, so the root page
# legitimately has a different name. Mirrors the `aliases` table in
# tools/sync-v5-repos.py — keep the two in step.
ALIASED = {'ecosystem-products.html': 'ecosystem.html'}

# School-specific pages that exist ONLY as a template. They have no vendor
# counterpart in the generator root because the vendor does not sell its own
# fee structure or product list. Verified to reach both client deployments.
STANDALONE = {'hmg_digital_products.html', 'school_fees.html',
              'school_products.html', 'status_manager.html'}

stale, missing = [], []
for t in sorted(TPL.glob('*.html')):
    if t.name in STANDALONE:
        continue
    r = GEN / ALIASED.get(t.name, t.name)
    if not r.exists():
        missing.append(t.name)
        continue
    if t.name in FORKED:
        continue
    a = set(r.read_text(encoding='utf-8').splitlines())
    b = set(t.read_text(encoding='utf-8').splitlines())
    if a - b:
        stale.append((t.name, len(a - b)))

if stale or missing:
    print('  FAIL: a client would ship an older version of these pages.')
    for name, n in stale:
        print(f'    - {name}: the root page has {n} line(s) the template lacks')
    for name in missing:
        print(f'    - {name}: the template exists but the root page does not')
    print('  Fix: copy the root page over its template, then re-run the sync.')
    sys.exit(1)

count = len(list(TPL.glob('*.html'))) - len(FORKED & {p.name for p in TPL.glob('*.html')})
print(f'  ALL PASS — every one of {count} page template(s) matches the page it mirrors.')
