# CBT Error `column "motto" does not exist` — V5.1.1 Fix

## Cause

`cbt_get_public_exam_v5` selected `school_settings.motto` directly. Some older School Connect databases have the exam tables/functions but predate that optional settings column. PostgreSQL therefore aborted the whole exam lookup even though code `XQTECN` existed and was open.

## Fix

- Adds missing legacy settings fields idempotently: `school_name`, `short_name`, `motto`, `address`, `phone`, `email`, `logo_url`.
- Replaces the V5 getter so it reads the complete settings row with `to_jsonb(ss)` and extracts optional keys from JSON. A missing optional key now becomes an empty value and cannot abort exam loading.
- Preserves normalised exam codes and explicit `not_open`, `archived`, `not_started`, `closed` and not-found diagnostics.
- Getter response now reports `engine_version: v5.1.1`.

## Immediate existing-database installation

1. Back up Supabase.
2. SQL Editor → run only:

```text
database/cbt-v5.1.1-getter-school-settings-fix.sql
```

3. Confirm the final success message.
4. Deploy the updated `cbt-exam.html` and service worker, then close old tabs and hard-refresh.
5. Retry code `XQTECN`.

You may instead rerun the newly updated `cbt-v5.1-zero-score-hotfix.sql` or full `complete-schema.sql`; both now contain this repair. Do not run multiple alternatives unnecessarily.

## Executed regression test

The SQL test installs the hotfix, deliberately drops `school_settings.motto`, and calls `cbt_get_public_exam_v5` with a code containing different spaces/hyphens. The getter succeeds, returns the school name and redacted questions, while an existing closed exam returns the explicit `not_open` diagnostic.
