#!/usr/bin/env python3
"""Split a PostgreSQL script into statements, tracking byte offsets.

Handles: dollar quoting ($tag$...$tag$), single/double quoted strings,
E'' escapes, line comments (--), block comments (/* */ nestable).
"""
import re

DOLLAR = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)?\$')


class Stmt:
    __slots__ = ('text', 'start', 'end', 'kind', 'key', 'index', 'sig_args',
                 'replaceable', 'name', 'if_not_exists')

    def __init__(self, text, start, end, index):
        self.text = text
        self.start = start
        self.end = end
        self.index = index
        self.kind = None
        self.key = None

    @property
    def size(self):
        return len(self.text)

    def __repr__(self):
        return f'<Stmt {self.index} {self.kind} {self.size}B>'


def split_statements(sql):
    """Return list of Stmt. Each statement text includes preceding comments/whitespace."""
    stmts = []
    i = 0
    n = len(sql)
    start = 0
    while i < n:
        c = sql[i]
        # line comment
        if c == '-' and i + 1 < n and sql[i + 1] == '-':
            j = sql.find('\n', i)
            i = n if j < 0 else j + 1
            continue
        # block comment
        if c == '/' and i + 1 < n and sql[i + 1] == '*':
            depth = 1
            i += 2
            while i < n and depth:
                if sql.startswith('/*', i):
                    depth += 1
                    i += 2
                elif sql.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        # single quote
        if c == "'":
            i += 1
            while i < n:
                if sql[i] == "'":
                    if i + 1 < n and sql[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        # double quote (identifier)
        if c == '"':
            i += 1
            while i < n:
                if sql[i] == '"':
                    if i + 1 < n and sql[i + 1] == '"':
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        # dollar quote
        if c == '$':
            m = DOLLAR.match(sql, i)
            if m:
                tag = m.group(0)
                close = sql.find(tag, m.end())
                if close >= 0:
                    i = close + len(tag)
                    continue
            i += 1
            continue
        if c == ';':
            stmts.append(Stmt(sql[start:i + 1], start, i + 1, len(stmts)))
            start = i + 1
        i += 1
    tail = sql[start:]
    if tail.strip() and tail.strip().strip(';').strip():
        stmts.append(Stmt(tail, start, n, len(stmts)))
    return stmts


# ---------------------------------------------------------------- classification
FUNC_RE = re.compile(
    r'create\s+(?:or\s+replace\s+)?function\s+(?:([a-z0-9_]+)\.)?("?[a-z0-9_]+"?)\s*\(',
    re.I)
VIEW_RE = re.compile(
    r'create\s+(or\s+replace\s+)?(?:materialized\s+)?view\s+(?:([a-z0-9_]+)\.)?("?[a-z0-9_]+"?)',
    re.I)
TABLE_RE = re.compile(
    r'create\s+table\s+(if\s+not\s+exists\s+)?(?:([a-z0-9_]+)\.)?("?[a-z0-9_]+"?)',
    re.I)
POLICY_RE = re.compile(
    r'create\s+policy\s+("?[^"\s]+"?)\s+on\s+(?:([a-z0-9_]+)\.)?("?[a-z0-9_]+"?)', re.I)
TRIGGER_RE = re.compile(
    r'create\s+(?:or\s+replace\s+)?(?:constraint\s+)?trigger\s+("?[^"\s]+"?)\s+', re.I)
INDEX_RE = re.compile(
    r'create\s+(unique\s+)?index\s+(concurrently\s+)?(if\s+not\s+exists\s+)?'
    r'("?[a-z0-9_]+"?)\s+on\s+(?:([a-z0-9_]+)\.)?("?[a-z0-9_]+"?)', re.I)
ALTER_ADDCOL_RE = re.compile(
    r'alter\s+table\s+(?:if\s+exists\s+)?(?:([a-z0-9_]+)\.)?("?[a-z0-9_]+"?)'
    r'\s+add\s+column\s+(if\s+not\s+exists\s+)?("?[a-z0-9_]+"?)', re.I)


def _sig_args(text, open_idx):
    """Extract the argument list text of a function declaration, balanced parens."""
    depth = 0
    i = open_idx
    while i < len(text):
        ch = text[i]
        if ch == "'":
            i += 1
            while i < len(text):
                if text[i] == "'":
                    if i + 1 < len(text) and text[i + 1] == "'":
                        i += 2
                        continue
                    break
                i += 1
        elif ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i]
        i += 1
    return text[open_idx + 1:]


RETURNS_RE = re.compile(r'\breturns\b', re.I)


def classify(st):
    """Set st.kind / st.key. Only the first meaningful keywords matter."""
    # strip leading comments/whitespace
    body = re.sub(r'^\s*(?:--[^\n]*\n\s*|/\*.*?\*/\s*)*', '', st.text, flags=re.S)
    head = body[:400].lower()
    m = FUNC_RE.match(body)
    if m:
        args = _sig_args(body, m.end() - 1)
        # normalise: name(arg types only) - drop default values & arg names
        types = []
        depth = 0
        cur = ''
        for ch in args:
            if ch in '([':
                depth += 1
            elif ch in ')]':
                depth -= 1
            if ch == ',' and depth == 0:
                types.append(cur)
                cur = ''
            else:
                cur += ch
        if cur.strip():
            types.append(cur)
        norm = []
        for t in types:
            t = t.strip()
            if not t:
                continue
            # drop DEFAULT ...
            t = re.split(r'\bdefault\b', t, flags=re.I)[0]
            # drop mode keywords
            t = re.sub(r'^\s*(in|out|inout|variadic)\s+', '', t, flags=re.I)
            toks = t.split()
            # last 1-2 tokens are the type; a leading token that isn't a type keyword is the arg name
            t = t.strip().lower()
            norm.append(t)
        st.kind = 'function'
        st.key = 'function %s(%s)' % ((m.group(1) or 'public') + '.' + m.group(2).strip('"'),
                                      ','.join(sorted(norm)))
        st.sig_args = args
        # is it CREATE OR REPLACE?
        st.replaceable = bool(re.match(r'create\s+or\s+replace', body, re.I))
        st.name = (m.group(1) or 'public') + '.' + m.group(2).strip('"')
        return st

    m = VIEW_RE.match(body)
    if m:
        st.kind = 'view'
        st.name = (m.group(2) or 'public') + '.' + m.group(3).strip('"')
        st.key = 'view ' + st.name
        st.replaceable = bool(m.group(1))
        return st

    m = TABLE_RE.match(body)
    if m:
        st.kind = 'table'
        st.name = (m.group(2) or 'public') + '.' + m.group(3).strip('"')
        st.key = 'table ' + st.name
        st.replaceable = False
        st.if_not_exists = bool(m.group(1))
        return st

    m = POLICY_RE.match(body)
    if m:
        st.kind = 'policy'
        st.name = (m.group(2) or 'public') + '.' + m.group(3).strip('"') + '.' + m.group(1).strip('"')
        st.key = 'policy ' + st.name
        st.replaceable = False
        return st

    m = TRIGGER_RE.match(body)
    if m:
        st.kind = 'trigger'
        st.key = 'trigger ' + m.group(1).strip('"')
        st.replaceable = False
        return st

    m = INDEX_RE.match(body)
    if m:
        st.kind = 'index'
        st.name = (m.group(5) or 'public') + '.' + m.group(4).strip('"')
        st.key = 'index ' + st.name
        st.replaceable = False
        st.if_not_exists = bool(m.group(3))
        return st

    m = ALTER_ADDCOL_RE.match(body)
    if m:
        st.kind = 'addcolumn'
        st.key = 'column %s.%s.%s' % ((m.group(1) or 'public'), m.group(2).strip('"'),
                                      m.group(4).strip('"'))
        st.replaceable = False
        return st

    if re.match(r'drop\s+policy', head):
        st.kind = 'drop policy'
    elif re.match(r'drop\s+trigger', head):
        st.kind = 'drop trigger'
    elif re.match(r'drop\s+function', head):
        st.kind = 'drop function'
    elif re.match(r'drop\s+view', head):
        st.kind = 'drop view'
    elif re.match(r'alter\s+table', head):
        st.kind = 'alter table'
    elif re.match(r'grant|revoke', head):
        st.kind = 'grant'
    elif re.match(r'create\s+type', head):
        st.kind = 'type'
    elif re.match(r'create\s+(unique\s+)?index', head):
        st.kind = 'index'
    elif re.match(r'create\s+(or\s+replace\s+)?function', head):
        st.kind = 'function'
    elif re.match(r'do\b', head):
        st.kind = 'do'
    elif re.match(r'comment\s+on', head):
        st.kind = 'comment'
    elif re.match(r'(select|set|begin|commit|insert|update|delete|with|analyze|listen|notify)', head):
        st.kind = 'data'
    elif re.match(r'create\s+(sequence|schema|extension|domain|rule)', head):
        st.kind = 'other'
    elif head.strip() == '':
        st.kind = 'blank'
    else:
        st.kind = 'other'
    st.key = None
    return st
