#!/usr/bin/env python3
"""V12.68 — ONE FILE ONLY.

The school must never be told to run a second SQL file. Every release since
V6 shipped its own `database/vX.Y-....sql` pack, and the UI learned to say
"run database/v10.1-....sql" whenever a call failed. Those messages are now
wrong twice over: the packs are all folded into `database/complete-schema.sql`,
and the real cause of a failed call is almost always a stale API cache.

This audit fails the build if any page or runtime script still instructs a
human to run something else.

Exit code 0 = every instruction points at complete-schema.sql.
"""
from __future__ import annotations
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
# Where a human-facing instruction can live. tools/ and database/ are excluded:
# the pack files themselves are kept for the historical record.
SCAN = [ROOT / '*.html', ROOT / 'assets/js/*.js', ROOT / 'assets/templates/pages/*.html',
        ROOT / 'assets/templates/pages/*.js']

# generator.js lists the files it COPIES INTO a generated site; that is a build
# manifest, not an instruction to a school. report-engine.js only cites a pack in
# a code comment describing where a rule came from.
ALLOW_FILES = {'assets/js/generator.js', 'assets/js/report-engine.js'}

OLD_PACK = re.compile(r'database/(?!complete-schema\.sql)[a-z0-9][a-z0-9._-]*\.sql', re.I)
INSTRUCTION = re.compile(r'\b(run|re-?run|execute|apply|install|install(ed)?|missing|needs?|'
                         r'required|first|update needed|database step)\b', re.I)

def lines_of(p: pathlib.Path):
    try:
        return p.read_text(errors='replace').split('\n')
    except Exception:
        return []

bad = []
for pat in SCAN:
    for f in sorted(ROOT.glob(str(pat.relative_to(ROOT)))):
        rel = str(f.relative_to(ROOT))
        if rel in ALLOW_FILES:
            continue
        for n, line in enumerate(lines_of(f), 1):
            if not OLD_PACK.search(line):
                continue
            if not INSTRUCTION.search(line):
                continue
            # a plain reference (e.g. "needs database/v9.4") is still an instruction
            bad.append((rel, n, line.strip()[:150]))

print(f'\n  School Connect — single-SQL audit\n  ' + '-' * 52)
if bad:
    for rel, n, txt in bad:
        print(f'  FAIL  {rel}:{n}')
        print(f'        {txt}')
    print(f'\n  {len(bad)} instruction(s) still point at a file other than complete-schema.sql\n')
    sys.exit(1)
print('  ALL PASS — every user-facing instruction points at database/complete-schema.sql\n')
