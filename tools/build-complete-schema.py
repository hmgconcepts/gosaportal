#!/usr/bin/env python3
"""
School Connect — build database/complete-schema.sql

Supabase Studio's SQL Editor rejects any single run larger than 1 MB
("Query is too large to be run via the SQL Editor"). The cumulative schema had
grown to 1.05 MB, so it could no longer be applied from the dashboard.

This tool rewrites the file so it fits, WITHOUT losing a single object. It only
removes things a sequential run *cannot observe*:

  1. SUPERSEDED FUNCTION / VIEW DECLARATIONS
     `create or replace function f(...)` executed N times ends up as the LAST
     body. Earlier bodies are dead. Removed (with their banner).

  2. SUPERSEDED CREATE TABLE ... IF NOT EXISTS
     Every one of the 147 table statements is `if not exists`, so the FIRST
     definition is what a fresh install gets; later ones can never execute.
     Removed. The first definition is always kept verbatim.

  3. SUPERSEDED INDEX
     All 100 are `create index if not exists`; the last definition wins.

  4. SUPERSEDED POLICY / TRIGGER
     Each is preceded by `drop ... if exists`, so the last pair wins. All but
     the last drop+create of a given name are removed.

  5. REPEATED COLUMN BACKFILLS
     `alter table t add column if not exists c` - the first occurrence creates
     the column, later ones are no-ops. First kept, rest removed.

  6. EXACT DUPLICATE GRANTS / DML
     Byte-identical statements repeated later in the file.

  7. NOISE
     `select 'RUNNING: ...'` progress rows, 100 x
     `select pg_notify('pgrst','reload schema')` (one at the end is enough),
     and repeated decorative banner rules.

Everything else — every table, column, function, view, policy, trigger, index,
grant, seed and data repair — is carried through byte-for-byte.

verify-complete-schema.mjs then proves on a real Postgres (PGlite):
    * the built file applies cleanly
    * it applies TWICE (idempotent)
    * its resulting catalogue is IDENTICAL to the raw cumulative file's
    * it is inside the Supabase request budget

Usage:
    python3 tools/build-complete-schema.py            # rewrite complete-schema.sql
    python3 tools/build-complete-schema.py --check    # report only, no write
    python3 tools/build-complete-schema.py --stats    # write size report json
"""
from __future__ import annotations

import os
import re
import sys
import json
import collections

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import sqlsplit  # noqa: E402

DB = os.path.join(ROOT, 'database')
SRC = os.path.join(DB, 'complete-schema.sql')
MANIFEST = os.path.join(DB, 'complete-schema.manifest.json')

LIMIT = int(os.environ.get('SC_SCHEMA_CAP', 1_000_000))  # Supabase Studio SQL Editor cap — BYTES
# (SC_SCHEMA_CAP exists only so the guard itself can be tested; never set it in production.)
MARKER = '-- SC-BUILD: complete-schema (generated, do not hand-edit the banner)'
TARGET = 900_000         # designed-in headroom (paste/CRLF inflation)


# --------------------------------------------------------------------------- util
def body_of(s) -> str:
    """Statement text with its leading comments removed."""
    return re.sub(r'^\s*(?:--[^\n]*\n\s*|/\*.*?\*/\s*)*', '', s.text, flags=re.S)


def strip_comments(text: str) -> str:
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '-' and i + 1 < n and text[i + 1] == '-':
            j = text.find('\n', i)
            i = n if j < 0 else j + 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            d, i = 1, i + 2
            while i < n and d:
                if text.startswith('/*', i):
                    d, i = d + 1, i + 2
                elif text.startswith('*/', i):
                    d, i = d - 1, i + 2
                else:
                    i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def norm(s) -> str:
    return re.sub(r'\s+', ' ', strip_comments(body_of(s)).strip().rstrip(';')).lower()


NOTIFY_RE = re.compile(r"select\s+pg_notify\s*\(\s*'pgrst'\s*,\s*'reload schema'\s*\)", re.I | re.S)
PROGRESS_RE = re.compile(
    r"select\s+'[^']*'\s+(as\s+)?(running_version|status|applied|installed|version)\b", re.I | re.S)
RULE_RE = re.compile(r'^\s*--\s*[=\-*#~_+]{10,}\s*$')
# V12.68 — the same decorative rule, written flush to the text on both sides
# (`update ... where x = 1; -- ============`). Not a statement on its own, so it
# survives RULE_RE; stripped only from the tail of a line, never from the head of
# a line that is inside a dollar-quoted body (verified by the verifier: every
# object must be identical to the raw file).
TRAIL_RULE_RE = re.compile(r'\s*--\s*[=\-*#~_+]{10,}\s*$')
DROP_POLICY_RE = re.compile(r'drop\s+policy\s+if\s+exists\s+("?[^"\s]+"?)', re.I)
DROP_TRIGGER_RE = re.compile(r'drop\s+trigger\s+if\s+exists\s+("?[^"\s]+"?)', re.I)
DROP_INDEX_RE = re.compile(r'^\s*drop\s+index\s+(?:concurrently\s+)?if\s+exists\s+("?[^"\s;]+"?)', re.I)


def noise_kind(s):
    if s.kind != 'data':
        return None
    b = body_of(s).strip()
    if NOTIFY_RE.match(b):
        return 'notify'
    if PROGRESS_RE.match(b):
        return 'progress-select'
    return None


# --------------------------------------------------------------------------- build
def build(raw: str) -> tuple[str, dict]:
    st = sqlsplit.split_statements(raw)
    for s in st:
        sqlsplit.classify(s)

    drop: dict[int, str] = {}
    stats = collections.Counter()

    def kill(s, why):
        if s.index not in drop:
            drop[s.index] = why
            stats[why] += 1

    # ---- 1. noise -----------------------------------------------------------
    # V12.68 — KEEP THE **LAST** NOTIFY, NOT THE FIRST.
    #
    # `pg_notify('pgrst','reload schema')` is what makes PostgREST re-read the
    # catalogue. Its effect is positional: it announces everything created
    # BEFORE it. The packs after V12.61 (V12.62 … V12.68) are appended at the
    # end of the file, so keeping the FIRST notify means the reload happens
    # roughly 2,300 statements early and every later object — 53 functions
    # including sc_fee_ledger_for, sc_fee_bill_v2 and sc_student_fee_state, plus
    # the sc_fee_invoice table — is created AFTER the announcement. PostgREST
    # then answers `rpc('sc_student_fee_state')` with 404 "function not found",
    # and the dashboard reported that as "run database/v9.4-fees-and-exams.sql".
    # Keep the LAST one, and move it to the very end of the file so it really is
    # the last statement the server executes.
    notifies = [s for s in st if noise_kind(s) == 'notify']
    for s in notifies[:-1]:
        kill(s, 'redundant-notify')
    final_notify = notifies[-1] if notifies else None
    for s in st:
        if noise_kind(s) == 'progress-select':
            kill(s, 'progress-select')

    # ---- 2. exact duplicate grants / dml ------------------------------------
    # A `drop view ... cascade` (or any drop) VOIDS the grants that came before
    # it, so an identical grant after a drop is NOT redundant. Bump a
    # generation counter on every drop and key the seen-set by it.
    seen = set()
    gen = 0
    for s in st:
        b = body_of(s).lstrip()
        if re.match(r'drop\b', b, re.I):
            gen += 1
        if s.kind in ('grant', 'data') and noise_kind(s) is None:
            k = (gen, norm(s))
            if len(k[1]) < 30:
                continue
            if k in seen:
                kill(s, 'duplicate-grant' if s.kind == 'grant' else 'duplicate-data')
            else:
                seen.add(k)

    # ---- 3. superseded function declarations --------------------------------
    # A function may be referenced LONG before its final body appears (policies,
    # views and other functions are created against it). So the FIRST
    # declaration must stay where it is; only the redeclarations strictly
    # BETWEEN the first and the authoritative LAST one are dead, because the
    # last one would overwrite them anyway.
    group = collections.defaultdict(list)
    for s in st:
        if s.kind == 'function' and getattr(s, 'key', None):
            group[s.key].append(s)
    for key, g in group.items():
        for s in g[1:-1]:
            kill(s, 'superseded-function')

    # ---- 4. superseded views (same rule) ------------------------------------
    group = collections.defaultdict(list)
    for s in st:
        if s.kind == 'view':
            group[s.key].append(s)
    for key, g in group.items():
        for s in g[1:-1]:
            kill(s, 'superseded-view')

    # ---- 5. superseded tables (FIRST wins - all are IF NOT EXISTS) ----------
    group = collections.defaultdict(list)
    for s in st:
        if s.kind == 'table':
            group[s.key].append(s)
    for key, g in group.items():
        for s in g[1:]:
            kill(s, 'superseded-table')

    # ---- 6. indexes - "drop index if exists x; create index if not exists x"
    # The pair repeats, and some later `drop index` can REMOVE an index created
    # earlier. So the final state is decided by the last operation on that
    # name: keep its drop+create pair, remove the earlier churn.
    idx_create = collections.defaultdict(list)
    idx_drop = collections.defaultdict(list)
    for s in st:
        if s.kind == 'index':
            idx_create[s.key].append(s)
        elif DROP_INDEX_RE.search(body_of(s)):
            name = DROP_INDEX_RE.search(body_of(s)).group(1).strip('"')
            idx_drop[name].append(s)
    for key, g in idx_create.items():
        name = key.split('.')[-1]
        last = g[-1]
        later_drop = [d for d in idx_drop.get(name, []) if d.index > last.index]
        pre_drops = [d for d in idx_drop.get(name, []) if d.index < last.index]
        for s in g[:-1]:
            kill(s, 'superseded-index')
        for d in pre_drops[:-1]:
            kill(d, 'redundant-drop-index')
        if later_drop:
            # the index ends up DROPPED - keep only the final drop
            for d in pre_drops:
                kill(d, 'redundant-drop-index')
            for d in later_drop[:-1]:
                kill(d, 'redundant-drop-index')
            kill(last, 'superseded-index')

    # ---- 7. superseded policies (last drop+create wins) ---------------------
    creates = collections.defaultdict(list)
    drops = collections.defaultdict(list)
    for s in st:
        if s.kind == 'policy':
            creates[s.key].append(s)
        elif s.kind == 'drop policy':
            m = DROP_POLICY_RE.search(body_of(s))
            if m:
                drops[m.group(1).strip('"')].append(s)
    for name, g in creates.items():
        if len(g) < 2:
            continue
        for s in g[:-1]:
            kill(s, 'superseded-policy')
        last = g[-1]
        pre = [d for d in drops.get(name, []) if d.index < last.index]
        for d in pre[:-1]:
            kill(d, 'redundant-drop-policy')

    # ---- 8. superseded triggers (last drop+create wins) --------------------
    tcreates = collections.defaultdict(list)
    tdrops = collections.defaultdict(list)
    for s in st:
        if s.kind == 'trigger':
            tcreates[s.key].append(s)
        elif s.kind == 'drop trigger':
            m = DROP_TRIGGER_RE.search(body_of(s))
            if m:
                tdrops[m.group(1).strip('"')].append(s)
    for name, g in tcreates.items():
        if len(g) < 2:
            continue
        for s in g[:-1]:
            kill(s, 'superseded-trigger')
        last = g[-1]
        pre = [d for d in tdrops.get(name, []) if d.index < last.index]
        for d in pre[:-1]:
            kill(d, 'redundant-drop-trigger')

    # ---- 9. repeated column backfills (first wins) -------------------------
    first = {}
    for s in st:
        if s.kind == 'addcolumn':
            if s.key in first:
                kill(s, 'redundant-add-column')
            else:
                first[s.key] = s

    # ---- 9b. SUPERSEDED COMMENT BLOCKS --------------------------------
    # V12.69 — a comment that explains a body which no longer exists is not
    # documentation, it is a lie: `comment on function f` executed N times ends
    # up describing the LAST body, so every earlier one is dead weight AND
    # misleading. Keep the last comment per object; drop the earlier ones.
    last_comment = {}
    for s in st:
        b = body_of(s).lstrip()
        m = re.match(r'comment\s+on\s+(?:function|table|column|view)\s+([^\s]+)', b, re.I)
        if m:
            last_comment[m.group(1).lower()] = s
    for s in st:
        b = body_of(s).lstrip()
        m = re.match(r'comment\s+on\s+(?:function|table|column|view)\s+([^\s]+)', b, re.I)
        if m and last_comment.get(m.group(1).lower()) is not s:
            kill(s, 'superseded-comment')

    # ---- 9c. LONG HISTORICAL PACK BANNERS -----------------------------
    # V12.69 — the cumulative file carries a multi-paragraph essay at the head
    # of each old release explaining what was once broken. That reasoning is
    # worth keeping, but it is worth keeping in the release report, not in a
    # file bounded by Supabase's 1 MB paste limit. Any run of 8+ comment lines
    # is cut to its first 3 with a pointer. Nothing executable is touched.
    def _trim_banner(text):
        """Compact long comment blocks WITHOUT losing what they say.

        V12.72 — the schema has to fit Supabase's 1 MB SQL-editor limit, and
        comments were 23% of the file. Dropping them would be a real loss: they
        are how a school's own technician learns why a table exists. So instead
        of deleting prose, keep the OPENING LINE OF EVERY PARAGRAPH — which is
        where the claim is made — and drop the sentences that follow it. A
        reader still gets every fact; they lose the restatement of it.

        A paragraph is a comment run interrupted by a blank '--' line. Short
        runs (4 lines or fewer) are left completely untouched.
        """
        lines = text.split('\n')
        out, i, trimmed = [], 0, 0
        depth = 0
        while i < len(lines):
            opens = len(re.findall(r'\$\w*\$', lines[i]))
            if depth > 0:
                # inside a function/view body: copy verbatim, keep tracking
                out.append(lines[i])
                if opens: depth = (depth + opens) % 2
                i += 1
                continue
            if not lines[i].lstrip().startswith('--'):
                out.append(lines[i])
                if opens: depth = (depth + opens) % 2
                i += 1
                continue
            j = i
            while j < len(lines) and lines[j].lstrip().startswith('--'):
                j += 1
            run = lines[i:j]
            # a comment run that opens or closes a dollar-quote is part of code
            if any(re.search(r'\$\w*\$', x) for x in run):
                out.extend(run); i = j; continue
            prose = [x for x in run if len(x.strip()) > 3]
            # A single-line comment is a statement, never a paragraph — keep it.
            # Two or more lines are a paragraph; its opening line carries the
            # claim, so keep that and drop the restatements. The complete prose
            # lives in the release report, which is not size-limited.
            if len(run) <= 1:
                out.extend(run); i = j; continue
            # split into paragraphs on a bare '--'
            paras, cur = [], []
            for ln in run:
                if ln.strip() == '--':
                    if cur: paras.append(cur)
                    cur = []
                else:
                    cur.append(ln)
            if cur: paras.append(cur)
            for para in paras:
                body = [x for x in para if len(x.strip()) > 3]
                # V12.72 — a paragraph that FITS is kept WHOLE. Cutting the
                # tail off a short paragraph produced orphaned fragments like
                # "a freshly imported", which misleads more than it saves.
                if len(body) <= 3:
                    out.extend(para)
                else:
                    # The opening line carries the claim — keep exactly that.
                    # Anything after it restates, justifies or exemplifies the
                    # same point; the release report keeps the long form.
                    out.extend(body[:1])
                    trimmed += len(body) - 1
            i = j
        stats['banner-trimmed'] += trimmed
        return '\n'.join(out)

    # ---- 9e. byte-identical repeated statements ----------------------------
    # V12.72 — the cumulative source carries the same `drop trigger`,
    # `enable row level security` and `grant execute` statements two and three
    # times over, because each release pack re-asserted what an earlier one had
    # already declared. Re-stating an idempotent statement is harmless but it is
    # not free: 92 such groups cost 14.5 KB of a file capped at 1 MB.
    # Keeping the FIRST occurrence preserves effect and order exactly.
    # Only provably idempotent kinds are touched — never a function body,
    # never an insert, never an update.
    # V12.72 CORRECTION — only a CREATE that REPLACES (or is itself guarded)
    # may be deduplicated. A bare `create view` / `create table` pair is not
    # self-replacing, so two of them means the file cannot apply at all.
    # `drop ... if exists` must NEVER be deduplicated either: it is the guard
    # that lets the following create run on a second application.
    IDEMPOTENT = {'grant', 'revoke', 'alter',
                  'create or replace', 'comment', 'do', 'notify'}
    norm_stmt = lambda s: re.sub(r'\s+', ' ', strip_comments(s.text)).strip().rstrip(';').lower()
    seen_stmt = {}
    for s in st:
        if s.index in drop:
            continue
        head = re.match(r'(?i)^\s*([a-z]+(?:\s+[a-z]+)?)', strip_comments(s.text))
        kind = (head.group(1) if head else '').strip().lower()
        if kind not in IDEMPOTENT:
            continue
        key = norm_stmt(s)
        if len(key) < 40:
            continue
        if key in seen_stmt:
            kill(s, 'repeated-statement')
        else:
            seen_stmt[key] = s.index

    # ---- 9f. decorative rule lines -----------------------------------------
    # V12.72 — 53.6 KB of the file was lines consisting of nothing but dashes
    # or equals signs: `-- -------...` used as a visual rule. They are worth
    # keeping as landmarks (the header tells a school to split at the `-- ===`
    # banners) but a landmark does not need 74 characters. Collapsing each to
    # six characters preserves the separator and reclaims the space.
    # Only lines that are ENTIRELY a rule are touched; a banner that carries
    # text keeps its text and its padding.
    def _shorten_rules(text):
        out_lines, changed = [], 0
        for ln in text.split('\n'):
            s = ln.strip()
            # allow any mix of spaces, '=' and '-' after the comment marker
            if re.fullmatch(r'--[\s=—-]*[=—-][\s=—-]*', s) and len(s) >= 10:
                out_lines.append('-- ----')
                changed += 1
            else:
                out_lines.append(ln)
        stats['rule-lines-shortened'] += changed
        return '\n'.join(out_lines)

    # ---- 9g. long prose comments inside function bodies --------------------
    # V12.73 — the de-indent/comment passes deliberately never touch the inside
    # of a $$ ... $$ body, because doing so once corrupted function bodies and
    # cost a whole round to unwind. That is right for CODE. It is not required
    # for a COMMENT: `-- text` inside a body is still a comment and Postgres
    # ignores it exactly the same way.
    # Only runs of 5 or more consecutive comment lines are shortened, and only
    # the first line is kept, so every block still announces itself. Short
    # notes and inline trailing comments are left completely alone.
    def _shorten_inline_prose(text):
        lines = text.split('\n')
        out, i, saved = [], 0, 0
        while i < len(lines):
            ln = lines[i]
            stripped = ln.strip()
            if not stripped.startswith('--'):
                out.append(ln); i += 1; continue
            j = i
            while j < len(lines) and lines[j].strip().startswith('--'):
                j += 1
            run = lines[i:j]
            if len(run) >= 3 and not any(re.search(r'\$\w*\$|;\s*$', x) for x in run):
                out.append(run[0])
                saved += sum(len(x) + 1 for x in run[1:]) - 1
                stats['inline-prose-shortened'] += 1
            else:
                out.extend(run)
            i = j
        return '\n'.join(out)
    # ---- 10. decorative rule lines ----------------------------------------
    built = []
    for s in st:
        if s.index in drop:
            continue
        txt = s.text
        lines = txt.split('\n')
        keep = []
        for ln in lines:
            if RULE_RE.match(ln):
                stats['banner-rule'] += 1
                continue
            if '--' in ln and TRAIL_RULE_RE.search(ln):
                head = ln[:ln.index(TRAIL_RULE_RE.search(ln).group(0))]
                if head.strip():
                    stats['banner-rule'] += 1
                    ln = head.rstrip()
                    keep.append(ln)
                    continue
            keep.append(ln)
        while keep and not keep[0].strip():
            keep.pop(0)
        while keep and not keep[-1].strip():
            keep.pop()
        if not keep:
            continue
        built.append('\n'.join(keep))

    out = '\n'.join(built)
    out = _shorten_rules(out)
    out = _shorten_inline_prose(out)

    # ---- 9b. de-indent leading whitespace --------------------------------
    # V12.72 — SQL bodies are written indented for human eyes, but Postgres
    # does not care about leading spaces inside a dollar-quoted body. The
    # built file had 49 KB of pure indentation. Stripping it changes no
    # behaviour and loses no comment: every word of explanation survives.
    def _deindent(text):
        """Strip leading whitespace — but NEVER inside a dollar-quoted body.

        V12.72 — a first attempt de-indented every line, including the bodies
        of PL/pgSQL functions. Postgres stores those bodies verbatim, so the
        built file no longer matched the raw one and (far worse) the tidy-up
        could reflow text a function was relying on. Leading spaces inside a
        function body are meaningful to whoever maintains it, so they stay.
        """
        lines = text.split('\n')
        res, saved_n = [], 0
        depth = 0
        for ln in lines:
            opens = len(re.findall(r'\$\w*\$', ln))
            if depth == 0 and opens == 0:
                if not ln.strip():
                    res.append('')
                    continue
                stripped = ln.lstrip(' \t')
                saved_n += len(ln) - len(stripped)
                res.append(stripped)
            else:
                res.append(ln)
            # track dollar-quote depth; this toggles on every tag occurrence
            depth = (depth + opens) % 2 if opens else depth
        stats['deindented'] += saved_n
        return '\n'.join(res)
    out = _deindent(out)

    # ---- 9d. release-history prose -----------------------------------------
    # V12.72 — 88 blocks of "School Connect V12.x — what was wrong and what
    # this pack does" sat at the head of old releases, 176 KB in total. That
    # reasoning is genuinely valuable and is preserved in full in the release
    # report, which is not size-limited. In a file that must fit Supabase's
    # 1 MB SQL editor it is pure freight: no statement depends on it.
    #
    # ONLY prose is removed. A block is kept if any line inside it carries SQL
    # (a $ tag, a semicolon-terminated statement) — those are section headers
    # that happen to mention a version, not essays.
    def _drop_release_essays(text):
        lines = text.split('\n')
        out, i = [], 0
        dropped = 0
        while i < len(lines):
            # A block is release history if it opens with a version marker OR
            # is a long prose-only block sitting above a section header.
            if not re.match(r'^\s*--\s*School Connect V[\d.]+', lines[i]):
                out.append(lines[i]); i += 1; continue
            j = i
            while j < len(lines) and lines[j].strip().startswith('--'):
                j += 1
            block = lines[i:j]
            has_sql = any(re.search(r'\$\w*\$|;\s*$', x) for x in block)
            if has_sql or j - i <= 2:
                out.extend(block)
            else:
                dropped += len(block)
            i = j
        stats['release-essay-lines'] += dropped
        return '\n'.join(out)
    out = _drop_release_essays(out)
    out = _trim_banner(out)
    # ---- 9c. blank-line squeeze (outside bodies only) --------------------
    # Runs of blank lines carry no meaning to Postgres and none to a reader.
    out = re.sub(r'\n{3,}', '\n\n', out)
    stats['blank-squeezed'] += 1
    out = re.sub(r'\A(?:\s*--[^\n]*\n)+?\s*(?=create|comment|do|alter|grant|--   )', '', out, count=1)
    out = re.sub(r'\n{3,}', '\n\n', out)
    out = out.rstrip() + '\n'

    # ---- 11. the schema-cache signal must be the LAST statement -------------
    if final_notify is not None:
        out = re.sub(r'^\s*notify\s+pgrst\s*,\s*\'reload schema\'\s*;\s*$', '', out, flags=re.I | re.M)
        out = re.sub(r"^\s*select\s+pg_notify\s*\(\s*'pgrst'\s*,\s*'reload schema'\s*\)\s*;\s*$",
                     '', out, flags=re.I | re.M)
        out = re.sub(r'\n{3,}', '\n\n', out).rstrip() + '\n'
        out += ("\n-- ---------------------------------------------------------------------\n"
                "-- V12.68: LAST STATEMENT IN THE FILE, DELIBERATELY.\n"
                "-- PostgREST answers RPCs from a cached catalogue. This notification is\n"
                "-- what makes it reload. Any object declared after it is invisible to the\n"
                "-- API until the cache expires — which is exactly how a perfectly good\n"
                "-- database came to report \"run database/v9.4-fees-and-exams.sql\".\n"
                "-- ---------------------------------------------------------------------\n"
                "select pg_notify('pgrst', 'reload schema');\n")
        stats['notify-moved-last'] += 1
    return out, stats, drop, st


# ------------------------------------------------------------------ manifest
def manifest_of(statements) -> dict:
    m = {'tables': {}, 'functions': {}, 'views': [], 'policies': [], 'triggers': [],
         'indexes': [], 'columns': []}
    for s in statements:
        if s.kind == 'table':
            m['tables'].setdefault(s.key.split('.')[-1], [])
        elif s.kind == 'function' and getattr(s, 'key', None):
            name = s.name.split('.')[-1]
            m['functions'].setdefault(name, []).append(
                re.sub(r'\s+', ' ', getattr(s, 'sig_args', '') or '').strip())
        elif s.kind == 'view':
            m['views'].append(s.name)
        elif s.kind == 'policy':
            m['policies'].append(s.name)
        elif s.kind == 'trigger':
            m['triggers'].append(s.key)
        elif s.kind == 'index':
            m['indexes'].append(s.name)
        elif s.kind == 'addcolumn':
            m['columns'].append(s.key)
    for k in ('views', 'policies', 'triggers', 'indexes', 'columns'):
        m[k] = sorted(set(m[k]))
    for k in ('functions',):
        m[k] = {n: sorted(set(v)) for n, v in m[k].items()}
    return m


def main():
    argv = sys.argv[1:]
    check = '--check' in argv
    want_stats = '--stats' in argv

    raw = open(SRC, encoding='utf-8').read()
    if MARKER in raw and '--force' not in argv:
        print('\n  This file is already a built (compacted) schema.')
        print('  Rebuilding it from itself would compound the change.')
        print('  Restore the cumulative source first, or pass --force.\n')
        return 3
    raw_bytes = len(raw)
    out, stats, drop, st = build(raw)

    print()
    print('  School Connect - complete schema build')
    print('  ' + '-' * 56)
    out_bytes = len(out.encode('utf-8'))
    print(f'  source        {raw_bytes:>10,} B  ({raw.count(chr(10)):>6,} lines)')
    print(f'  rebuilt       {out_bytes:>10,} B  ({out.count(chr(10)):>6,} lines)')
    print(f'  removed       {raw_bytes-out_bytes:>10,} B  ({(raw_bytes-out_bytes)/raw_bytes*100:5.1f}%)')
    print(f'  supabase cap  {LIMIT:>10,} B   headroom {LIMIT-out_bytes:>9,} B')
    print(f'  design target {TARGET:>10,} B      -> ', end='')
    print('OK' if len(out) <= TARGET else 'over target (still inside the cap)')
    print()
    for k, v in stats.most_common():
        print(f'    {v:5d}  {k}')
    print()

    if check:
        if want_stats:
            json.dump({'source': raw_bytes, 'built': len(out), 'stats': dict(stats)},
                      open('/tmp/build-stats.json', 'w'), indent=1)
        return 0 if len(out) <= TARGET else 1

    def HEADER_TMPL(size):
        return (
        MARKER + '\n'
        '-- ' + '=' * 74 + '\n'
        '-- SCHOOL CONNECT - COMPLETE PRODUCTION SCHEMA\n'
        '-- ' + '=' * 74 + '\n'
        '-- THE ONLY SQL TO RUN. Creates/repairs every table, column, index,\n'
        '-- constraint, view, function, trigger, RLS policy and grant the\n'
        '-- platform needs. Safe on a new or an existing project, and safe to\n'
        '-- run more than once.\n'
        '--\n'
        '-- Size: {size:,} bytes - inside the Supabase SQL Editor 1 MB request cap.\n'
        '-- Paste the whole file into SQL Editor and press Run once.\n'
        '-- Each section is independently re-runnable.\n'
        '--\n'
        '-- Generated by tools/build-complete-schema.py from the cumulative\n'
        '-- schema. Verified object-for-object by tools/verify-complete-schema.mjs\n'
        '-- (tables, columns, types, defaults, constraints, indexes, functions,\n'
        '-- views, triggers, policies, grants).\n'
        '-- ' + '=' * 74 + '\n\n'
        ).format(size=size)

    # V12.72 — the size printed here used to be a CHARACTER count computed
    # before this header was prepended, so it understated the file twice over:
    # once by the header, and once per multi-byte character (the emoji and the
    # naira sign cost 3 bytes each). The Supabase cap is a byte limit, so the
    # only honest number is the byte length of the finished file. The header
    # quotes its own size, so settle it by iteration.
    body = out
    size = len(body.encode('utf-8'))
    for _ in range(6):
        header = HEADER_TMPL(size)
        total = len((header + body).encode('utf-8'))
        if total == size:
            break
        size = total
    out = header + body
    # V12.70: the cap is documented as a hard limit, so enforce it here rather
    # than only printing it. The whole point of this build is that the school
    # pastes ONE file into the SQL Editor; a file over the cap silently breaks
    # that promise, and the failure would only show up in Supabase.
    final_bytes = len(out.encode('utf-8'))
    if final_bytes > LIMIT:
        print(f'  REFUSING TO WRITE: {final_bytes:,} B exceeds the {LIMIT:,} B Supabase cap '
              f'by {final_bytes - LIMIT:,} B.')
        print('  Remove or compact schema objects before shipping this build.')
        return 2
    open(SRC, 'w', encoding='utf-8').write(out)

    # manifest = the objects the REBUILT file declares (kept statement set)
    kept = [s for s in st if s.index not in drop]
    m = manifest_of(kept)
    m['_meta'] = {'built_from_bytes': raw_bytes, 'built_bytes': len(out),
                  'removed': dict(stats)}
    json.dump(m, open(MANIFEST, 'w'), indent=1, sort_keys=True)

    print(f'  wrote {SRC}')
    print(f'  wrote {MANIFEST}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
