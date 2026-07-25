# 🚀 DEPLOYMENT GUIDE — School Connect Gen v8

This guide has **two parts**:

- **Part A** — deploy **the Builder** (this repo) so schools can use the wizard.
- **Part B** — what **a school** does after downloading a generated ZIP.

Everything uses **free tools only**. No credit card, no monthly fees, no AI APIs.

> ## CBT V5.1 existing-database requirement
> If correct attempts currently record zero, stop new sittings, back up Supabase,
> run **`database/cbt-v5.1-zero-score-hotfix.sql`**, then deploy the matching V5.1
> CBT pages/engine. The candidate page deliberately refuses to start against an
> old engine. In CBT Manager use **Diagnose Scoring** and **Repair Scoring** on
> legacy exams. If the getter specifically reports `column "motto" does not exist`,
> run `database/cbt-v5.1.1-getter-school-settings-fix.sql`. Fresh projects run only
> `complete-schema.sql`, which includes both repairs.

---

# PART A — Deploy the Builder (this repository)

The builder is a 100% static, browser-only app. It needs **no database** to run —
it generates ZIPs entirely in the visitor's browser.

## A1. Get the files onto GitHub
1. Create a free GitHub account, then a **new public repository**
   (e.g. `school-connect-gen`) at https://github.com/new.
2. Upload **all** the files and folders from this package (keep the structure):
   `builder.html`, `index.html`, `assets/`, `database/`, the `.md` docs,
   `manifest.json`, `sw.js`, `robots.txt`, `sitemap.xml`, `.nojekyll`.
   > The empty **`.nojekyll`** file matters — it stops GitHub Pages from trying to
   > run Jekyll, which can hide files that start with `_`.

## A2. Turn on GitHub Pages
1. In the repo: **Settings → Pages**.
2. **Source:** *Deploy from a branch*. **Branch:** `main`. **Folder:** `/ (root)`. **Save.**
3. Wait ~1 minute. Your live builder appears at `https://USERNAME.github.io/REPO/`.

## A3. (Optional) Enable the live demos
The voting/notifications demo pages can talk to a Supabase project if you want
live data on the builder site itself:
1. Create a free Supabase project (see Part B, step 1).
2. Run `database/complete-schema.sql` in its SQL Editor.
3. Open `assets/js/config.js` and paste your `window.SUPABASE_URL` and
   `window.SUPABASE_KEY`. Re-commit.
> This is optional. The wizard and ZIP generation work without it.

## A4. (Optional) Other free hosts
- **Netlify Drop:** drag the folder onto https://app.netlify.com/drop.
- **Cloudflare Pages / Vercel:** connect the repo, framework = *None/Static*, build command = *(none)*, output dir = root.

---

# PART B — A school deploys its generated ZIP

> Every generated ZIP also contains its **own** `DEPLOYMENT-GUIDE.md` and
> `TROUBLESHOOTING.md` tailored to that school. This is the same flow.

## B1. Create a free database (Supabase)
1. https://supabase.com → **Start your project** → sign in with GitHub.
2. **New project** → name it, **generate & save** a DB password, pick the nearest
   region → **Create new project** (wait ~2 minutes).

## B2. Install the tables (run ONE SQL file)
1. Supabase → **SQL Editor → + New query**.
2. Open **`database/complete-schema.sql`** from the ZIP, copy **all** of it, paste, **Run**.
3. Confirm the final success message: **`School Connect CBT V5.1 definitive grading engine installed — use RPC cbt_submit_v5 ✅`**.
   - ✅ This one file installs everything (all tables, RLS, triggers, views, and
     **every RPC the app calls** — all 16 — plus the CBT scale pack and the
     Punctuality Points engine).
   - ✅ It is **idempotent** — safe to run again.
   - ✅ Apart from the optional demo packs (`demo-users.sql`, `demo-seed.sql`),
     this is the **only** SQL your deployment ever needs.
   - ❌ You do **not** need to run any smaller feature SQL separately (each of those
     is only for upgrading an *older* already-live project without a full re-run).
   - ❌ If you ever see `relation "public.profiles" does not exist`, you ran an old
     file — use the one from **this** ZIP, where the ordering bug is fixed.

## B3. Get your API keys
Supabase → **Project Settings → API**. Copy the **Project URL** and the
**anon public** key.

## B4. Paste keys into the app
Open `assets/js/config.js` (or `public/assets/js/config.js` for a Modern build) and
replace the placeholders:
```js
window.SUPABASE_URL = 'https://YOUR-PROJECT.supabase.co';
window.SUPABASE_KEY = 'eyJ...your anon public key...';
```
Save. (The anon key is safe to publish — RLS protects the data.)

## B5. Host the site (free)
- **GitHub Pages:** new public repo → upload all ZIP files → Settings → Pages →
  branch `main`, root → Save.
- **Netlify Drop / Cloudflare Pages / Vercel:** as in Part A4.

In Supabase → **Authentication → URL Configuration**, set **Site URL** to your live
address so confirmation emails link correctly.

## B6. Make yourself the admin
1. On the live site: **Sign in → Request access** → fill the form, choose **Admin**,
   submit, then **click the confirmation email**.
2. Supabase → SQL Editor → run (with **your** email):
```sql
update public.profiles
   set role = 'admin', status = 'approved'
 where email = 'your-email@example.com';
```
3. Sign in. You now have full admin access. 🎉

---

## ✅ Master checklist
- [ ] (Builder) repo uploaded, Pages enabled, builder opens
- [ ] (School) Supabase project created
- [ ] (School) `schema.sql` run → success message
- [ ] (School) URL + anon key pasted into `config.js`
- [ ] (School) site hosted and opening in a browser
- [ ] (School) first admin registered, confirmed, promoted, and logged in

## 🆘 If something breaks
Open **TROUBLESHOOTING.md** (top-level here, and inside every generated ZIP). It
maps each exact error message — including the two `42P01` errors and the login
issue — to its precise fix.

Powered by **HMG Concepts** — https://hmgconcepts.pages.dev/


## School Connect v1 Final Deployment Note
Run `database/complete-schema.sql` once in Supabase SQL Editor for a fresh deployment. It is now cumulative and self-contained: it includes base schema, CBT, voting, report cards, enterprise tables, class fee structures, product store, status audit log, parent-child access policies, staff check-in deadline settings, and schema-cache reload notifications. The smaller update SQL files are retained only for upgrading older deployed clients.

---

> ## ⚠️ V12 IMPORTANT UPDATE (this build)
> The database layer was **rebuilt** into ONE clean, dependency-ordered, idempotent file:
> **`database/complete-schema.sql`** (v12). Guides below that say "run the schema" refer to
> exactly that file — paste it once into the Supabase SQL Editor and run. It also **repairs**
> older deployments (missing tables/columns/unique keys) and reloads the API schema cache,
> eliminating all "table not found in schema cache" and "ON CONFLICT" errors permanently.
> The former merged file is kept for reference as `database/complete-schema-v11-LEGACY-MERGED.sql`.
> Do not run legacy/migration SQL files after the v12 schema — they are superseded.
