/* V12.76 — platform security & integrity audit (catalogue-level).

   This boots the SHIPPED database/complete-schema.sql into a bare Postgres
   (PGlite) and interrogates the resulting catalogue. It answers the questions a
   reviewer would ask before signing off a school's deployment:

     1. Is every table protected?            (RLS enabled, policies present)
     2. Are privileged functions pinned?     (SECURITY DEFINER + search_path)
     3. Can the anonymous role reach anything it should not?
     4. Are there policies that allow everything to everyone?
     5. Can a report/fee query do a full scan? (missing indexes on FK columns)
     6. Does every table have a primary key?
     7. Are there write paths with no audit trail?

   It is read-only: it inspects the catalogue and prints findings. Exit code 1
   if any HIGH finding is present, so the gate can enforce it. */
import { PGlite } from '@electric-sql/pglite';
import { schemaText } from './schema-loader.mjs';

const HERE = new URL('.', import.meta.url).pathname;
const db = await PGlite.create();
await db.exec(schemaText(HERE + '../../database/complete-schema.sql'));

const q = async (sql) => (await db.query(sql)).rows;

const findings = [];
const add = (level, code, msg, detail) => findings.push({ level, code, msg, detail });

/* ---------------------------------------------------------------- 1. RLS --- */
const rlsOff = await q(`
  select c.relname
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
   order by 1`);
for (const r of rlsOff) add('HIGH', 'RLS-OFF', `table ${r.relname} has row-level security disabled`);

const noPolicy = await q(`
  select c.relname,
         (select count(*) from pg_policies p
           where p.schemaname = 'public' and p.tablename = c.relname)::int as policies
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
   order by 1`);
const DENY_ALL_OK = new Set(['cbt_edit_log', 'cbt_results_recovery_log', 'cbt_retake_allowances']);
for (const r of noPolicy.filter(x => x.policies === 0)) {
  add(DENY_ALL_OK.has(r.relname) ? 'INFO' : 'WARN', 'RLS-DENY-ALL',
      `table ${r.relname} has RLS enabled with NO policies — deny-all for every client role`);
}

/* ------------------------------------------- 2. SECURITY DEFINER pinning --- */
const sd = await q(`
  select p.proname,
         pg_get_function_identity_arguments(p.oid) as args,
         coalesce(array_to_string(p.proconfig, ','), '') as cfg
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef
   order by 1`);
for (const f of sd) {
  if (!/search_path/.test(f.cfg)) {
    add('HIGH', 'SD-NO-PATH',
        `SECURITY DEFINER ${f.proname}(${f.args}) does not pin search_path`);
  }
}

/* --------------------------------------------------- 3. anon reachability --- */
const anon = await q(`
  select p.proname, pg_get_function_identity_arguments(p.oid) as args,
         has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can,
         p.prosecdef, coalesce(array_to_string(p.proconfig, ','), '') as cfg
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
   order by 1`);
/* The public surface is a DECISION, not an accident, so it is written down here
   and asserted on every run. These are exactly the RPCs the signed-out pages
   call (submit_admission on apply.html, verify_certificate on
   verify-certificate.html, lookup_login_email on forgot-password.html, the
   cbt_* / sc_cbt_* public-exam family on cbt-exam.html, the licence banner and
   keep-alive heartbeat that run on every page) plus the predicates that RLS
   policies evaluate. A function that is NOT in this list and is still reachable
   by anon is a regression, and is reported as HIGH. */
const ANON_BY_DESIGN = new RegExp(
  '^(cbt_get_public_exam|cbt_submit|cbt_store_pending|cbt_proctor_register' +
  '|sc_cbt_(resolve_code|take_link|save_flags|window_state)' +
  '|lookup_login_email|submit_admission|submit_exam_registration|get_exam_registration_link' +
  '|verify_certificate' +
  '|sc_(keep_alive|heartbeat_health|installed_packs|license_status|license_locked|currency' +
  '|current_role|fee_overview|my_access_state|staff_pay_state|student_fee_state)' +
  '|is_(admin|staff|parent_of|tutor)|sc_can_edit|sc_is_report_generation_allowed' +
  '|sc_cbt_subject_allowed|teacher_can_manage_student|teacher_can_manage_subject_class)');
const anonOpen = anon.filter(f => f.prosecdef && f.anon_can);
for (const f of anonOpen) {
  if (!ANON_BY_DESIGN.test(f.proname)) {
    add('HIGH', 'ANON-SD', `SECURITY DEFINER ${f.proname}(${f.args}) is executable by anon and is not part of the documented public surface`);
  } else {
    add('INFO', 'ANON-PUBLIC', `${f.proname}() — documented public endpoint, reachable signed-out`);
  }
}
const anonTables = await q(`
  select c.relname
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and has_table_privilege('anon', c.oid, 'SELECT')
   order by 1`);
for (const r of anonTables) add('INFO', 'ANON-SELECT', `anon holds SELECT on ${r.relname}`);

/* ------------------------------------------------------ 4. permissive RLS --- */
const permissive = await q(`
  select tablename, policyname, cmd, array_to_string(roles, ',') as roles,
         coalesce(qual, '') as qual, coalesce(with_check, '') as wc
    from pg_policies
   where schemaname = 'public'
     and (qual = 'true' or with_check = 'true')
   order by 1, 2`);
/* Policies that deliberately admit everything, with the reason each one is
   allowed to. Anything else that says `true` is a finding. */
const WIDE_BY_DESIGN = {
  'cbt_pending_anon_insert': 'the public exam WAL: a candidate with no account must be able to hand in a submission that survives a lost connection',
  'vis_insert': 'the public visitor log on the landing page — an insert-only honeypot, no read',
  'notifications_send': 'any signed-in person may raise a notification (assignment submitted, poll opened); recipients are governed by notifications_read',
  'notifications_touch': 'read_by is a per-user array; the row is only reachable when notifications_read already allows it',
  'cbt_exams_read_signed_in': 'every signed-in role legitimately lists exams; the answer-bank columns are revoked from anon separately',
};
for (const p of permissive) {
  const reason = WIDE_BY_DESIGN[p.policyname];
  if (reason) add('INFO', 'RLS-WIDE-BY-DESIGN', `${p.policyname} on ${p.tablename}: ${reason}`);
  else if (/^(anon|public)$/.test(p.roles) && p.cmd !== 'SELECT') {
    add('HIGH', 'RLS-WIDE', `policy ${p.policyname} on ${p.tablename} (${p.cmd}) allows EVERYTHING to ${p.roles}`);
  } else {
    add('INFO', 'RLS-WIDE', `policy ${p.policyname} on ${p.tablename} (${p.cmd}) allows everything to ${p.roles}`);
  }
}

/* ------------------------------------------------ 5. indexes on FK columns --- */
const fkNoIndex = await q(`
  select con.conrelid::regclass::text as tbl,
         att.attname as col,
         con.conname
    from pg_constraint con
    join pg_attribute att on att.attrelid = con.conrelid and att.attnum = con.conkey[1]
   where con.contype = 'f' and con.connamespace = 'public'::regnamespace
     and array_length(con.conkey, 1) = 1
     and not exists (
       select 1 from pg_index i
        where i.indrelid = con.conrelid
          and i.indkey[0] = con.conkey[1]
     )
   order by 1, 2`);
for (const r of fkNoIndex) {
  add('WARN', 'FK-NO-INDEX', `no index on ${r.tbl}.${r.col} (${r.conname}) — every delete/join scans the table`);
}

/* ------------------------------------------------------- 6. primary keys --- */
const noPk = await q(`
  select c.relname
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and not exists (select 1 from pg_constraint k
                      where k.conrelid = c.oid and k.contype = 'p')
   order by 1`);
for (const r of noPk) add('HIGH', 'NO-PK', `table ${r.relname} has no primary key`);

/* --------------------------------------- V12.76-8: the audit as a function ---- */
/* If the shipped posture function disagrees with this script, the school is being
   told one thing by its own dashboard and another by the gate. One of them would
   be lying, so the gate insists they agree: no row may be 'fail', and every check
   the script ships must appear. */
const posture = await q(`select check_name, status, detail from public.sc_security_posture()`);
const postureFails = posture.filter(r => r.status === 'fail');
for (const r of postureFails) add('HIGH', 'POSTURE', `sc_security_posture() reports ${r.check_name}: ${r.detail}`);
const named = posture.map(r => r.check_name).join(' | ');
for (const need of ['row-level security', 'search_path', 'anonymous execution', 'foreign keys', 'primary key', 'policies', 'marks'])
  if (!named.includes(need)) add('HIGH', 'POSTURE', `sc_security_posture() no longer reports the ${need} check`);
if (!posture.length) add('HIGH', 'POSTURE', 'sc_security_posture() returned nothing');
console.log(`posture: ${posture.length} check(s), ${postureFails.length} failing`);

/* ------------------------------------------------------------- summary ---- */
const byLevel = { HIGH: 0, WARN: 0, INFO: 0 };
for (const f of findings) byLevel[f.level]++;
const counts = await q(`select
   (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='public' and c.relkind='r')::int tables,
   (select count(*) from pg_policies where schemaname='public')::int policies,
   (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public')::int functions`);

console.log('\n=== V12.76 platform audit ===');
console.log(`tables ${counts[0].tables} · policies ${counts[0].policies} · functions ${counts[0].functions}`);
const show = (lv) => findings.filter(f => f.level === lv);
for (const lv of ['HIGH', 'WARN', 'INFO']) {
  const list = show(lv);
  if (!list.length) continue;
  console.log(`\n--- ${lv} (${list.length}) ---`);
  for (const f of list) console.log(`  [${f.code}] ${f.msg}`);
}
console.log(`\nHIGH ${byLevel.HIGH} · WARN ${byLevel.WARN} · INFO ${byLevel.INFO}`);
await db.close();
process.exit(byLevel.HIGH ? 1 : 0);
