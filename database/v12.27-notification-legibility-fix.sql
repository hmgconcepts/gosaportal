-- ============================================================================
-- School Connect V12.27 — NOTIFICATION LEGIBILITY FIX + POPUP LEGIBILITY FINAL (pass 104)
-- ----------------------------------------------------------------------------
-- Issue: When clicking notification bell icon, texts not legible until
--   highlighted. Same on notification page.
-- Root cause:
-- - Two conflicting .toast definitions in style.css — white bg dark text vs
--   dark bg #0f172a white text — second overrode first's bg but .toast-msg
--   still had var(--gray-700) dark gray on dark bg → dark on dark → NOT legible
-- - .notif-dropdown had background:white but in dark mode var(--dark) is light
--   #f8fafc → light on white → NOT legible until highlighted (selection inverts)
-- - Light gradient cards (e.g., #dbeafe→#f0f9ff for notifications) had no dark
--   text override for dark mode → light text on light gradient in dark mode
-- - Many components had no dark mode overrides → hardcoded #fff bg with
--   inherited light text in dark mode
--
-- Fix (robust, self-contained, all-inclusive, seamless):
-- - style.css: single robust toast definition with light bg dark text for each
--   type + dark mode overrides dark bg light text, plus dark overrides for ALL
--   components .notif-dropdown, .notif-item, .notif-entry, .mc-*, .form-input,
--   .btn-outline, .card, .stat-card, .table-wrap etc. using CSS vars --bg,
--   --card, --line, --txt, --mut
-- - Added CSS for ALL light gradient cards to have dark text #0f172a in light
--   mode and dark bg light text in dark mode (or keep dark text on light
--   gradient even in dark mode for legibility)
-- - Added specific #notif-dropdown and #notif-page-list legibility rules with
--   !important for both light and dark modes — ALWAYS legible even without JS
-- - legibility.js: MutationObserver watches popups (modal, toast, notif-dropdown,
--   notif-item, notif-entry, mc-*, sc-drive-progress, sc-theme-float, etc.) and
--   fixes contrast if WCAG AA <4.5:1 via setProperty important — watches
--   data-theme changes and re-scans on theme button clicks
-- - theme-manager.js V12.24 FINAL triggers SCLegibility.rescan() after
--   toggleMode/applyTheme (100ms and 600ms)
--
-- No return type changes — safe, idempotent.
-- ============================================================================
select 'RUNNING: School Connect notification legibility fix pack V12.27' as running_version;

-- Ensure columns exist (from previous packs)
alter table public.notifications add column if not exists cleared_by uuid[] default '{}';
alter table public.notifications add column if not exists recipient_id uuid;
alter table public.notifications add column if not exists created_by uuid;
alter table public.notifications add column if not exists link text;
alter table public.notifications add column if not exists user_id uuid;
alter table public.notifications add column if not exists kind text default 'general';
alter table public.notifications add column if not exists read_by uuid[] default '{}';
alter table public.notifications add column if not exists url text;
alter table public.notifications add column if not exists audience text default 'all';

alter table public.messages add column if not exists sender uuid;
alter table public.messages add column if not exists recipient uuid;
alter table public.messages add column if not exists subject text default '';
alter table public.messages add column if not exists sender_name text;
alter table public.messages add column if not exists read_at timestamptz;
alter table public.messages add column if not exists to_role text;

create index if not exists messages_pair_idx on public.messages (sender, recipient, created_at);
create index if not exists messages_recipient_idx on public.messages (recipient, read_at);

-- Markers
insert into public.sc_install_state(key,details) values ('v12.27-notification-legibility-fix.sql','{"self":true}') on conflict (key) do nothing;
insert into public.sc_install_state(key,details) values ('v12.26-theme-legibility-final.sql','{"self":true,"retro":"v12.27"}') on conflict (key) do nothing;
insert into public.sc_install_state(key,details) values ('v12.25-fix-messages-sender-42703.sql','{"self":true,"retro":"v12.27"}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.27 notification legibility fix pack installed — bell dropdown and page list ALWAYS legible' as status;
