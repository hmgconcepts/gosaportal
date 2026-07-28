# Supabase Free-Tier Protection — Complete, Automated & Unambiguous

> **The problem:** Supabase **pauses** every FREE-tier project that records **no database activity for ~7 consecutive days**. A paused school portal shows connection errors until someone logs into the Supabase dashboard and manually restores it. On the free tier there are **no automatic backups**, and a project left paused too long can eventually be **deleted**.
>
> **Key fact (verified):** the inactivity detector counts **real database activity** (queries/writes hitting Postgres). A ping that never touches the database does **not** reliably reset the timer. That is why every layer below performs an actual **database write** through the `sc_keep_alive()` RPC.

---

## What is already built in (zero setup for the client)

`database/complete-schema.sql` installs a tiny heartbeat system:

| Object | Purpose |
|---|---|
| `public.sc_heartbeat` table | One row storing the last ping time, source and count |
| `public.sc_keep_alive(src)` RPC | Performs a real `UPDATE` (genuine DB activity) — callable with the anon key, exposes no school data |
| `pg_cron` job `sc-keep-alive` | **Layer 4** — internal DB scheduler fires every 2 days automatically (skipped gracefully where pg_cron is unavailable) |

**Layer 1 — Site-visit heartbeat (automatic, nothing to configure)**
`assets/js/app.js` on every page calls `sc_keep_alive('site-visit')` at most **once per device per 24 hours**. As long as *anyone* (a teacher, a parent, even you) opens the site once a week, the project never pauses. This is fully automated the moment the site is deployed.

Because school traffic can stop during long holidays, add the independent external layers below. **Total setup time: under 10 minutes, once, at handover. After that everything is automatic.**

---

## Layer 2 — GitHub Actions heartbeat (5 minutes, recommended)

File already included: `.github/workflows/keep-supabase-alive.yml`
It calls the `sc_keep_alive` RPC **every Monday and Thursday** (max gap 4 days — safely inside the 7-day window) and can be run manually from the Actions tab.

**Setup (exact steps):**
1. Push this site to a GitHub repository (you already do this to deploy on Vercel).
2. Open the repo → **Settings → Secrets and variables → Actions → New repository secret**.
3. Add **two** secrets:
   - `SUPABASE_URL` → e.g. `https://abcdefgh.supabase.co` (Dashboard → Project Settings → API)
   - `SUPABASE_ANON_KEY` → the **anon / public** key from the same page (never the service-role key)
4. Open the **Actions** tab → select **Keep Supabase Alive** → **Run workflow** once to confirm you see `✅ Keep-alive heartbeat written`.

> ⚠️ GitHub disables schedules in repos with **no commits for 60 days**. Layers 1, 3 and 4 cover that gap; or simply push any commit every couple of months.

## Layer 3 — UptimeRobot + Edge Function (5 minutes, also free)

The edge function `supabase/functions/ping/index.ts` now performs a **real database write** (it calls `sc_keep_alive('edge-ping')`), not just a JSON reply.

1. Install the Supabase CLI and deploy once:
   ```bash
   supabase functions deploy ping --no-verify-jwt
   ```
2. Create a free account at [uptimerobot.com](https://uptimerobot.com) → **Add New Monitor**:
   - Type: **HTTP(s)**
   - URL: `https://YOUR-PROJECT.supabase.co/functions/v1/ping`
   - Interval: **every 12 hours** is plenty (5-minute intervals waste your monthly Edge-Function quota)
3. Bonus: add a second monitor pointing at your Vercel site URL — it keeps the site warm **and** triggers Layer 1 in some setups.

## Layer 4 — pg_cron (fully internal, installed automatically)

`complete-schema.sql` (or the standalone `database/keep-alive.sql`) schedules a Postgres cron job that runs `sc_keep_alive('pg_cron')` **every 2 days inside the database itself** — no external service at all. Internal scheduled queries count as database activity. If the pg_cron extension is not available on your project, installation skips it silently and the other layers still protect you.

---

## Existing sites installed before this feature

Run `database/keep-alive.sql` once in the Supabase **SQL Editor** (Dashboard → SQL Editor → paste → Run). It is idempotent and safe to re-run. Then redeploy the site files so the new `app.js` heartbeat is live.

## How to verify it is working

Run in the SQL Editor:
```sql
select last_ping, last_source, ping_count from public.sc_heartbeat;
```
`last_ping` should never be older than ~4 days. `last_source` tells you which layer fired last (`site-visit`, `github-actions`, `edge-ping`, `pg_cron`).

## Recommended client handover checklist

- [x] Layer 1 (site-visit) — automatic, nothing to do
- [x] Layer 4 (pg_cron) — automatic when the schema is installed
- [ ] Layer 2: add the two GitHub secrets, run the workflow once ✅
- [ ] Layer 3: deploy `ping` + one UptimeRobot monitor (optional but free)
- [ ] Verify: `select * from public.sc_heartbeat;`

With Layers 1 + 4 alone the project stays alive automatically; adding Layer 2 (and optionally 3) gives independent, external redundancy so the portal **never pauses**, even across long school holidays.

> **Best long-term option for a production school:** the Supabase **Pro plan** ($25/mo) removes pausing entirely and adds 7-day backups. The free layers above are a robust zero-cost alternative.

---
Maintained by HMG Concepts — School Connect Generator
