# CBT Zero-Score Fix — V5.1

## Why earlier fixes could still record zero

The platform had more than one failure path:

1. Old databases exposed `cbt_submit`/`cbt_submit_v2` implementations that compared only exact strings.
2. Historical banks used many answer-key spellings: `CorrectAnswer`, `Correct Answer`, `correct_answer`, `answer_key`, `correctOption`, `rightAnswer`, and sometimes an option index.
3. Some managers stored questions only in `questions`; others used `csv_data`.
4. A newer frontend could still call an older cached RPC and accept its `saved: true, score: 0` response.
5. Missing answer keys were silently interpreted as wrong answers.

## Definitive V5.1 behaviour

- The student page calls a new, unambiguous RPC: **`cbt_submit_v5`**.
- The result is accepted only when the response contains `engine_version: v5.1.x`.
- The exam is blocked before starting when the public getter does not report V5.1.
- Legacy key names and option names are found case-insensitively.
- Letter, option text, true/false, numeric tolerance, multi-select sets, accepted alternatives and legacy 0/1-based option indexes are handled.
- Randomised questions are graded using their original bank indexes.
- Browser-supplied score/percent fields are ignored.
- Missing objective keys return `answer_key_missing`; no false zero result is inserted.
- Public exam questions remove every recognised answer/accepted-answer/explanation alias.
- Each result stores `engine_version`, `grading_status`, `ungraded_count` and per-subject scores.

## Existing database installation

1. Stop new CBT sittings temporarily.
2. Back up Supabase.
3. SQL Editor → run:
   ```text
   database/cbt-v5.1-zero-score-hotfix.sql
   ```
4. Confirm the last message says:
   ```text
   School Connect CBT V5.1 definitive grading engine installed
   ```
5. Deploy the updated files:
   - `cbt-exam.html`
   - `cbt.html`
   - `cbt-multi.html`
   - `assets/js/cbt-engine.js`
   - updated `sw.js`, `_headers`, `vercel.json`
6. Close all portal tabs and reopen/hard-refresh.
7. In CBT Manager, click **Diagnose Scoring** for an existing exam.
8. If missing/legacy keys are reported, click **Repair Scoring**, then diagnose again.
9. Use **Regrade Saved Results** to recalculate historical rows whose `answers_data` was retained. Rows without saved answers or with unresolved keys remain unchanged and are counted in the response.
10. Use **Repair Tabs** separately for old UTME subject metadata.

Fresh projects should run the full `complete-schema.sql`, which already contains the same engine.

## SQL verification

```sql
select routine_name
from information_schema.routines
where routine_schema='public'
  and routine_name in (
    'cbt_submit_v5','cbt_diagnose_exam','cbt_repair_exam_scoring',
    'cbt_regrade_exam_results_v5','sc_cbt_answer_matches','sc_cbt_public_question'
  )
order by routine_name;
```

Expected: six rows.

Check newly submitted results:

```sql
select student_name, score, total, percent,
       correct_count, wrong_count, skipped_count,
       grading_status, ungraded_count, engine_version,
       subject_scores, submitted_at
from public.cbt_results
order by submitted_at desc
limit 20;
```

New results must show `engine_version = 'v5.1.0'`.

## Executed regression proof

`tools/test-cbt-sql-engine.mjs` runs the actual hotfix in embedded PostgreSQL-compatible PGlite and submits a five-question bank using legacy formats:

- `CorrectAnswer` with `Option A/B/C`
- option text in `correct_option`
- `Correct Answer` true/false
- `answer_key: B|C` with `mrq`
- `rightAnswer` numeric tolerance

Observed result: **10/10, 100%, five correct**, idempotent retry, public answer aliases redacted, and a broken bank returns `answer_key_missing` instead of saving zero.
