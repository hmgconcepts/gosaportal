# School Connect — Deployment Guide

**Version 12.77 · 8 November 2026**

This guide takes a school from "nothing" to "a live, branded school platform with its own data" using **only free tools**. Follow it in order. Every step states exactly what to click or paste, what you should see when it worked, and what to do when it did not.

Total time: about **25 minutes** for the first school.

---

## 0. What you need before you start

| Thing | Why | Cost |
|---|---|---|
| An email address | Supabase account and the first admin login | free |
| A Supabase account — <https://supabase.com> | database, login, API | free tier |
| A static-host account — Netlify, Vercel, Cloudflare Pages or GitHub Pages | serves the HTML | free tier |
| The generated ZIP for your school | the site itself | — |
| A school logo (PNG or SVG, at least 512 px wide) | appears on every page and every ID card | — |

You do **not** need: a server, Docker, Node.js, a domain, a paid certificate, an SMS/email provider, or any AI service. The product ships with no paid dependency.

---

## 1. Create the database (Supabase)

1. Sign in at <https://supabase.com> and press **New project**.
2. Fill in:
   - **Name:** your school's name (e.g. `gosa-portal`)
   - **Database password:** a long password — **save it in your password manager**, it is not shown again
   - **Region:** the one closest to the school
   - **Plan:** Free
3. Press **Create new project** and wait for the status to read **Active** (1–3 minutes).

**Check:** the project dashboard opens and shows "Project is healthy".

---

## 2. Install the schema — the one paste that creates everything

1. In the left sidebar open **SQL Editor**.
2. Press **New query**.
3. Open `database/complete-schema.sql` from the ZIP in a text editor (Notepad, TextEdit, VS Code — anything).
4. Select **all** of it (`Ctrl/Cmd + A`), copy, and paste into the query window.
5. Press **Run** (or `Ctrl/Cmd + Enter`).

The file is ~990 KB across 15,486 lines. It takes **20–60 seconds**. You will see a series of "Success. N rows" messages, ending with the status row
`V12.77 installed — per-student CBT papers, no mark can exceed its maximum, one row per mark`, followed by the catalogue-reload notice which reports `Success. No rows returned` (that silent last line is the signal that makes the API see the new objects — it is supposed to say nothing) and then, from the final catalogue-reload notification, `Success. No rows returned`.

**Check — do this before anything else:**

```sql
select count(*) from information_schema.tables  where table_schema='public';   -- expect 139
select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public';                                                       -- expect 270
select count(*) from pg_policies where schemaname='public';                      -- expect 315
select id from storage.buckets order by id;                                      -- archives, branding, proctor
```

```sql
select * from public.sc_heartbeat_health();   -- expect ok: true, status: healthy
```

```sql
select check_name, status from public.sc_security_posture();
-- expect 7 rows, every status 'pass'
```

That last one is the release's own audit, expressed as a query. If every row says `pass`, the database
you just installed carries every guarantee this release makes; if one says `fail`, the row's `detail`
column names the object that drifted. You can re-run it on any day of the year — it is also on
**Platform Health → Security Posture**, with the same rows and a Copy button.

Any shortfall means the paste was truncated — reload the page and paste again (or upload the file). A correct install also leaves the in-app **Platform Health** page entirely green; that page re-checks every object from the browser and names anything missing.

> **If the pasting fails:** a very small number of browsers truncate a 1 MB paste. Use the **Upload** option in the SQL Editor (the arrow next to *Run*) and choose the file directly. The build refuses to produce a file above the 1,000,000-byte limit Supabase allows, so an unmodified release always fits.

> **If you see `function … already exists` or `policy … already exists`:** harmless — the file is idempotent and is meant to be re-runnable. Only a message starting with **ERROR** matters; scroll to the first one.

### 2b. Storage — nothing to create

Do **not** create buckets by hand. Step 2 already created, with their exact limits and access policies:

| Bucket | Public | Holds |
|---|---|---|
| `archives` | no | term archives (JSON), 50 MB each |
| `proctor` | no | CBT proctoring snapshots, 5 MB each, images only |
| `branding` | yes | the school logo and brand images, 200 KB each |

Verify in **Storage** — three buckets, nothing else needed. Every photo elsewhere in the product (learners, staff, ID cards) is a **URL field**: paste an image URL, including a Google Drive share link, or upload into `branding` and paste its public URL. The URL field always works and needs no storage at all.

---

## 3. Get the API keys

1. Left sidebar → **Project Settings** → **API**.
2. Copy two values:
   - **Project URL** — looks like `https://abcdefghijkl.supabase.co`
   - **anon / public** key — a long string starting `eyJ…`

> The **anon** key is designed to be public; row-level security is what protects the data. **Never** put the `service_role` key in a web page — it bypasses every policy.

---

## 4. Put the keys into the site

1. Open the ZIP's `assets/js/config.js` in a text editor.
2. You will see:

```js
window.SC_CONFIG = {
  supabaseUrl: 'PASTE_YOUR_PROJECT_URL_HERE',
  supabaseAnonKey: 'PASTE_YOUR_ANON_KEY_HERE',
  schoolName: 'Your School Name',
  ...
};
```

3. Paste your two values between the quotes. Keep the quotes.
4. Save.

**Check:** the file now contains `https://<something>.supabase.co` and a key beginning `eyJ`. No other file needs editing.

---

## 5. Deploy the site

### Option A — Netlify (recommended, ~2 minutes)

1. Sign in at <https://app.netlify.com>.
2. Open the **Sites** tab and drag the **unzipped folder** onto the "Drag and drop your site output here" area.
   - Drag the **folder that contains `index.html`**, not the ZIP itself.
3. Netlify returns a URL such as `https://gosa-portal.netlify.app`.

### Option B — Vercel

1. <https://vercel.com> → **Add New… → Project → Deploy** without a Git repository (use the CLI, or upload via the dashboard's *Deploy* tab).
2. **Framework preset:** Other · **Build command:** none · **Output directory:** `.`

### Option C — Cloudflare Pages

1. <https://dash.cloudflare.com> → **Workers & Pages → Create → Pages → Upload assets**.
2. Upload the folder. Build command: none. Output directory: `/`.

### Option D — GitHub Pages

1. Create a repository, upload every file, then **Settings → Pages → Source: Deploy from a branch → main / (root)**.

**Check:** open the URL. The school's landing page loads with its logo, name and colours.

> Optional custom domain: add it in the host's **Domain** settings and follow that host's DNS instructions. Certificates are issued automatically and free by all four hosts.

---

## 6. First login and the first admin

1. Open `https://your-site/` and press **Sign up** (or go to `login.html`).
2. Register with the school's real email address and a strong password.
3. Confirm the email if your Supabase project has email confirmation enabled (**Authentication → Providers → Email**).

Signing up creates a `profiles` row carrying the role you chose, with status **pending** — deliberately: nobody can grant themselves access. Promote yourself once, from the SQL Editor:

```sql
update public.profiles
   set role = 'super_admin', status = 'approved'
 where email = 'head@yourschool.edu';        -- your real address
```

Then sign in again. Every later account is approved from the in-app **Approvals** page (or `Directory → Approve`), never by hand.

**Check:** sign in. The dashboard opens with the full navigation (every module) and your school's branding.

---

## 7. Configure the school (do this once, in this order)

| # | Page | What to set |
|---|---|---|
| 1 | **Settings** | School name, short name, motto, address, phone, email, logo, primary and accent colours |
| 2 | **Academic Setup** | Current session (e.g. `2026/2027`), the term, and the assessment columns with their **maxima** — this is the number every report card is measured against |
| 3 | **Classes / Subjects / Departments** | The school's real lists |
| 4 | **Staff** | Add teachers; then **Approvals** to activate them, and assign each the subjects and classes they teach |
| 5 | **Students** | Add learners (or **Admin Data → Import** for a CSV), with class, admission number, **admission year**, date of birth, gender, blood group, guardian phone |
| 6 | **Fees** | Fee structure per class and term |
| 7 | **Timetable** | Enter the grid, or use the generator |

**Check:** the dashboard tiles show real numbers, and *Students → a learner → Report Card* renders.

> **The assessment maxima are not decoration.** Every mark is validated against the column maximum at the database level. If a CBT paper is worth 21 marks, the column it pushes into must also have a maximum of 21 — the push clamps the percentage, and the database refuses anything above the maximum rather than letting a card print "21 out of 20".

---

## 8. Generate ID cards (optional, and worth doing)

1. Open **ID Cards**.
2. Choose **Student** or **Staff**, a design, the school colours, and the finished size (ID-1 is the credit-card standard, 85.60 × 53.98 mm).
3. Choose the orientation. **Portrait** automatically selects a design drawn for portrait (Vertical or Badge) — a landscape design on a portrait card is scaled to fit and the page says so.
4. Pick a learner, or leave the selector blank to use the typed values.
5. Press **⬇ Download PDF** (production) or **🖨 Print**.

The PDF is vector, at exact millimetres, with every card carrying the front on one side and the back on the other. Print at **100% / "Actual size"** — never "Fit to page".

---

## 9. Verify the deployment

Run these in the SQL Editor. Each must return `ok: true` (or a clean list):

```sql
select * from public.sc_heartbeat_health();            -- ok: true, status: healthy
select count(*) from information_schema.tables
 where table_schema = 'public';                        -- expect 139
select * from public.sc_report_mark_audit() limit 5;   -- no impossible marks
select status, count(*) from public.sc_security_posture()
 group by status;                                      -- expect: pass | 7
```

In the browser:

1. Sign in as the admin — the navigation shows every module.
2. Open **Report Cards**, load a class, enter a score above the column maximum — it is refused with a message naming the maximum.
3. Open **ID Cards** — the preview shows two faces of exactly the same size.
4. Open **Platform Health** → **Security Posture** — every row is green, and the pill reads
   *all 7 checks pass*. Press **🔄 Re-run checks** once to confirm it is reading live.
5. Open the browser console (`F12`) — there are no red errors.

---

## 10. Updates (this is the part most schools get wrong)

When a new release ZIP arrives:

1. **Database first.** Paste the new `database/complete-schema.sql` into the SQL Editor and Run. It is idempotent; existing data is untouched. Wait for the final "reload schema" row.
2. **Then the files.** Upload the new folder over the old one on your host (Netlify: drag the folder onto the existing site → *Deploys*; Vercel/Cloudflare: same idea).
3. **Then let the devices catch up.** Open the site on a phone. A bar appears: **"New version available"** → press **Update now**. The page reloads on the new version, and **the bar does not come back** — the applied version is recorded per device.

If a bar ever reappears after a successful update, that is a bug, not normal behaviour: it means the device is running a cached old worker. Clear the site data once (`Settings → Site settings → Clear data`), reload, and the bar will be gone for good.

---

## 11. Backups

Supabase Free includes **daily backups for 7 days** (Project Settings → Database → Backups). For a school, also keep your own copy:

1. **Database** → **Backups** → **Download** once a term.
2. **Admin Data → Export** in the app downloads the school's data as JSON/CSV.

A restore is: create a new project, paste the schema, then import the export.

---

## 12. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Every page says **"Database not configured"** | keys not pasted | redo step 4; ensure the file is `assets/js/config.js` at the site root's `assets/js/` |
| Dashboard is empty but the login works | role not set, or no data yet | `select role from public.profiles where email='…';` then complete step 7 |
| "Could not find the function …" in the console | the database predates the page | re-run `database/complete-schema.sql` (step 10.1) |
| A page renders unstyled | the folder was uploaded flat | re-upload so that `index.html`, `assets/`, and the pages sit at the same level |
| "Mark X is above the maximum Y" | correct, by design | lower the mark, or raise the column maximum in *Report Cards → Settings* |
| ID card back looks a different shape | a cached old `super.js` | hard-reload (`Ctrl+Shift+R`), then press **Update now** on any other device |
| Print dialog cuts the card | "Fit to page" is on | print at 100% / Actual size |
| `pgrst` errors after a schema run | the reload notification did not execute | re-run the last lines of the schema, or Project Settings → API → **Reload schema cache** |

---

## 13. Cost

| Item | Free tier | When a school would pay |
|---|---|---|
| Supabase | 500 MB database, 1 GB file storage, 50,000 monthly users | only if a large school exceeds the storage |
| Netlify / Vercel / Cloudflare Pages | 100 GB bandwidth / month | only on very heavy traffic |
| Domain | not required (`*.netlify.app` is free) | if the school wants `portal.school.edu.ng` |
| Everything else in the product | — | nothing: no AI API, no SMS gateway, no paid library |

A single school of 1,000 learners fits comfortably inside the free tiers.

---

## 14. Handover checklist

- [ ] Schema installed: 139 tables, 269 functions, `sc_heartbeat_health()` returns `ok: true`
- [ ] Keys pasted, site deployed, landing page loads with the school's branding
- [ ] First `super_admin` created and able to sign in
- [ ] Session, term and assessment maxima configured
- [ ] Classes, subjects, staff (approved) and students loaded
- [ ] Fee structure entered
- [ ] One report card and one ID card produced as a test
- [ ] `sc_report_mark_audit()` clean
- [ ] Backup taken
- [ ] Two staff members shown the **Update now** bar and the *Feature Guide* page

---

## 15. What is new in V12.77, and the four checks that prove it installed

If you are upgrading from V12.76 the procedure is the same four steps as §4 —
back up, run `database/complete-schema.sql` once, upload the files, hard-reload.
The database step is **not optional**: without it CBT pages will refuse to run
(they detect the obsolete engine and stop before a candidate sees a question) and
marks remain unprotected.

After the pack has run, confirm each of these on the live site:

1. **CBT per-candidate papers.** Open a CBT exam whose CSV holds more questions
   than its *Select N questions* value (e.g. 100 questions, 60 selected). Sit it
   as two different candidates: each gets 60 questions, the sets differ, and each
   candidate's set is identical after a refresh. The server side records
   `engine_version = 'v12.77'` and a `selection_seed` you can see in the audit.
2. **No mark can exceed its maximum.** Enter 21 against a 20-mark column: the
   save is refused with an explanation. A duplicated push updates the existing
   row instead of adding a second (Reports → the mark no longer reads 21/20).
3. **Reports → Mid Term → "Load current setting"** fills the panel and the panel
   says *Editing: Mid Term · …*. Fees → **Fee Doctor**: the class dropdown opens
   and lists your classes.
4. **ID cards**: pick Academic Crest, Clinical Staff, Aurora, Transit Access.
   Front and back are the same size and the same way up; choosing a portrait
   design switches the card to portrait and says so.

**Rolling back.** Restore the backup taken in step 1 and redeploy the previous
ZIP. V12.77 only adds objects (two functions, two triggers, one unique index) and
changes no column type, so a rollback of the files alone is safe for readers; the
database rollback needs the backup.

### Free-tier notes (unchanged)

The whole release costs nothing to run: no AI API is called anywhere (the
client-hardening audit prints `No paid AI API dependency introduced`), the
database pack stays inside the Supabase free-tier 500 MB allowance, and the only
network calls the browser makes are to your own Supabase project.
