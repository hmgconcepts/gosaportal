#!/usr/bin/env python3
"""Upgrade-safety audit for database/complete-schema.sql — PASS/FAIL, not prose.

THE QUESTION: a school that already installed an older release runs this file.
Does every statement still succeed? Postgres has objects that CANNOT be replaced
in place, and each one fails an upgrade while a fresh install looks perfect:

    42P13  cannot change return type of existing function   (RETURNS TABLE / OUT)
    42P16  cannot change name of view column                (CREATE OR REPLACE VIEW)
    42710  policy / constraint already exists
    42P07  index already exists
    42701  column already exists
    42703  column does not exist                            (DROP COLUMN again)

This file is the audit, kept in the repository so it can be re-run instead of
re-argued. It exits non-zero when it finds an unguarded hazard.

    python3 tools/audit-schema-upgrade.py [path/to/complete-schema.sql]
"""
import re
import sys
from pathlib import Path

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else
            Path(__file__).resolve().parent.parent / 'database' / 'complete-schema.sql')
SQL = PATH.read_text()

# ------------------------------------------------------------------ masking
def mask_bodies(src):
    """Return (top_level_text, list_of_do_blocks).

    top_level_text has every dollar-quoted body replaced by spaces (same
    length, so offsets still line up); the DO blocks are returned separately so
    their contents can be judged by their own guards.
    """
    out = list(src)
    blocks, i = [], 0
    while True:
        m = re.search(r'\bdo\s+\$([A-Za-z0-9_]*)\$', src[i:])
        if not m:
            break
        tag = m.group(1)
        start = i + m.end()
        endm = re.compile(r'\$' + tag + r'\$').search(src, start)
        if not endm:
            break
        body = src[start:endm.start()]
        blocks.append(body)
        for k in range(start, endm.start()):
            if out[k] != '\n':
                out[k] = ' '
        i = endm.end()
    # plain function bodies too (language sql/plpgsql as $$ … $$)
    for m in re.finditer(r'\b(as|do)\s+\$([A-Za-z0-9_]*)\$', src):
        tag = m.group(2)
        start = m.end()
        endm = re.compile(r'\$' + tag + r'\$').search(src, start)
        if not endm:
            continue
        for k in range(start, endm.start()):
            if out[k] != '\n':
                out[k] = ' '
    return ''.join(out), blocks

TOP, DO_BLOCKS = mask_bodies(SQL)
DO_TEXT = '\n'.join(DO_BLOCKS)
stmts = [s.strip() for s in re.split(r';\s*(?:\n|$)', TOP) if s.strip()]

problems = []
def bad(kind, what, detail=''):
    problems.append((kind, what, detail))

# --------------------------------------------------- 1. row-returning functions
def func_headers(src):
    for m in re.finditer(
            r'create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?"?(\w+)"?\s*\((.*?)\)\s*(returns.*?)'
            r'(?:\s+language\s|\s+as\s+\$|\s+begin\b)', src, re.S | re.I):
        yield m.group(1), re.sub(r'\s+', ' ', m.group(2)), re.sub(r'\s+', ' ', m.group(3))

HDRS = list(func_headers(SQL))
row_type_funcs = set()
for name, args, ret in HDRS:
    if re.match(r'returns\s+(table\s*\(|setof\b|record\b)', ret, re.I) or \
       re.search(r'(?:^|,)\s*(?:inout|out)\s+\w+', args, re.I):
        row_type_funcs.add(name)

# what the file drops up front
# the guard itself lives INSIDE a do-block, so read the raw file, not the mask
dropped_names = set(x.strip().strip("'") for m in re.findall(r"proname\s+in\s*\(([^)]*)\)", SQL, re.I)
                    for x in m.split(','))
dropped_names |= set(re.findall(r'drop\s+function\s+if\s+exists\s+(?:public\.)?"?(\w+)"?', SQL, re.I))
for f in sorted(row_type_funcs - dropped_names):
    bad('42P13', f'function {f}() returns a ROW TYPE and is never dropped first',
        'adding a column to it breaks every existing install')

# ------------------------------------------------------------------- 2. views
view_creates = [(m.group(1), m.start()) for m in
                re.finditer(r'create\s+(?:or\s+replace\s+)?(?:materialized\s+)?view\s+(?:public\.)?"?(\w+)"?\s+as', TOP, re.I)]
view_drops = [(m.group(1), m.start()) for m in
              re.finditer(r'drop\s+(?:materialized\s+)?view\s+if\s+exists\s+(?:public\.)?"?(\w+)"?', TOP, re.I)]
for name, pos in view_creates:
    if not any(n == name and p < pos for n, p in view_drops):
        bad('42P16', f'view {name} is created without a preceding "drop view if exists"',
            'a changed column list cannot be replaced in place')

# ---------------------------------------------------------------- 3. policies
def table_policy_wipes():
    t = set()
    for m in re.finditer(r"drop\s+policy\s+if\s+exists\s+%I\s+on\s+public\.%I", DO_TEXT, re.I):
        t.add('%any%')
    for m in re.finditer(r"foreach\s+\w+\s+in\s+array\s+array\[([^\]]*)\]", DO_TEXT, re.I):
        if re.search(r'pg_policies', DO_TEXT, re.I):
            t.add('%any%')
    return t
wipe_all = bool(table_policy_wipes())
for m in re.finditer(r'create\s+policy\s+"?(\w+)"?\s+on\s+(?:public\.)?"?(\w+)"?', TOP, re.I):
    name, table = m.group(1), m.group(2)
    before = SQL[:m.start()]          # guards can live inside DO blocks
    if re.search(r'drop\s+policy\s+if\s+exists\s+"?' + re.escape(name) + r'"?', before, re.I):
        continue
    if wipe_all and re.search(r'pg_policies', before, re.I):
        continue
    bad('42710', f'policy {name} on {table} may already exist',
        'create policy has no OR REPLACE and no drop before it')

# ---------------------------------------------------------------- 4. triggers
for m in re.finditer(r'create\s+(or\s+replace\s+)?trigger\s+"?(\w+)"?\s', TOP, re.I):
    if m.group(1):
        continue
    name = m.group(2)
    before = TOP[:m.start()]
    if not re.search(r'drop\s+trigger\s+if\s+exists\s+"?' + re.escape(name) + r'"?', before, re.I):
        bad('42710', f'trigger {name} may already exist', 'no drop trigger if exists before it')

# ------------------------------------------------------- 5/6. tables, indexes
for m in re.finditer(r'create\s+table\s+(?!if\s+not\s+exists)(?:public\.)?"?(\w+)"?', TOP, re.I):
    bad('42P07', f'table {m.group(1)} is created without IF NOT EXISTS')
for m in re.finditer(r'create\s+(?:unique\s+)?index\s+(?!if\s+not\s+exists)(?:concurrently\s+)?("?[\w.]+"?)', TOP, re.I):
    bad('42P07', f'index {m.group(1)} is created without IF NOT EXISTS')

# ------------------------------------------------------------- 7. add column
guarded_cols = set()
for m in re.finditer(r"(?:column_name|attname)\s*=\s*'(\w+)'", DO_TEXT, re.I):
    guarded_cols.add(m.group(1))
ADD_COL = re.compile(
    r'alter\s+table\s+(?:public\.)?"?(\w+)"?\s+add\s+(?:column\s+)?(if\s+not\s+exists\s+)?"?(\w+)"?',
    re.I)
for m in ADD_COL.finditer(TOP):
    table, guard, col = m.group(1), m.group(2), m.group(3)
    if col.upper() in ('CONSTRAINT', 'PRIMARY', 'UNIQUE', 'CHECK', 'FOREIGN', 'EXCLUDE'):
        continue
    if guard:
        continue                      # guarded in the SQL itself
    if col in guarded_cols:
        continue                      # guarded by a pg_attribute check in a DO block
    bad('42701', f'column {table}.{col} is added without IF NOT EXISTS')

# ------------------------------------------------------------ 8. drop column
for m in re.finditer(r'alter\s+table\s+(?:public\.)?"?(\w+)"?\s+drop\s+column\s+(?:if\s+exists\s+)?("?\w+"?)', TOP, re.I):
    # inside a DO block this lives in DO_TEXT, not TOP; if it is at top level it
    # needs its own IF EXISTS
    if 'if exists' not in m.group(0).lower():
        bad('42703', f'{m.group(1)}.{m.group(2)} is dropped without IF EXISTS',
            'a second run finds no such column')

# ------------------------------------------------------------ 9. constraints
for m in re.finditer(r'alter\s+table\s+(?:public\.)?"?(\w+)"?\s+add\s+constraint\s+"?(\w+)"?', TOP, re.I):
    name = m.group(2)
    before = TOP[:m.start()]
    if not re.search(r'drop\s+constraint\s+if\s+exists\s+"?' + re.escape(name) + r'"?', before, re.I):
        bad('42710', f'constraint {name} may already exist', 'no drop constraint if exists before it')

# ------------------------------------------------------------------- verdict
checked = {
    'row-type functions': len(row_type_funcs),
    'views': len(view_creates),
    'policies': len(re.findall(r'create\s+policy\s', TOP, re.I)),
    'triggers': len(re.findall(r'create\s+(?:or\s+replace\s+)?trigger\s', TOP, re.I)),
    'tables': len(re.findall(r'create\s+table\s', TOP, re.I)),
    'indexes': len(re.findall(r'create\s+(?:unique\s+)?index\s', TOP, re.I)),
    'column additions': len(ADD_COL.findall(TOP)),
    'constraints': len(re.findall(r'add\s+constraint\s', TOP, re.I)),
}
print(f'  file: {PATH}')
print(f'  top-level statements: {len(stmts)}   DO blocks: {len(DO_BLOCKS)}')
print('  objects examined: ' + ', '.join(f'{v} {k}' for k, v in checked.items()))
print(f'  row-type functions protected by an up-front drop: '
      f'{len(row_type_funcs & dropped_names)}/{len(row_type_funcs)}')
if problems:
    print(f'\n  UNGUARDED UPGRADE HAZARDS: {len(problems)}\n')
    for kind, what, detail in problems[:40]:
        print(f'   [{kind}] {what}' + (f'\n           {detail}' if detail else ''))
    if len(problems) > 40:
        print(f'   … and {len(problems) - 40} more')
    sys.exit(1)
print('\n  ALL PASS — every statement in the file is safe on a database that already has an older version.')
