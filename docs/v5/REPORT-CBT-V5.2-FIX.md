# Report Card, Bulk CBT Push and Exam Access — V5.2

## Report-card data correction

V5.2 makes `assessment_columns` + `report_scores` the sole official source once a report context is configured. Raw CBT, reading and LMS attempts are no longer injected automatically.

Root causes fixed:

- Global column scores were keyed by student + column but omitted the subject, allowing another subject’s value to appear.
- Save All converted blank inputs to zero and created rows the teacher never entered.
- Raw CBT percentages could be counted beside an explicitly pushed score.
- Default affective/psychomotor ratings and comments invented values.

New behaviour:

- Every query is scoped by class, subject, term and session.
- Blank cells remain absent and print as `—`.
- Clearing an entered value deletes that official score row.
- No default traits/comments are invented; reports say “Not rated” or “No comment entered.”
- **Audit / Clear Unwanted Scores** shows exact student, subject, column, score, source and update time. Nothing is deleted automatically.

## Promotion indication

The report card reads the approved `promotions` record by student ID, with a legacy student-name fallback. It prints one of:

- `PROMOTED TO …`
- `GRADUATED`
- `NOT PROMOTED — REPEAT …`
- `PROMOTION DECISION PENDING`
- `PROMOTION NOT YET DECIDED`

Academic average never silently decides promotion.

## Bulk CBT push

Use **Bulk Push CBT Scores → Official Report Cards** from CBT Manager or Report Cards.

1. Filter by class, subject, term and session.
2. Preview matching exams, result counts and report destinations.
3. Select all or selected exams.
4. Use each exam’s configured report column or override every selection.
5. Optionally create missing global columns with an explicit maximum mark.
6. Keep “V5.1 verified/regraded only” enabled.
7. Push once.

The pipeline scales each verified percentage to the destination maximum and upserts directly to `report_scores`. It handles multi-subject `subject_scores`, is idempotent, and never duplicates a learner/subject/destination row.

## Exam-access correction

The candidate page now calls `cbt_get_public_exam_v5`, not the ambiguous legacy getter. Codes ignore case, spaces and hyphens. The server distinguishes:

- no matching code
- exists but not open
- archived
- not started
- closed
- getter/server upgrade error

CBT Manager now confirms open/close updates and reports RLS errors. The school name is displayed twice in the identity header and once in the entry card, with forced visible white heading styles.

## Deployment

For this cumulative V5.2 change, back up Supabase and run the updated `complete-schema.sql`, then deploy all updated repository files. The focused CBT hotfix also contains the explicit V5 getter, but the full schema is required for the cumulative report/promotion indexes and constraints.
