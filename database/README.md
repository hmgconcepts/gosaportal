# School Connect V5.8 database installation

Back up Supabase and run the entire **`complete-schema.sql`**. It is the only
production SQL for a fresh project or cumulative upgrade and is safe to re-run.
It contains every V5.1–V5.8 table, migration, trigger, view, RLS policy, grant and
RPC. Do not run focused/versioned SQL afterward.

Wait for: `School Connect V5.8 complete cumulative schema installed successfully ✅ — no other production SQL is required`.

Demo-only order: complete schema → create five Auth users → `demo-users.sql` →
`demo-seed.sql`. Never run demo SQL in production.

V5.8 adds institutional signatories, editable/deletable public exam-registration
campaigns, protected public submission RPCs, performance comment bands and
owner/leadership role boundaries while retaining every earlier repair.
