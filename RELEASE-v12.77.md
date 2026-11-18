# School Connect / GoSA Portal — V12.77

**Released:** 8 November 2026 · **Database pack:** `database/complete-schema.sql` (V12.77)
**Gate:** `ALL SUITES PASS` — see `work/gate1277-final.log`

This release closes the eight items reported after the V12.76 round. Nothing that
existed before has been removed: every change either repairs a defect or adds to a
feature, and every new behaviour explains itself on screen.

---

## 1. Professional ID-card designs — 13 families, researched and implemented

The card designer used to offer nine templates, seven of which were variations of
the same horizontal band layout, and the reverse of every card was the same
generic block. Two things are now true:

**Thirteen designs, each drawn for a purpose.** `Super.idcard.TEMPLATES` is the
single registry — the engine, the page, the print sheet, the PDF and the card
preview all read it, so a design can never exist in one place and be missing in
another.

| Design | Family | Drawn for | Where the layout comes from |
|---|---|---|---|
| Premium | classic | landscape | navy header band, photo, QR — the reference school card |
| Executive | classic | landscape | dark green + gold, embassy/board style |
| Heritage | classic | landscape | serif, crest rule, older institutions |
| Corporate | classic | landscape | dark executive, accent rule, staff-heavy schools |
| Minimal | classic | landscape | Swiss: white, one accent rule, maximum legibility |
| **Academic Crest** (new) | classic | landscape | gold seal, double rule, motto band — academic boards |
| **Clinical Staff** (new) | clinical | landscape | teal, cross motif, department prominence |
| Smart Card | modern | landscape | fintech chip, dark, premium finish |
| Gradient | modern | landscape | vibrant, modern, youth-facing |
| **Aurora** (new) | modern | landscape | soft gradient, glass panels |
| Badge | badge | **portrait** | conference badge, lanyard slot |
| Vertical | badge | **portrait** | lanyard portrait with a strong name block |
| **Transit Access** (new) | badge | **portrait** | high-contrast pass, barcode strip at the foot |

The research behind the geometry and the field set is recorded in
`ID_CARD_PRINT_GUIDE.md`: CR80 / ISO-IEC 7810 ID-1 (85.60 × 53.98 mm, 0.76 mm,
3.175 mm corner radius, 3.175 mm safe margin, 1.5875 mm bleed per side, 300 dpi),
QR codes never smaller than 15 mm and always dark-on-light, the front carrying
identity only and the back carrying return instructions, emergency contact, blood
group, a verification QR, the signature block and the card rules — and **never** a
government ID number.

**Every design now owns its reverse.** The back is drawn for the same *family*
(`classic / modern / badge / clinical`): same palette, same trim, same
typography, and the family is printed in the page (`data-back-family`,
`data-back-template`) so a mismatched pair is visible in the markup.

**The page explains itself.** Choosing a portrait-only design sets the card to
portrait and says so under the dropdown — "Transit Access is drawn for portrait
cards, so the card has been set to portrait. Pick the other orientation again if
you need this design on a landscape card — it will still print, centred, with
margins." The dropdown itself is rebuilt from the registry at load
(`ICUI.refreshTemplateMenu()`), so the list can never fall behind the engine.

## 2. Front and back: one orientation, one size — always

The report was exact: *the back is stuck in landscape whatever the front does, and
when both are the same orientation they are different sizes.* Three separate
defects caused it, and all three are closed:

1. **The back derived its own shape.** It now takes the shape of the canvas the
   front was measured on (`backAspect()` reads the canvas before it reads the
   millimetres).
2. **Each face was measured separately**, so two designs with different natural
   proportions were scaled by two different factors. `pairHtml()` now measures
   **one canvas and one scale** and hands both faces the same result.
3. **The painted card was not pinned to the canvas.** A design that painted its
   own natural height came out shorter than its twin. Both faces are now drawn
   *at* the canvas (`cardAt2(html, canvas.W, canvas.H)`) and then scaled.

To make that possible the canvas is now chosen by measurement rather than by
assumption: the renderer samples widths, gives each one the card's exact height,
discards every sample that makes content overflow, and keeps the widest sample
that fits — so the design is laid out for the card rather than letterboxed into
it. Where a design simply cannot fill the shape (a lanyard badge on a landscape
card), it keeps its own proportions and is centred, and the page says which
designs prefer which shape.

**Proven, not asserted:** `tools/verification/t42-idcard-faces.mjs` renders all
**13 designs × 2 orientations × 2 card sizes = 52 card pairs** in a real browser
and measures three rectangles on every one: the face box, the scaled wrapper and
the painted card. Result:

```
rendered 52 card pairs across 13 templates
worst face-size difference: 0px · worst wrapper difference: 0px · worst painted-card difference: 0px
ID CARD FACES OK — one card, two faces, one size, one orientation, every professional template.
```

It also proves that no in-flow content is clipped on either face, that every
design fills at least 95 % of a card of its own shape, that each of the 13
renders differently (a menu whose options all draw the same card is worse than a
short menu), and that the page offers every design the engine knows.

Legacy names are kept working: `horizontal → Premium`, `elegant → Heritage`,
`compact → Minimal`, and so on, so a card saved before this release still prints.

## 3. CBT — 60 of 100, per candidate

A tutor uploads a 100-question bank and needs 60. The old code **sliced**: the
first sixty questions went to everybody, questions 61–100 were never served, and
it was impossible to say which questions a candidate had seen.

Now the **selection** is drawn at random from the whole bank for every candidate,
whether or not option-order randomisation is on, and the draw is **seeded** from
the exam and the candidate: a refresh, a resumed attempt and a re-mark all see the
same sixty questions, while two candidates sitting the same paper rarely see the
same set. Order randomisation stays a separate switch. Multi-subject papers draw
inside each subject, so "40 English + 20 Mathematics" keeps its shape.

The server does the same thing with the same seed inputs (`sc_cbt_pick_questions`,
`cbt_get_public_exam_v8`), so the browser and the database cannot disagree about
which questions a candidate was given.

`tools/verification/t43-cbt-pick.mjs` proves: 60 served, no duplicates, the whole
bank reachable including question 100, different papers across candidates, the
same paper on a refresh, the per-subject shape preserved, order randomisation
independent, `select_count = 0` still meaning "all", and a 25-question bank asked
for 60 degrading honestly to 25.

## 4. Reports — "Load current setting" on Mid Term

The report policy panel wrote to a prefix guessed from the *element ids* it
expected. On the Mid Term tab those ids do not exist, so the panel found nothing,
reported nothing, and left the user staring at an unchanged panel — Terminal and
Subject Broadsheet worked because their ids did match. `ReportPolicy._pfx(kind)`
now resolves the prefix from the DOM that is actually present (`mpol` when
`#mpol-body` exists, otherwise `pol`), `load()`, `_write()` and `save()` all use
it, and the panel states which policy it is editing ("Editing: **Mid Term** ·
Second Term · 2025/2026") so the two can never be confused again.

## 5. Fee Doctor — the class dropdown opens and lists classes

Three faults in one control: the select was filled from a query that silently
returned nothing when `students.class` was unset, the fill ran once at load and
never again, and `FeeDoctor.run()` read the field before it was populated. Now:

* `FeeClassPickers` is one shared source (`students.class` → `classes.name` →
  `class_fee_structure.class`), used by **both** pickers on the page (Fee Doctor
  and the bill audit) and by any future control that carries
  `data-class-picker`;
* it is filled at load **and** re-filled inside `FeeDoctor.run()` if the picker is
  still empty, so a slow session can no longer audit "all classes" by accident;
* the selection is preserved across re-fills, and the control disables itself with
  an explanation when there are genuinely no classes yet.

## 6. "New version available" — it updates, and it does not come back

The banner asked the user to reload; the reload did not always pick the new
worker up, and the banner returned even when the platform was current.

The contract now: the **version identity is the service worker's `CACHE` string**
(cache-busted, network-only). A pending version is written before the reload and
promoted to *applied* only when the worker that is actually running reports that
version — so a stale worker can never confirm a version it is not running. The
banner is suppressed for versions that are applied, pending or running, and a
first install no longer counts as an update. The last-resort reset (clear caches,
unregister, reload) runs each step in its own `try`, so one refusal cannot kill
the rest.

`t38-update-now.mjs` prints `UPDATE NOW OK` across all seven checks.

## 7. Marks can never exceed the subject maximum (21/20)

Cause, in the order it was found:

1. a CSV / typed entry above the column maximum was accepted verbatim;
2. the same mark pushed twice created a **second** `report_scores` row which the
   report **summed**, so two 10½ out of 20 read as 21/20;
3. lowering a maximum left earlier marks above it;
4. CBT scores were written against a stale maximum.

Fixes, in the database: `report_scores_one_row_per_mark` (one row per
learner/subject/column/session/term) with `sc_trg_report_score_upsert` turning a
second write into an update; `sc_trg_column_max_guard` refusing any mark above
the column maximum (bypassable only inside the migration transaction via
`set_config('sc.allow_mark_overflow','on',true)`); `sc_midterm_rebuild_one`
reporting `capped` and `overflow` per column; and `sc_mark_reconcile()` — staff
only — to find and repair historical rows.

Analogous cases enumerated and closed: duplicate rows, over-max rows, a maximum
lowered under existing marks, CBT score above the exam maximum, negative or NaN
marks, mid-term column capped by the terminal maximum, and a mark attached to a
column that belongs to another class.

`t41-cbt-marks.mjs`: **21 passed, 0 failed.**

## 8. Every file, every repo

`schoolconnect`, `gosaportal` and `schoolconnectdemo` now carry identical
`super.js` (the whole `idcard` engine), `idcard-pdf.js`, `report-engine.js`,
`cbt-engine.js`, `pwa-install.js` and `database/complete-schema.sql`, and the
page/template pairs (`idcards.html`, `report-cards.html`, `fees.html`,
`cbt-exam.html`) are in step both at the root and under
`assets/templates/pages/`. The audits that enforce this report:

```
Repo parity audit: ALL PASS — every deployment carries the generator's logic
Template drift:    ALL PASS — every one of 68 page template(s) matches its page
V5..V12 audit:     513 passed, 0 failed
Security audit:    HIGH 0 · WARN 0 · INFO 53
```

Two V12.77 trigger functions were taken off the public execution surface during
this pass (`revoke ... from public, anon, authenticated`), which is what the
security posture check now confirms.

---

## Installing V12.77

The full, unambiguous procedure is in `DEPLOYMENT.md` — §4 is the four-minute
path. In short:

1. **Back up** Supabase (Database → Backups).
2. Open **SQL Editor**, paste **all** of `database/complete-schema.sql`, run it
   once. Near the end you will see the row
   `V12.77 installed — per-student CBT papers, no mark can exceed its maximum, one row per mark`,
   followed by the catalogue-reload notice, which reports
   `Success. No rows returned` (it is meant to return nothing).
3. Upload the site files (or deploy the repo); hard-reload once
   (`Ctrl`/`Cmd` + `Shift` + `R`).
4. Open **Reports → ⚙️ What the report prints** on **Mid Term** and press
   **Load current setting** — the panel must say *Editing: Mid Term*.
5. Open **Fees → 🩺 Fee Doctor** — the class dropdown must list your classes.
6. Open **ID cards**, pick each design once: front and back must be the same
   size and the same way up.

If step 2 is skipped, CBT pages will refuse to run (obsolete engine) and marks
stay unprotected — the pack is not optional.

## What did not change

* No AI API is called anywhere: the client-hardening audit confirms
  `No paid AI API dependency introduced`.
* No pre-existing feature was removed. Legacy ID-card template names, the old
  report prefixes, the previous CBT slice behaviour's settings and the existing
  update banner's cache-busting route all still work.

## Files in this release

| File | What it is |
|---|---|
| `schoolconnect-v12.77.zip` | the generator / full platform |
| `gosaportal-v12.77.zip` | GoSA Portal deployment |
| `schoolconnectdemo-v12.77.zip` | the demo deployment |
| `FEATURES.md` | what the platform does, in plain language |
| `DEPLOYMENT.md` | step-by-step deployment, including the free-tier path |
| `RELEASE-v12.77.md` | this document |
