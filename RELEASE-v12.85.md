# School Connect V12.85 — "the bill that cannot move by itself, and the button that shows its plan"

**Release date:** 8 November 2026 · **Database change:** yes (fee arbitration + a price-list clobber) ·
**New dependency:** none · **Supabase plan:** unchanged (free tier) ·
**Schema size:** 982,250 B (cap 1,000,000 B)

---

## 1. Why this round exists

The school said, plainly, that the previous rounds had not fixed the problems and asked for a different
approach: *check, do not assume; visit the live sites and the repos.* So this round started from the outside
in — and the first thing it proved is that **nothing was stale**:

```
curl https://gosaportal.vercel.app/sw.js          →  sc-client-v12.84-20261130-1
curl https://gosaportal.vercel.app/cbt-exam.html  →  93,645 B  (byte-identical to the repo file)
curl https://gosaportal.vercel.app/fees.html      →  162,464 B (byte-identical to the repo file)
```

The live site was running the newest build. Which means every remaining complaint was a **real defect,
still in the source, still shipped, and still deployed.** Three of them were:

| # | What the school reported | What was actually happening |
|---|---|---|
| 1 | "There is no prep timetable for each teacher" | It was **never built**. The database function existed and was correct, but it was reachable only from the Exam Timetable page. A tutor's own dashboard had no card at all (`grep prep_timetable assets/js` → nothing). |
| 6 | "What does *Reschedule prep exams* actually do?" | It wrote, silently, and reported a count. No preview, no diff — so a paper that moved and moved back could never be explained. |
| 5 | "The fee is ₦17,100 on one screen and ₦35,100 on another" | **Two** early returns outranked the newest price list — and, worse, **every schema run silently rewrote the published total** to the sum of its components. |
| 3/4 | "A dropped connection loses the paper" | Submitting on a dead line was handled; being *mid-paper* on a dead line was not: nothing said the answers were safe, and the clock was never re-based after a reconnect. |

---

## 2. Issue 5 — the fee that changed by itself (two root causes, both fixed)

### 2a. A published total was being replaced by its components

`compute_class_fee_total()` is a trigger on `class_fee_structure`. Its rule was *"wherever components exist,
the total is their sum"* — on **every** insert and **every** update. This schema file contains a one-time
backfill, `update class_fee_structure set tuition = tuition`, which is a no-op for the data but **fires the
trigger for every row**:

| Class | Published total | Tuition component | After the next schema run |
|---|---|---|---|
| SS 2, First Term 2026/2027 | ₦35,100 | ₦27,000 | **₦27,000** |

A bursar who published a total had it replaced the next time the school upgraded. This is exactly the class
of bug that makes two screens disagree, and it fired on **every upgrade, for every class**.

**Fixed:** the components are summed **only when the total is blank**. A total that was typed is a decision
and is left exactly as typed. On UPDATE the sum applies only when a component actually changed **and** the
total itself was not touched — so a no-op backfill cannot move a single naira. The backfill itself now only
fills rows whose total is 0.

Proved by `t65` §5 and by the re-run suite: **`tmp-rerun-live` 17/0** — *"the same bill, figure for figure:
35,100 before, 35,100 after"*, where before this fix it read 35,100 → 27,000.

### 2b. An older invoice outranked a newer price list

Two early returns won against the published price list:

* `sc_fee_bill_v2_structure` returned any existing `sc_fee_invoice` **immediately**;
* `sc_fee_bill_v2` returned any receipt carrying a `fee_total` with `total_overridden` **immediately**.

So a ₦17,100 invoice (or a bursar's personal total) recorded months earlier beat the ₦35,100 price list
published later — and the payload still said `match_status='structure'`, i.e. it claimed to be quoting the
class price list while quoting history.

**Fixed — V12.85 arbitration.** The newest published price list wins; an older recorded figure is *history*
and is reported as such:

| Situation | Result |
|---|---|
| price list newer than the recorded invoice/total | price list is the bill; the older figure comes back in `superseded` = `{amount, source, recorded_at}` and is named in `match_note` **with both dates** |
| recorded figure newer than the price list | the recorded figure wins, reported as `invoice` / `override` |
| no price list for the term | `bill 0`, `bill_known false` (unchanged from V12.84) |
| a healed receipt whose total now equals the price list | reported as **`structure`**, not as *"✏️ Personal total set by the bursar"* (a label bug found while testing) |

`sc_fee_account_for` now carries `superseded` and `structure_updated_at`, and the **Fees & Payments** form
prints the superseded figure, its date and its source on the same line as the bill — so a bursar holding a
printed ₦17,100 invoice can see exactly why the screen says ₦35,100, and what the school stands behind.

**Proof:** `t65-bill-newer-than-history.mjs` — **19 passed, 0 failed**; `t62-class-fee-truth` **43/0** and
`tmp-bill-resolve` **77/0** unchanged.

---

## 3. Issue 1 — the tutor's own prep timetable, on the tutor's own screen

**What was asked for:** every teacher should see the prep exam timetable **for each class**, on his own
screen, so a wrong time or duration is caught by him — and he should also be able to see the other teachers'
timetables.

**What existed:** `sc_prep_teacher_timetable(p_scope, p_class, p_tz)` — one call, `mine` / `all`, returning
the date, start, end, length, venue, tutor, status **and an `issues[]` array**
(`closes_before_it_opens`, `closing_time_vs_length`, `under_10_minutes`, `over_3_hours`, `open_all_day`,
`outside_school_hours`, `no_class`, `not_on_timetable`, `clashes_with_another_paper`). It was reachable only
from `exam-timetable.html#prep-exams`.

**What is new:** a staff-only dashboard card — **🧪 Prep exam timetable — mine, and every tutor's** — with:

* a `🙋 My prep timetable` / `👥 All tutors' prep exams` switch;
* papers **grouped by class** (the question the school actually asked);
* per paper: **date**, **start–end**, **length**, paper + code, **venue**, **status** (open / upcoming / closed);
* a **Timing check** column that prints each issue in plain English on an amber row — *"closing time
  disagrees with the paper length"*, *"not on the Exam Timetable yet — run 'Reschedule prep exams'"*,
  *"overlaps another paper in the same class"*;
* links straight to the CBT Manager to correct it.

Every cell comes from the single RPC, so the card **cannot** disagree with the Exam Timetable page
(`App.loadDashPrepTimetable()` in `assets/js/app.js`, card in `assets/templates/pages/dashboard.html`).

---

## 4. Issue 6 — "Reschedule prep exams" now shows its plan before it writes

**Root cause:** `sc_prep_sync_all()` wrote with no preview and the UI printed only counts. There was no way to
see which rows it would touch.

**Now:** `sc_prep_sync_all(p_dry_run boolean default false)`.

* `sc_prep_sync_all(true)` **changes nothing** and returns, per prep paper: `action`
  (`create` / `update` / `in_sync` / `remove` / `nothing`), the `reason`, the row **now** (`before`), the row
  **after** (`after`), and a list of exactly which fields change —
  `date 2026-11-12 → 2026-11-13`, `start 19:30 → 08:00`, `venue Main Hall → Hall B`.
* The CBT manager prints that table with the heading **"Nothing has been changed yet"** and a single
  confirm button. The apply re-computes the plan at the moment of confirmation, so a colleague's change in
  the last few seconds cannot be overwritten by a stale preview.
* The plan is computed **by the database**, so the preview cannot drift from the write. The apply still
  returns the old `scheduled` / `cleared` / `failed` keys, so nothing else breaks.

**Upgrade-safe:** the old zero-argument signature is dropped and its grants moved to the `boolean`
signature, so `grant execute` cannot fail on an existing installation.

**Proof:** `t66-reschedule-preview.mjs` — **27 passed, 0 failed** (preview writes nothing; create / update /
remove / in-sync each behave; the exact Lagos-time change 19:30 → 08:00 is named; staff-only).

---

## 5. Issues 3 / 4 — a dropped connection mid-paper

Submitting on a dead line was already handled (saved on device, queued, re-flushed, downloadable proof).
**Being mid-paper** on a dead line was not. Added to `assets/templates/pages/cbt-exam.html`:

| Situation | Before | Now |
|---|---|---|
| The signal drops mid-paper | nothing on screen; learner cannot tell whether answers are saved | **offline banner**: *"Your answers are being saved on THIS device after every question, so nothing is lost… do not close this tab"* |
| The signal returns | countdown still running on a clock reading from load time | **`Exam.resyncClock()`** asks the **database** (`sc_cbt_window_state`) for the server instant and the seconds left, and re-bases both skew and countdown — the phone's clock is never trusted |
| The paper closed while away | learner would fail to submit with no explanation | the same **"Time is up — send my answers"** door; **nothing is submitted behind their back** |
| A submission was queued | retried on its own schedule | also **re-flushed the moment the connection returns** |
| 4G → 2G → no service | invisible | a slow-network hint, plus a re-check when the tab is shown again |
| The device already knows it is offline | — | it does not even ask the network |

The V12.84 interruption behaviour (a ringing phone pauses, never submits) is untouched: `t63` **23/0**.

**Proof:** `t67-network-resume.mjs` — **23 passed, 0 failed** against the shipped page: the handlers are
wired, the banner says the answers are safe, the countdown is re-based on the server (a 4-minute phone-error
is corrected, and a stale 60-second deadline becomes the true 600), an expired paper shows the send door and
does **not** self-submit, and an offline device makes no request at all.

---

## 6. The round-30 audit and the free-tier budget (the two documents asked for)

* **`AUDIT-v12.85.md`** — every prompt from the start of the conversation, sorted into **obeyed**,
  **not obeyed**, **asked for but omitted** and **pre-existing features dropped** (none dropped; verified
  three ways), then a deep bug/consistency analysis, then an honest list of what could not be verified.
* **`FREE-TIER-BUDGET.md`** — the Supabase free-tier limits in figures, the per-learner arithmetic
  (~75 KB and ~40 KB of egress per learner per term), the operating routine that replaces the missing
  automatic backups, the thresholds at which the school must act, and the one honest warning this platform
  has always carried: **Vercel Hobby is for non-commercial use** — Cloudflare Pages or Netlify Free are the
  free-tier-safe hosts for a fee-paying school.

---

## 7. What was NOT changed

* **No AI APIs.** Nothing in this round adds a network cost: marking remains key-based, fees are a
  precedence rule, timetables are derived in SQL.
* **No paid plan, no new dependency.** The only new dev dependency used by the tests is
  `@electric-sql/pglite`, which is not shipped in any ZIP.
* **No feature removed.** The three additions are `App.loadDashPrepTimetable`, `CBTUI.resyncPrepApply`
  and `Exam.resyncClock` / `netBanner` / `netState`.
* **Anti-cheat policy** (copy/paste, right-click, camera, violation limit) is untouched.

---

## 8. Proof — all green

```
node tools/verification/t65-bill-newer-than-history.mjs        19 passed,  0 failed
node tools/verification/t66-reschedule-preview.mjs             27 passed,  0 failed
node tools/verification/t67-network-resume.mjs                 23 passed,  0 failed
node tools/verification/tmp-rerun-live.mjs                     17 passed,  0 failed   (35,100 → 35,100)
node tools/verification/tmp-cbt-remap.mjs                       9 passed,  0 failed   (restored this round)
node tools/verification/t62-class-fee-truth.mjs                43 passed,  0 failed
node tools/verification/t63-interruption-not-submission.mjs    23 passed,  0 failed
node tools/verification/t64-sitting-guards.mjs                 14 passed,  0 failed
node tools/verify-complete-schema.mjs                          ALL PASS — object-identical
python3 tools/audit-v5.py                                      513 passed,  0 failed
python3 tools/audit-repo-parity.py                             three repos identical
```

One test file had been lost in a workspace cleanup (`tmp-cbt-remap.mjs`, referenced by `tmp-bulk-ux`).
It was **rebuilt**, not skipped: it now proves that changing an exam's Report column **moves** the score row
instead of copying it — *"there is still exactly ONE row"* — and that a dry run moves nothing.

---

## 9. Upgrading (short form — full steps in `DEPLOYMENT.md`)

1. Supabase → SQL Editor → paste and run `database/complete-schema.sql` (idempotent; safe twice).
2. **Do this once, on a copy of the database if you can:** open **💳 Class Fee Structure** and confirm each
   class's **Total** is the figure you actually published. The old trigger may have replaced a total with the
   sum of its components on a previous upgrade; from this version on it cannot.
3. Deploy the site files as usual, including `sw.js` (`sc-builder-v12.85-20261108-1`) so every phone picks up
   the new pages.
4. Tell the bursars what is new: on the Fees form, an older invoice now shows as **"superseded"** with its
   date and source; the CBT manager's *Reschedule prep exams* now opens a **preview** that changes nothing
   until it is confirmed.

---

## 10. Note for the next round

Two things remain genuinely unverified and are named in `AUDIT-v12.85.md` §7: **Supabase email
deliverability** (the school never supplied the screenshot of the project's auth/SMTP settings) and
**real-device mobile behaviour** (the interruption and network paths are proved against the shipped page in a
DOM harness and against the live deployed bytes, not on a physical handset).
