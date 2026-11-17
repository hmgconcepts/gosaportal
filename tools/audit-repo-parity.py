#!/usr/bin/env python3
"""V12.70 — THE THREE REPOS MUST CARRY THE SAME LOGIC.

The two school deployments (gosaportal, schoolconnectdemo) are generated from
this repo. Their pages legitimately differ in BRANDING (school name, motto,
address, phone, email, logo extension) and must be identical in EVERYTHING else.
A fix that reaches only the generator is a fix the schools never receive — that
has happened repeatedly, and it is invisible because the pages still render.

This audit normalises the brand strings away and then compares the files that
carry behaviour. Exit 1 on any unexplained difference.
"""
import re
import sys
from pathlib import Path

GEN = Path(__file__).resolve().parents[1]
SIBLINGS = [GEN.parent / 'gosaportal', GEN.parent / 'schoolconnectdemo']

# files whose content must match the generator exactly
PAGES = ['cbt.html', 'idcards.html', 'fees.html', 'academic_setup.html',
         'report-cards.html', 'midterm-reports.html', 'students.html', 'dashboard.html']
ASSETS = ['assets/js/crud.js', 'assets/js/app.js', 'assets/js/super.js',
          'assets/js/cbt-engine.js', 'assets/js/report-engine.js',
          'assets/js/idcard-pdf.js', 'database/complete-schema.sql',
          'database/complete-schema.manifest.json']
# V12.70: documentation drifts silently and then a client is handed instructions
# that no longer match their build — exactly what had happened to the deployment
# guide's table counts. Docs are part of the shipped product, so they are
# compared like code.
# README.md is deliberately NOT here: each deployment's README names its own
# site and URL, so a difference is correct, not drift.
DOCS = ['docs/FEATURE-CATALOG.md', 'DEPLOYMENT-GUIDE.md']

BRANDS = [
    ('School Connect Demonstration College', 'X'), ('School Connect Demo School', 'X'),
    ('God of Seed Academy', 'X'), ('GOD OF SEED ACADEMY', 'X'),
    ('Excellence in Learning and Character', 'M'),
    ('A fully simulated school — explore every feature', 'M'),
    ('63B, Ishaga Abosule Street, Agbado Crossing, Ogun State', 'A'),
    ('HMG Demo Campus, Lagos, Nigeria', 'A'),
    ('godofseedacademy@gmail.com', 'E'), ('buildingmyictcareer@gmail.com', 'E'),
    ('2348088667076', 'P'), ('08088667076', 'P'), ('+234 810 086 6322', 'P'),
]


def normalise(text):
    for a, b in BRANDS:
        text = text.replace(a, b)
    text = re.sub(r'\b(?:GOSA|GoSA|GSA|SCD)\b', 'SC', text)
    text = re.sub(r'logo(-512)?\.(?:png|jpe?g|webp|svg)', r'logo\1.E', text)
    # V12.73 (item 17) — the install banner names the SCHOOL's portal, because the
    # icon lands on a parent's home screen. "Install School Connect" (vendor) and
    # "Install GoSA" (school) are the same instruction, deliberately different.
    text = re.sub(r'Install (?:School Connect|[A-Za-z][A-Za-z .\'-]{0,30}?)(?=<)', 'Install BRAND', text)
    return text


def main():
    problems = 0
    checked = 0
    for rel in PAGES + ASSETS + DOCS:
        gen = GEN / rel
        if not gen.exists():
            continue
        want = normalise(gen.read_text(encoding='utf-8', errors='ignore'))
        for sib in SIBLINGS:
            if not sib.exists():
                print(f'  SKIP  {sib.name} is not present')
                continue
            f = sib / rel
            checked += 1
            if not f.exists():
                print(f'  FAIL  {sib.name}/{rel} is missing')
                problems += 1
                continue
            got = normalise(f.read_text(encoding='utf-8', errors='ignore'))
            if got != want:
                first = next((i for i, (a, b) in enumerate(zip(want, got)) if a != b), min(len(want), len(got)))
                line = want[:first].count('\n') + 1
                print(f'  FAIL  {sib.name}/{rel} differs from the generator (first at line {line}; '
                      f'{len(want)} vs {len(got)} bytes)')
                problems += 1
    print(f'\nRepo parity audit: {checked} file(s) compared across {len(SIBLINGS)} deployment(s)')
    if problems:
        print(f'  {problems} difference(s) — run: python3 tools/sync-v5-repos.py')
        sys.exit(1)
    print('  ALL PASS — every deployment carries the generator\'s logic (branding aside)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
