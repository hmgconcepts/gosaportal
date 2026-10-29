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

## Existing CBT edit and Attach CSV integrity (V12.58+)

Question edits and CSV append run through row-locked server RPCs. Existing legacy JSON/TEXT banks are normalized; the currently served bank is read using the same precedence as the student getter. Save now requires an optimistic version match and independent verification that `csv_data` and `questions` contain the same canonical bank/hash. Append falls back to a non-empty legacy `questions` bank when `csv_data` is empty, then writes both aliases. Advanced structured question data is preserved by the single-question editor; use the full CSV/structured editor to modify pairs, categories, matrices or rubrics. On a mismatch or failed readback, the page does not claim success; refresh and compare before retrying.
