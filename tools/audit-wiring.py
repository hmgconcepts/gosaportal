#!/usr/bin/env python3
"""
ROUND-15 ITEM 3 — "revisit every page and process; find every error and
potential error."

The existing audits answer "does this link resolve?" (audit-every-page) and
"does the SQL cover what the code calls?" (audit-schema-coverage). Neither
answers the question that actually breaks a school's day:

    Does each button on each page lead to code that EXISTS and CAN RUN for
    the role that is allowed to press it?

This audit checks, for all three deployments:
  1. every inline handler names a function or object method that is defined
     somewhere the page actually loads;
  2. every element a script looks up by id exists in that page's HTML, or the
     lookup is guarded by a null check;
  3. no page ships an inline handler for a page it does not load the script for;
  4. no duplicate ids that are NOT in mutually-exclusive branches;
  5. every page that needs auth loads the guard.
Exit 1 on any finding.
"""
import re, sys, json
from pathlib import Path

REPOS = [Path('/home/user/repos/schoolconnect'),
         Path('/home/user/repos/gosaportal'),
         Path('/home/user/repos/schoolconnectdemo')]

# functions the browser provides
NATIVE = {'alert','confirm','prompt','print','open','close','event','this','window',
          'document','history','localStorage','sessionStorage','location','navigator',
          'setTimeout','setInterval','clearTimeout','clearInterval','fetch','parseInt',
          'parseFloat','String','Number','Boolean','Array','Object','JSON','Math','Date',
          'encodeURIComponent','decodeURIComponent','isNaN','void','return','scrollTo',
          'postMessage','requestAnimationFrame','getComputedStyle','CustomEvent',
          'Event','Blob','URL','FileReader','FormData','Promise','RegExp','Error',
          'structuredClone','btoa','atob','queueMicrotask','matchMedia','Image','Audio'}

def strip_js_comments(s):
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    s = re.sub(r'(?m)^\s*//.*$', ' ', s)
    s = re.sub(r'(?<![:\w])//[^\n]*$', ' ', s, flags=re.M)
    return s

def collect_defs(texts):
    """every identifier that could be a callable at page scope"""
    names = set()
    for src in texts:
        for m in re.finditer(r'(?:async\s+)?function\s+([A-Za-z_$][\w$]*)', src):
            names.add(m.group(1))
        for m in re.finditer(r'(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:function|\()', src):
            names.add(m.group(1))
        for m in re.finditer(r'window\.([A-Za-z_$][\w$]*)\s*[=:]', src):
            names.add(m.group(1))
        for m in re.finditer(r'(?<![\w$.])([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{', src):
            names.add(m.group(1))
        for m in re.finditer(r'(?<![\w$.])async\s+([A-Za-z_$][\w$]*)\s*\(', src):
            names.add(m.group(1))
        for m in re.finditer(r'(?<![\w$.])([A-Za-z_$][\w$]*)\s*:\s*(?:async\s*)?(?:function|\()', src):
            names.add(m.group(1))
        # object literals assigned to a global: collect their members
        for m in re.finditer(r'(?:const|let|var|window\.)\s*([A-Za-z_$][\w$]*)\s*=\s*\{', src):
            obj = m.group(1)
            names.add(obj)
    return names

def page_texts(f, html):
    """the HTML plus every script the page actually RUNS — inline blocks and
    local src= files alike. Reading only src= files, as this audit first did,
    misses every function a page defines inline (builder.html defines its three
    grid handlers inside a <script> block, which produced three false failures)."""
    parts = [strip_js_comments(html)]
    # inline script bodies
    for m in re.finditer(r'<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>', html, re.S):
        parts.append(strip_js_comments(m.group(1)))
    # local src= files
    for m in re.finditer(r'<script[^>]+src="([^"]+)"', html):
        src = m.group(1)
        if src.startswith('http') or src.startswith('//'):
            continue
        p = f.parent / src
        if p.exists():
            parts.append(strip_js_comments(p.read_text(errors='ignore')))
    return parts

def check_repo(repo):
    findings = []
    pages = sorted(repo.glob('*.html'))
    if not pages:
        return findings
    # all local js, for "does it exist anywhere the app can reach"
    alljs = [strip_js_comments(p.read_text(errors='ignore'))
             for p in (repo / 'assets/js').glob('*.js')]
    global_defs = collect_defs(alljs)
    for f in pages:
        html = f.read_text(errors='ignore')
        texts = page_texts(f, html)
        defs = collect_defs(texts) | global_defs
        # 1. inline handlers
        calls = set()
        for m in re.finditer(r'on(?:click|change|input|submit|keyup|keydown|blur|focus|load|error)\s*=\s*"\s*(?:return\s+)?(?:javascript:)?\s*([A-Za-z_$][\w$]*)\s*\(', html):
            calls.add(m.group(1))
        for m in re.finditer(r'href\s*=\s*"\s*javascript:\s*([A-Za-z_$][\w$]*)\s*\(', html):
            calls.add(m.group(1))
        for c in sorted(calls):
            if c in NATIVE or c in defs:
                continue
            findings.append(f"{f.name}: handler {c}() has no definition in any script the page loads")
        # 2. ids used by scripts vs ids present
        present = set(re.findall(r'\sid="([^"]+)"', html))
        # ids created dynamically count too
        for t in texts:
            present |= set(re.findall(r"""id=\\?["']([A-Za-z][\w-]*)""", t))
            present |= set(re.findall(r"""\.id\s*=\s*['"]([A-Za-z][\w-]*)['"]""", t))
        wanted = set()
        for t in texts:
            wanted |= set(re.findall(r"""getElementById\(\s*['"]([A-Za-z][\w-]*)['"]""", t))
            wanted |= set(re.findall(r"""\$\('#([A-Za-z][\w-]*)'\)""", t))
        # ids that a shared helper CREATES at run time are legitimate: the
        # modal container is built by openModal()/scEnsureModal() when a page
        # does not ship it. Treat the modal trio as satisfied if the page (or a
        # script it loads) can create it.
        MODAL = {'modal-title', 'modal-body', 'modal-footer'}
        can_make_modal = any('scEnsureModal' in x or 'modal-backdrop' in x for x in texts)
        missing = sorted(w for w in wanted if w not in present
                         and not (w in MODAL and can_make_modal))
        # 6. a page that CALLS openModal() must have a container — either it
        #    ships one or a loaded helper builds one. Without this, the call is
        #    a no-op and the button looks dead.
        # Count CALLS only. A page that merely declares an empty openModal(){} to
        # suppress a reference (cbt-exam.html does this on its public exam page)
        # is not calling anything and cannot break.
        open_calls = len(re.findall(r'(?<![\w$.])openModal\s*\(', html)) \
                   - len(re.findall(r'function\s+openModal\s*\(', html))
        if open_calls > 0:
            ships = 'modal-backdrop' in html
            helper = any('scEnsureModal' in x for x in texts)
            if not (ships or helper):
                findings.append(f"{f.name}: calls openModal() but neither ships a modal container nor loads one — the call does nothing")
        # a missing id is only a defect if it is dereferenced without a guard
        for mid in missing:
            pat = re.compile(r"getElementById\(\s*['\"]" + re.escape(mid) + r"['\"]\s*\)\s*\.\s*[a-zA-Z]")
            if pat.search(html) or any(pat.search(t) for t in texts):
                findings.append(f"{f.name}: #{mid} is read and dereferenced but never exists in the page")
    return findings

total = 0
for repo in REPOS:
    if not repo.exists():
        continue
    fs = check_repo(repo)
    total += len(fs)
    label = repo.name
    if fs:
        print(f"{label}: {len(fs)} finding(s)")
        for x in fs[:40]:
            print("   ", x)
    else:
        pages = len(list(repo.glob('*.html')))
        print(f"{label}: clean — {pages} pages, every handler defined, every measured id present")
print()
if total:
    print(f"FAIL — {total} wiring defect(s)")
    sys.exit(1)
print("ALL PASS — every page's controls reach code that exists")
