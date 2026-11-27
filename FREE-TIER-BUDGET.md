# Free-tier budget — what the school gets for ₦0, and where the edges are

**Version:** V12.86 · **Date:** 8 November 2026 · **Plan:** Supabase **Free** (no Pro), hosting on a
free static host (Vercel Hobby or any static host — see §6).

This is the arithmetic behind the instruction *"every tool must remain free-tier; no AI APIs."*
It is written so that the school can see **when** something must change before anything breaks, instead of
discovering a limit from an error page.

---

## 1. The plan limits this platform is designed against

### Supabase Free (checked against Supabase's published pricing, 2026)

| Resource | Free-plan limit | What the platform does about it |
|---|---|---|
| **Database size** | **500 MB** per project | The whole schema is **999,951 B** (≈1.0 MB) — **0.2 %**. The rest is the school's own rows; §3 gives the per-learner cost |
| **File storage** | **1 GB** | Photos, ID-card PDFs, receipts. Compressed on upload; §4 gives the rules |
| **Egress (data transfer out)** | **5 GB / month** (+5 GB cached) | The heaviest actions are report cards and CBT papers; §3 counts them |
| **Monthly active users (Auth)** | **50,000** | A school of 2,000 learners + parents + staff peaks near 6,000. Not a real limit here |
| **Edge Function invocations** | 500,000 / month | **Not used.** All logic is SQL in the database and plain JS in the browser — deliberately, so there is nothing to invoke |
| **Realtime connections** | 200 concurrent | Used for live dashboards only; the app degrades to polling and never depends on it |
| **Active projects** | **2** | One for the live school, one for the demo (`schoolconnectdemo`) |
| **Automatic backups** | **not included** | **This is the one real gap.** §5 is the manual backup routine that replaces it — it is not optional |
| **Pausing** | project **pauses after 7 days of inactivity** | §5 keep-alive; a paused project resumes in minutes and loses nothing |
| **Log retention** | 1 day | Client-side activity log (`activity_log`) is the durable trail, not Supabase logs |

### Hosting (Vercel Hobby, or any static host)

| Resource | Hobby limit | Reality for this app |
|---|---|---|
| Fast Data Transfer | **100 GB / month** | ~70 static pages, ~500 KB each with cache disabled; §3 shows the page-view headroom |
| Edge / function invocations | 1 M / month | **Zero functions are deployed.** The site is static files + `sw.js`; the browser talks to Supabase directly |
| Build minutes | 6,000 / month | No build step: the ZIP is the site. Re-deploys are uploads |
| **Commercial use** | **not allowed on Hobby** | **Read §6 before going live.** A fee-paying school's portal is a commercial use; the honest options are listed there |

---

## 2. Why this design keeps a school inside the free tier

Three decisions carry the whole budget:

1. **No AI APIs.** Marking is deterministic (answer keys, rubrics, CBT engine), report-card comments come from
   teacher input and templates, fee resolution is a precedence rule. There is no per-request cost anywhere.
2. **No server of our own.** Every query goes browser → Supabase (PostgREST/RPC) over HTTPS. Nothing sits in the
   middle to be paid for, and there is no compute to scale.
3. **The database does the work.** Aggregation, eligibility, fee arbitration, timetable derivation and CBT
   grading are SQL functions. One round trip returns a screen's worth of truth, instead of a dozen REST calls
   with a megabyte of JSON between them.

---

## 3. The arithmetic, per learner, per term

Assumptions are deliberately pessimistic (a term = 13 school weeks; a learner has 2 guardians; results are
published twice a term).

| Item | Size / count | Per learner per term |
|---|---|---|
| Learner row + guardian links + class history | ~6 KB | 6 KB |
| Attendance (65 school days × ~200 B) | ~13 KB | 13 KB |
| Results (12 subjects × 2 assessments × ~300 B) | ~7 KB | 7 KB |
| CBT: 1 prep + 1 exam (questions ~40 × 400 B, one attempt, answers) | ~35 KB | 35 KB |
| Fees: 1 invoice + 3 receipts + ledger | ~4 KB | 4 KB |
| Messages / diary / behaviour / assignments (light use) | ~10 KB | 10 KB |
| **Total new data** | | **≈ 75 KB / learner / term** |

**Database headroom.** 500 MB ÷ 75 KB ≈ **6,800 learner-terms**. A 1,000-learner school uses
≈ 75 MB per term, so the free tier holds roughly **six terms (two full sessions) of live data** before any
archive is needed. The archive routine in §5 is what keeps it there for ever: old sessions move out to a
CSV/JSON export (kept by the school) and are removed from the database.

**Egress headroom.** The two heavy read paths are measured against the 5 GB/month allowance:

| Action | Bytes | 5 GB allows |
|---|---|---|
| Learner opens the dashboard (HTML+JS cached by `sw.js`, JSON ~40 KB) | ~40 KB | ~128,000 opens/month |
| Report card printed (one learner, one term) | ~120 KB | ~43,000 printings/month |
| CBT paper loaded (40 questions) | ~90 KB | ~57,000 sittings/month |
| Parent checks fees | ~25 KB | ~205,000 checks/month |

A 1,000-learner school with 2,000 guardians, 12 subjects, one report card and one CBT per term sits around
**600 MB/month** — about **12 %** of the allowance. The number that actually grows is report-card printing at
end of term; §5 gives the rule that keeps it flat.

---

## 4. File storage (the 1 GB bucket)

| Rule | Why |
|---|---|
| Photos are resized to ≤ 400 px on the long edge before upload (JPEG q80, ~35 KB) | 1,000 learner photos ≈ 35 MB instead of 3 GB |
| ID cards are stored as **one PDF per learner** (~120 KB), never as page images | 10× smaller |
| Receipts and report cards are **generated on demand**, not stored | zero bytes per document |
| Documents older than two sessions are exported and removed | keeps the bucket flat |
| **Max bucket plan:** photos 35 MB + IDs 120 MB + notices/assignments 300 MB ≈ **455 MB** | stays inside 1 GB with room to spare |

Anything the school uploads that would push the bucket past **800 MB** is refused at upload with a plain
message, not a silent failure — the limit is enforced in the app so nobody discovers it from an error page.

---

## 5. Operating routine — the price of free

The free tier has no backups and pauses after seven idle days. Both are handled by a five-minute routine:

| Cadence | Task | How |
|---|---|---|
| **Daily (school day)** | nothing — the app is used, so the project never idles | — |
| **Weekly, holidays** | keep-alive: open the portal, or run any report | one visit resets the 7-day timer |
| **After every publishing burst** (fees, results, CBT) | **Export**: Supabase → Database → Backups is not available on Free, so use `Database → Data → Download` per table, or the app's own *Data export* page | the export is the backup; keep it off-site (school Google Drive) |
| **End of session** | **Archive**: export `results`, `attendance`, `cbt_results`, `fee_payments` for the closed session, then delete those rows | keeps the 500 MB ceiling flat for ever |
| **Monthly** | Check *Settings → Usage*: database %, storage %, egress % | act at the thresholds below |

### The thresholds (act **before** the limit)

| Reading | Action |
|---|---|
| Database **> 350 MB** (70 %) | run the session archive early |
| Storage **> 700 MB** | clear the oldest session's documents |
| Egress **> 3.5 GB** in a month | turn on `sw.js` caching for report cards (it is on by default) and stop bulk PDF re-prints |
| MAU **> 40,000** | none needed — a school cannot reach this; it is noted only for completeness |
| Project **paused** | Supabase dashboard → *Restore project*. No data is lost; the app shows a friendly "waking up" message |

---

## 6. The one honest warning: Vercel Hobby is for non-commercial use

Vercel's Hobby plan is free **for personal, non-commercial projects**. A school portal that takes fees is a
commercial use, and Vercel's terms say so. Nothing in this codebase depends on Vercel specifically — it is
static HTML, CSS, JS and one service worker — so the school has three free-tier-safe routes:

| Option | Free? | Notes |
|---|---|---|
| **Cloudflare Pages** | Yes, including commercial use | Unlimited bandwidth on the free plan, custom domain, same upload-a-folder workflow. **Recommended** |
| **Netlify Free** | Yes, commercial use allowed | 100 GB/month, 300 build minutes (no build needed) |
| **Vercel Hobby** | Free but non-commercial only | Fine for a demo or a school that charges nothing; read the terms before relying on it |
| **GitHub Pages** | Yes, commercial use allowed | Static only — this app is static, so it works; no custom server headers |

Supabase's free tier has no such restriction, and nothing here needs Supabase Pro.

---

## 7. What would make the school need a paid plan (and what it would cost)

| Trigger | Why | Free workaround before paying |
|---|---|---|
| Database > 500 MB | archive not run | run §5 archive — this alone postpones it for years |
| Needs **automated daily backups** | Free has none | scheduled export to the school's own Drive (§5) |
| Cannot accept the **7-day pause** | low-traffic holiday periods | weekly keep-alive visit; or a free uptime monitor (UptimeRobot free tier) pinging the portal |
| Needs **email sending that always arrives** | free-tier auth mail is rate-limited | use the school's own SMTP (any free mailbox provider) in Supabase Auth → SMTP settings; see `DEPLOYMENT.md` |
| Needs 2+ custom environments | 2 active free projects | use the demo project as staging, or pause the demo while not in use |

Only the last two are genuinely plan-shaped problems, and both are solved in settings, not by upgrading.

---

## 7b. The Supabase email, answered without paying (V12.86)

The school received Supabase's **"exhausting Disk IO Budget"** notice for project **God of Seed Academy
Portal** (ref `auptmhagbksebetbxkvn`, region `eu-west-1`, compute **NANO**), and the usage panel shows:

| Resource | Used | Limit | State |
|---|---|---|---|
| Egress | 1.33 GB | 5 GB | fine |
| Database size | 118 MB | 500 MB | fine |
| Monthly active users | 180 | 50,000 | fine |
| File storage | 0.13 GB | 1 GB | fine |
| **Log Ingestion** | **1.01 GB** | **1 GB** | **over — this is the actual breach** |
| Log Query | 0 GB | 100 GB | fine |

Two separate things are being reported in one email, and neither needs Pro ($25/month) or a compute upgrade.

**(a) Disk IO Budget.** Supabase warns when sustained read/write IO on a Nano instance outruns its budget; the
usual cause on this platform is *polling* — a page asking the database the same question on a timer, and
per-row functions that re-read whole tables. What V12.86 does about it, all free:

1. **Nothing polls per second.** The exam clock is display-only; the database is asked once per reconnect
   (`sc_cbt_window_state`), not once per tick.
2. **Repairs are set-based.** Each Fee Doctor check is one statement over the whole table, not a loop over
   learners — a 148-learner scan is a handful of reads, not hundreds.
3. **The heaviest read (the bill) is unchanged in cost but no longer repeated**: `sc_fee_bill_v2_structure`
   is one call per learner per screen, and the new extras lookup is a single indexed query against
   `class_fee_extra` rather than a scan.
4. **Write amortisation**: draft answers go to the device, not the database; the receipt snapshot is
   recomputed by a statement-level trigger, not a row-level one.
5. **Do not run the doctor on a timer.** It is an administrator action; running it every 15 minutes is the
   one thing that would genuinely burn IO.

**(b) Log Ingestion over 1 GB.** This is a *plan meter*, not a hard stop, and it is the only number actually
over. Free remedies, in order of effect:

1. **Turn down what is logged**: Supabase → *Project Settings → Logs* — keep only `postgres` error logs and
   drop the verbose `edge_logs`/`postgrest` request logs the platform does not read. (Saves the bulk.)
2. **Stop the noisy source**: `pg_stat_statements`-style noise usually comes from repeated failing calls. The
   V12.78 schema doctor (`platform-health.html`) names the table and function doing the writing — run it,
   fix that one thing, and the log volume stops being generated.
3. **Keep the 1-day retention** (free plan) and export anything you need to keep to the school's own Drive
   with the routine in §5.
4. **Trim the activity log** with the archive routine in §5 — `activity_log` grows with use and is the most
   common source of both log volume and disk-IO churn.

**What the school should NOT do:** upgrade compute, buy Pro, or turn off Row-Level Security to "reduce load".
None of those is needed for either message, and the first two cost money.

---

## 8. Summary

| Question | Answer |
|---|---|
| Does anything here cost money at runtime? | **No.** No AI APIs, no servers, no paid services, no build pipeline. |
| Does it fit Supabase Free? | **Yes** — schema is 0.2 % of the database allowance; a 1,000-learner school is ~12 % of monthly egress. |
| What is the real free-tier risk? | **No automatic backups** and the **7-day pause**. §5 is the answer to both, and both are the school's routine, not a code change. |
| Anything that must be decided before going live? | **Hosting terms (§6).** Cloudflare Pages or Netlify Free are the free-tier-safe choices for a commercial school. |
