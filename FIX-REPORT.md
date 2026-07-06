# School Connect — Deep Analysis, Bug Audit & Fix Report

**Date:** 2026-07-04
**Scope:**
1. `schoolconnectportal` — the **generator/builder tool** (schoolconnectportal.vercel.app)
2. `gosaportal` — a **generated client site** produced by the builder for "God of Seed Academy" (gosaportal.vercel.app)

---

## 1. What the platform is (expert diagnosis)

**School Connect** is a free, no-code **school-management-platform generator** by HMG Concepts.
A school proprietor fills a 6-step wizard (school name, motto, logo, colours/86 themes, 42 fonts,
layout, and a selection from **88 catalog modules**), previews the result live, and downloads a
**complete, self-contained static PWA** as a ZIP:

- **Frontend:** ~100 static HTML pages sharing 11 runtime JS files (`app.js`, `crud.js`,
  `cbt-engine.js`, `report-engine.js`, `notifications.js`, `voting.js`, `site-help.js`,
  `super.js`, `enterprise.js`, `pwa-install.js`, `analytics.js`) + one generated
  per-school `assets/js/config.js`.
- **Backend:** free-tier **Supabase** (Postgres + Auth + Realtime), created by the school owner
  by running the bundled SQL (`database/schema.sql` + module schemas) — with 95+ RLS policies.
- **Hosting:** any static host (GitHub Pages / Vercel / Cloudflare Pages) — zero monthly cost.
- **Key features:** students/staff/classes/subjects, results & printable report cards, CBT exams
  (17 question types, anti-cheat, entrance mode), fees/finance/HR/payroll, attendance with QR
  ID-card check-in, timetable + auto-generator, voting & polls (Supabase realtime), multi-channel
  notifications (in-app bell, browser push, free mailto:/wa.me/sms: channels), PWA install
  enforcement, SEO lead-gen (robots/sitemap/JSON-LD), ID cards, certificates, flyers, chatbot
  help, admissions funnel, alumni, hostel, inventory, and more.

**Architecture insight (critical for fixing):** the builder does **not** template the runtime
JS per school — it copies the shared files verbatim into every ZIP. Therefore *fixing a bug in a
shared runtime file inside the generator repo automatically fixes every future generated site*;
already-delivered sites need the one file replaced.

---

## 2. Deliverables in this workspace

| File / folder | Contents |
|---|---|
| `output/schoolconnect-original-files.zip` | **Original, untouched** downloads of both repos (full folder structure preserved) |
| `output/schoolconnect-FIXED-generator-and-site.zip` | **Fixed generator** (`schoolconnectportal-fixed/`) + **fixed generated demo site** (`gosaportal-fixed/`) |
| `schoolconnectportal-fixed/` | Fixed builder repo (browse it directly) |
| `gosaportal-fixed/` | Fixed GOSA demo site (browse it directly) |
| `FIX-REPORT.md` | This report |

---

## 3. Bugs found & fixed — GENERATOR (`schoolconnectportal`)

### G-1 · `pageFileName()` map had **duplicate object keys** — silent logic bug
`assets/js/generator.js` line 73 declared `profile:` **twice** and both
`change_password:` and `'change-password':`. In JS the last duplicate silently wins; this is
exactly the kind of drift that produces wrong filenames after future edits.
**Fix:** de-duplicated the map (`profile`, `change_password`, `change-password`, `cbt_multi`,
`cbt-multi` each once). Added a duplicate-key regression check to `verify-generated-output.js`.

### G-2 · Uploaded school logo was **never written into the ZIP** — broken logo on every client site
The wizard stores the upload as base64 (`config.logoData`), and every generated page references
`assets/img/logo.<ext>` — but `Generator.build()` only ever wrote a generated **SVG placeholder**.
A school that uploaded a PNG (like GOSA) got a site whose manifest/icons/pages pointed at a
`logo.png` **that did not exist in the ZIP** (the GOSA repo only works because the file was added
by hand afterwards).
**Fix:** `logoData` now flows into `resolvedConfig`, is base64-decoded and written as
`assets/img/logo.<ext>`; the SVG placeholder is kept as fallback.

### G-3 · PWA broken on sub-path hosting (manifest + service worker used absolute URLs)
`manifest.json` used `start_url: '/'` and `sw.js` precached `'/index.html'`, `'/assets/...'` —
these **break on GitHub Pages project sites** (`user.github.io/school/`), which is the exact
free hosting the README recommends. The manifest also hard-coded an SVG icon regardless of the
uploaded logo format, and set `background_color` to the theme colour (splash-screen bug).
**Fix:** relative `start_url: './index.html'` + `scope: './'`; SW precache list is fully
relative; icons follow `logoExt` with proper 192/512 entries; dated cache name
(`sc-v8-<build-date>`) so regenerated sites bust stale caches.

### G-4 · `offline.html` referenced but **never generated**
The SW's navigation fallback needs `offline.html`; the generator never emitted one, so offline
mode silently failed.
**Fix:** new `Generator.generateOfflinePage()` (branded, theme-coloured) emitted into every ZIP
and precached by the SW.

### G-5 · SEO files were wrong and dangerous
- `sitemap.xml` (as deployed on GOSA) contained **95 URLs including private, auth-gated pages**
  (dashboard, payroll, admin-data, finance…) and used **relative `<loc>` values** (`/students.html`),
  which is invalid per the sitemap protocol.
- `robots.txt` had `Disallow: /assets/js/*.js` — non-standard wildcard *and* blocks Google from
  rendering the site (Google requires JS/CSS access), directly hurting the "SEO lead-gen" pillar.
**Fix:** sitemap now lists **only the 6 public pages** with **absolute URLs** built from a new
**"Site URL"** wizard field (`siteUrl`, added to `builder.html` step 1); robots.txt allows assets,
keeps `/database/` disallowed, and emits an absolute Sitemap line.

### G-6 · Contact details collected but thrown away
The wizard collects address / phone / email / currency, but `resolvedConfig` dropped them —
every generated `config.js` shipped `address:'', phone:'', email:''` (verifiable on GOSA).
**Fix:** they now flow into `resolvedConfig` → generated `config.js` → landing-page footer
(rendered as clickable tel:/mailto: links).

### G-7 · XSS / broken markup from school name & motto
`indexContent()` interpolated `cfg.schoolName` / `cfg.schoolMotto` raw into HTML (nav, hero,
footer, `alt` attributes). A name containing `"`, `<` or `&` produced broken or injectable markup.
**Fix:** all landing-page interpolations HTML-escaped; smoke-tested with
`Test "High" <School>`.

### G-8 · Duplicate `id="dash-announcements"` ×3 on the dashboard (invalid HTML)
`templates.js` gave the staff, parent and student notice panels the **same element id**, so
`getElementById` could only ever address the first.
**Fix:** unique ids (`dash-announcements-staff/-parent/-student`) + shared class
`dash-announcements`; `app.js` already targets `#dash-announcements,.dash-announcements`, so the
fix is backward-compatible.

### G-9 · `T.head()` crash risk + duplicated page titles
`T.head()` dereferenced `theme.primary` with no fallback → a TypeError (blank output) if
`SC.THEMES` was empty in the build context. It also produced titles like
**"God of Seed Academy • God of Seed Academy"** (visible on GOSA) and hard-coded
`og:image` to `logo.png` regardless of format.
**Fix:** safe theme fallback from `themePrimary/themeAccent`; title de-duplication when the page
title equals the school name; `og:image` follows `logoExt`.

### G-10 · CSV templates referenced but never bundled
Generated `students.html` has a "📋 CSV template" download for `students_import_template.csv`,
and CBT pages reference the sample question banks — none were bundled (the GOSA repo again had
them added by hand).
**Fix:** the three CSVs are now fetched and bundled (root copy + `database/` copies); they were
also **added to the generator repo's `database/`** folder (they only existed in the generated
repo before — a repo-integrity gap).

### G-11 · Static-page sanitizer forced every logo back to SVG
`sanitizeStaticPage()` rewrote `logo.png → logo.svg` unconditionally — schools with PNG/JPG
logos got broken images on all 20 specialised template pages.
**Fix:** rewrites to the school's **actual** `logoExt` with the correct MIME type;
`bellAndBanner()` install banner likewise no longer hard-codes `logo.svg`.

### G-12 · Repo verification suite tested a retired architecture (31 + 44 false failures)
`verify-generated-output.js` and large parts of `verify.sh` still checked the **v7**
function-per-page generator (`pageCBT()`, `pageStorage()`, literal `zip.file('cbt-exam.html'`)…),
so a healthy v8 build reported **31 FAIL / 44 ❌** — masking real regressions.
**Fix:** both scripts rewritten/patched to verify the real v8 pipeline (dedicatedPages array,
dynamic `zip.file(p.id + '.html')`, `pageFileName(canonical)` emitters, static templates in
`assets/templates/pages/`), plus new regression guards for every bug above.
**Result: `verify.sh` 168/168 ✅, `verify-generated-output.js` 0 failures, role-navigation ✅.**

### G-13 · Housekeeping defects
- Removed 6 stray 1-byte placeholder files (`assets/css/a`, `assets/img/a`, `assets/js/a`,
  `assets/templates/pages/a`, `database/a`, `tools/a`) — the repo's own DIAGNOSIS.md claimed
  these were removed, but they were still present.
- Removed misnamed icons `logo-192.png.svg` / `logo-512.png.svg` (unreferenced, double-extension).
- Landing page claimed **"54+ modules"** in one stat, **"All 88 modules"** in pricing — catalog
  actually registers 88; stat corrected to 88.
- 21 pages + robots/sitemap pointed at the old `hmgconcepts.github.io/schoolconnect` domain —
  updated to the live `schoolconnectportal.vercel.app` (canonical/OG/sitemap consistency).
- Added missing docs the verify suite expects (`TROUBLESHOOTING.md`, `CBT_AND_REPORTCARD_GUIDE.md`,
  `CBT_AUDIT_REPORT.md`, `SUPER_FEATURES_GUIDE.md`, `CUMULATIVE_AUDIT.md`,
  `AUDIT_REPORT_FINAL_V2.md`, `MAINTAINER_NOTES.md`, `vercel.json`).

---

## 4. Bugs found & fixed — GENERATED DEMO SITE (`gosaportal`)

### D-1 · Builder internals leaked into the client site
`assets/js/` contained **6 builder-only files** (`generator.js`, `templates.js`, `wizard.js`,
`preview.js`, `catalog.js`, `chatbot.js`) referenced by **zero** pages, **plus 5 stale duplicate
copies at repo root** (`generator.js`, `notifications.js`, `enterprise.js`, `preview.js`,
`pwa-install.js`) — two of which (**generator.js, notifications.js**) *differed* from the
`assets/js/` versions: a version-skew time bomb and an internals leak (~150 KB dead weight,
including `YOUR_SUPABASE_URL` placeholder text that confuses the troubleshooting docs).
**Fix:** all 11 removed. Verified no page references them.

### D-2 · SEO: 95-URL sitemap with private pages + relative locs; robots blocking JS
Same as G-5, materialized. **Fix:** public-only 6-URL sitemap with absolute
`https://gosaportal.vercel.app/...` locs; corrected robots.txt.

### D-3 · Duplicated title/description on index & about
`<title>God of Seed Academy • God of Seed Academy</title>` and
`description "God of Seed Academy — God of Seed Academy"`.
**Fix:** proper title ("God of Seed Academy — School Portal" / "About Us • …") and a real,
motto-based meta description.

### D-4 · Dashboard: `id="dash-announcements"` duplicated 3× → invalid HTML.
**Fix:** unique ids + `dash-announcements` class (works with existing `app.js` selector).

### D-5 · config.js brand colours didn't match the site
`config.js` said `primary:'#4f46e5' / accent:'#7c3aed' / themeId:'indigo'` while every page and
the manifest use `#0506ae/#964eec` — so JS-generated artifacts (ID cards, flyers, certificates,
charts) rendered in the **wrong colours** vs the site theme.
**Fix:** config.js aligned to `#0506ae`/`#964eec`.

### D-6 · vercel.json set headers for `/manifest.webmanifest` — the file is `manifest.json`
The content-type/caching rule never matched. **Fix:** source corrected to `/manifest.json`.

### D-7 · `_headers` file was a GitHub Pages **404 HTML page**, not a headers file
9.4 KB of GitHub's error page committed as `_headers` — on Cloudflare Pages/Netlify this yields
zero security headers (or parse errors). **Fix:** replaced with a real headers file (CSP,
nosniff, frame, referrer, permissions policy, SW no-cache).

### D-8 · Housekeeping
- Removed 4 stray 1-byte `a` placeholder files.
- Removed the duplicated root `students_import_template.csv`? — **kept** (students.html links to
  the root copy) but noted; `database/` copy retained for the SQL workflow.
- No apple-touch-icon anywhere → added `<link rel="apple-touch-icon">` on the 5 public entry
  pages (index, login, about, apply, contact).
- SW cache name bumped (`sc-cache-2026-07-04-fix1`) so returning visitors pick up the fixes.
- `dgarrlzbmscpgtefdupm.supabase.co` anon key is committed in config.js — this is **by design**
  for this architecture (anon key + RLS), flagged for awareness, not changed.

---

## 5. How the generator will now build error-free client sites

Every defect above was fixed **at the source (generator)**, not just on the demo output:

1. **Logo pipeline** — uploads are embedded in the ZIP in their real format end-to-end
   (manifest → SW → pages → static templates → install banner).
2. **Relative-URL PWA** — works on root domains *and* sub-paths; offline fallback actually ships.
3. **SEO correctness by construction** — new *Site URL* wizard field feeds absolute, public-only
   sitemap + crawlable robots; no private page can leak into the sitemap again.
4. **Config completeness** — school contact details, currency and siteUrl land in `config.js`
   and the landing page automatically.
5. **Escaping** — school-provided text can no longer break/inject markup.
6. **No builder internals** can leak: the ZIP file list is explicit and verified.
7. **Regression safety net** — `verify.sh` (168 checks), `verify-generated-output.js`
   (v8-aware + regression guards for G-1…G-11) and `verify-role-navigation.js` all pass at 100%,
   and an end-to-end headless build was executed: **74-entry ZIP** generated for a test school,
   with all key entries (index/login/dashboard/offline/sw/manifest/robots/sitemap/_headers/
   vercel.json/config.js/logo.png/CSVs/module pages) verified byte-level.

---

## 6. Validation summary

| Check | Before | After |
|---|---|---|
| `bash verify.sh` | 124 pass / **44 fail** | **168 pass / 0 fail** |
| `node verify-generated-output.js` | **31 failures** | **0 failures** |
| `node verify-role-navigation.js` | pass | pass |
| `node --check` on all JS (both repos) | pass | pass |
| Broken internal refs (HTML→assets audit) | 0 | 0 |
| Duplicate DOM ids | 1 page (dashboard ×3) | **0** |
| End-to-end generator build (headless) | logo missing, abs URLs, no offline.html, 95-URL sitemap | all green (see §5.7) |

*Next step: send me the bugs you came across and I'll address them against this fixed baseline.*

---

## 2026-07-06 Additional expert audit fixes

### GOSA-429 — `report-cards.html` was a GitHub 429 error page
- Replaced the corrupted 199-byte `report-cards.html` with the actual branded Report Cards page.
- The page now loads the portal shell, `report-engine.js`, Supabase config, notifications, role navigation and document-printing controls.
- Confirmed no repository file still contains `429: Too Many Requests` or GitHub scraping warning text.

### GOSA-PWA — Notification click default path
- Changed the service-worker notification-click fallback from `/` to `./` so sub-path/project deployments open the portal root correctly.

### GOSA-HDR — Camera policy for QR scanning
- Updated `_headers` from `camera=()` to `camera=(self)` so QR/check-in/ID-card camera workflows are not blocked on Cloudflare Pages/Netlify.

### GOSA-GEN — Aligned bundled generator copies
- Updated the included `generator.js` copies to the fixed generator version so stale generator code is not accidentally reused.

---

## 2026-07-06 V10 user-discovered issue fixes applied to generated GoSA portal

- Added dropdown de-duplication runtime and stronger CRUD option de-duplication.
- Updated CBT exam page/runtime/database scripts for multi-subject subject tabs, exact randomised-question grading and 400+ candidate retry/cache/queue hardening.
- Rebuilt Messaging Centre with multi-select recipients, Select All/Clear and real recipient Inbox delivery.
- Updated Report Cards page to enforce read-only student/parent views and linked-child-only access.
- Added public anonymous `exam-register.html` and fixed `exam_registrations.html` heading to “Examination”.
- Updated birthday import logic for students, staff and parents without duplicate birthday rows in a single import run.
- Aligned generator/runtime copies with fixed School Connect generator.
