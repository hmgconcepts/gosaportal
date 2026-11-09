# School Connect — database installation (V12.65)

Back up Supabase and run the entire **`complete-schema.sql`**. It is the only
production SQL for a fresh project or a cumulative upgrade, and it is safe to
re-run.

It installs **127 tables, 1,541 columns, 195 functions, 4 views, 292 RLS
policies, 242 indexes and 354 constraints** — every table, column, index,
constraint, view, function, trigger, RLS policy, grant and seed row the platform
uses, including the V12.64 fair-ranking report engine and the V12.65 class diary.
Do not run older focused/versioned SQL afterwards.

Wait for the final row:

```
V12.65 applied: public.diary + diary_ack, sc_diary_ack, sc_diary_acks, sc_diary_feed
```

Demo-only order: complete schema → create five Auth users → `demo-users.sql` →
`demo-seed.sql`. Never run demo SQL in production.

---

## Size, and why it matters

Supabase's SQL Editor refuses any single run above **1 MB** with:

> Error: Query is too large to be run via the SQL Editor
> Run this query by connecting to your database directly

The cumulative schema had grown to 1.05 MB and could no longer be applied from
the dashboard. It is now **782 KB (V12.65)** and runs from the dashboard in one
paste-and-Run.

## `complete-schema.sql` is generated — do not hand-edit it

```bash
python3 tools/build-complete-schema.py      # rebuild from the cumulative source
node    tools/verify-complete-schema.mjs    # prove the rebuild changed nothing
python3 tools/audit-schema-coverage.py      # prove nothing the app calls is missing
```

**Adding a feature the right way:**

1. write `database/vX.Y-your-feature.sql` (idempotent, self-contained);
2. append it to the cumulative source;
3. run `tools/build-complete-schema.py`;
4. run both verification tools — they must print **ALL PASS**;
5. `python3 tools/sync-v5-repos.py` to push it to every mirrored repo.

`build-complete-schema.py` removes only things a sequential run cannot observe:
superseded function/view/table/index/policy/trigger declarations, repeated
`add column if not exists` backfills, duplicate grants, and progress-select
noise. It never removes an object, a column, a policy or a grant.

`verify-complete-schema.mjs` boots two real Postgres instances (PGlite), applies
the raw cumulative schema to one and the rebuilt schema to the other, and diffs
the catalogues object by object — tables, columns, types, defaults, constraints,
indexes, function bodies, views, triggers, policies, grants, RLS flags. It also
proves the file applies **twice**.

## If your editor still refuses the file

Every `-- ===...===` section banner is an independent, re-runnable boundary.
Split there and run the parts in order; the result is identical.
