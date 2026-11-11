#!/usr/bin/env python3
"""V12.0 permanent guard (pass 68): every .from('t').select('cols') in client
code must reference only columns that exist in complete-schema.sql.
This bug class (42703 → silently-swallowed error → empty UI) caused the
voting 0% bug, the birthday-widget zero and the messages recipient hole.
Run by verify.sh; fails the build on any NEW mismatch."""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
schema = (ROOT / 'database/complete-schema.sql').read_text()

cols = {}
for m in re.finditer(r'create table if not exists public\.(\w+)\s*\((.*?)\);', schema, re.S):
    tbl, body = m.group(1), m.group(2)
    body = re.sub(r'--[^\n]*', '', body)   # strip SQL comments (commas inside them corrupted the split)
    cset = cols.setdefault(tbl, set())
    # NOTE: a comma-split is right (each part starts a new column) but the old
    # code missed columns after inline constraints with parentheses. Track
    # paren depth so we only split on top-level commas, then take part word 1.
    depth = 0; part = ''
    parts = []
    for ch in body:
        if ch == '(': depth += 1
        elif ch == ')': depth -= 1
        if ch == ',' and depth == 0: parts.append(part); part = ''
        else: part += ch
    parts.append(part)
    for line in parts:
        w = line.strip().split()
        if w and re.match(r'^[a-z_][a-z0-9_]*$', w[0]) and w[0] not in ('primary','unique','check','constraint','foreign'):
            cset.add(w[0])
# V12.70 — the old pattern matched ONE `add column` per ALTER, so a block like
#   alter table public.admissions
#     add column if not exists photo_url text,
#     add column if not exists data jsonb, ...
# registered only its first column. Anything added in the 2nd or later position
# was reported as missing — a false positive that pushed real findings into the
# ALLOW list and taught people to ignore this audit. Scan whole ALTER statements
# and collect every `add column` inside them.
for m in re.finditer(r'alter table\s+(?:if exists\s+)?public\.(\w+)([^;]*);', schema, re.S):
    tbl, body = m.group(1), m.group(2)
    for c in re.finditer(r'add\s+column\s+(?:if not exists\s+)?(?:"?(\w+)"?)', body, re.I):
        cols.setdefault(tbl, set()).add(c.group(1))

# Views / RPC-backed pseudo-tables and embedded-resource selects are exempt.
EXEMPT_TABLES = {t for t in re.findall(r'create (?:or replace )?view (?:public\.)?(\w+)', schema)}
# Known-safe: columns proven present under other DDL shapes or optional probes
# wrapped in explicit fallbacks. KEEP THIS LIST SHORT — every entry needs a reason.
ALLOW = {
    # crud.js probes optional columns with .then(r=>r, ()=>({data:[]})) fallbacks by design
}

issues = []
files = list(ROOT.glob('*.html')) + list((ROOT / 'assets/js').glob('*.js'))
for f in files:
    t = f.read_text(errors='ignore')
    for m in re.finditer(r"\.from\('(\w+)'\)\s*\.select\('([^']+)'", t):
        tbl, sel = m.group(1), m.group(2)
        if tbl not in cols or tbl in EXEMPT_TABLES or '*' in sel: continue
        if '(' in sel: continue          # embedded resources — PostgREST join syntax
        for c in re.split(r'[,\s]+', sel):
            c = c.strip().split(':')[0].split('!')[0]
            if not c or not re.match(r'^[a-z_][a-z0-9_]*$', c): continue
            if c not in cols[tbl] and c != 'count' and (f.name, tbl, c) not in ALLOW:
                issues.append((f.name, tbl, c))

# V12.3: WRITE direction — literal keys in .insert({...})/.update({...})/.upsert({...})
WRITE_ALLOW = {
    # enterprise.js logIncident: flagged keys live INSIDE the data jsonb object (legal)
    ('enterprise.js','module_records','class'), ('enterprise.js','module_records','date'),
    ('enterprise.js','module_records','reported_by'), ('enterprise.js','module_records','severity'),
    ('enterprise.js','module_records','student_name'),
    # V12.7 app.js parent returning hint: data jsonb keys (legal, inside data:{}), plus string-literal false positives from title/body colons
    ('app.js','module_records','email'), ('app.js','module_records','children_admission_nos'),
    ('app.js','module_records','scenario'), ('app.js','module_records','parent_name'),
    ('app.js','module_records','nos'), ('app.js','module_records','returning'),
    ('app.js','module_records','children'),
}
for f in files:
    t = f.read_text(errors='ignore')
    for m in re.finditer(r"\.from\('(\w+)'\)\s*\.(?:insert|update|upsert)\(\s*\{([^}]*)\}", t):
        tbl, body = m.groups()
        if tbl not in cols or tbl in EXEMPT_TABLES: continue
        for k in re.findall(r"(?:^|[,{\s])(\w+)\s*:", body):
            if k == 'id' or not re.match(r'^[a-z_][a-z0-9_]*$', k): continue
            if k not in cols[tbl] and (f.name, tbl, k) not in WRITE_ALLOW:
                issues.append((f.name, tbl, k + ' [WRITE]'))

uniq = sorted(set(issues))
if uniq:
    print('42703 GUARD FAILED — client selects columns missing from the schema:')
    for x in uniq: print('  ', x)
    sys.exit(1)
print(f'42703 guard passed: {len(files)} files, {len(cols)} tables — no phantom columns selected.')
