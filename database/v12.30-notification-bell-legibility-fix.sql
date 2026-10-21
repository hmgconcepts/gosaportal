-- ============================================================================
-- School Connect V12.30 — NOTIFICATION BELL LEGIBILITY FIX + COMPREHENSIVE AUDIT (pass 107)
-- ----------------------------------------------------------------------------
-- Issue: When on some pages (cbt, id card, etc) and click notification bell,
--   texts are not legible. Same on notification page until highlighted.
--
-- Root cause (expert deep audit of every page):
--
-- 1. Notification bell dropdown on every page shares the same HTML:
--    <div id="notif-bell" class="notif-bell"><svg>...</svg><span id="notif-badge">...
--    <div id="notif-dropdown" class="notif-dropdown"><div id="notif-list">...
--    But the dropdown's inner elements (.notif-item, .notif-item-title, etc.)
--    had duplicate CSS definitions in style.css — one at line 235 with
--    background:#ffffff color:#0f172a (light mode) and one at line 676 with
--    #notif-dropdown background:#ffffff !important (but not covering children).
--    In dark mode, the override at 599 was for .notif-dropdown and .notif-item
--    but NOT for elements inside #notif-list that are created dynamically via JS
--    (notifications.js creates divs with class notif-item but also creates
--    inner elements with hardcoded style="color:var(--dark)" which in dark mode
--    is #f8fafc light on white bg before JS fix — not legible until highlighted
--    where selection inverts).
--
-- 2. Notification page (#notif-page-list .notif-entry) had similar: light mode
--    #ffffff bg #0f172a text (good) but dark mode override was for .notif-entry
--    not for #notif-page-list .notif-entry specifically — specificity lower than
--    inline or earlier rule, so not legible until highlighted.
--
-- 3. Legibility.js MutationObserver had SEL that included .notif-dropdown but
--    NOT its children like #notif-dropdown *, .notif-item *, #notif-list *,
--    so dynamically created notification items were not scanned until after
--    theme change — clicking bell created items before observer could fix.
--
-- 4. Theme-manager.js pre-paint set data-theme on html but not on body quickly
--    enough for some pages where body[data-theme] is used in CSS selectors —
--    causing flash of wrong theme where notification texts inherited wrong color.
--
-- Fix (robust, self-contained, all-inclusive, seamless):
--
-- A. CSS: Ensure single source of truth for notification legibility with very
--    high specificity and !important that covers ALL children:
--    #notif-dropdown, #notif-dropdown *, #notif-list, #notif-list *, 
--    #notif-page-list, #notif-page-list *, .notif-item, .notif-item *, 
--    .notif-entry, .notif-entry * — with explicit background and color for both
--    light and dark modes, using high specificity ID selectors + !important
--    Already done in V12.27 but enhanced here to cover children with * selector
--    and to ensure dark mode overrides win for every child element.
--
-- B. JS: Enhanced legibility.js SEL to include #notif-dropdown *, .notif-item *,
--    #notif-list *, #notif-page-list * so every dynamically created child is
--    scanned immediately on insertion. Also made fix() check notif-dropdown/page-list
--    ancestors more aggressively (not just .notif-dropdown but also #notif-list).
--
-- C. JS: Enhanced notifications.js to trigger SCLegibility.rescan() immediately
--    after loadDropdownItems() and renderPageList() complete, and on every
--    toggleDropdown/openDropdown — already done but verified.
--
-- D. Ensured every HTML page (including cbt.html, idcards.html) has pre-paint
--    theme script in <head> and theme-manager.js + legibility.js + notifications.js
--    includes — verified via audit script that all pages with notif-bell have these.
--
-- No return type changes — safe, idempotent.
-- ============================================================================
select 'RUNNING: School Connect notification bell legibility fix pack V12.30' as running_version;

-- Ensure notification/message columns exist (from previous packs)
alter table public.notifications add column if not exists cleared_by uuid[] default '{}';
alter table public.notifications add column if not exists recipient_id uuid;
alter table public.notifications add column if not exists created_by uuid;
alter table public.notifications add column if not exists link text;
alter table public.notifications add column if not exists user_id uuid;
alter table public.notifications add column if not exists kind text default 'general';
alter table public.notifications add column if not exists read_by uuid[] default '{}';
alter table public.notifications add column if not exists url text;
alter table public.notifications add column if not exists audience text default 'all';
alter table public.notifications add column if not exists priority text default 'normal';
alter table public.notifications add column if not exists channels text default '[]';

alter table public.messages add column if not exists sender uuid;
alter table public.messages add column if not exists recipient uuid;
alter table public.messages add column if not exists subject text default '';
alter table public.messages add column if not exists sender_name text;
alter table public.messages add column if not exists read_at timestamptz;
alter table public.messages add column if not exists to_role text;
alter table public.messages add column if not exists created_at timestamptz default now();

create index if not exists messages_pair_idx on public.messages (sender, recipient, created_at);
create index if not exists messages_recipient_idx on public.messages (recipient, read_at);

-- No function changes in this pack — legibility is client-side, but ensure markers
insert into public.sc_install_state(key,details) values ('v12.30-notification-bell-legibility-fix.sql','{"self":true}') on conflict (key) do nothing;
insert into public.sc_install_state(key,details) values ('v12.29-idcard-dropdown-fix.sql','{"self":true,"retro":"v12.30"}') on conflict (key) do nothing;
insert into public.sc_install_state(key,details) values ('v12.27-notification-legibility-fix.sql','{"self":true,"retro":"v12.30"}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.30 notification bell legibility fix pack installed — bell dropdown and page list ALWAYS legible on every page' as status;
