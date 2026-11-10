/* V12.68 — the complete schema must be the ONLY file a school runs.
   Boot a BARE Postgres: no auth schema, no auth.uid(), no api roles.
   If complete-schema.sql is genuinely self-contained it applies cleanly. */
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import { schemaText } from './schema-loader.mjs';
const HERE = new URL('.', import.meta.url).pathname;
const S = p => schemaText(HERE + '../../database/' + p);
let pass = 0, fail = 0;
const ok = (c, m, e) => { if (c) { pass++; console.log('  PASS', m); } else { fail++; console.log('  FAIL', m, e ?? ''); } };

console.log('\n=== 1. a completely bare database ===');
const db = await PGlite.create();
const pre0 = await db.query(`select
   (select count(*) from information_schema.schemata where schema_name='auth')::int auth_schema,
   (select count(*) from pg_roles where rolname='authenticated')::int role_authed`);
const pre = pre0.rows;
ok(pre[0].auth_schema === 0, 'no auth schema exists before we start', pre[0]);
ok(pre[0].role_authed === 0, 'no authenticated role exists before we start');

let applied = false, err = '';
try { await db.exec(S('complete-schema.sql')); applied = true; }
catch (e) { err = e.message; }
ok(applied, 'complete-schema.sql applies to a bare database with no other SQL', err);

if (applied) {
  console.log('\n=== 2. it built the prerequisites it needed ===');
  const r0 = await db.query(`select
     (select count(*) from information_schema.schemata where schema_name='auth')::int a,
     (select count(*) from pg_roles where rolname='authenticated')::int b,
     (select count(*) from pg_roles where rolname='anon')::int c,
     (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='auth' and p.proname='uid')::int d`);
  const r = r0.rows;
  ok(r[0].a === 1, 'auth schema exists', r[0]);
  ok(r[0].b === 1, 'authenticated role exists', r[0]);
  ok(r[0].c === 1, 'anon role exists', r[0]);
  ok(r[0].d === 1, 'auth.uid() exists', r[0]);

  console.log('\n=== 3. and the platform actually works on it ===');
  const U = '11111111-1111-1111-1111-111111111111';
  await db.exec(`insert into auth.users(id,email) values('${U}','a@b.c') on conflict do nothing;
                 insert into profiles(id,full_name,role,status) values('${U}','A','admin','approved')
                   on conflict(id) do update set role='admin',status='approved';`);
  const st = await db.query(`select public.is_staff('${U}'::uuid) s, public.is_admin('${U}'::uuid) a`);
  ok(st.rows[0].s === true, 'is_staff() answers', st.rows[0]);
  ok(st.rows[0].a === true, 'is_admin() answers', st.rows[0]);
  const tr = await db.query(`select public.sc_term_resolve(null,null) r`);
  ok(tr.rows[0].r && tr.rows[0].r.ok === true, 'the term resolver runs', tr.rows[0]);

  console.log('\n=== 4. every V12.6x engine is present ===');
  const fns = await db.query(`select proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                               where n.nspname='public'`);
  const names = new Set(fns.rows.map(x => x.proname));
  for (const f of ['sc_term_resolve','sc_fee_bill_v2','sc_fee_ledger_for','sc_fee_invoice_sync',
                   'sc_fee_prior_terms','sc_fee_truth_migrate','sc_fee_doctor_v3','sc_fee_page_rows',
                   'sc_fee_allocate','sc_fee_receipt_bill','sc_report_policy','sc_report_remap_cbt',
                   'sc_report_repair_all','sc_recompute_fee_rows']) {
    ok(names.has(f), 'contains ' + f);
  }

  console.log('\n=== 5. running it twice is still safe ===');
  let twice = false; let e2 = '';
  try { await db.exec(S('complete-schema.sql')); twice = true; } catch (e) { e2 = e.message; }
  ok(twice, 'the second run succeeds (idempotent)', e2);
}

console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
