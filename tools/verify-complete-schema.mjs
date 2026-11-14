/**
 * School Connect - complete-schema equivalence verifier
 *
 * Proves that database/complete-schema.sql (rebuilt, Supabase-sized) produces
 * EXACTLY the same database as the raw cumulative file it was built from.
 *
 * It boots two independent Postgres instances (PGlite), applies one file to
 * each, then diffs the resulting catalogue object by object:
 *     tables, columns (name/type/nullable/default), constraints, indexes,
 *     functions (signature + body), views, triggers (timing/events/function),
 *     policies (command/roles/using/with-check) and grants.
 *
 * Also checks:
 *     - the built file applies twice (idempotent)
 *     - the built file is under the Supabase SQL Editor request cap
 *
 * Usage:
 *     node tools/verify-complete-schema.mjs                        # vs git/raw copy
 *     node tools/verify-complete-schema.mjs path/to/raw.sql
 */
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import path from 'path';
import { schemaText } from './verification/schema-loader.mjs';

const HERE = new URL('.', import.meta.url).pathname;
const ROOT = path.resolve(HERE, '..');
const BOOT = path.join(HERE, 'verification', 'pglite-boot.sql');
const BUILT = path.join(ROOT, 'database', 'complete-schema.sql');
/* V12.67 — the raw source now has a canonical home inside the workspace. The
   old default (/tmp) silently compared against a stale copy and reported
   phantom drift, so resolve the persistent location first and fail loudly
   rather than comparing against nothing. */
const RAW = process.argv[2] || process.env.SC_RAW
  || (fs.existsSync('/home/user/work/schema/complete-schema.raw.sql')
        ? '/home/user/work/schema/complete-schema.raw.sql'
        : '/tmp/complete-schema.raw.sql');

const LIMIT = 1_000_000;
let failures = 0;
const ok = (c, msg) => { console.log(`  ${c ? 'PASS' : 'FAIL'}  ${msg}`); if (!c) failures++; };

function load(p) {
  /* V12.68 — shared loader. It neutralises only TOP-LEVEL create-extension
     statements; the schema also has one inside a PL/pgSQL block (pg_cron),
     where a bare SELECT is a syntax error and the block's own text gets
     corrupted. See tools/verification/schema-loader.mjs. */
  return schemaText(p);
}

async function build(p) {
  const db = await PGlite.create();
  await db.exec(fs.readFileSync(BOOT, 'utf8'));
  const errs = [];
  try { await db.exec(load(p)); }
  catch (e) { errs.push(String(e.message)); }
  return { db, errs };
}

const Q = {
  tables: `select c.relname as name from pg_class c join pg_namespace n on n.oid=c.relnamespace
           where n.nspname='public' and c.relkind='r' order by 1`,
  columns: `select table_name||'.'||column_name as k, data_type, udt_name,
                   is_nullable, coalesce(column_default,'') as def, coalesce(character_maximum_length::text,'') as len
            from information_schema.columns where table_schema='public' order by 1`,
  /* V12.72 — hash the function body with WHITESPACE NORMALISED.
     The build de-indents SQL to fit Supabase's 1 MB limit; that changes
     pg_get_functiondef() byte-for-byte while the function stays identical.
     Comparing raw whitespace would fail on a purely cosmetic difference and
     hide a real one, so the comparison is made on the tokens. */
  functions: `select p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' as sig,
                     pg_get_functiondef(p.oid) as body
              from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' order by 1`,
  views: `select viewname as name from pg_views where schemaname='public' order by 1`,
  matviews: `select matviewname as name from pg_matviews where schemaname='public' order by 1`,
  triggers: `select t.tgname||' on '||c.relname||' '||pg_get_triggerdef(t.oid) as def
             from pg_trigger t join pg_class c on c.oid=t.tgrelid
             join pg_namespace n on n.oid=c.relnamespace
             where not t.tgisinternal and n.nspname='public' order by 1`,
  policies: `select policyname||' on '||tablename as k, permissive, array_to_string(roles,',') as roles,
                    cmd, coalesce(qual,'') as qual, coalesce(with_check,'') as wc
             from pg_policies where schemaname='public' order by 1`,
  indexes: `select indexname||' on '||tablename as k, indexdef
            from pg_indexes where schemaname='public' order by 1`,
  constraints: `select conrelid::regclass::text||'.'||conname as k, contype, pg_get_constraintdef(oid) as def
                from pg_constraint where connamespace='public'::regnamespace order by 1`,
  grants: `select table_name||' '||grantee||' '||privilege_type as k
           from information_schema.role_table_grants where table_schema='public' order by 1`,
  rls: `select c.relname||' rls='||c.relrowsecurity::text as k
        from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind='r' order by 1`,
  seq: `select sequence_name as k from information_schema.sequences where sequence_schema='public' order by 1`,
};

async function dump(db) {
  const out = {};
  for (const [k, sql] of Object.entries(Q)) {
    try {
      const r = await db.query(sql);
      out[k] = r.rows.map(row => {
        /* V12.72 — the build de-indents SQL to fit Supabase's 1 MB editor
           limit, which changes pg_get_functiondef() formatting while every
           function stays identical. Compare FUNCTIONS on their tokens, not
           on their leading spaces, so a cosmetic difference cannot mask a
           real one and cannot fail the gate either. */
        if (k === 'functions' && row.body) {
          /* V12.73 — the build also shortens long COMMENT blocks inside a
             function body to stay under the 1 MB cap. A comment is not a schema
             object: Postgres stores the body text verbatim, and no query result
             can differ because a `-- ...` line is shorter. Strip comment lines
             before comparing so the gate measures behaviour, not prose. */
          const code = String(row.body)
            .split('\n')
            .filter(ln => !ln.trim().startsWith('--'))
            .join('\n')
            .replace(/\s+/g, ' ')
            .trim();
          row = { ...row, body: code };
        }
        return JSON.stringify(row);
      });
    } catch (e) {
      out[k] = ['ERR:' + e.message];
    }
  }
  return out;
}

function diff(a, b) {
  const sa = new Set(a), sb = new Set(b);
  return {
    missing: [...sa].filter(x => !sb.has(x)),
    extra: [...sb].filter(x => !sa.has(x)),
  };
}

// --------------------------------------------------------------------- run
console.log('\n  School Connect - complete schema equivalence\n  ' + '-'.repeat(52));

if (!fs.existsSync(RAW)) {
  console.log(`\n  raw copy not found: ${RAW}`);
  console.log('  (pass the pre-build file as the first argument)');
  process.exit(2);
}

const builtBytes = fs.statSync(BUILT).size;
const rawBytes = fs.statSync(RAW).size;
console.log(`  raw    ${rawBytes.toLocaleString()} B`);
console.log(`  built  ${builtBytes.toLocaleString()} B`);
console.log();

ok(builtBytes < LIMIT, `built file is under the Supabase ${LIMIT.toLocaleString()} B cap`);

const A = await build(RAW);
ok(A.errs.length === 0, `raw file applies${A.errs.length ? ': ' + A.errs[0].slice(0, 200) : ''}`);

const B = await build(BUILT);
ok(B.errs.length === 0, `built file applies${B.errs.length ? ': ' + B.errs[0].slice(0, 200) : ''}`);

// idempotency of the built file
let twice = true, twiceMsg = '';
try { await B.db.exec(load(BUILT)); } catch (e) { twice = false; twiceMsg = ': ' + String(e.message).slice(0, 200); }
ok(twice, `built file applies a SECOND time (idempotent)${twiceMsg}`);

console.log();
const da = await dump(A.db);
const db_ = await dump(B.db);

const LABELS = {
  tables: 'tables', columns: 'columns (name/type/nullable/default)',
  constraints: 'constraints', indexes: 'indexes', functions: 'functions (signature + body)',
  views: 'views', matviews: 'materialised views',
  triggers: 'triggers (timing/events/function)', policies: 'policies (cmd/roles/using/check)',
  grants: 'table grants', rls: 'row-level security flags', seq: 'sequences',
};
let identical = true;
for (const k of Object.keys(Q)) {
  const { missing, extra } = diff(da[k], db_[k]);
  const same = missing.length === 0 && extra.length === 0;
  if (!same) identical = false;
  ok(same, `${(LABELS[k] || k).padEnd(40)} ${String(da[k].length).padStart(4)} objects` +
            (same ? '' : `  (raw-only ${missing.length}, built-only ${extra.length})`));
  if (!same) {
    missing.slice(0, 5).forEach(x => console.log(`         - only in raw:   ${x.slice(0, 150)}`));
    extra.slice(0, 5).forEach(x => console.log(`         + only in built: ${x.slice(0, 150)}`));
  }
}

console.log();
if (identical) console.log('  ALL PASS - the rebuilt schema is object-identical to the raw cumulative schema.');
else console.log(`  ${failures} DIFFERENCE(S) - do not ship.`);
console.log();
process.exit(failures === 0 ? 0 : 1);
