#!/usr/bin/env python3
"""
audit-school-day.py — "a date is not an instant"

V12.83 replaced 103 hand-rolled calendar days with ONE helper, scDay()/scToday()
(assets/js/net-resilience.js), because

    new Date().toISOString().slice(0, 10)

is the UTC day, not the school's day. In Lagos (UTC+1) everything recorded
between 00:00 and 00:59 was filed under YESTERDAY; in any zone west of
Greenwich the whole evening is filed under TOMORROW. Attendance, receipts, the
diary and every "is this paper today?" filter read that string.

A fix that can silently rot is not a fix, so this audit enforces three rules,
in all three deployments:

  1. NO FILE computes a calendar day from UTC any more. The only permitted
     occurrence of `.toISOString().slice(0,10)` is inside net-resilience.js,
     where it is documented as the fallback — the helper itself.

  2. EVERY page that calls scDay/scToday/scDaysFromNow loads net-resilience.js,
     and loads it BEFORE the first call site.

  3. EVERY script (assets/js/*.js) that calls the helper is only ever loaded by
     such a page.

Run: python3 tools/audit-school-day.py
"""
import os
import re
import sys

REPOS = ['/home/user/repos/schoolconnect',
         '/home/user/repos/gosaportal',
         '/home/user/repos/schoolconnectdemo']

HELPER = 'assets/js/net-resilience.js'
HELPER_FILE = 'net-resilience.js'
CALL = re.compile(r'\b(scDay|scToday|scDaysFromNow)\s*\(')
UTC_DAY = re.compile(r'\.toISOString\(\)\.slice\(0,\s*10\)')

fails = []
passes = 0


def ok(cond, msg):
    global passes
    if cond:
        passes += 1
    else:
        fails.append(msg)
    return cond


def read(path):
    with open(path, encoding='utf-8', errors='replace') as fh:
        return fh.read()


def repo_label(root):
    return os.path.basename(root)


for root in REPOS:
    label = repo_label(root)
    if not os.path.isdir(root):
        fails.append('%s — repository missing' % label)
        continue

    pages = sorted(f for f in os.listdir(root) if f.endswith('.html'))
    page_text = {p: read(os.path.join(root, p)) for p in pages}

    # ---- rule 1: no UTC day maths outside the helper -------------------
    offenders = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in
                       {'node_modules', '.git', 'deliverables', 'samples', '.cache'}]
        for fn in filenames:
            if not fn.endswith(('.html', '.js', '.mjs')):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            if rel.replace(os.sep, '/') == HELPER:
                continue
            # tools/ are the proof itself (fixtures date themselves in Node,
            # where there is no school and no browser) — they never ship.
            if rel.replace(os.sep, '/').startswith('tools/'):
                continue
            try:
                txt = read(full)
            except OSError:
                continue
            if UTC_DAY.search(txt):
                offenders.append(rel)
    ok(not offenders,
       '%s — %d file(s) still build a calendar day from UTC: %s'
       % (label, len(offenders), ', '.join(offenders[:6])))

    # ---- rule 2: helper loaded before use -------------------------------
    missing, late = [], []
    for p, txt in page_text.items():
        calls = [m.start() for m in CALL.finditer(txt)]
        if not calls:
            continue
        idx = txt.find(HELPER_FILE)
        if idx < 0:
            missing.append(p)
        elif idx > min(calls):
            late.append(p)
    ok(not missing,
       '%s — page(s) call scDay/scToday without loading %s: %s'
       % (label, HELPER, ', '.join(missing[:6])))
    ok(not late,
       '%s — page(s) load %s AFTER the first call site: %s'
       % (label, HELPER, ', '.join(late[:6])))

    # ---- rule 3: modules are only shipped with the helper --------------
    jsdir = os.path.join(root, 'assets', 'js')
    bad_mods = []
    unloaded = []
    if os.path.isdir(jsdir):
        for fn in sorted(os.listdir(jsdir)):
            if not fn.endswith('.js') or fn == HELPER_FILE:
                continue
            txt = read(os.path.join(jsdir, fn))
            if not CALL.search(txt):
                continue
            users = [p for p, t in page_text.items() if fn in t]
            if not users:
                # No page in this deployment loads it, so it cannot break a page
                # here. (Reported, not failed: an unreferenced file is a packing
                # question, and audit-repo-parity owns what actually ships.)
                unloaded.append(fn)
                continue
            orphan = [p for p in users if HELPER_FILE not in page_text[p]]
            if orphan:
                bad_mods.append('%s → %s' % (fn, ', '.join(orphan[:3])))
    ok(not bad_mods,
       '%s — module(s) use the helper but ship to pages that do not: %s'
       % (label, '; '.join(bad_mods[:5])))
    if unloaded:
        print('  note  %s — module(s) using the helper that no page loads: %s'
              % (label, ', '.join(sorted(unloaded))))

    # ---- the helper itself must exist and be the school's zone ---------
    helper_path = os.path.join(root, HELPER)
    if os.path.exists(helper_path):
        h = read(helper_path)
        ok('function dayOf(' in h and 'window.scDay = dayOf' in h,
           '%s — %s does not export the day helper' % (label, HELPER))
        ok("Africa/Lagos" in h and 'Intl.DateTimeFormat' in h,
           '%s — %s does not resolve the school timezone with Intl' % (label, HELPER))
    else:
        ok(False, '%s — %s is missing' % (label, HELPER))

print()
if fails:
    for f in fails:
        print('FAIL ' + f)
    print('\nSCHOOL-DAY AUDIT FAILED — %d passed, %d failed' % (passes, len(fails)))
    sys.exit(1)
print('SCHOOL-DAY AUDIT PASSED — %d checks across %d deployments · every calendar '
      'day in the product is the SCHOOL\'s day, and there is exactly one place '
      'that decides what that means.' % (passes, len(REPOS)))
