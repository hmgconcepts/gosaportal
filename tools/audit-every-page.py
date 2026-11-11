#!/usr/bin/env python3
"""
Every page, every link, every deployment — item 4/5 as a permanent detector.

WHY THIS EXISTS
---------------
Item 4 asks for an audit of every pre-existing and every new feature, and item 5
for every page and every process. "Read all 132 pages" is not a verification
result; it is a promise. So the classes of defect that are mechanically provable
are turned into checks that run on every build:

  1. DEAD INTERNAL LINKS   a page links to a .html that is not shipped.
  2. DEAD ASSETS           a page loads a .js/.css/.png the deployment lacks.
  3. UNSHIPPED NAV TARGETS a client deployment keeps navigation to a page the
                           sync deliberately withholds (builder.html and the
                           other builder-only pages).
  4. BROKEN SCRIPT PAGES   a page whose inline JavaScript does not parse.

Each of these has already shipped at least one real defect:
  - projects.html/guide.html were deployed to clients while linking at a
    builder.html that was deliberately not deployed — eleven dead links, one of
    them the primary "Open Builder" call to action.
  - suite.html (a public marketing page that DOES ship) linked Guide and
    Builder, both absent.

WHAT IT DOES NOT CLAIM
----------------------
It cannot tell you a button does the wrong thing. It tells you nothing is
visibly broken and nothing points at a page that is not there. That is the
honest, provable half of "audit every page"; the behavioural half lives in the
per-feature suites (tmp-midterm-policy, tmp-mark-integrity, tmp-cbt-remap, …).
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUITE = ROOT.parent
DEPLOYMENTS = [d for d in (ROOT, SUITE / 'gosaportal', SUITE / 'schoolconnectdemo') if d.exists()]

# Pages the sync withholds from a client deployment on purpose. A client page
# that links to one of these is a dead link, not a missing file.
BUILDER_ONLY = {'builder.html', 'projects.html', 'guide.html', 'offline.html'}

LINK_RE = re.compile(r'(?:href|src)\s*=\s*"([^"]+)"')
IGNORE_PREFIX = ('http://', 'https://', 'mailto:', 'tel:', 'javascript:', 'data:', '#', '//')
ASSET_EXT = ('.js', '.css', '.png', '.jpg', '.jpeg', '.svg', '.webp', '.ico', '.woff', '.woff2', '.ttf')

problems = []
stats = {'pages': 0, 'links': 0, 'deployments': 0}


def check_links(dep: Path, is_client: bool):
    pages = sorted(dep.glob('*.html'))
    names = {p.name for p in pages}
    for page in pages:
        stats['pages'] += 1
        text = page.read_text(errors='replace')
        for raw in LINK_RE.findall(text):
            if raw.startswith(IGNORE_PREFIX):
                continue
            target = raw.split('#')[0].split('?')[0].strip()
            if not target:
                continue
            stats['links'] += 1
            # absolute-from-root or relative both resolve under the deployment
            resolved = dep / target.lstrip('/')
            if target.endswith('.html'):
                if is_client and target in BUILDER_ONLY:
                    problems.append(f'{dep.name}/{page.name}: links to builder-only page {target}')
                elif not resolved.exists():
                    problems.append(f'{dep.name}/{page.name}: DEAD PAGE link -> {target}')
            elif target.endswith(ASSET_EXT):
                if not resolved.exists():
                    problems.append(f'{dep.name}/{page.name}: MISSING ASSET -> {target}')


def check_inline_js():
    """Parse every inline <script> block. A page whose JavaScript does not parse
    cannot work at all, and this catches it without a browser."""
    tool = ROOT / 'tools' / 'test-inline-scripts.py'
    if not tool.exists():
        return
    r = subprocess.run([sys.executable, str(tool)], capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0:
        problems.append('inline JavaScript does not parse:\n' + (r.stdout or r.stderr).strip()[:800])


for dep in DEPLOYMENTS:
    stats['deployments'] += 1
    check_links(dep, is_client=(dep != ROOT))
check_inline_js()

print(f"\nEvery-page audit: {stats['pages']} page(s), {stats['links']} link(s), "
      f"{stats['deployments']} deployment(s)")
if problems:
    print(f"  {len(problems)} problem(s):")
    for p in problems[:40]:
        print('   -', p)
    sys.exit(1)

print("  ALL PASS — every page's links and assets resolve; every inline script parses.")
sys.exit(0)
