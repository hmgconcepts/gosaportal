#!/usr/bin/env python3
"""V12.70 — DUPLICATE CONTROLLER MEMBERS (silent dead code).

Why this exists
---------------
The ID-card "print" fix was written, reviewed and shipped — and had no effect,
because an older `printAll()` sat LATER in the same object literal. In
JavaScript the last definition of a duplicate key wins, so the new code was dead
on arrival. Nothing reports it: the file is valid JavaScript, every syntax check
passes, and the function simply never runs. That is how a fix can be "applied"
six times and never once take effect.

How it works
------------
It is a real (small) parser, not a regex sweep. For every `window.X = { ... }`
literal it walks the body tracking (), [] and {} depth, splits the TOP-LEVEL
members on the commas that separate them, and reads each member's key. A nested
payload such as `return { ok: false, error: … }` lives at depth > 0 and is never
mistaken for a member — which is exactly what made an earlier regex version
useless.

Run:  python3 tools/audit-duplicate-methods.py [--self-test]
Exit: 0 = clean, 1 = findings.
"""
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEYWORDS = {'if', 'for', 'while', 'switch', 'catch', 'return', 'function', 'else',
            'do', 'try', 'new', 'typeof', 'delete', 'await', 'yield', 'case', 'with'}


def strip_strings(s):
    """Blank out comments and string bodies so their text cannot look like code."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == '/' and i + 1 < n and s[i + 1] == '/':
            j = s.find('\n', i); i = n if j < 0 else j
        elif c == '/' and i + 1 < n and s[i + 1] == '*':
            j = s.find('*/', i + 2); i = n if j < 0 else j + 2
        elif c in '"\'':
            q = c; i += 1
            while i < n:
                if s[i] == '\\': i += 2; continue
                if s[i] == q: i += 1; break
                i += 1
            out.append('""')
        elif c == '`':
            i += 1
            while i < n:
                if s[i] == '\\': i += 2; continue
                if s[i] == '`': i += 1; break
                i += 1
            out.append('""')
        else:
            out.append(c); i += 1
    return ''.join(out)


def split_top_level(body):
    """Split an object body on the commas that separate its own members."""
    parts, depth, buf, i = [], 0, [], 0
    while i < len(body):
        c = body[i]
        if c in '{([':
            depth += 1
        elif c in '})]':
            depth -= 1
        if c == ',' and depth == 0:
            parts.append(''.join(buf)); buf = []
        else:
            buf.append(c)
        i += 1
    if ''.join(buf).strip():
        parts.append(''.join(buf))
    return parts


def member_key(part):
    p = part.strip()
    if not p:
        return None
    p = re.sub(r'^(?:async|get|set)\s+', '', p)
    # method shorthand `name(`, or a key/value pair `name:` — either form
    m = re.match(r'(#?[A-Za-z_$][\w$]*)\s*[\(:]', p)
    if not m:
        return None
    key = m.group(1)
    return None if key in KEYWORDS else key


def controller_duplicates(raw):
    found = []
    # Any object literal bound to a NAME a handler can call into:
    #   window.X = {…}      const X = {…}      var X = {…}      X = {…}
    # (ID-cards binds `const ICUI = {…}` and exports it later — an audit that
    # only scanned `window.X = {` would skip the very file that had the bug.)
    for m in re.finditer(r'(?:window\s*\.\s*)?\b([A-Za-z_$][\w$]{1,24})\s*=\s*\{', raw):
        obj = m.group(1)
        # Only CONTROLLERS: objects an onclick handler calls into. Those are the
        # ALL-CAPS-ish page names (ICUI, CBTUI, RC, AS, VT, TTG …) or anything
        # published on `window`. A local lookup table (`const map = {…}`) is a
        # data structure, and two of them in one function are perfectly legal.
        published = re.search(r'window\s*\.\s*' + re.escape(obj) + r'\s*=', raw) is not None
        looks_controller = bool(re.match(r'^[A-Z][A-Za-z0-9_]{2,}$', obj))
        if not (published or looks_controller):
            continue
        # The brace scanbelow must count braces inside strings/comments correctly,
        # otherwise a single `'{'` in a message desynchronises it and the "object"
        # swallows the rest of the file (that produced false hits on Super.html).
        i, depth, start = m.end() - 1, 0, m.end()
        q = None
        while i < len(raw):
            ch = raw[i]
            if q:
                if ch == '\\':
                    i += 2; continue
                if ch == q:
                    q = None
            elif ch in '"\'`':
                q = ch
            elif ch == '/' and i + 1 < len(raw) and raw[i + 1] == '/':
                j = raw.find('\n', i); i = len(raw) if j < 0 else j; continue
            elif ch == '/' and i + 1 < len(raw) and raw[i + 1] == '*':
                j = raw.find('*/', i + 2); i = len(raw) if j < 0 else j + 2; continue
            elif ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0: break
            i += 1
        if i >= len(raw):
            continue
        body = strip_strings(raw[start:i])
        keys = [k for k in (member_key(p) for p in split_top_level(body)) if k]
        dup = {k: v for k, v in Counter(keys).items() if v > 1}
        if dup:
            found.append((obj, dup))
    return found


def scan(path):
    try:
        raw = path.read_text(encoding='utf-8', errors='ignore')
    except Exception:
        return []
    if len(raw) > 4_000_000:
        return []
    return controller_duplicates(raw)


def self_test():
    """Prove the detector actually fires — a test that cannot fail is worthless."""
    js = """window.TestCtrl = {
      alpha() { return 1; },
      beta: function () { return { ok: true, error: 'nested payload is not a member' }; },
      async byId(c, t, id) { if (!c) return { ok: false, error: 'x' }; return { ok: true }; },
      gamma() { return [1, 2, 3].map(x => ({ a: x, b: x })); },
      alpha: undefined
    };"""
    hits = controller_duplicates(js)
    ok = bool(hits) and hits[0][0] == 'TestCtrl' and 'alpha' in hits[0][1]
    print(('  PASS  self-test: a repeated member is detected' if ok
           else '  FAIL  self-test: the detector missed a repeated member'))
    clean = """window.CleanCtrl = {
      a() { return { ok: 1, error: 2 }; },
      b() { return { ok: 3, error: 4 }; }
    };"""
    ok2 = not controller_duplicates(clean)
    print(('  PASS  self-test: nested return payloads are NOT counted as members' if ok2
           else '  FAIL  self-test: a nested payload was miscounted'))
    return ok and ok2


if '--self-test' in sys.argv:
    sys.exit(0 if self_test() else 1)

targets = sorted(set(
    list(ROOT.glob('*.html')) +
    list((ROOT / 'assets' / 'templates' / 'pages').glob('*.html')) +
    list((ROOT / 'assets' / 'js').glob('*.js'))
))

findings = 0
for path in targets:
    for obj, dup in scan(path):
        findings += 1
        print(f'  FAIL  {path.relative_to(ROOT)}: window.{obj} defines '
              + ', '.join(f'{k} ×{v}' for k, v in sorted(dup.items())) + ' more than once')

print(f'\nDuplicate controller-member audit: {len(targets)} files checked')
if findings:
    print(f'  {findings} finding(s) — each one is code that can never run')
    sys.exit(1)
print('  ALL PASS — no controller object defines the same member twice')
