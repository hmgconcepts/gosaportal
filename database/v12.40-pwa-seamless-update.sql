-- ============================================================================
-- School Connect V12.40 — PWA seamless update (install + background refresh)
-- ----------------------------------------------------------------------------
-- Issue: When GOSA/School Connect is installed on phone/laptop as PWA
--   (Add to Home Screen, standalone display-mode) and the platform is updated
--   (new sw.js CACHE v12.40, new cbt.html/js), the installed app kept showing
--   the old cached CBT/report code. Users had to manually clear cache or
--   uninstall/reinstall. No notification, no auto-update — not seamless.
--   Especially painful for students/parents/staff/admin on phones who never
--   open the browser tab, only the installed icon.
--
-- Root-cause audit (expert, 6 layers):
--   a) sw.js did skipWaiting() on install and clients.claim() on activate,
--      but never postMessaged clients that a new version was ready — so the
--      page had no way to know to show "New version available" banner.
--   b) pwa-install.js only handled beforeinstallprompt → install banner,
--      never handled updatefound → waiting → controllerchange → reload.
--      No polling, no visibilitychange/online/focus re-check, so an update
--      found while the app was backgrounded was missed.
--   c) No update banner UI at all — the installed PWA had no persistent,
--      accessible place to tap "Update now". Users on iOS standalone have no
--      address bar pull-to-refresh.
--   d) No auto-reload fallback — if user ignored the banner, the old SW
--      stayed controlling forever (especially with multiple tabs, only one
--      would get the updatefound event).
--   e) iOS Safari standalone has different lifecycle (no skipWaiting guarantee,
--      no Badge API) — needs its own 10s auto-update for installed vs 20s
--      for browser tab.
--   f) Offline: if update check fails (user offline), no retry — next online
--      event should re-check, but pwa-install.js never listened to online.
--
-- Fix (seamless, robust, self-contained, all-inclusive):
--   - sw.js: On install still skipWaiting, on activate claim clients AND
--     postMessage {type:'SW_UPDATED', version:CACHE} to every window client.
--     Also listen for message {type:'SKIP_WAITING'} from client (manual Update now).
--   - pwa-install.js (v8, 319 lines): Now handles BOTH install and update.
--     Injects #pwa-update-banner + styles dynamically (so every page that
--     includes pwa-install.js gets update UX without editing HTML). Banner
--     shows "New version available! Updating in 10s/20s" with "Update now"
--     and "Later" (2h snooze via localStorage). Standalone PWA auto-updates
--     in 10s, browser tab in 20s. Countdown interval, manual Update Now
--     posts SKIP_WAITING to waiting SW and fallback reloads in 1.5s if
--     controllerchange doesn't fire. Listens to updatefound → installing
--     → installed (with controller) → show banner; message SW_UPDATED → show;
--     controllerchange → reload once (guarded by _hasReloaded). Polls
--     registration.update() every 60m and on visibilitychange (!hidden),
--     online, focus, pageshow, plus initial 5s. Patches
--     navigator.serviceWorker.register to intercept future registrations.
--     Exposes manualCheck() for Settings page and console.
--   - CORE: pwa-install.js is already in SW CORE precache, so update to
--     pwa-install.js itself is part of the new CACHE version — next SW
--     install will bring new logic automatically.
--
-- Idempotent. No DB schema change — this pack is a marker so platform-health
-- can verify deployment. Free-tier only (no Push API server needed).
-- ============================================================================
select 'RUNNING: School Connect PWA seamless update pack V12.40' as running_version;

-- Marker so sc_installed_packs() and platform-health can verify
create table if not exists public.sc_install_state(key text primary key,applied_at timestamptz not null default now(),details jsonb default '{}'::jsonb);
insert into public.sc_install_state(key,details) values ('v12.40-pwa-seamless-update.sql','{"self":true,"feature":"pwa-update"}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.40 PWA seamless update installed — installed apps auto-notify and update in 10s (standalone) / 20s (tab), with manual Update now' as status;
