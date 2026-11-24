# School Connect V12.84 — "the right bill, and the paper you keep"

**Release date:** 30 November 2026 · **Database change:** yes (fee resolver) · **New dependency:** none
**Supabase plan:** unchanged (free tier) · **Schema size:** 968,321 B (cap 1,000,000 B)

---

## 1. Why this round exists

Two complaints arrived in the same week, and from opposite ends of the school:

* a bursar: *"when I enter a payment, the platform pulls a different current-term fee for the
  student than the class's own current-term fee"*;
* a parent: *"my child finished her prep test at home, the phone rang, and when she came back the
  test had submitted itself."*

Both are the same class of defect: a screen that **knew** the truth was unavailable, and
presented a guess instead — one in money, one in marks. Each was reproduced first, then fixed,
and each now has a test that fails if it comes back.

| # | What the school would say | What was actually happening |
|---|---|---|
| 1 | "The fee for a student is not the fee for their class." | The class matcher compared **one lowercase string**, then walked sideways through other arms and other terms **while still reporting `match_status='structure'`**. Two learners in JSS 1 were charged from two different price lists. |
| 2 | "A call made the exam submit itself." | The wall clock kept running while the phone was away, so the first tick after the call found `0` and submitted. Every blur was a fresh integrity flag, so one ring could reach the limit and submit on its own. |
| 3 | "Two tabs, one attempt." / "It never saved my answers." | Nothing stopped a second tab running a second clock and posting a second attempt; a full phone store failed silently. |
| 4 | "It gave her 4 minutes less than everyone else." | The paper was timed by the **device's** clock, not the school's. |

---

## 2. Issue 1 — the price list must be for this learner, this term

### What was wrong (proved, then fixed)

Reproduced in PGlite against the shipped schema, with the price list above (JSS 1 priced
per arm: A = ₦50,000, B = ₦60,000; SSS 2 class-wide = ₦80,000):

| Learner | Published price list | What the platform charged |
|---|---|---|
| JSS 1 · arm A | JSS 1 A — ₦50,000 | ₦50,000 ✅ |
| **JSS 1A** (arm written in the class name) | JSS 1 A — ₦50,000 | **₦0, reported as "no structure"** |
| **JSS 1 · arm blank** | two arms priced | **₦60,000** — arm B's figure, with no warning |
| SSS 2 | ₦80,000 | ₦80,000 ✅ |
| any class, **unpublished term** | a previous term exists | **the previous term's figure** |

Every one of those numbers was printed next to a green tick, because the resolver reported
`match_status='structure'` for all of them.

### What changed

`sc_fee_bill_v2_structure` (and everything above it) now returns a **verdict**, not a number:

```
match_status ∈ { structure, invoice, override, ambiguous_arm,
                 no_structure_this_term, no_structure, no_structures_at_all }
bill_known   =  true ONLY for structure / invoice / override
matched_by   ∈ { exact_term, current_term_label, exact_term_class_wide,
                 current_term_label_class_wide, exact_term_from_class_name,
                 current_term_label_from_class_name, invoice, override }
```

* **an arm written into the class name is understood** — `JSS 1A` resolves to JSS 1 · arm A,
  and the note tells the bursar *"the arm was read from the class name"*;
* **a blank arm against two priced arms is `ambiguous_arm`** — the bill is 0, `bill_known` is
  false, **both priced arms are listed with their figures**, no invoice is raised, and nothing
  is charged;
* **an unpublished term is `no_structure_this_term`** — the last published figure comes back in
  `fallback` and is **never charged**; the note says in words that it is *not* this term's bill;
* **a hand-raised invoice or a bursar's personal total is reported as `override`**, not disguised
  as the class price list;
* `sc_fee_account_for` and `sc_student_fee_state` now carry `match_status`, `matched_by`,
  `match_note`, `candidates` and `fallback` to the screens, so the Fees page, the family card and
  the dashboard can all say *why* a figure is missing instead of printing `0.00`.

On the Fees page the bursar now sees, per case: the priced arms to choose from; or the reason
the term is unpublished, with the last published figure offered **only through an explicit
"use the last published bill" confirmation**, which is recorded as a hand-set total for that
learner and leaves the class price list untouched.

Two further bugs died with it: a plpgsql `by` variable (a reserved word) that made the whole
function fail to compile, and `pick is not null` on a `record` — which is true only when **every**
column is non-null, so a matched row with any empty column was treated as "not found".

---

## 3. Issue 2 — a phone call is not a submission

Proved in `t63` against the real page (`assets/templates/pages/cbt-exam.html`):

1. `visibilitychange` / `pagehide` **pause** the countdown and write the answers to the device;
2. the time the interruption took is **handed back** on return (capped at 30 minutes, logged),
   and the new deadline is written to the key a reload would read;
3. **nothing is ever submitted while the page is away** — the countdown simply waits;
4. when time really is up, the candidate gets a **"Time is up — send my answers"** card and
   presses Send; a visible, attended page sends itself after a **two-minute grace**;
5. **one away period records at most one integrity flag** — a call used to fire blur + hidden +
   focus-loss, three flags for one ring — and an escalation that lands while away is **held**
   until the candidate returns and is asked, not fired behind their back;
6. the sitting is timed by the **server's clock** (`server_now`), so a phone that is four minutes
   fast no longer closes a ninety-minute paper four minutes early.

---

## 4. Issue 3 — the accidents around a paper

| Accident | Before | Now |
|---|---|---|
| The link opened twice on one phone | two clocks, two attempts, the second overwriting the first | **one sitting per device** (heartbeat lock, 12 s); the second tab is told so and can take over deliberately |
| Storage full / blocked | draft silently never saved | the candidate is **warned once**, in words, and told to keep the page open |
| Tutor sees "time taken" | measured on the phone's clock | measured on the **same clock that set the deadline** |
| Impatient double-tap on Send | second call re-entered the submit path | refused at the first line (`_done`) — unchanged, now pinned by a test |
| Reload mid-paper | answers had to survive on trust | draft carries answers, original question numbers and the candidate's own id |

---

## 5. What was NOT changed

* **Anti-cheat policy is still the school's.** Copy/paste, right-click, devtools and camera rules
  are untouched; a genuine fifth violation on an attended page still submits. Only *interruption*
  signals (blur / tab-switch / hidden) are de-duplicated per away period, and an escalation is
  deferred — never silently discarded.
* **Nothing is billed from a fallback.** If a term has no price list, the learner is unbilled
  until the school publishes one (or a bursar sets it by hand on purpose).
* **The free tier is unchanged.** No new tables, no new crons, no new columns beyond the
  resolver's own payload — the round's schema work was a *shrink* (see §7).

---

## 6. Proof — all green

```
node tools/verification/t62-class-fee-truth.mjs              43 passed,  0 failed
node tools/verification/t63-interruption-not-submission.mjs  23 passed,  0 failed
node tools/verification/t64-sitting-guards.mjs               14 passed,  0 failed
node tools/verify-complete-schema.mjs   ALL PASS — object-identical to the raw schema
```

Two older suites were **updated, not silenced**, because their assertions encoded the defect:
`tmp-bill-resolve.mjs` used to assert *"a term with no structure of its own falls back to the class
fee (35,100)"* — that is the bug, written down as a test. It now asserts `no_structure_this_term`,
`bill_known=false`, and the figure offered only as `fallback` (77/0). `tools/audit-v5.py` guarded two
literal SQL fragments that no longer exist; it now guards the V12.84 contract instead (513/0).

`t62` seeds a real price list (per-arm + class-wide + a previous term), then asserts: the exact
arm, the arm-in-the-name, the ambiguous arm (both candidates, no invoice, no charge), the other
class, the unpublished term (fallback offered, nothing charged, no phantom invoice), and the
full precedence chain invoice → override. `t63`/`t64` run the **shipped** `cbt-exam.html` script
in a hermetic DOM harness, so what they prove is what the phone runs.

---

## 7. Schema housekeeping (why the cap is safe)

The build was **964,103 B → 968,321 B** for the fee work, but it first had to make room:
`tools/build-complete-schema.py` gained rule **3b** — a superseded function body is dropped when
the name it defines is not referenced before the last definition (qualified references included,
and the function's own earlier definitions excluded from the scan). Ten dead bodies went,
about **34 KB**, and the rebuilt file is proven **object-identical** to the raw cumulative
schema (`verify-complete-schema.mjs`: applies, re-applies, every object diff 0).

---

## 8. Upgrading

1. Run `database/complete-schema.sql` in the Supabase SQL editor (idempotent; safe twice).
2. Nothing to change on the client — but tell the bursars to expect the new wording:
   *"Arm not set — choose the arm"*, *"No bill for Second Term — the last published bill is …"*.
3. Recommended, once: open **💳 Class Fee Structure** and confirm every class that is priced per
   arm has an arm on each learner, or publish one whole-class bill with the arm left blank.
4. Bump the service worker by deploying `sw.js` (`sc-builder-v12.84-20261130-1`).

---

## 9. Note for the next round

The one thing this round could not verify is the **Supabase email/screenshot** referenced in the
request — it is not in the workspace and was not re-supplied, so §"home prep on the free tier"
was worked from the network behaviour of the page itself (retries with jitter, offline copy,
server-anchored clock, no polling during a sitting). If that screenshot contains a specific
billing/quota notice, re-share it and it will be handled against the same evidence standard as
everything above.
