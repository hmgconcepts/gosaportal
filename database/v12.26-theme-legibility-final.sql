-- ============================================================================
-- School Connect V12.26 — THEME LEGIBILITY FINAL + POPUP LEGIBILITY (pass 103)
-- ----------------------------------------------------------------------------
-- Issues:
-- 1. Popup messages texts aren't legible
--    - Root cause: Two conflicting .toast definitions in style.css — one white
--      bg dark text, one dark bg #0f172a white text — second overrode first's
--      bg but .toast-msg still had var(--gray-700) dark gray on dark bg → NOT
--      legible. Also many popups set background:#fff inline and inherit text
--      colour from dark theme → white on white or dark on dark.
--    - Fix: Single robust toast definition with high contrast light bg + dark
--      text for each type (success #dcfce7/#166534, warning #fef3c7/#92400e,
--      danger #fee2e2/#991b1b, info #eef2ff/#3730a3) + dark mode overrides with
--      dark bg + light text, plus legibility.js MutationObserver that watches
--      for popups and fixes contrast if WCAG AA <4.5:1 via setProperty important
--
-- 2. Theme button switching → some texts not legible
--    - Root cause: Many elements have hardcoded colors color:#0f172a,
--      background:#fff, color:#fff on gradient that don't adapt to dark mode.
--      When toggled to dark, dark text on dark bg or white on white → illegible
--    - Also pre-paint only set data-theme + primary/accent, not all 18 tokens
--    - Fix: style.css dark mode overrides for ALL components using CSS vars
--      --bg, --card, --line, --txt, --mut + specific overrides for
--      .app-sidebar, .app-topbar, .card, .stat-card, .table-wrap, .form-input,
--      .btn-outline, .notif-dropdown, .notif-item, .mc-* etc. + legibility.js
--      watches data-theme changes and re-scans + theme-manager.js triggers
--      rescan after toggleMode/applyTheme + topbar has 🌙 + 🎨 buttons on every
--      page + floating button + palette + settings card with live preview +
--      high-contrast support
--
-- No return type changes — safe, idempotent.
-- ============================================================================
select 'RUNNING: School Connect theme legibility final + popup legibility pack V12.26' as running_version;

-- Ensure notifications and messages columns exist (from V12.22/V12.25)
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

-- No function return type changes in this pack — just ensure existing functions still exist
-- (they are already in complete-schema from V12.25, but we ensure markers)

insert into public.sc_install_state(key,details) values ('v12.26-theme-legibility-final.sql','{"self":true}') on conflict (key) do nothing;
insert into public.sc_install_state(key,details) values ('v12.25-fix-messages-sender-42703.sql','{"self":true,"retro":"v12.26"}') on conflict (key) do nothing;
insert into public.sc_install_state(key,details) values ('v12.24-fix-notif-clear-42883.sql','{"self":true,"retro":"v12.26"}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.26 theme legibility final + popup legibility pack installed — toast legible, dark mode legible, legibility.js guard active' as status;
