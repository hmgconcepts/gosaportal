-- ============================================================================
-- SCHOOL CONNECT DEMO — GUEST ACCOUNTS  v6  (run AFTER complete-schema.sql)
-- ----------------------------------------------------------------------------
-- ADOPT-ONLY healer for the five one-tap "Explore as Guest" accounts:
--   admin@scdemo.school   Demo#Admin1   → role: admin
--   teacher@scdemo.school Demo#Teach1   → role: teacher (linked staff record)
--   parent@scdemo.school  Demo#Parent1  → role: parent  (linked to 2 demo kids)
--   student@scdemo.school Demo#Study1   → role: student (linked student record)
--   bursar@scdemo.school  Demo#Bursar1  → role: bursar
--
-- ── WHAT WE PROVED LIVE (2026-07-23, newest hosted GoTrue v2.193+) ──────────
-- Probed the real demo project end-to-end. The rules that matter:
--   1. Dashboard → Authentication → Users → "Add user" does NOT validate the
--      email domain — @scdemo.school accounts are created and CONFIRMED fine.
--   2. Password LOGIN does NOT validate the email domain either — those
--      Dashboard-created @scdemo.school accounts sign in with JWTs (200 OK).
--      Only the PUBLIC SIGNUP API validates domains — and demo guests never
--      sign up, they log in. @scdemo.school is therefore ideal: no real
--      inboxes are ever involved (vs @gmail.com, which may belong to real
--      people).
--   3. SQL-CREATED auth rows CANNOT LOG IN on the newest projects (400
--      "Invalid login credentials") — no matter how careful the INSERT. So
--      v6 deliberately creates NO auth users. Create the five accounts in
--      the Dashboard (Auto Confirm ON, ~60 seconds), then run this file.
--   4. SQL-WRITTEN PASSWORDS break otherwise-healthy Dashboard accounts on
--      these projects (verified: an adopted account stopped logging in after
--      a crypt() reset). So v6 NEVER touches passwords. To set/repair a
--      password: Dashboard → Users → the user → Edit user → set password.
--   5. Dashboard "Add user" failing with "Database error checking email" /
--      "finding user" means: THAT EMAIL ALREADY EXISTS as a row GoTrue
--      cannot parse (i.e. an old SQL script created it). It is NOT a domain
--      rejection. Fix: delete the unusable row (Dashboard → Users → delete,
--      or the optional block at the bottom), re-add natively, run v6.
--   6. The signup trigger (handle_new_user) makes every new profile a
--      PENDING STUDENT → the "Account pending approval" screen. THAT is
--      what this file cures: it upserts the five profiles to the correct
--      role + status 'approved', and ensures emails sit confirmed.
--
-- FAILS LOUDLY: heals run in block 1 (they COMMIT even when something is
-- missing); block 2 then raises an ERROR naming exactly which Dashboard
-- "Add user" rows to create — so present accounts are fixed immediately and
-- nothing is rolled back. Idempotent — re-running is always safe.
-- demo-seed.sql links all demo data to these accounts BY EMAIL.
-- ============================================================================

do $$
declare
  emails_c  constant text[] := array['admin@scdemo.school','teacher@scdemo.school','parent@scdemo.school','student@scdemo.school','bursar@scdemo.school'];
  names_c   constant text[] := array['Demo Administrator','Funke Alabi','Mr. Adewale Okafor','Adanna Okafor','Demo Bursar'];
  roles_c   constant text[] := array['admin','teacher','parent','student','bursar'];
  v_id uuid; i int; errs text := ''; healed int := 0;
begin
  for i in 1 .. 5 loop
    select id into v_id from auth.users where lower(email) = lower(emails_c[i]) limit 1;

    if v_id is null then
      -- Handled after the loop with exact instructions. NO SQL creation —
      -- SQL-created auth rows cannot log in on the newest hosted projects.
      errs := errs || ' ' || emails_c[i];
      continue;
    end if;

    -- Safe heal #1: make sure the email counts as confirmed (no-op when the
    -- Dashboard "Auto Confirm" already set it). Touches nothing else in auth.
    update auth.users
       set email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now()
     where id = v_id;

    -- Safe heal #2: portal profile → correct role + APPROVED (this is the
    -- fix for the "Account pending approval" screen).
    insert into public.profiles (id, email, full_name, role, status, phone, campus)
    values (v_id, emails_c[i], names_c[i], roles_c[i], 'approved', '+234 810 000 000'||i, 'Main Campus')
    on conflict (id) do update
       set role = excluded.role, status = 'approved',
           full_name = excluded.full_name, email = excluded.email;

    healed := healed + 1;
    raise notice 'demo: healed % → role % approved (id %)', emails_c[i], roles_c[i], v_id;
  end loop;

  if errs <> '' then
    raise warning 'demo: missing accounts →% (see the ERROR block below for exact Dashboard steps)', errs;
  else
    raise notice 'demo: all 5 guest accounts present — profiles approved ✔ (healed: %)', healed;
  end if;
end $$;

-- BLOCK 2 (separate statement → heals above are already committed): verify
-- and fail LOUDLY with exact instructions if anything is still missing.
do $$
declare
  emails_c constant text[] := array['admin@scdemo.school','teacher@scdemo.school','parent@scdemo.school','student@scdemo.school','bursar@scdemo.school'];
  roles_c  constant text[] := array['admin','teacher','parent','student','bursar'];
  i int; errs text := '';
begin
  for i in 1 .. 5 loop
    if not exists (select 1 from auth.users u where lower(u.email) = lower(emails_c[i])) then
      errs := errs || ' user:' || emails_c[i];
    elsif not exists (select 1 from auth.users u where lower(u.email) = lower(emails_c[i]) and u.email_confirmed_at is not null) then
      errs := errs || ' confirm:' || emails_c[i];
    elsif not exists (select 1 from public.profiles p join auth.users u on u.id = p.id
                       where lower(u.email) = lower(emails_c[i]) and p.role = roles_c[i] and p.status = 'approved') then
      errs := errs || ' profile:' || emails_c[i];
    end if;
  end loop;
  if errs <> '' then
    raise exception 'DEMO-USERS FAILED for:% — if it says "user:": create those accounts in Supabase Dashboard → Authentication → Users → "Add user" (passwords from DEMO-SETUP.md — Demo#Admin1 / Demo#Teach1 / Demo#Parent1 / Demo#Study1 / Demo#Bursar1 — "Auto Confirm User" ON), then re-run this file. "confirm:"/"profile:" items are already half-healed — just re-run. NOTE: v6 intentionally creates no users in SQL — on the newest hosted Supabase, SQL-created auth rows cannot log in; Dashboard-created ones always can.', errs;
  end if;
end $$;

-- Visible summary in the SQL Editor result grid — expect the 5 scdemo.school
-- emails, all confirmed, right role, status approved:
select u.email, (u.email_confirmed_at is not null) as email_confirmed, p.role, p.status
  from auth.users u
  left join public.profiles p on p.id = u.id
 where lower(u.email) in ('admin@scdemo.school','teacher@scdemo.school','parent@scdemo.school','student@scdemo.school','bursar@scdemo.school')
 order by u.email;

-- ────────────────────────────────────────────────────────────────────────────
-- OPTIONAL CLEANUP (recommended while you are here): if earlier script
-- versions (v1–v5) left SQL-CREATED guest rows behind — e.g. the @gmail.com
-- set: admin/teacher/parent/student/bursar @gmail.com — they can never log in
-- and only confuse the Dashboard ("Database error checking email"). The SAFE
-- removal path is Dashboard → Authentication → Users → ⋯ → Delete user (GoTrue
-- cleans up identities/sessions itself). Prefer that. If you must do it in
-- SQL, uncomment BOTH lines (profiles first, auth.users cascades identities):
--   delete from public.profiles where email in ('admin@gmail.com','teacher@gmail.com','parent@gmail.com','student@gmail.com','bursar@gmail.com');
--   delete from auth.users where email in ('admin@gmail.com','teacher@gmail.com','parent@gmail.com','student@gmail.com','bursar@gmail.com');
-- ────────────────────────────────────────────────────────────────────────────
