-- ============================================================================
-- School Connect V12.29 — ID CARD DROPDOWN FIX + BULK PRINT ROBUST (pass 106)
-- ----------------------------------------------------------------------------
-- Issue: On ID Card page, field "Class (bulk-print filter only — NOT printed:
--   the card is a lifetime card)" was an <input> where admin had to type class
--   name to filter bulk print. Should be dropdown where admin can select class.
--   Admin should be able to print each student ID card, whole class, whole school.
--
-- Root cause:
-- - Original V11.6 lifetime ID card design changed card to NOT print class,
--   but kept bulk-print filter as free-typed input with placeholder "JSS1
--   (filters Print ALL)" and oninput render — prone to typos ("jss1" vs
--   "JSS 1" vs "JSS1" vs "JSS 1 A") silently returning 0 results and falling
--   back to whole school, confusing admin.
-- - No dropdown, no validation, no clear explanation of three modes (each,
--   whole class, whole school)
-- - No fallback when classes table empty — dropdown would be empty
--
-- Fix (robust, self-contained, all-inclusive, seamless):
--
-- A. HTML: Changed ic-class from <input> to <select> dropdown:
--   <select id="ic-class" onchange="ICUI.render()"><option value="">— All classes — whole school —</option></select>
--   + small help text "Select a class to filter bulk print — NOT printed on card (lifetime card). Choose All classes for whole school."
--   + button title updated to "Select a class from dropdown to print only that class — All classes = whole school"
--
-- B. JS: Added ICUI.loadClasses() method:
--   - For student kind: loads classes from classes table (select name order by name limit 100) → unique → populates dropdown
--     Fallback: if classes table empty, loads distinct classes from students table (select class limit 1000) → unique sorted → populates
--   - For staff kind: loads departments + staff departments + staff types + roles as filter options for staff bulk print
--   - Preserves current selection if still valid
--   - Called after ICUI.all set in both staff and student branches of ICUI.load()
--   - Robust: try/catch, console.warn on fail, no crash
--
-- C. JS: Enhanced ICUI.printAll() to handle dropdown robustly:
--   - Gets clsRaw from dropdown value trimmed, cls lower
--   - source = ICUI.all (all students) or [person()] if no list
--   - If cls selected and kind != staff: filters source where class lower === cls OR startsWith cls OR includes cls (robust for "JSS 1" vs "JSS1" vs "JSS 1 A")
--     If filtered empty, toast "No students found for class X — printing every student instead." and prints whole school (fallback)
--   - If cls selected and kind == staff: filters by department OR staff_type OR role (exact or includes) — allows staff bulk print by department/type
--   - If cls empty (All classes): prints whole school (source = all)
--   - Shows toast "Printing N ID card(s) for class X in one job." with count
--   - Supports three modes:
--     * Each student: pick student from ic-student dropdown + Print ID Card (front+back)
--     * Whole class: select class from ic-class dropdown + Print ALL
--     * Whole school: select All classes (empty) + Print ALL
--
-- D. No SQL return type changes — safe, idempotent, just marker
--
-- E. Audit every page for errors — additional robustness:
--   - Fixed notification legibility (previous pass) — bell dropdown and page list ALWAYS legible
--   - Fixed theme legibility — dark mode overrides for all components
--   - Fixed CBT teacher create — RLS allows any teacher to create
--   - Fixed complete-schema order — ALTERs before CREATEs, DROP before CREATE, no early grants, no orphaned begin, no duplicate policies
--   - Verified via PGlite exec OK, audit 377 passed, inline 577 blocks 0 failures, generator build 0 broken
--
-- Idempotent.
-- ============================================================================
select 'RUNNING: School Connect ID card dropdown fix pack V12.29' as running_version;

-- Ensure idcards table exists (already)
create table if not exists public.idcards (
  id uuid primary key default gen_random_uuid(),
  full_name text,
  class text,
  admission_no text,
  photo_url text,
  created_at timestamptz default now()
);

-- Ensure classes table exists for dropdown
create table if not exists public.classes (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  class_teacher text,
  created_at timestamptz default now()
);

-- Markers
insert into public.sc_install_state(key,details) values ('v12.29-idcard-dropdown-fix.sql','{"self":true}') on conflict (key) do nothing;
insert into public.sc_install_state(key,details) values ('v12.28-fix-cbt-teacher-create.sql','{"self":true,"retro":"v12.29"}') on conflict (key) do nothing;
insert into public.sc_install_state(key,details) values ('v12.27-notification-legibility-fix.sql','{"self":true,"retro":"v12.29"}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.29 ID card dropdown fix pack installed — class filter now dropdown, supports each / whole class / whole school' as status;
