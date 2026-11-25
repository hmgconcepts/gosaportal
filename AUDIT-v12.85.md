# Round 30 audit — V12.85

**Date:** 8 November 2026
**Question the school asked:** *"Go back through every prompt from the start of this conversation. Which
have been obeyed, which have not? Which features were asked for and never built? Which pre-existing
features were dropped? Put them all back, then do a deep all-round bug and consistency analysis.
Do not assume — check and verify. Visit the live sites and the repos. Use a different approach,
because what has been done so far has not rectified the issues."*

This document is that audit. It is deliberately written so that every claim can be checked against a
file, a command or a test in this repository. Where something could **not** be verified, it says so
in §7 instead of being quietly left out.

---

## 1. The different approach (what was actually done this round)

The previous rounds re-ran the same gate and reported green. That was not evidence that the live
system was right, so this round started from the outside in:

| Step | Command / method | What it proved |
|---|---|---|
| 1. Live-site forensics | `curl -s https://gosaportal.vercel.app/sw.js` | the site serves `sc-client-v12.84-20261130-1` — the newest build is deployed |
| 2. Live bytes vs repo bytes | `curl -s …/cbt-exam.html \| wc -c` vs `wc -c` of the repo file | 93,645 B both — **the live site is not stale**, so "it is still broken" is a code issue, not a deployment issue |
| 3. Live behaviour grep | `curl -s …/cbt-exam.html \| grep -c 'pauseForInterruption\|takeSitting'` | 6 hits — the V12.84 fixes really are in the deployed page |
| 4. Repo-wide search for the missing feature | `grep -rn prep_timetable assets/js assets/templates/pages` | **no match** → the teacher prep timetable was never built (see §4, item 1) |
| 5. Read the code that the complaint names | `cbt.html` `resyncPrep()`, `sc_prep_sync_all`, `sc_prep_sync_exam` | the button wrote with no preview and no diff (see §4, item 6) |
| 6. Execute the shipped schema | PGlite (`@electric-sql/pglite`) loading `database/complete-schema.sql` | the fee arbitration bug reproduced **before** it was fixed (t65) |
| 7. Re-check the deployed pages against source | `curl` sizes for `fees.html` (162,464 B) | identical to the repo file |
| 8. Re-run the shipped schema **on a database that already has data** | `tmp-rerun-live.mjs` | it went red: **the published class total changed from ₦35,100 to ₦27,000 on the second run.** A defect no green gate had ever looked for — the money moves when the school upgrades |

The conclusion of that forensics is important on its own: **there was no stale deployment.** Everything
that was still wrong was still wrong in the source, in the shipped ZIP and on the live site at the same time.

---

## 2. Prompts that HAVE been obeyed (with the proof)

Each row names the artefact that fails if the behaviour regresses.

| Standing instruction | Where it lives | What proves it |
|---|---|---|
| Fix defects at the root cause, never silence a failing test | `tools/verification/*.mjs`, `work/run-all-tests.sh` | 60+ suites; the gate has no `skip` and no `|| true`. This round's fee fix is proved by `t65` (15/0) **without** weakening `t62` (43/0) |
| Never remove a pre-existing feature; enhance it | `tools/audit-v5.py` feature inventory | 513 checks; nothing this round was deleted, only added to (§5) |
| Every feature must have a detailed explanation | page copy + `RELEASE-v12.8x.md` per round | each release note carries a per-feature "what the school would say / what was actually happening / what changed" |
| Deployment documented in unambiguous steps | `DEPLOYMENT.md` | step-by-step, Supabase → Vercel → service worker, with verification commands |
| **No AI APIs** (not cost-effective) | whole codebase | `grep -rn "openai\|anthropic\|gemini\|huggingface" assets/js` → 0 hits. CBT marking, report cards, fee resolution, timetables are all deterministic SQL/JS |
| Free tier only — **Supabase free tier, no Pro** | `FREE-TIER-BUDGET.md`, `SUPABASE_FREE_TIER_PROTECTION.md` | every feature is designed to fit 500 MB / 5 GB egress / 50k MAU; the budget document now sets the thresholds (§4, item 7) |
| Deliver as the 3 versioned ZIPs | `work/mkzips.py` | `schoolconnect-v12.85.zip`, `gosaportal-v12.85.zip`, `schoolconnectdemo-v12.85.zip` |
| Cut workspace bloat | `README-WORKSPACE.md` | 93 MB / ~1,700 files; no `debs/`, no `node_modules`, no logs |
| Prove it with tests, not prose | `t62`…`t67` | each new behaviour has a suite that fails when the behaviour is removed |
| Timetables / prep exams scheduled automatically with date, time, duration | `sc_prep_sync_exam`, `exam_timetable` trigger | `t45` (prep schedule), `t57` (tutor timetable), `t66` (reschedule preview) |
| A prep exam must reach the learners of that class, with date and time | `sc_my_prep_exams`, dashboard card | `t45` §5 |
| One number for money everywhere (resolver = account = ledger = screen) | `sc_fee_bill_v2`, `sc_fee_account_for`, `sc_student_fee_state` | `t65` §5 "every screen quotes the same number"; `tmp-bill-resolve` 77/0 |
| A ringing phone must not submit a paper | `cbt-exam.html` pause/resume | `t63` 23/0 against the shipped page |
| Two tabs, a full phone store, a wrong phone clock must not break a sitting | `cbt-exam.html` guards | `t64` 14/0 |
| The school's clock, not UTC's, on every date | `sc_school_tz`, `t59`, `audit-school-day.py` | `t59` + static audit |
| Nobody is rendered as somebody else (role never guessed) | `t61` | 100% |
| One refresh per device; sign-out really leaves | `t60` | 100% |

---

## 3. Prompts that were NOT obeyed (honest list)

| # | Instruction | Status before this round | Now |
|---|---|---|---|
| 1 | Item 1 — a **teacher's own prep timetable**, per class, on his own screen, to catch a wrong time or duration, **plus the other tutors' sittings** | **Not built.** `sc_prep_teacher_timetable` existed and was correct, but it was only reachable on the Exam Timetable page; the dashboard had no card and `grep prep_timetable assets/js assets/templates` returned nothing | **Built** — see §4 item 1 |
| 2 | Item 6 — *explain* what "Reschedule prep exams" does, and stop it changing things invisibly | **Not explained.** The button wrote and reported a count; no preview, no diff, no undo | **Built** — see §4 item 6 |
| 3 | Item 5 — two different current-term fees for one learner (₦17,100 vs ₦35,100) | **Reproduced and fixed at the root cause this round**, not before | see §4 item 5 |
| 4 | Item 3/4 — interruption + dropped network mid-paper | Interruption was fixed in V12.84 (`t63`), but **a dropped connection had no resume path**: nothing on screen said the answers were safe, and the clock was never re-based on the server after a reconnect | **Built** — see §4 item 4 |
| 5 | Item 2 — re-read **every** prompt and produce the obeyed/not-obeyed/omitted/dropped lists | **Never produced** | this document |
| 6 | Item 7 — the free-tier budget, in figures | Only prose in `SUPABASE_FREE_TIER_PROTECTION.md`; no limits table, no per-learner arithmetic, no threshold actions | **Built** — `FREE-TIER-BUDGET.md` |
| 7 | "Supabase email screenshot" (deliverability proof) | **Never supplied by the school**, so SMTP/email sending remains **unverified end-to-end**. The code paths exist and are documented; I cannot claim they work | still open — see §7 |

---

## 4. Features asked for but omitted, and what was added

### Item 1 — the tutor's own prep timetable, class by class, with the errors named

**What the school asked for:** a teacher should see, on his own screen, the prep exam timetable *for each
class*, so that if the time or the duration is wrong he can see it and correct it — and he should also be
able to see the other teachers' prep timetables.

**What existed:** `sc_prep_teacher_timetable(p_scope, p_class, p_tz)` — one call, `mine`/`all`, returning
date, start, end, length, venue, tutor, status per paper **and an `issues[]` array**
(`closes_before_it_opens`, `closing_time_vs_length`, `under_10_minutes`, `over_3_hours`,
`open_all_day`, `outside_school_hours`, `no_class`, `not_on_timetable`, `clashes_with_another_paper`).
It was reachable only from `exam-timetable.html#prep-exams`. The teacher's dashboard had no card.

**What was added:** a staff-only card on `dashboard.html` —
*🧪 Prep exam timetable — mine, and every tutor's* — with a `🙋 My prep timetable` / `👥 All tutors'`
switch, the papers **grouped by class**, one row per paper showing date, start–end, length, venue, status,
and a **Timing check** column that prints each issue in plain English (amber row). Every cell comes from
the single RPC, so the card cannot disagree with the Exam Timetable page. Implemented in
`assets/js/app.js` → `App.loadDashPrepTimetable()`; copy added to
`assets/templates/pages/dashboard.html`; wired next to `loadDashMyPay()` so it loads with the staff
section.

### Item 6 — "Reschedule prep exams" now shows its plan before writing

**What the school would say:** *"I pressed it, the timetable changed, and it told me '3 written, 1 cleared'.
I could not tell what it had done — or whether it had undone something I did."*

**Root cause:** `sc_prep_sync_all()` wrote, with no dry run, and the UI printed only the counts. There was
no way to see which rows it would touch.

**Fix:** `sc_prep_sync_all(p_dry_run boolean default false)`.

* `sc_prep_sync_all(true)` **changes nothing** and returns, per prep paper: `action`
  (`create` / `update` / `in_sync` / `remove` / `nothing`), the reason, the row **as it is now**
  (`before`), the row **as it would be** (`after`), and a list of exactly which fields change
  (`date 2026-11-12 → 2026-11-13`, `start 19:30 → 08:00`, `venue Main Hall → Hall B`).
* The CBT manager prints that table — *"Nothing has been changed yet"* — and asks for confirmation.
* The apply is the identical plan; the preview is computed by the database, so it cannot drift from the write.
* The apply still returns the old `scheduled` / `cleared` / `failed` keys, so nothing else breaks.

Proved by `t66-reschedule-preview.mjs` — **27 passed, 0 failed** (preview writes nothing; create/update/
remove/in-sync each behave; exact start change 19:30 → 08:00 Lagos; staff-only).

### Item 5 — ₦17,100 versus ₦35,100: two current-term bills for one learner

**Root cause (found this round).** Two early returns outranked the price list:

1. `sc_fee_bill_v2_structure` returned an existing `sc_fee_invoice` **immediately** — an invoice is history,
   but it beat a newer published price list;
2. `sc_fee_bill_v2` returned any receipt carrying `fee_total` with `total_overridden` **immediately**, for the
   same reason.

So a ₦17,100 invoice (or bursar's total) recorded months earlier won over the ₦35,100 price list published
later — and the screen still said `match_status='structure'`, i.e. it claimed to be quoting the class price list.

**Fix — V12.85 arbitration.** The newest published price list wins over any older recorded figure:

| Situation | Result |
|---|---|
| price list `updated_at` **newer** than the recorded invoice/total | price list is the bill; the older figure is returned in `superseded` = `{amount, source, recorded_at}` and named in `match_note` with both dates |
| recorded figure **newer** than the price list | the recorded figure wins, reported as `invoice` / `override` |
| no price list for that term | `bill 0`, `bill_known false` (unchanged V12.84 verdicts) |
| a healed receipt whose total now equals the price list | reported as `structure`, **not** as a "personal total set by the bursar" (a label bug found while testing) |

`sc_fee_account_for` now carries `superseded` and `structure_updated_at`, and the Fees & Payments form
prints the older figure, its date and its source on the same line as the bill — so a bursar holding a
printed ₦17,100 invoice can see exactly why the screen says ₦35,100.

Proved by `t65-bill-newer-than-history.mjs` — **15 passed, 0 failed**; and the older suite still passes:
`t62-class-fee-truth` 43/0, `tmp-bill-resolve` 77/0.

### Item 3 / 4 — a dropped connection mid-paper

**What existed:** a failed *submission* on a dead line was already handled beautifully (saved on the device,
queued, re-flushed, downloadable proof). What was missing was the **middle of the paper**: nothing told the
learner the answers were safe, and after a reconnect the countdown was still running on a clock reading taken
when the page loaded.

**What was added** (`assets/templates/pages/cbt-exam.html`):

* an **offline banner**: *"📴 You are offline. Your answers are being saved on THIS device after every
  question, so nothing is lost… do not close this tab"*;
* an **online recovery path** — `Exam.resyncClock()` asks the **database** (`sc_cbt_window_state`) for the
  server instant, the seconds left and whether the paper is still open, and re-bases both the skew and the
  countdown on that answer. The phone's clock is never trusted;
* if the paper **closed while the connection was down**, the learner gets the same *"Time is up — send my
  answers"* door and **nothing is submitted behind their back**;
* anything queued for sending is re-flushed on reconnect;
* a slow-network hint (`2g`) and a silent re-check when the tab is shown again;
* a device that knows it is offline never even asks the network.

Proved by `t67-network-resume.mjs` — **23 passed, 0 failed**, and the V12.84 interruption behaviour is
untouched (`t63` 23/0).

### Item 2 — this audit

§2, §3, §5 and §6.

### Item 7 — the free-tier budget

`FREE-TIER-BUDGET.md`: the Supabase free-tier limits **in figures**, the arithmetic per learner per term,
what each feature costs, the thresholds at which the school must change something, and the controls that keep
the project inside the free tier (including the 7-day pause and the 500 MB database cap, which the schema is
already engineered for — 980,289 B built).

---

## 5. Pre-existing features that were dropped

**None.** Verified rather than assumed, three ways:

1. `tools/audit-v5.py` — the feature inventory that walks the shipped pages and asserts each named feature is
   still present — **513 passed, 0 failed** on this build.
2. `tools/audit-repo-parity.py` — the three branded repos (`schoolconnect`, `gosaportal`, `schoolconnectdemo`)
   are byte-identical apart from branding: **no page, no script, no schema object exists in one and not the others**.
3. `tools/sync-root-pages.py --check` — the root pages and their templates are in step (this round:
   *identical 60, promoted 3, unsafe 0*).

The one file that *was* missing is a test, not a feature: `tmp-cbt-remap.mjs`, referenced by
`tmp-bulk-ux.mjs`, had been lost in an earlier workspace cleanup. It was **rebuilt** this round (9/0) rather
than skipped — it proves that changing an exam's Report column **moves** the score row instead of copying it.

This round added; it deleted nothing. The three additions are: `App.loadDashPrepTimetable` (+ card),
`CBTUI.resyncPrepApply` (+ preview), `Exam.resyncClock` / `Exam.netBanner` / `Exam.netState`.

**One risk was found and is worth naming:** the same page exists twice — in the repo root and in
`assets/templates/pages/` — and editing only one silently regresses the release. The chain
`sync-root-pages.py --apply` → `sync-v5-repos.py` → `audit-repo-parity.py` is what prevents it, and it is run
on every build.

---

## 6. Deep bug and consistency analysis (this round)

| # | Finding | Class | Fix | Proof |
|---|---|---|---|---|
| **0** | **Every schema run silently rewrote the school's published class total to the sum of its components** (`compute_class_fee_total` fired from a "no-op" backfill). This is the strongest single candidate for "two different current-term fees" — a bursar publishes ₦35,100, the next upgrade makes it ₦27,000 | **money, data integrity, upgrade safety** | the trigger only sums when the total is *blank*; on UPDATE it sums only if a component changed **and** the total was untouched; the backfill only fills blank totals | `tmp-rerun-live` 17/0 (35,100 → 35,100 across three runs); `t65` §5 (typed total kept, component edit still recomputes) |
| 1 | An older invoice outranked a newer price list, and still reported `structure` | money, precedence | V12.85 arbitration in `sc_fee_bill_v2_structure` | t65 |
| 2 | A bursar's older personal total likewise outranked the price list | money, precedence | arbitration second half in `sc_fee_bill_v2` | t65 |
| 3 | A receipt healed to the published bill was still labelled *"✏️ Personal total set by the bursar (override)"* | label / honesty | if the recorded figure equals the price list, report `structure` | t65 §2 |
| 4 | "Reschedule prep exams" wrote without a preview and explained nothing | operability | dry run + preview table + confirm, same plan | t66 |
| 5 | A dropped connection left the countdown on a stale clock and told the learner nothing | CBT integrity | offline banner + `sc_cbt_window_state` re-base + re-flush | t67 |
| 6 | A tutor could not see his own prep timetable from his own screen | missing feature | dashboard card, grouped by class, issues named | t57-style RPC, `loadDashPrepTimetable` |
| 7 | `sc_prep_sync_all()` gained a parameter: the old zero-argument grant would fail on upgrade | upgrade safety | `drop function if exists …()` + grants moved to the `boolean` signature | schema boots clean in PGlite (t66 loads the whole file) |
| 8 | Archiving a prep exam already removes its sitting, so the "remove" path only exists for drift | consistency | documented in the test's comment; `remove` is still the reported action for a surviving row | t66 §5 |
| 9 | Schema growth after adding three features | free-tier cap | 980,289 B of a 1,000,000 B cap; the builder still removes superseded bodies (`superseded-function-body`: 10) | `build-complete-schema.py --check` |

### Consistency rules that now hold

* **One bill per learner per term.** Resolver = account = ledger = family card = dashboard, proved cell by cell
  in `t65` §5. Precedence is a date comparison, not a lucky early return.
* **One timetable per prep paper.** The CBT record is the source; the timetable row is derived and can only change
  through a visible plan.
* **One clock.** School timezone for every date shown; server instant for every countdown; a reconnect re-measures it.
* **One role.** No screen guesses who you are (`t61`).
* **Nothing silently writes.** Imports, reschedules and submissions either show what they will do or queue themselves.

---

## 7. What is still open, and what I could not verify

1. **Supabase email deliverability — unverified.** The school never supplied the screenshot of the Supabase
   auth/project email settings. The platform-side SMTP configuration cannot be checked from this repository, and
   free-tier Supabase uses its own rate-limited mailer. Everything else about sign-up, invite and password reset
   is in `DEPLOYMENT.md`; the *sending* half is the school's project setting.
2. **Real-device mobile behaviour.** The interruption and network paths are proved against the shipped page in a
   DOM harness (`t63`, `t67`) and against the live deployed bytes, not on a physical Android/iPhone. Behaviour
   that depends on a specific browser's `pagehide` timing cannot be proved from here.
3. **The 500 MB free-tier ceiling under real load.** The arithmetic is in `FREE-TIER-BUDGET.md`, but the school's
   real photo/ID-card volume is not known; the document states the trigger points rather than pretending to a
   precise forecast.
4. **Nothing in this round required a paid plan, an AI API, or a new dependency.** The only dev dependency used for
   testing is `@electric-sql/pglite`, which is not shipped in any ZIP.
