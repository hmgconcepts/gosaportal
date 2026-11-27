# School Connect V12.86 — "two price lists, an honest repair, and a paper nothing can take away"

**Release date:** 8 November 2026 · **Database change:** yes (new columns, a widened key, two new tables,
new/fixed functions) · **New dependency:** none · **Supabase plan:** unchanged (free tier) ·
**Schema size:** 999,951 B (cap 1,000,000 B — 49 B spare, see §11)

---

## 1. What this round answers

Ten things were reported. Each one is answered below with **the fault that produced it**, **what changed**,
and **the proof that the change works**. Nothing here is a re-statement of an older fix: every item was
reproduced first.

| # | Reported | Root cause found | Where it is fixed |
|---|---|---|---|
| 1 | Prep exams at home fail; in-school exams do not | A home connection is a *different machine* from a school router: no stable path, no shared cache, family phones competing, the tab discarded under memory pressure | `HOME-EXAM-RESILIENCE.md` §2–§4, `cbt-exam.html` |
| 2 | A class fee structure cannot be made for new **and** returning learners | The unique key was `(class, arm, department, term)` — exactly one price per class per term | `class_fee_structure.student_type` + key `class_fee_structure_uq_v1286` |
| 3 | Why home fails where school does not; fix the Supabase email | Wrong layer blamed: it was never the network alone — it was the clock, the tab and the quota | `HOME-EXAM-RESILIENCE.md` §2, `FREE-TIER-BUDGET.md` §7 |
| 4 | A call auto-submits the paper | Three separate routes could end a sitting the candidate did not end (blur flags, a frozen clock, a discarded tab) | `Exam.onViolation` + boot credit + re-arming sender |
| 5 | Affective domain saves and is not there on reopen | The grid was re-drawn from the defaults every load, and a blank term was written blank | `crud.js` `_bfLoad`/`_bfSave` |
| 6 | "Repair stored receipt totals" is inconsistent | It rewrote **every** receipt with one inferred figure, including the ones that were right | `sc_fee_truth_migrate` rewritten to compare, classify, and only fix what it can prove |
| 7 | "CBT scores in two columns = 75" cannot be fixed | The doctor reported; nothing could act | `sc_fee_doctor_v4` + a Fix button per row |
| 8 | "Fix everything fixable" does not fix everything | No function ever re-read the counts after fixing | The doctor re-counts after applying; a second press reports zero |
| 9 | 21 "overpayments", mostly new learners | New learners were billed the class list **without** the fees only new learners pay | `class_fee_extra` + `sc_student_type` + extras on both billing paths |
| 10 | Update every file, every repo | — | §9 (files), §10 (deployment) |

---

## 2. Item 9 (and 2) — new and returning learners are now billed differently, because they are different

### The fault

`class_fee_structure` had the key `unique (class, arm, department, term)`. A school therefore had **one**
price per class per term, so the platform had no way to say *"JSS 1 returning = ₦28,100, JSS 1 new =
₦28,100 + admission + uniform + books"*. Every new learner was billed the returning price. When the family
paid what the school had actually asked for, the ledger saw money beyond the bill and called it an
**overpayment**. That is the whole of the "21 false overpayments" report: the parents were right and the
platform was wrong.

### What changed

* `class_fee_structure.student_type` (default `'all'`) — a price list can now be published for `returning`,
  `new`, or `all`.
* The key is now `(class, arm, department, term, session, student_type)` — `class_fee_structure_uq_v1286`.
* **The de-duplicator was the dangerous part.** The old repair block inside the schema *deleted* the second
  row it found for a class/term. Widening the key without fixing that block would have silently eaten half of
  every two-price list on the next install. It now de-duplicates on the full key and never touches two
  different types.
* New table `class_fee_extra` — the one-off items a new intake pays (admission, uniform, books, ID card,
  transport levy…), each with `applies_to` = `new` / `returning` / `all`.
* New function `sc_student_type(student, term, session)` — a learner is **new** when the first session they
  were ever billed for is the session being billed, and **returning** otherwise. An explicit value on the
  learner record always wins, so a mid-session joiner can be corrected by hand.
* `sc_fee_bill_v2_structure` now applies the type: it prefers the price list published for that learner's
  type, then `all`; then adds every applicable `class_fee_extra` item as its **own line** (marked 🆕). This
  happens on **both** billing paths — from the price list *and* from a recorded invoice — because an invoice
  is the class bill, not the whole bill.
* The Fee Structure page (`school-fees.html`) gained a panel that shows, for one class and term: the
  returning bill, the new bill, every extra item, and how many learners in the class are in each group.

### The arithmetic, in one table

| Learner | Class bill | New-learner extras | What they are billed |
|---|---|---|---|
| Returning, JSS 3 | ₦28,100 | — | **₦28,100** |
| New, JSS 3 | ₦28,100 | Admission ₦5,000 + Uniform ₦3,000 + Excursion ₦2,000 | **₦38,100** |

Proved in `tools/verification/tmp-round32.mjs` §3.

---

## 3. Item 6 — the repair table that was not to be trusted

### The fault

The old repair took the current bill and wrote it onto **every** receipt for that term, whether or not the
receipt was wrong. On the school's own data that produced rows like `GAFAR FAWAS ₦35,100 → ₦80,500` — the
"repair" *raised* a figure by ₦45,400. That is why the table looked inconsistent: some stored values were
right and were changed anyway.

### What changed

`sc_fee_truth_migrate(p_dry_run)` no longer rewrites blindly. For every receipt it computes what the bill is
(invoice first, then `sc_fee_bill_v2`), and classifies:

| Verdict | Meaning | What the repair does |
|---|---|---|
| `correct` | stored = bill | nothing |
| `fix` · `invoice_is_the_recorded_bill` | a real invoice says what was billed | rewrites from the invoice |
| `fix` · `running_balance` | stored = bill + other receipts | rewrites to the bill |
| `fix` · `bill_increased` | the price list went up after the receipt | rewrites to the current bill |
| `keep` · `unexplained` | the difference cannot be explained from the records | **nothing — it is left exactly as it is** |
| `review` · `no_bill_on_record` | no invoice and no price list for that term | nothing, and it says so |

The page now prints that verdict per row, explains which of the two numbers is the record, and says out loud
that `keep` rows were not touched. A receipt with a hand-set total (`total_overridden`) is never touched at
all.

---

## 4. Items 7 and 8 — every finding has a one-click fix, and a second press finds nothing

`sc_fee_doctor_v4(p_apply, p_only)` returns ten checks, each with a count and whether it is fixable. For each
fixable check the page shows **what it found**, **what it means for the money**, **exactly what the fix
does**, and a button that runs *only that fix*:

| Check | The one-click fix |
|---|---|
| `unlinked_receipts` | link the receipt to the one learner whose name matches (refuses when two match) |
| `duplicate_receipts` | keep the earliest row, remove exact copies only |
| `nonpositive_amounts` | remove rows that record no money |
| `missing_period` | stamp the current term and session |
| `overpayments` | hold the excess as `students.credit_balance`; **no receipt is edited or deleted** |
| `cbt_two_columns` | keep the column the exam itself names as its report column, else the earliest |
| `conflicting_structures` | keep the newest list per learner type, deactivate the rest |
| `aid_naming_nobody` | void the orphan award |

**Item 8 in one sentence:** the counts you see are read *after* the fixes, in the same call, and a fix is
written so that its own check stops counting it — the overpayment count subtracts the credit already
recorded, the CBT count counts groups of two, the structure count counts duplicates. `FeeDoctor.fixEverything()`
runs every key in turn, re-scans, and tells you, in a line at the top, whether anything is still open.
`tmp-round32.mjs` §6 asserts that the second press finds zero.

Every repair is written to `sc_repair_log` (who, when, which check, how many rows) and the page has a
**🧾 Repair history** button that reads it back.

---

## 5. Item 5 — the affective domain that remembers

### The fault (two, both in the browser)

1. `CRUD._bfLoad` re-drew the grid from the defaults. It never read `affective_traits` at all, so a saved
   rating *could not* appear however correct the save was.
2. `CRUD._bfSave` wrote `term` and `session` straight from two optional dropdowns. A blank dropdown wrote a
   blank period; the report asks for `First Term`, found nothing, and the teacher's work looked lost.

### What changed

* `_bfLoad` reads the saved rows for **that class, that term, that session**, pre-selects every saved rating,
  marks the learner "✓ on record", and prints `N of M learner(s) already have ratings on record — last saved
  …`. A learner with nothing saved still opens at 3, and the header says so.
* `_bfSave` resolves a blank period from the current academic period before writing, writes ratings as
  **numbers**, and refuses with a clear message when no period can be resolved anywhere (instead of saving
  something unfindable). The window opens on the current term/session automatically.
* The database side got the write policy these tables were missing, so a tutor's save is accepted and a
  stranger's is not.

Proved in `tools/verification/t68-affective-roundtrip.mjs` — the shipped `_bfLoad`/`_bfSave` are extracted
and executed against a PostgREST-shaped stub.

---

## 6. Item 4 — an interruption cannot take the paper away

Three routes could end a sitting the candidate did not end, all closed:

1. **Blur escalation.** A ring produced blur + hidden + focus-loss = three integrity flags; at the fifth the
   paper submitted itself. Now at most **one** flag is recorded per away period, and the escalation is *held*
   until the candidate is back in front of the screen.
2. **A frozen clock.** While the page is hidden the countdown pauses, and the time away is given back
   (capped, and logged into the interruption record).
3. **A discarded tab (new in V12.86).** A phone under memory pressure closes the tab outright — no
   `visibilitychange`, no `pagehide`. The page now writes a **heartbeat** with every draft save; on reboot it
   reads the heartbeat and hands the gap back (up to 30 minutes over the whole sitting), logs it as
   `page_closed`, and tells the learner. A 20-second reload gets nothing, so nothing can be farmed.
4. **The end-of-paper sender** used to fire once, at 120 s, and give up. It now re-arms every 20 s and only
   sends when the page is **visible**, **online**, and the candidate has been idle for two minutes.

Proved in `t69-cbt-boot-credit.mjs` (the arithmetic is executed, not described) and `t63`/`t64`/`t67` for the
older guarantees.

---

## 7. Item 1 and 3 — why home is not school (full analysis in `HOME-EXAM-RESILIENCE.md`)

Short version: the school router gives every candidate the same path, the same DNS, the same NAT and a
cached paper; a home connection gives each of them a different path, a different radio, a different DNS and a
tab that the operating system may kill at any moment. `HOME-EXAM-RESILIENCE.md` lists the standards the
platform is now measured against (1EdTech QTI 3 attempt/resume model, 1EdTech Proctoring Services `resume`
action, AWS Well-Architected REL05-BP03 retry-with-backoff-and-jitter, idempotency, W3C Page Visibility,
Service-Worker offline-first, WCAG 2.2 for the away/interrupted states) and shows, item by item, where the
code now complies.

---

## 8. What was NOT done, and why

* **The pack is at the paste cap.** 999,951 B of a 1,000,000 B limit. To make room for V12.86's objects the
  build now shortens the *documentation* comments inside `comment on …` statements and the header banner (the
  full wording stays in the raw schema and in these notes). No executable statement was removed. The next
  round that adds SQL must first reclaim space — the honest candidates are `sc_fee_doctor_v2` (superseded by
  v4 and only reachable from a fallback path) and `sc_fee_ledger_doctor` (superseded by v2/v3/v4).
* **`sc_student_type` cannot know a mid-session joiner's history if the school never recorded the earlier
  session.** It falls back to "no receipts before this session → new". The learner record carries the manual
  override for exactly this case; it is on the Students form, labelled *New or returning learner*.
* **Two checks were dropped from the one-click doctor** to stay inside the paste cap: `future_dated_receipts`
  and the two purely informational rows (`periods_no_dates`, `class_bills_zero`, `opening_balances` are
  still reported by the fourteen-check doctor, and the page still explains them).

---

## 9. Files changed

| File | Change |
|---|---|
| `work/schema/complete-schema.raw.sql` → `database/complete-schema.sql` | V12.86 section: `students.student_type/first_session/credit_balance`, `class_fee_structure.student_type` + new key, `class_fee_extra`, `sc_repair_log`, `sc_student_type`, `sc_fee_extras`, rewritten `sc_fee_truth_migrate`, new `sc_fee_doctor_v4`, extras on both bill paths, affective write policies |
| `assets/js/crud.js` | `_bfLoad`/`_bfSave` rewritten; `student_type`, `first_session`, `credit_balance` on the Students form; `student_type` on the fee-structure form |
| `assets/templates/pages/fees.html` (+ root copy) | Fee Doctor v4 UI with a Fix button per row and `fixEverything()`; repair-history panel; honest repair table |
| `assets/templates/pages/school-fees.html` (+ root copy) | new/returning price-list builder and the new-learner extras editor |
| `assets/templates/pages/cbt-exam.html` (+ root copy) | heartbeat + boot credit; re-arming end-of-paper sender |
| `sw.js` | cache name `sc-builder-v12.86-20261108-1` |
| `tools/build-complete-schema.py` | `comment-fitted` rule, shorter header, V12.86 status line |
| `tools/verification/tmp-round32.mjs`, `t68-affective-roundtrip.mjs`, `t69-cbt-boot-credit.mjs` | new suites (32 + 11 + 13 assertions) |
| `RELEASE-v12.86.md`, `HOME-EXAM-RESILIENCE.md`, `DEPLOYMENT.md`, `FREE-TIER-BUDGET.md` | this release, the standards analysis, the deployment steps, the free-tier answer |

---

## 9a. Verification — the gate, and the six suites that were red before they were green

The full gate is `bash work/run-all-tests.sh`; the log of the run this release ships on is
`work/gate-v12.86.log`: **101 suites, 0 failures, `EXIT=0`**.

That number was not free. The first complete run of this round ended `EXIT=1` with **six** failing
suites, and none of them was a V12.86 defect. Each was diagnosed rather than silenced, and each was
proven to be pre-existing or environmental before anything was changed:

| Failing suite | What it actually said | Root cause, proven how | Outcome |
|---|---|---|---|
| `CBT: Edit opens the editor` | `CBTUI is not defined` inside `page.evaluate` | The suite drives a **real browser**. Unpacked the shipped **v12.85** ZIP into `/tmp/v1285`, symlinked `node_modules`, ran the same suite: it fails there in exactly the same way. So the page is not the regression — the browser runtime the suite needs was missing its shared libraries. | Green once Chromium's libraries were restored (`work/chromium-env.sh`). |
| `CBT: Flush now reports back` | same page-side error | same reproduction on v12.85 | Green. |
| `PWA update now: applies, no repeat` | `missing /home/user/repos/gosaportal/sw.js` | The two branded mirror repos are **deliberately not kept** between rounds (they are 35 MB of the snapshot), so the suite had no second deployment to update. | Green after the mirrors were rebuilt. `work/mkzips.py` now rebuilds them by itself, from each mirror's own previous ZIP, before zipping. |
| `ID card: 13 designs…` | page-side error, same family | same reproduction on v12.85 | Green with the browser runtime restored. |
| `V12.83: no calendar day is computed from UTC` | missing `gosaportal` / `schoolconnectdemo` repositories | same missing mirrors as above; this is the school-day audit running across all three deployments | Green: *18 checks across 3 deployments — every calendar day is the school's day.* |
| `V5..V12 platform audit (513)` | `No module named 'pglast'` | `tools/audit-v5.py` parses the SQL statically and needs the `pglast` package, which is not part of a fresh sandbox | Green after `pip install pglast`: **513 passed, 0 failed**. |

The lesson is recorded here on purpose: **a red gate is not automatically a regression, and a green gate
is not automatically a proof.** Both directions were checked — the browser suites were reproduced on the
*shipped* v12.85 artefact to show the failure travelled with them, and the two "missing" failures were
re-run after supplying the missing input rather than by deleting the suite.

What V12.86 itself adds to the gate, all green:

| Suite | Assertions | What it proves |
|---|---|---|
| `tmp-round32.mjs` | 32 | schema objects, keys, triggers, policies, the doctor's fix-keys, the extras on both bill paths |
| `t68-affective-roundtrip.mjs` | 11 | fill → save → reopen pre-selects the saved ratings, `N of M on record`, blank term resolved |
| `t69-cbt-boot-credit.mjs` | 13 | deadline credit after a call, 45 s gap threshold, 30 min cap, nothing submitted while hidden |
| `verification/tmp-rerun-live.mjs` | 17 | the built schema applies **3 times** on live data, 390 indexes before and after, money unchanged |
| `verification/tmp-midterm-holds.mjs` | 17 | mid-term report holds survived the rewritten bill paths |

---

## 10. Deployment — in order, with what success looks like

1. **Database.** Supabase → **SQL Editor** → **New query** → paste the whole of
   `database/complete-schema.sql` → **Run**.
   *Success:* the last line says `V12.86 inserted` in the results grid, with no red error. (The pack ends
   with `select pg_notify('pgrst','reload schema')`, which makes the API see the new functions immediately.)
2. **Wait 20 seconds**, then reload the site once. The service worker cache name changes to
   `sc-builder-v12.86-20261108-1`, so every device fetches the new JS by itself.
3. **Fee structure.** Fees → *Class Fee Structure* → **+ Add new** → class, arm, term, **Who this price is
   for = returning** → enter the term bill → Save. Repeat with **new** if your new intake pays a different
   class bill. Then Fees → *New and returning learners* → pick the class → add the extra items
   (Admission, Uniform, Books…) with **Who pays it = New learners only**.
   *Success:* the panel shows two different bills side by side (e.g. ₦28,100 and ₦38,100).
4. **Raise invoices** for the term (Fees → *Raise invoices for this term*), then **🩹 Repair stored receipt
   totals**.
   *Success:* the repair table shows `keep` on the rows it cannot explain and `fix` on the ones it can; no
   negative differences.
5. **Fee Doctor** → **🔍 Check only**, read every row, then **🩹 Fix everything fixable**.
   *Success:* the banner says *Everything fixable is now zero*; pressing the button again reports the same
   zeros. The overpayment count drops as credits are recorded — check the new-student fees first (§3.3).
6. **Affective domain.** Open the bulk-fill form, choose the current term/session, fill and save.
   *Success:* reopening the same class/term shows the saved ratings pre-selected and `N of M on record`.
7. **CBT.** Open any paper at home, answer a few questions, take a call for a minute and come back.
   *Success:* the clock is paused, the time is handed back, and nothing is submitted.

---

## 11. The one number to watch

The built schema is **999,951 B** against a hard **1,000,000 B** paste limit. The build refuses to write a
file over the cap (it has done so three times in this round while the V12.86 objects were being fitted in).
Before the next SQL change, reclaim space with:

```bash
cd repos/schoolconnect
python3 tools/build-complete-schema.py | grep headroom
```
