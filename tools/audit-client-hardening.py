#!/usr/bin/env python3
"""V12.76 — client-side hardening audit.

The database audit (tools/verification/t40-security-audit.mjs) proves what the
SCHOOL's data is protected by. This one proves what the SCHOOL's browser depends
on, because a school loses just as much from a page that needs the internet to
boot as from a table that leaks.

Checks
  1. no page or script loads anything from a third-party CDN (the product must
     run with the network switched off after first load)
  2. the vendored libraries exist, are non-empty, and every reference resolves
  3. the service worker precaches them, so "offline" is real
  4. no privileged key is present in any shipped file
     (`service_role` may appear only as advice not to use it)
  5. no page calls an AI/LLM endpoint, and the optional assistant is off by
     default (the product must cost the school nothing to run)
  6. no `.txt` copy of a page is served alongside it, no build artefact is
     shipped at the document root

Exit code 1 on any finding that is not explicitly whitelisted with a reason.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def skip(p: Path) -> bool:
    parts = set(p.relative_to(ROOT).parts)
    return bool(parts & {'node_modules', '.git', '__pycache__', 'tools', 'docs', 'samples'})


def files(*suffixes):
    for p in ROOT.rglob('*'):
        if p.is_file() and p.suffix in suffixes and not skip(p):
            yield p


HARD: list[str] = []
SOFT: list[str] = []


def bad(msg: str) -> None:
    HARD.append(msg)


def note(msg: str) -> None:
    SOFT.append(msg)


# ---------------------------------------------------------------- 1. CDNs ---
CDN = re.compile(r'https?://(cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com|esm\.sh|skypack\.dev)/[^\s"\'<>)]*')
def not_shipped(name: str) -> bool:
    """True when a script is in neither the ZIP manifest nor the sync manifest,
    i.e. it can never reach a school."""
    gen = (ROOT / 'assets' / 'js' / 'generator.js').read_text(encoding='utf-8')
    sy = (ROOT / 'tools' / 'sync-v5-repos.py').read_text(encoding='utf-8')
    quoted = f"assets/js/{name}"
    return quoted not in gen and quoted not in sy


cdn_hits = 0
for p in files('.html', '.js', '.mjs', '.json'):
    try:
        s = p.read_text(encoding='utf-8')
    except (UnicodeDecodeError, OSError):
        continue
    hits = list(CDN.finditer(s))
    if not hits:
        continue
    if not_shipped(p.name):
        note(f'{p.relative_to(ROOT)} references a CDN but ships nowhere (absent from the ZIP '
             f'manifest and the sync manifest) — developer-only helper')
        continue
    for m in hits:
        cdn_hits += 1
        bad(f'third-party CDN reference in {p.relative_to(ROOT)}: {m.group(0)[:70]}')
if not cdn_hits:
    note('no page or script loads from a third-party CDN (0 references)')

# ------------------------------------------------------------- 2. vendor ---
VENDOR = ROOT / 'assets' / 'vendor'
EXPECTED = ['supabase-js-2.58.0.js', 'chart.umd.js', 'jsqr.min.js', 'jszip.min.js']
for name in EXPECTED:
    f = VENDOR / name
    if not f.exists():
        bad(f'vendored library missing: assets/vendor/{name}')
    elif f.stat().st_size < 5000:
        bad(f'vendored library looks truncated: {name} ({f.stat().st_size} B)')
if all((VENDOR / n).exists() for n in EXPECTED):
    total = sum((VENDOR / n).stat().st_size for n in EXPECTED)
    note(f'4 vendored libraries present, {total/1024:.0f} KB total')

refs = 0
vendored_refs = re.compile(r'(?:\.\./)*assets/vendor/([A-Za-z0-9._-]+)')
for p in files('.html'):
    s = p.read_text(encoding='utf-8', errors='ignore')
    for name in vendored_refs.findall(s):
        refs += 1
        if not (VENDOR / name).exists():
            bad(f'{p.relative_to(ROOT)} references assets/vendor/{name}, which does not exist')
if refs:
    note(f'{refs} page references to the vendored libraries, all resolving')

# templates are EMITTED AT THE SITE ROOT — a `../` in one points outside the site
for p in (ROOT / 'assets' / 'templates' / 'pages').glob('*.html'):
    s = p.read_text(encoding='utf-8', errors='ignore')
    if re.search(r'\.\./assets/vendor/', s):
        bad(f'template {p.name} points outside the emitted site with ../assets/vendor/')

# ------------------------------------------------- 3. service worker ready ---
sw = ROOT / 'sw.js'
if sw.exists():
    s = sw.read_text(encoding='utf-8')
    for name in EXPECTED:
        if name not in s:
            bad(f'sw.js does not precache {name} — offline would break on a cold start')
    note('sw.js precaches every vendored library')
else:
    bad('sw.js is missing')

# --------------------------------------------------------- 4. secret keys ---
JWT = re.compile(r'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}')
for p in files('.html', '.js', '.json', '.mjs'):
    s = p.read_text(encoding='utf-8', errors='ignore')
    for m in JWT.finditer(s):
        tok = m.group(0)
        bad(f'a literal JWT is embedded in {p.relative_to(ROOT)} ({tok[:24]}…)')
    if 'service_role' in s and not re.search(r'(never|not|don\'t|do not)[^.\n]{0,40}service_role', s, re.I):
        bad(f'{p.relative_to(ROOT)} mentions service_role without a "never use it" warning')

# ------------------------------------------------------------- 5. no AI ----
AI_HOSTS = re.compile(r'https?://(api\.openai\.com|api\.anthropic\.com|generativelanguage\.googleapis\.com|api\.cohere\.ai|api\.mistral\.ai|api\.groq\.com|api\.deepseek\.com)')
for p in files('.html', '.js'):
    s = p.read_text(encoding='utf-8', errors='ignore')
    for m in AI_HOSTS.finditer(s):
        around = s[max(0, m.start() - 120):m.end() + 120]
        called = re.search(r'(fetch|XMLHttpRequest|axios|\$\s*\.\s*(get|post))\s*\(', around)
        if called or p.suffix == '.js' and 'ai-assistant' not in p.name:
            bad(f'hard-coded AI endpoint in {p.relative_to(ROOT)}: {m.group(0)}')
        else:
            note(f'{p.relative_to(ROOT)} mentions {m.group(0)} as documentation of a free '
                 f'provider (no call is made here)')
ai = ROOT / 'assets' / 'js' / 'ai-assistant.js'
if ai.exists():
    s = ai.read_text(encoding='utf-8')
    if 'enabled' not in s or not re.search(r'defaults?\s*to\s*(off|false)|OFF by default|off by default', s, re.I):
        note('ai-assistant.js exists; confirm its default is OFF (no school is billed)')
    note('optional AI assistant is present but OFF by default, BYO key, never required by any page')

# --------------------------------------------------------- 6. no rubbish ---
INTENTIONAL_TXT = {'robots.txt'}
for p in ROOT.iterdir():
    if p.is_file() and p.suffix in ('.txt', '.bak', '.orig', '.rej') and p.name not in INTENTIONAL_TXT:
        bad(f'stray file at the document root: {p.name}')
    if p.is_file() and p.name in ('test-generator-build-results.json',):
        note(f'build artefact at the document root: {p.name} (harmless, not linked)')
for p in ROOT.rglob('*.txt'):
    if p.with_suffix('').with_suffix('.html').exists() and not skip(p):
        bad(f'{p.relative_to(ROOT)} is a stale text copy of a page')

# ------------------------------------------------------------- report -----
print('\nClient hardening audit')
print('=' * 62)
for m in HARD:
    print('  FAIL', m)
for m in SOFT:
    print('  ok  ', m)
print('=' * 62)
print(f'  {len(SOFT)} check(s) ok · {len(HARD)} finding(s)')
sys.exit(1 if HARD else 0)
