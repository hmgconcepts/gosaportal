/* V12.79 — THE FILE MUST UPGRADE AN OLDER INSTALL, NOT ONLY INSTALL A NEW ONE.
   ---------------------------------------------------------------------------
   The school's report, verbatim:

       Failed to run sql query: ERROR: 42P13: cannot change return type of
       existing function
       DETAIL: Row type defined by OUT parameters is different.
       HINT: Use DROP FUNCTION sc_my_prep_exams(text,text) first.

   A fresh database installed the file perfectly. A database that already had
   the previous release did not, because `create or replace function` replaces a
   BODY — it cannot replace a SIGNATURE, and for a `returns table(...)` function
   the column list IS part of the signature. The release added columns to
   sc_my_prep_exams, and every school that already had it hit the wall.

   This suite builds that exact situation and proves three things:
     1. the OLD file (without the upgrade prelude) really does fail with 42P13 —
        so the test is reproducing the reported error, not a guess;
     2. the SHIPPED file upgrades the same database cleanly;
     3. after the upgrade the functions really are the new ones (columns,
        return types) and a third run is still a no-op (idempotent).

   Run: node tools/verification/t53-schema-upgrade.mjs
*/
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import path from 'path';
import { schemaText } from './schema-loader.mjs';

const HERE = new URL('.', import.meta.url).pathname;
const ROOT = path.resolve(HERE, '..', '..');
const BOOT = path.join(ROOT, 'tools', 'verification', 'pglite-boot.sql');
const BUILT = path.join(ROOT, 'database', 'complete-schema.sql');

let pass = 0, fail = 0;
const ok = (c, m, x) => { c ? (pass++, console.log('  PASS', m)) : (fail++, console.log('  FAIL', m, x === undefined ? '' : JSON.stringify(x).slice(0, 400))); };

const sql = schemaText(BUILT);
const stripped = sql.replace(/do \$sc_upgrade\$[\s\S]*?end\$sc_upgrade\$;/, '-- (upgrade prelude removed on purpose by the test)');
const hasPrelude = /do \$sc_upgrade\$/.test(sql);

/* the row-returning functions the file protects */
const protectedNames = (() => {
  const m = sql.match(/and p\.proname in \(([^)]*)\)/);
  return m ? m[1].split(',').map(s => s.trim().replace(/^'|'$/g, '')) : [];
})();

async function fresh() {
  const db = await PGlite.create();
  await db.exec(fs.readFileSync(BOOT, 'utf8'));
  return db;
}

/* turn a modern database into an OLDER one: every protected function redefined
   with a different row type, and the hold-list view with a shorter column list.
   Args are read from the catalogue, so no signature is hard-coded here. */
const AGE = `
do $age$declare r record; n int;begin
  for r in select p.oid::regprocedure::text sig,
                  pg_get_function_identity_arguments(p.oid) args, p.proname nm
             from pg_proc p join pg_namespace n2 on n2.oid=p.pronamespace
            where n2.nspname='public' and p.prorettype='record'::regtype
              and p.proname = any (array[${protectedNames.map(n => `'${n}'`).join(',')}])
  loop
    execute format('drop function %s', r.sig);
    /* two shapes matter: the multi-column one the school actually had, and a
       single-column one (which Postgres stores as a SCALAR return type, not a
       row type — the case a return-type filter silently misses) */
    if r.nm = 'table_sizes' then
      execute format('create function %I(%s) returns table(zzz int) language sql as $old$ select 1 $old$',
                     r.nm, r.args);
    else
      execute format('create function %I(%s) returns table(zzz int, yyy int) language sql as $old$ select 1,2 $old$',
                     r.nm, r.args);
    end if;
  end loop;
end $age$;
/* an older release of the view had fewer columns than the current one */
drop view if exists public.sc_report_hold_list cascade;
create view public.sc_report_hold_list as
  select h.id, h.student_id_ref from public.sc_report_position_hold h;
`;

const Q = {
  funcs: `select p.proname as name,
                 pg_get_function_identity_arguments(p.oid) as args,
                 case when p.prorettype='record'::regtype then 'record' else format_type(p.prorettype,null) end as ret,
                 pg_get_function_result(p.oid) as result,
                 (select string_agg(a.attname, ',' order by a.attnum)
                    from pg_type t join pg_attribute a on a.attrelid=t.typrelid
                   where t.oid=p.prorettype and a.attnum>0) as cols
            from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname = any (array[${protectedNames.map(n => `'${n}'`).join(',')}])
           order by 1, 2`,
  viewCols: `select string_agg(column_name, ',' order by ordinal_position) cols
               from information_schema.columns
              where table_schema='public' and table_name='sc_report_hold_list'`,
};

try {
  ok(hasPrelude, 'the shipped file carries the upgrade prelude');
  ok(protectedNames.length >= 7, `it protects every row-returning function (${protectedNames.length})`, protectedNames);
  ok(protectedNames.includes('sc_my_prep_exams'), 'including the one in the school’s error', protectedNames);

  /* ---------------------------------------------- 1. the error, reproduced -- */
  console.log('\n=== an older install, and the file as it used to be ===');
  const dbOld = await fresh();
  await dbOld.exec(sql);                       // a school that installed the last release
  await dbOld.exec(AGE);                       // …whose functions are the OLD shapes
  const before = await dbOld.query(Q.funcs);
  const prepOld = before.rows.find(r => r.name === 'sc_my_prep_exams');
  ok(!!prepOld && /zzz/.test(String(prepOld.result || '')),
     'the test database really is in the old shape (sc_my_prep_exams returns a dummy row)', prepOld);
  const sizesOld = before.rows.find(r => r.name === 'table_sizes');
  ok(!!sizesOld && /integer/i.test(String(sizesOld.ret || '')),
     'and one function is in the single-column shape Postgres stores as a scalar', sizesOld && sizesOld.ret);

  let oldErr = null;
  try { await dbOld.exec(stripped); } catch (e) { oldErr = String(e.message || e); }
  ok(!!oldErr && /42P13|cannot change return type/i.test(oldErr),
     'WITHOUT the prelude the same database fails exactly as the school reported', oldErr && oldErr.slice(0, 160));

  /* --------------------------------------------------- 2. the shipped file -- */
  console.log('\n=== the shipped file, on the same older install ===');
  const dbNew = await fresh();
  await dbNew.exec(sql);
  await dbNew.exec(AGE);
  let upgradeErr = null;
  try { await dbNew.exec(sql); } catch (e) { upgradeErr = String(e.message || e); }
  ok(!upgradeErr, 'the shipped file upgrades the older database cleanly', upgradeErr && upgradeErr.slice(0, 200));

  const after = await dbNew.query(Q.funcs);
  const byName = Object.fromEntries(after.rows.map(r => [r.name, r]));
  ok(after.rows.every(r => !/^zzz$/.test(r.cols || '')), 'no protected function is left returning the old row type',
     after.rows.filter(r => /^zzz$/.test(r.cols || '')).map(r => r.name));

  const prep = byName.sc_my_prep_exams;
  ok(!!prep && prep.ret === 'record', 'sc_my_prep_exams exists again', prep);
  /* the column list of a TABLE function lives in its OUT parameters, so read it
     from the function's own result signature */
  const cols = String((prep && (prep.result || prep.cols)) || '');
  ['exam_id', 'code', 'title', 'subject', 'class', 'start_local', 'status', 'seconds_to_start', 'seconds_to_close', 'server_now']
    .forEach(c => ok(new RegExp('\\b' + c + '\\b').test(cols), `sc_my_prep_exams returns "${c}"`, cols.slice(0, 220)));
  const sizesAfter = byName.table_sizes;
  ok(!!sizesAfter && !/zzz/.test(String(sizesAfter.result || '')),
     'so does the single-column one that a naive filter would have missed', sizesAfter && String(sizesAfter.result).slice(0, 120));

  const viewAfter = await dbNew.query(Q.viewCols);
  const vcols = String(viewAfter.rows[0].cols || '');
  ok(vcols.split(',').length >= 9, 'the hold-list view is back with its full column list', vcols);

  /* --------------------------------------------- 3. still idempotent -------- */
  console.log('\n=== and it is still safe to run again ===');
  let thirdErr = null;
  try { await dbNew.exec(sql); } catch (e) { thirdErr = String(e.message || e); }
  ok(!thirdErr, 'a third run is a no-op', thirdErr && thirdErr.slice(0, 200));

  /* ------------------------------------------- 4. the caller can still use it */
  const rpc = await dbNew.query(`select count(*)::int n from public.sc_my_prep_exams(null,'Africa/Lagos')`);
  ok(rpc.rows[0].n === 0 || typeof rpc.rows[0].n === 'number', 'the function can be called after the upgrade', rpc.rows[0]);
} finally {
  /* nothing to close: each PGlite instance dies with the process */
}

if (fail) { console.error(`\nSCHEMA UPGRADE FAILED — ${pass} passed, ${fail} failed`); process.exit(1); }
console.log(`\nSCHEMA UPGRADE OK — ${pass} passed, 0 failed · the file installs a new school AND upgrades an old one.`);
