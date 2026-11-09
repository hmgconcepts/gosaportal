# CBT & Report Card Guide — School Connect V5.1

## Definitive CBT grading path

- Candidate fetch: `cbt_get_public_exam` reports `engine_version: v5.1.0` and strips answer/explanation aliases case-insensitively.
- Candidate submit: `cbt-exam.html` calls only `cbt_submit_v5` and accepts a result only when the server returns V5.1.
- V5.6.1 production repair: back up Supabase and run the full `database/complete-schema.sql` for both existing and fresh projects. It includes all historical CBT hotfixes; do not run them separately afterward.
- The browser sends answers and original bank indexes; it does not decide the official mark.
- Server matching supports letter↔option text, true/false aliases, numeric tolerance, multi-select sets, accepted alternatives, legacy option indexes and case-insensitive fields such as `CorrectAnswer`, `Correct Answer`, `answer_key`, `correct_option` and `rightAnswer`.
- If an objective answer key is missing, the server returns `answer_key_missing` and inserts no false-zero result.
- CBT Manager provides **Diagnose Scoring**, **Repair Scoring** and **Repair Tabs**.
- New/edited/appended banks are validated before publishing and both `csv_data`/`questions` stay synchronised.
- Result rows record `engine_version`, `grading_status`, `ungraded_count` and `subject_scores`.

## Question imports

Use `database/sample-question-bank.csv`, `sample-questions.csv` or `further_maths_sample.csv`. Both `CorrectAnswer` and `Correct Answer` headers work. Objective rows require a correct key. Essay/manual rows are stored for teacher review and do not expose an answer key.

## Offline resilience

A failed submission retains its local draft and downloadable answer payload. Authorised staff can import it through `cbt_import_backup`, which delegates to the same V5.1 matcher with idempotent `client_ref` handling.

## Report cards

- `assets/js/report-engine.js` creates the sample-matched report card, class broadsheet and subject broadsheet.
- `report-cards.html` routes all three print actions through this engine.
- `report_scores`/`assessment_columns` are authoritative; legacy `results` remains supported.
- CBT results can be mapped to a selected report-card column through the Report Engine export workflow.

## Required test

After deployment, create a disposable exam containing a letter key, exact option-text key, true/false, numeric tolerance and multi-select. Submit it, then confirm the row shows `engine_version='v5.1.0'`, a nonzero score and correct counts.


## V5.6.1 open/multi-subject repair
Open and multi-subject examinations can start without an admission number. The V6 getter returns a null optional candidate instead of dereferencing an unassigned PL/pgSQL record. Registered examinations still require the official admission number and roster.

## Midterm reports (V12.58+)

Midterm tests can have a separate report sheet without changing terminal report cards. Use the single CBT assessment purpose **Mid-term Assessment**; the score destination is a separate choice (for example CA1, CA2, or Midterm). Legacy CBT `assessment_type` values `ca` and `test`, and legacy column labels such as “Mid-term CA/Test”, remain supported. Push verified results to the report card, then open **Midterm Reports** and choose class, term and session. The generator recognizes Midterm, CA1/CA2, and tagged midterm columns; it does not require a column literally named `Midterm`. It creates roster rows even when scores have not been pushed, clearly marking those rows as no-score rather than creating fabricated marks. The separate `midterm_report_cards` table and RPCs never write terminal `report_cards`. Scores read from `report_scores` synchronize into the Midterm sheet; each score retains its subject, report column, mark and maximum. Tutors can print one standalone student sheet or print the whole generated class; families can view/print only their own published sheet. In CBT → Bulk Push, filter **Assessment purpose = Mid-term Assessment only** when required. The server-side push safely creates/uses destinations, resolves student IDs, skips unidentified/manual/unverified rows according to the selected policy, and selects one best or latest graded attempt per student/subject to prevent duplicate upsert collisions.


## Assessment standards — how percentages, grades and positions are calculated (V12.64+)

This section is the school's published rule book. Every report sheet, broadsheet,
dashboard tile and comment band obeys it, because they all call the same engine.

### 1. A percentage is always marks ÷ the full expected load

The expected load is **every assessment the class was timetabled to sit** for that
class, term and session — read from `assessment_columns` through
`sc_expected_load(class, term, session, midterm?)`. It never depends on what an
individual learner happened to submit.

> A learner who sat **one** paper is measured out of **four** if the class sat four.
> Their missing papers count as zero. They cannot gain by omission.

**Why this changed.** Upto V12.63 the percentage was `AVG(score)` — the mean of the
marks a learner happened to have. A learner with a single 38/100 paper produced
"38.00"; a learner with four papers totalling 138/400 produced "34.50". Comparing
those two numbers is meaningless, and the single-paper learner finished first.

Worked example (Midterm, JSS 2, four subjects of 100 marks each):

| Learner | Sat | Marks | Old percentage | **Correct percentage** | Old rank | **New rank** |
|---|---|---|---|---|---|---|
| Ada | 4 of 4 | 138 / 400 | 34.50 | **34.50** | 2nd | **1st** |
| Bola | 4 of 4 | 120 / 400 | 30.00 | **30.00** | 3rd | **2nd** |
| Chidi | 1 of 4 | 38 / 400 | 38.00 ✗ | **9.50** | 1st ✗ | **not ranked** |

### 2. Positions use competition ranking

Equal percentages share a place, and the next place is skipped: **1, 1, 3**. This is
the convention used by WAEC, NECO, Cambridge and IB transcripts. It is *not* 1, 2, 3
for ties, and it is not dense ranking (1, 1, 2).

The tie itself is ordered deterministically so a class never reshuffles between
runs:

1. higher percentage,
2. more assessments completed,
3. more subjects sat,
4. alphabetical by name.

The tie-break decides the **order of display**, never the **place awarded** —
a genuine tie still shows the same place for both learners.

### 3. A learner must take part to be ranked

`sc_report_min_participation()` sets the floor (default **34%** of assessments sat;
change the one function to change school policy). Below it, the learner is **not
ranked** and the card says why.

A learner who sat **nothing** receives no percentage, no grade and no position.
They are **ungraded**, never graded **F** — an F is evidence of poor performance,
and there is no evidence at all.

### 4. Completeness is stated on every sheet

Each card records `subjects_sat / subjects_expected` and
`assessments_sat / assessments_expected`. A learner who is ranked but incomplete
keeps their position **and** carries the note:

> *"Ranked 2 of 24 on 45.20% of the full load, but only 3 of 4 subjects sat —
> result is incomplete and must be read as provisional."*

### 5. Grades are never invented

Scale (printed on every broadsheet): **A** 80–100 Excellent · **B** 70–79 Very Good ·
**C** 60–69 Good · **D** 50–59 Credit · **E** 40–49 Pass · **F** 0–39 Fail.
Blank means *no marks* — not zero.

### 6. Every rank can be defended to a parent

`sc_report_explain(student_ref, class, term, session, kind)` returns the working:

```
Student: Ada Obi · Total: 138 · Expected: 400 · Percentage: 34.50
Grade: F · Position: 1 · Cohort: 2 · Subjects: 4 of 4
Working: 138 marks out of an expected 400 = 34.50%.
```

The same sentence is printed on the report sheet under the position.

### 7. Midterm and terminal reports use one engine

`generate_midterm_reports` and `sc_generate_terminal_reports` differ only in which
columns they read (`sc_is_midterm_column` splits them). They share
`sc_expected_load`, `sc_report_grade`, the participation floor and the ranking
rule, so the two reports can never again disagree about what a percentage means.

### 8. Repairing reports generated before V12.64

Any class generated before this release carries the old, wrong percentages and
positions. Use **one button**:

* **Midterm Reports → 🔧 Repair percentages & positions**
* **Report Cards → 🏅 Repair percentages & positions**

Both call `sc_reports_recompute(class, term, session, dry_run)`:

1. it **first reports the damage** — every card whose percentage is not marks ÷
   expected load, and every partial sitting ranked above a complete one;
2. it asks for confirmation, showing what it found;
3. it re-measures and re-ranks both midterm and terminal cards;
4. it is idempotent — running it twice changes nothing the second time.

From SQL: `select sc_reports_recompute('JSS 2','First Term','2025/2026', false);`

### 9. Function reference

| Function | Purpose |
|---|---|
| `sc_expected_load(class, term, session, midterm?)` | the authoritative expected load |
| `sc_report_grade(percentage)` | the grade scale |
| `sc_report_min_participation()` | the participation floor (default 0.34) |
| `sc_midterm_rebuild_one(...)` | re-measure one midterm card |
| `sc_midterm_rank(class, term, session)` | rank a midterm cohort |
| `sc_terminal_rebuild_one(...)` | re-measure one terminal card |
| `sc_terminal_rank(class, term, session)` | rank a terminal cohort |
| `sc_generate_terminal_reports(class, term, session)` | build + rank terminals |
| `sc_reports_recompute(class, term, session, dry_run)` | **the one-button repair** |
| `sc_report_explain(ref, class, term, session, kind)` | defend any rank |

### 10. Browser parity

`ReportEngine.rankCohort(rows, knownSubjects)` is the browser mirror of the SQL
engine and produces the same percentages and positions, so a sheet printed from
the browser and a card generated in the database always agree. The regression
suite asserts this: `tools/verification/tmp-rank.mjs` (Postgres),
`tmp-rank-edge.mjs` (ties, no-shows, partials) and `work/rank-check.js` (browser).

## Existing CBT edit and Attach CSV integrity (V12.58+)

Question edits and CSV append run through row-locked server RPCs. Existing legacy JSON/TEXT banks are normalized; the currently served bank is read using the same precedence as the student getter. Save now requires an optimistic version match and independent verification that `csv_data` and `questions` contain the same canonical bank/hash. Append falls back to a non-empty legacy `questions` bank when `csv_data` is empty, then writes both aliases. Advanced structured question data is preserved by the single-question editor; use the full CSV/structured editor to modify pairs, categories, matrices or rubrics. On a mismatch or failed readback, the page does not claim success; refresh and compare before retrying.
