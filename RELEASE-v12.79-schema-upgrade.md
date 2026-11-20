# School Connect — schema upgrade fix (V12.79, build 2)

**8 November 2026 · what changed, why it happened, and what to do**

---

## The error schools were seeing

```
Failed to run sql query: ERROR: 42P13: cannot change return type of existing function
HINT: Use DROP FUNCTION public.sc_my_prep_exams(text,text) first.
```

It happened **only** where the database already held an older School Connect —
never on a new project. That asymmetry is the whole story.

## Why it happened

`create or replace function` can replace a function's **body**. It cannot replace
its **signature**. For a function that returns a table, the column list *is* part
of the signature:

```sql
returns table(exam_id uuid, code text, title text, …)   -- V12.78: 8 columns
returns table(exam_id uuid, code text, title text, …, server_now timestamptz)  -- V12.79: 10
```

So the release that added two columns to the prep-exam function was fine on a
fresh database and a hard stop on every existing one. One line of SQL, one
release, and the school could not upgrade — the worst possible place for a
release to break, because the database is step one of every update.

The same class of failure existed in three more places, all silent on a fresh
install:

| Postgres error | Cause | Fixed by |
|---|---|---|
| `42P13` | function's `RETURNS TABLE` / `OUT` list changed | the file now drops those functions by name and signature before re-creating them |
| `42P16` | view column list changed (`sc_report_hold_list`) | `drop view if exists … cascade` before the create |
| `42710` | policy / constraint already exists | already handled by the file's own guards — now proved by the audit |
| `42701` | column already exists | every `add column` carries `if not exists` — now proved by the audit |

## The fix — structural, in the generator

`tools/build-complete-schema.py` now writes an **upgrade prelude** at the top of
the generated file (step 9d). It is derived from the file itself on every build:
any function whose header declares a row type (`returns table(…)`, `returns
setof`, `returns record`, or `out`/`inout` parameters) is dropped first.

```sql
do $sc_upgrade$ declare r record; begin
  for r in select p.oid::regprocedure::text sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('verify_certificate','table_sizes','retention_candidates',
                                'sc_list_student_archives','sc_diary_acks','sc_security_posture',
                                'sc_my_prep_exams')
  loop
    begin execute 'drop function ' || r.sig;
    exception when others then
      raise notice 'School Connect: % kept in place (%). A dependent object holds it; drop that object first.', r.sig, sqlerrm;
    end;
  end loop;
end $sc_upgrade$;
```

Three properties matter:

1. **It is generated, not hand-listed.** The next release that adds a column to
   *any* row-returning function is protected automatically; nobody has to
   remember this rule.
2. **It drops by name *and* signature** (`regprocedure`), so genuine overloads
   survive and only the changed shapes go.
3. **It can never stop the install.** If something still depends on a function,
   the drop raises a notice and the script continues; the following
   `create or replace` then either succeeds or reports the real dependency.

## The evidence

`tools/verification/t53-schema-upgrade.mjs` (in the gate) builds a database from
the shipped file, **ages it** — redefines every protected function as
`returns table(zzz int, yyy int)`, and one of them as a single-column
`returns table(zzz int)`, which Postgres stores as a *scalar* return type — then:

- strips the prelude from the same shipped file and proves it fails with
  **exactly the school's `42P13`** (so the test cannot pass by accident),
- runs the real file and proves the upgrade succeeds,
- proves `sc_my_prep_exams` comes back with all ten columns, and `table_sizes`
  with its real one,
- proves the hold-list view returns with its full column list,
- proves a third run is a no-op and the function is callable afterwards.

`23 passed, 0 failed`.

`tools/audit-schema-upgrade.py` is the standing guard: it reads the file, masks
dollar-quoted bodies, and classifies every top-level statement by the failure it
would cause on an older database — 7 row-type functions, 7 views, 332 policies,
36 triggers, 135 tables, 87 indexes, 388 column additions, 4 constraints. It
exits non-zero on any unguarded hazard and is wired into `run-all-tests.sh`, so a
future edit that reintroduces the bug fails the gate instead of a school's
install.

`node tools/verify-complete-schema.mjs` remains ALL PASS: the same 134 tables,
1,661 columns, 280 functions, 5 views, 53 triggers, 315 policies, 386 indexes,
380 constraints, 1,037 grants and 134 RLS flags as the cumulative source, applied
twice.

## What a school does

1. Download the current V12.79 ZIP again (the schema inside was rebuilt — the
   SHA-256 on the download shelf has changed).
2. SQL Editor → paste `database/complete-schema.sql` → **Run**.
3. Expect a handful of notices while it runs, of the form
   `School Connect: public.sc_my_prep_exams(text,text) kept in place` **or**
   silence — both are normal. What matters is the last row:
   *"reload schema"*, and that the statement list ends green.
4. Upload the new files over the old ones, then **Update now** on a phone.

No data is touched. Nothing needs to be dropped by hand, and no function has to
be deleted before pasting — that instruction is exactly what this build removes.
