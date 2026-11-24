# School Connect — Deployment Guide

**Version 12.81 · 20 November 2026**

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

   This file is written to **upgrade a database that already has an older School Connect**, not only to create a new one. Functions whose returned column list grew (for example `sc_my_prep_exams`, which gained two columns in V12.79) are dropped and re-created automatically before the rest of the script runs — Postgres cannot change a function's return type in place, so the file does the drop for you. **You never have to drop a function by hand.** You may see notices such as `School Connect: public.sc_my_prep_exams(text,text) kept in place`; they mean a dependent object held that one function and the script carried on safely.
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

> **"The download page keeps saying *Updating…*" / "the ZIP button does nothing."**
> Two different things, neither of them a broken file. The workspace file viewer
> publishes the whole workspace (~75 MB) before it hands over any file — that is
> the spinner. And an in-app preview panel is a sandboxed frame, which browsers
> forbid from starting a download. Use the download shelf instead
> (`python3 /home/user/work/downloads.py`, port 8080): open it in its **own tab**
> (the ⤢ control), where a click downloads immediately, or press **Copy link** on
> the file you want and paste that address into a normal browser tab. The shelf
> prints each ZIP's size and SHA-256 so you can confirm the download finished.

| Symptom | Cause | Fix |
|---|---|---|
| Every page says **"Database not configured"** | keys not pasted | redo step 4; ensure the file is `assets/js/config.js` at the site root's `assets/js/` |
| Dashboard is empty but the login works | role not set, or no data yet | `select role from public.profiles where email='…';` then complete step 7 |
| "Could not find the function …" in the console | the database predates the page | re-run `database/complete-schema.sql` (step 10.1) |
| `ERROR: 42P13: cannot change return type of existing function` | you are pasting an **older** ZIP's schema into a database created by a newer one — `create or replace function` cannot change a returned column list | download the current ZIP and paste the schema from it; the current file drops those functions itself. Never drop a function by hand |
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

## 15. What is new in V12.83 (upload only — no database step)

V12.83 fixes four things that were never reported as bugs because each one looked
like something else. **There is no SQL to run this round**: `complete-schema.sql` is
byte-identical to V12.82.

| The school says… | What it was | Check it yourself |
|---|---|---|
| "last night's register went in under yesterday" | the calendar day was computed in **UTC** in 103 places | mark a register between 00:00 and 01:00 — the date is the school's day |
| "it signs us out for no reason" | every tab refreshed the **same** token; the second spent one already rotated | open two tabs, watch one refresh in the network panel, stay signed in |
| "my classes are empty, it says I am offline" | a failed "who am I" call **invented the role `student`** | drop the network for 5 s while a page loads — a teacher still sees their classes |
| "the page reloads while I type" / "somebody else's dashboard opened here" | first-visit reload, and a sign-out that left cached pages behind | sign out in one tab — the other leaves too, and the cached pages are gone |

Design notes and the full evidence: [`RELEASE-v12.83.md`](RELEASE-v12.83.md).
After the upload, hard-reload once (the service worker cache name changed to
`v12.83`), and confirm on a phone at home — not only inside the school — that two tabs
stay signed in together.

---

## 15b. What is new in V12.82, and the six checks that prove it installed

If you are upgrading from V12.81 the procedure is the same four steps as §4 —
back up, run `database/complete-schema.sql` once, upload the files, hard-reload.
Then do the **five-minute dashboard checklist** in
[`EXAM-WEEK-LOAD-PLAYBOOK.md`](EXAM-WEEK-LOAD-PLAYBOOK.md) §3 — *raise the two Auth
rate limits first*; that is the change that stops "some students cannot log in" on
home data.

After the pack has run you should see this line among the results:

```
V12.82 installed — every tutor sees every prep timetable, the bell costs one count instead of three queries, and the disk-IO doctor names the table that is doing the writing
```

Then confirm each of these on the live site:

1. **A tutor reads their own prep diary.** Exam Timetable → **🧑‍🏫 Prep sittings by
   tutor** (staff only). It lists the signed-in tutor's prep papers with class, day,
   `10:00–10:45`, **45 min**, venue and how many learners have sat.
2. **And everybody else's, in one click.** Press **All tutors** — the same list opens
   grouped by tutor name, in date order, across every tutor in the school.
3. **The faults are named.** Create a prep exam with a closing time that disagrees with
   its length (45 minutes, but closes three hours later) and reload the card: its row is
   tinted amber and says *"closing time disagrees with the length"*. Two prep papers on
   the same class at the same time say *"clashes with another paper"* on **both** rows.
4. **The bell is one query, not three.** Open Platform Health, then any portal page: the
   network panel shows one `POST /rest/v1/rpc/sc_poll_bundle` about every two minutes per
   tab, instead of a 50-row `GET /notifications` plus `/auth/v1/user` plus
   `sc_message_unread` every 30 seconds. Hidden tabs send nothing.
5. **A bad line no longer signs anybody out.** Throttle a phone to offline in DevTools
   while signed in: you stay signed in, a banner says the work is saved on the device,
   and when you go back online the queued traffic is sent without a reload.
6. **The disk-IO doctor.** Platform Health → **🩺 Load & Disk IO → ↻ Read the report**:
   database size, top-written tables, tables read without an index, bloat, and the
   **🧹 Prune old notices** button with it.

**Rolling back.** Restore the backup taken in step 1 and redeploy the previous ZIP.
V12.82 adds four functions (`sc_poll_bundle`, `sc_prep_teacher_timetable`,
`sc_io_report`, `sc_prune_noise`), one index, and drops **two duplicate** indexes on
`cbt_results`; no table and no column changes, so a file-only rollback is safe for readers.

> **Schema budget: 998,213 B of 1,000,000 (1,787 B of room).** Headroom had fallen to
> 1,462 B. `tools/build-complete-schema.py` gained four proven reclaim rules this round
> (one install-marker row per key, repeated `enable row level security`, the reload
> signal written two ways, and grants already covered by a later grant). The verifier
> still proves the built file is **object-identical** to `complete-schema.raw.sql`.

## 15c. What was new in V12.81

If you are upgrading from V12.79 the procedure is the same four steps as §4 —
back up, run `database/complete-schema.sql` once, upload the files, hard-reload.
This round changes **no table and no column type**: it corrects how a time is
read, when a sitting closes, and what a learner is allowed to see.

After the pack has run you should see this line among the results:

```
V12.81 installed — a prep exam opens at the time the school typed, closes when it ends, and keeps the answers of anyone already sitting
```

Then confirm each of these on the live site:

1. **10:00 means 10:00.** CBT → **+ New Exam / Test** → 🧪 Prep Exam, class
   `JSS 1`, **Starts at** *today 10:00*, duration 45. Under the field the live
   preview reads *"Opens … 10:00 (09:00 UTC)"*. Save, then open the learner's
   dashboard: the sitting says 10:00 and its **Sit now →** button appears at
   10:00 — not 11:00.
2. **The edit form shows your clock.** Edit that exam: the **Starts at** field
   says 10:00 (it used to say 09:00, and re-saving silently moved the paper).
   Save without touching it — the paper does not move.
3. **A sitting closes when it ends.** Take a paper whose window has passed and
   open its link: it is refused with *"This exam has closed."* It used to stay
   open for ever when no closing time was set, and the Exam Timetable now
   advertises exactly the end the database enforces.
4. **A learner inside the window keeps their answers.** Start a paper 5 minutes
   before it closes and submit after it closes: the answers are marked, not
   thrown away.
5. **Already-wrong sittings are repairable in one click.** CBT → **🕒 Check prep
   times** lists every sitting with the school clock, the instant actually
   stored, and **−1 h / −15 m / +15 m / +1 h**. One click rewrites the exam and
   its Exam Timetable row together.

Also in this round, silently: a lesson's attempt count is no longer shared by
two learners with the same name, an unreleased score no longer appears on a
learner's dashboard, "0 attempts" reads as unlimited instead of one, and an
exam can no longer be 30 minutes long and 60 minutes long at the same time.

**Rolling back.** Restore the backup taken in step 1 and redeploy the previous
ZIP. V12.81 adds one column (`school_settings.school_timezone`, defaulted), two
functions and one trigger, and changes the bodies of six others; nothing is
dropped, so a file-only rollback is safe for readers.

## 15d. What was new in V12.79

If you are upgrading from V12.77 the procedure is the same four steps as §4 —
back up, run `database/complete-schema.sql` once, upload the files, hard-reload.
The database step is **not optional** this time either: the timetable columns
and the three new functions live there, and the pages degrade politely (they say
"run database/complete-schema.sql") rather than pretending to work.

After the pack has run you should see this line among the results:

```
V12.79 installed — a prep exam set for a class is a timetable sitting, and every learner can find it
```

Then confirm each of these on the live site:

1. **A prep exam schedules itself.** CBT → **+ New Exam / Test** → purpose
   **🧪 Prep Exam (rehearsal)**, class `SSS 1`, opens *today at 18:30*, duration
   45, venue *Main Hall*. Save. Open **Exam Timetable**: a row exists for SSS 1,
   *PREP EXAM*, 19:30–20:15, Main Hall — written by the exam, not by you. Edit
   the exam's start time: the row **moves**; it does not duplicate.
2. **The learner can find it.** Sign in as an SSS 1 student (or use
   **Admin Oversight → Student portal**). The dashboard card **🧪 Prep Exams**
   lists the sitting with its date, time, venue and a **Sit now →** button.
   An SSS 2 student does not see it. A parent sees their child's, with the
   child's name on the row.
3. **Archiving clears it.** Archive the prep exam: the timetable row disappears.
   Restore it: the row comes back. If a bulk import ever leaves the two out of
   step, CBT → **🔄 Reschedule prep exams** rebuilds every sitting in one click
   and reports how many it wrote.
4. **A student can keep their own ID card.** Sign in as a student and open
   **ID Cards**: the card renders, and below it the **⬇️ Download & print your
   card** bar is visible. Press **⬇ Download PDF** — a PDF downloads named
   `student-id-cards-<their name>-<date>.pdf` containing that learner's card and
   nobody else's. **🖨 Print ALL** is not offered to a student; the design,
   type and class controls are still staff-only.

**Rolling back.** Restore the backup taken in step 1 and redeploy the previous
ZIP. V12.79 only *adds* objects (one column on `cbt_exams`, three on
`exam_timetable`, one unique index, three functions, one trigger) and changes no
column type, so a file-only rollback is safe for readers; the database rollback
needs the backup.

> **Note for the next release (schema budget).** The pack is now 999,867 bytes
> against Supabase's 1,000,000-byte limit for a pasted script. V12.79 fit by
> trimming its own comments; the next round must reclaim space from older,
> superseded narrative before adding objects.

### Free-tier notes (unchanged)

The whole release costs nothing to run: no AI API is called anywhere (the
client-hardening audit prints `No paid AI API dependency introduced`), the
database pack stays inside the Supabase free-tier 500 MB allowance, and the only
network calls the browser makes are to your own Supabase project.

---

## Section 15 — V12.84 upgrade (the right bill, and the paper you keep)

**Database change: yes.** This round changes the fee resolver and the payloads the
fee screens read. The client files change with it; deploy both together or the
Fees page will keep describing the old verdicts.

### 1. What you must do (in order)

1. **Back up** — Supabase → *Database* → *Backups*, or
   `pg_dump "$DATABASE_URL" > backup-before-v12.84.sql`.
2. Paste **`database/complete-schema.sql`** (968,321 B) into the Supabase SQL
   editor and run it. It is idempotent: running it twice is safe, and the pack
   has been proven object-identical to the raw cumulative schema
   (`node tools/verify-complete-schema.mjs` → `ALL PASS`).
3. Upload the client files as usual — `sw.js` carries the new cache name
   `sc-builder-v12.84-20261130-1`, so phones pick the new shell on their next
   visit. No "clear site data" is required.
4. **Nothing else.** No new table, no new cron, no new API key, no paid service.
   The round *shrank* the schema (superseded function bodies dropped) before it
   added to it.

### 2. What the bursar will notice (and should be told)

| Situation | Before V12.84 | From V12.84 |
|---|---|---|
| Price list published **per arm**, learner has **no arm** | charged *another arm's* figure, silently | **"Arm not set — choose the arm"**, both priced arms listed, **nothing charged** |
| Arm written **into the class name** (`JSS 1A`) | charged **₦0**, reported as "no structure" | matched to JSS 1 · arm A, and the note says the arm came from the class name |
| **This term** never published, an older term exists | charged the **older term's** figure | **"No bill for <term>"**, nothing charged; the older figure is offered as an *option* that must be confirmed, then recorded as a hand-set total |
| A figure was **set by hand** | reported as if it came from the price list | reported as **override**, with the note saying who decided it |

Nothing above changes a figure that was already correct. Run the Fees page for
one class before and after if you want to see it: the numbers that agree today
will still agree, and the ones that disagreed will now say why.

### 3. What the exam officer will notice

* A candidate whose **phone rings** during a home paper keeps their paper: the
  clock pauses, the time is handed back, and the interruption is recorded on the
  attempt (`interruptions`, `interruption_ms`, `interruption_log`, `paused_clock`).
* When time is up the candidate sees **"Time is up — send my answers"** and presses
  Send (two-minute grace on an attended page). **Being on a call never sends it.**
* A second tab of the same paper is refused, with an explicit **"Continue in this
  tab"** button — no more two attempts in one sitting.
* A paper is timed by the **school's clock**; a phone with a wrong clock no longer
  closes early.

### 4. Verify the deployment

```bash
node tools/verification/t62-class-fee-truth.mjs               # 43/0
node tools/verification/t63-interruption-not-submission.mjs   # 23/0
node tools/verification/t64-sitting-guards.mjs                # 14/0
node tools/verify-complete-schema.mjs                         # ALL PASS
```

Then, on the live site: **💳 Class Fee Structure** → confirm every per-arm class
has the arm set on its learners (or publish one whole-class bill with the arm
blank). That single check removes the only remaining way to see an "Arm not set"
warning.

**Rolling back.** Restore the backup from step 1 and redeploy the previous ZIP.
V12.84 replaces function bodies and adds payload keys only — it changes no column
type and drops no data — so a file-only rollback is safe for readers; the
database rollback needs the backup.

### Free-tier notes (unchanged)

No AI API, no paid service, no extra cron. The schema stays inside Supabase's
1,000,000-byte pasted-script limit with ~31 KB of headroom, and the fee resolver
answers from tables the platform already reads.
