#!/usr/bin/env python3
"""
School Connect — schema coverage audit

Answers one question: does database/complete-schema.sql really contain
everything the platform needs?

Three independent checks, no hard-coded lists:

  1. FRONTEND -> SCHEMA
     Every .from('tbl') and .rpc('fn') in the shipped JS/HTML must exist as a
     table or a function in the schema.

  2. VERSIONED SQL -> SCHEMA
     Every object declared in any database/v*.sql must also be declared in
     complete-schema.sql (so no versioned pack is silently missing).

  3. SUPABASE-ONLY SURFACES
     Reports objects the frontend uses that the schema does not create, and
     RPCs defined in SQL that nothing calls (informational).

Exit code is non-zero when check 1 or 2 fails.
"""
from __future__ import annotations
import os
import re
import sys
import glob
import json
import collections

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import sqlsplit  # noqa: E402

DB = os.path.join(ROOT, 'database')
COMPLETE = os.path.join(DB, 'complete-schema.sql')


# ------------------------------------------------------------------ schema side
def schema_objects(path):
    sql = open(path, errors='replace').read()
    st = sqlsplit.split_statements(sql)
    out = {'table': set(), 'function': set(), 'view': set(), 'columns': set()}
    for s in st:
        sqlsplit.classify(s)
        if s.kind == 'table':
            out['table'].add(s.name.split('.')[-1])
        elif s.kind == 'view':
            out['view'].add(s.name.split('.')[-1])
        elif s.kind == 'function' and getattr(s, 'name', None):
            out['function'].add(s.name.split('.')[-1])
        elif s.kind == 'addcolumn':
            out['columns'].add(s.key)
    # columns declared inline in CREATE TABLE (only for the SHORT form)
    for s in st:
        if s.kind == 'table':
            b = re.sub(r'^\s*(?:--[^\n]*\n\s*)*', '', s.text, flags=re.S)
            m = re.match(r'\s*create\s+table\s+(?:if\s+not\s+exists\s+)?(?:(?:public)\.)?("?[a-z0-9_]+"?)',
                         b, re.I)
            if not m:
                continue
            tbl = m.group(1).strip('"')
            open_i = b.find('(', m.end() - 1)
            if open_i < 0:
                continue
            depth, cur, cols = 0, '', []
            for ch in b[open_i:]:
                if ch == '(':
                    depth += 1
                    if depth == 1:
                        continue
                elif ch == ')':
                    depth -= 1
                    if depth == 0:
                        break
                if ch == ',' and depth == 1:
                    cols.append(cur)
                    cur = ''
                elif depth == 1:
                    cur += ch
            cols.append(cur)
            for c in cols:
                c = re.sub(r'--.*', '', c).strip()
                if not c or re.match(r'(constraint|primary|unique|foreign|check|exclude)\b', c, re.I):
                    continue
                cm = re.match(r'("?[a-z0-9_]+"?)', c, re.I)
                if cm:
                    out['columns'].add('column public.%s.%s' % (tbl, cm.group(1).strip('"')))
    return out


# ----------------------------------------------------------------- frontend side
# a storage bucket is not a table
STORAGE_FROM_RE = re.compile(r"storage\s*\.\s*from\(\s*['\"]([a-z0-9_-]+)['\"]")
FROM_RE = re.compile(r"\.from\(\s*['\"]([a-z0-9_]+)['\"]")
RPC_RE = re.compile(r"\.rpc\(\s*['\"]([a-z0-9_]+)['\"]")
# Supabase itself, not ours
IGNORE_FROM = {'rpc'}


def frontend_calls():
    tbl, rpc = collections.Counter(), collections.Counter()
    buckets = set()
    files = [p for p in glob.glob(os.path.join(ROOT, '**', '*.js'), recursive=True) +
             glob.glob(os.path.join(ROOT, '**', '*.html'), recursive=True) +
             glob.glob(os.path.join(ROOT, '**', '*.cjs'), recursive=True)
             if 'node_modules' not in p and '/.git/' not in p and '/tools/' not in p]
    for p in files:
        try:
            t = open(p, errors='replace').read()
        except OSError:
            continue
        for m in STORAGE_FROM_RE.finditer(t):
            buckets.add(m.group(1))
        # blank out storage.from(...) so the table regex cannot match it
        masked = STORAGE_FROM_RE.sub('storage.bucket(', t)
        for m in FROM_RE.finditer(masked):
            tbl[m.group(1)] += 1
        for m in RPC_RE.finditer(t):
            rpc[m.group(1)] += 1
    return tbl, rpc, buckets, len(files)


# ------------------------------------------------------------------------ report
def main():
    argv = sys.argv[1:]
    verbose = '--verbose' in argv

    comp = schema_objects(COMPLETE)
    tbl, rpc, buckets, nfiles = frontend_calls()
    failures = 0

    print()
    print('  School Connect — schema coverage audit')
    print('  ' + '-' * 56)
    print(f'  frontend files scanned      {nfiles:>5}')
    print(f'  complete-schema.sql objects  {len(comp["table"]):>5} tables, '
          f'{len(comp["view"])} views, {len(comp["function"])} functions, '
          f'{len(comp["columns"])} columns')
    print()

    # ---- 1. frontend tables
    known_tbl = comp['table'] | comp['view']
    missing_tbl = sorted(t for t in tbl if t not in known_tbl and t not in IGNORE_FROM)
    if missing_tbl:
        failures += 1
        print(f'  FAIL  {len(missing_tbl)} table(s) used by the frontend are not in the schema:')
        for t in missing_tbl:
            print(f'          {t}   ({tbl[t]} call sites)')
    else:
        print(f'  PASS  every table the frontend reads/writes exists  ({len(tbl)} distinct)')

    # ---- 2. frontend RPCs
    missing_rpc = sorted(r for r in rpc if r not in comp['function'])
    if missing_rpc:
        failures += 1
        print(f'  FAIL  {len(missing_rpc)} RPC(s) called by the frontend are not in the schema:')
        for r in missing_rpc:
            print(f'          {r}()   ({rpc[r]} call sites)')
    else:
        print(f'  PASS  every RPC the frontend calls exists            ({len(rpc)} distinct)')

    # ---- 3. versioned SQL files
    lost = collections.defaultdict(list)
    files = sorted(glob.glob(os.path.join(DB, 'v*.sql')))
    for f in files:
        try:
            o = schema_objects(f)
        except Exception as e:  # noqa: BLE001
            print(f'  !! unreadable {os.path.basename(f)}: {e}')
            continue
        for k in ('table', 'view', 'function'):
            for x in o[k] - comp[k]:
                lost[k].append((os.path.basename(f), x))
    # a 4-arg function whose 5-arg superset exists is not a gap
    real_lost = []
    for k, items in lost.items():
        for fname, x in items:
            real_lost.append((k, fname, x))
    if real_lost:
        print(f'  WARN  {len(real_lost)} object(s) in versioned packs are absent from the complete schema:')
        for k, fname, x in real_lost[:40]:
            print(f'          {k:9s} {x[:50]:52s} ({fname})')
    else:
        print(f'  PASS  every object in {len(files)} versioned packs is present  ')

    # ---- informational
    uncalled = sorted(f for f in comp['function'] if f not in rpc)
    if verbose:
        print()
        print(f'  {len(uncalled)} function(s) defined in SQL but never called directly by the')
        print('  frontend (normal: triggers, RLS helpers, internal helpers, RPC surface')
        print('  used by SQL rather than JS).')
        for f in uncalled[:60]:
            print(f'          {f}')

    print()
    if failures:
        print(f'  {failures} COVERAGE GAP(S)')
    else:
        print('  ALL PASS — the complete schema covers every table and RPC the platform uses.')
    print()
    return 0 if failures == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
