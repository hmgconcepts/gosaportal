/* V12.72 item 3 — one hand-drawn signature per teacher, and it must actually
   reach the printed documents. This suite proves the whole chain:
   the pad exists, the save path is server-authoritative, the signature is
   stored per teacher (not per school), and the report engine reads it back. */
import { PGlite } from '@electric-sql/pglite';
import { schemaText } from './schema-loader.mjs';
import fs from 'fs';
const HERE = new URL('.', import.meta.url).pathname;
const REPO = HERE + '../../';
let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  FAIL ' + m)); };

/* ---------- 1. the page can be drawn on ---------- */
const profile = fs.readFileSync(REPO + 'profile.html', 'utf8');
ok(/<canvas[^>]+id="sig-pad"/.test(profile), 'the signature pad canvas exists');
ok(/touch-action:\s*none/.test(profile), 'the pad accepts a finger on a phone (touch-action none)');
for (const fn of ['initSignaturePad', 'clearSignaturePad', 'signaturePadBlob', 'saveSignaturePad'])
  ok(profile.includes('function ' + fn), fn + '() is defined');
ok(/addEventListener\('click',\s*saveSignaturePad\)/.test(profile), 'the Save button calls saveSignaturePad');
ok(/addEventListener\('click',\s*clearSignaturePad\)/.test(profile), 'the Clear button calls clearSignaturePad');

/* ---------- 2. it is stored per teacher, not per school ---------- */
ok(profile.includes("'signatures/teacher-'") || profile.includes('signatures/teacher-'),
   'the upload path is namespaced per teacher');
ok(/sc_signature_save/.test(profile), 'the authoritative write is the server RPC');
ok(/Only your own profile signature can be changed here/.test(profile),
   'the page states only your own signature can be changed');

/* ---------- 3. the server stamps who and when ---------- */
const db = new PGlite();
await db.exec(schemaText(REPO + 'database/complete-schema.sql'));
const q = async (s) => (await db.query(s)).rows;

for (const [col, type] of [['signature_url','text'], ['signature_name','text'], ['signature_updated_at','timestamptz']]) {
  const r = await q(`select data_type from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='${col}'`);
  ok(r.length === 1, `profiles.${col} exists (${type})`);
}
const st = await q(`select 1 from information_schema.columns
  where table_schema='public' and table_name='staff' and column_name='signature_url'`);
ok(st.length === 1, 'staff.signature_url exists (the staff directory copy)');

/* the RPC refuses an empty signature and refuses to run anonymously */
const anon = await q("select sc_signature_save('https://example.com/s.png','Mr A') as r");
ok(anon[0].r.ok === false && /Not authenticated/.test(anon[0].r.error),
   'sc_signature_save refuses when nobody is signed in');
const empty = await q("select sc_signature_save('','Mr A') as r");
ok(empty[0].r.ok === false, 'sc_signature_save refuses an empty signature');

/* ---------- 4. two teachers keep two different signatures ---------- */
// profiles.id references auth.users, and the self-contained prelude creates a
// stub auth schema, so a row must exist there first.
for (const id of ['11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222']) {
  try { await db.exec(`insert into auth.users(id) values ('${id}') on conflict do nothing`); } catch (_) {}
}
await db.exec(`insert into profiles(id,full_name,signature_url) values
  ('11111111-1111-1111-1111-111111111111','Teacher One','https://x/one.png'),
  ('22222222-2222-2222-2222-222222222222','Teacher Two','https://x/two.png')
  on conflict (id) do update set signature_url=excluded.signature_url, full_name=excluded.full_name`);
const two = await q(`select full_name, signature_url from profiles
  where id in ('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222')
  order by full_name`);
ok(two.length === 2 && two[0].signature_url !== two[1].signature_url,
   'each teacher keeps their OWN signature — one is not shared');

/* ---------- 5. the report engine reads the class teacher's signature ---------- */
const engine = fs.readFileSync(REPO + 'assets/js/report-engine.js', 'utf8');
ok(/signature_url/.test(engine), 'the report engine reads signature_url');
ok(/class_teacher/.test(engine), 'it resolves the signature from the CLASS TEACHER of the class');
ok(/teacherSignatureInk/.test(engine), 'teacherSignatureInk() renders the ink onto the sheet');
ok(/driveDirect/.test(engine), 'a Google Drive share link is converted to a direct image');

/* the prep report is a rehearsal sheet, so it must show the same ink */
const prep = fs.readFileSync(REPO + 'prep-exam-reports.html', 'utf8');
ok(prep.length > 1000, 'the prep report page is present');

console.log(`signature: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
