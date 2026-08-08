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

Because school traffic can stop during long holidays, add the independent external layers below. **Total setup time: under 15 minutes, once, at handover. After that everything is automatic.**

---

## Layer 2 — GitHub Actions heartbeat (recommended, ~5 minutes)

The file `.github/workflows/keep-supabase-alive.yml` is already in this package. Once activated, GitHub's servers automatically call your database **every Monday and Thursday** (maximum gap = 4 days, safely inside the 7-day window). You never touch it again.

To activate it, GitHub needs to know your Supabase URL and anon key. You store them as **repository secrets**. A "secret" in GitHub is simply a **named value**: the **Name** field is a label the workflow uses to find the value, and the **Secret** field is the value itself. You will create **two separate secrets** — one named `SUPABASE_URL` and one named `SUPABASE_ANON_KEY`. The names must be typed **exactly** as shown (all capitals, underscores, no spaces), because the workflow file looks them up by those exact names.

### Step A — Copy your two values from Supabase first

1. Open [supabase.com/dashboard](https://supabase.com/dashboard) and open your project.
2. Click the ⚙️ **Project Settings** (bottom of the left sidebar) → **API** (on some dashboards this is now called **Data API** / **API Keys**).
3. You will see:
   - **Project URL** — looks like `https://abcdefghijklmnop.supabase.co`. Copy it into a notepad.
   - **anon / public** key — a very long text starting with `eyJ...`. Click the copy icon next to it and paste it into your notepad too.
4. ⚠️ On the same page there is also a **service_role** key. **Never use that one anywhere** — it bypasses all security.

### Step B — Create the first secret (`SUPABASE_URL`)

1. Open your site's repository on **github.com**.
2. Click the **Settings** tab (top of the repo — if you don't see it, you are not an admin of the repo).
3. In the left sidebar scroll to **Security** → click **Secrets and variables** → click **Actions**.
4. Make sure you are on the **Secrets** tab (not "Variables"), then click the green **New repository secret** button.
5. You now see the two fields you asked about. Fill them like this:

   | Field on the GitHub form | What you type |
   |---|---|
   | **Name** | `SUPABASE_URL` (exactly this, in capitals) |
   | **Secret** | paste your Project URL, e.g. `https://abcdefghijklmnop.supabase.co` |

6. Click **Add secret**.

### Step C — Create the second secret (`SUPABASE_ANON_KEY`)

1. Click **New repository secret** again (each secret is added one at a time — that is why you saw only one Name/Secret pair).
2. Fill the form:

   | Field on the GitHub form | What you type |
   |---|---|
   | **Name** | `SUPABASE_ANON_KEY` (exactly this) |
   | **Secret** | paste the long **anon / public** key (`eyJ...`) |

3. Click **Add secret**. You should now see both `SUPABASE_URL` and `SUPABASE_ANON_KEY` listed. (GitHub hides the values after saving — that is normal; you can only *update* or *remove* them, never re-read them.)

### Step D — Test it once (do not skip)

1. Click the **Actions** tab at the top of the repo.
   - If you see a button like **"I understand my workflows, go ahead and enable them"**, click it.
2. In the left list click **Keep Supabase Alive**.
3. On the right, click the **Run workflow** dropdown → keep the default branch → click the green **Run workflow** button.
4. Wait ~20 seconds, refresh, and click the new run. Open the **heartbeat** job.
   - ✅ Success looks like: `✅ Keep-alive heartbeat written (HTTP 200). Supabase inactivity timer reset.`
   - ❌ If it says the RPC is missing, run `database/keep-alive.sql` once in the Supabase **SQL Editor** and re-run the workflow.
   - ❌ If it warns that secrets are not set, re-check Step B/C — the names must match exactly.
5. Optional double-check inside Supabase → SQL Editor:
   ```sql
   select last_ping, last_source, ping_count from public.sc_heartbeat;
   ```
   `last_source` should now say `github-actions`.

> ⚠️ **One caveat:** GitHub automatically disables *scheduled* workflows in repositories with **no commits for 60 days** (it emails you first, and you can re-enable with one click on the Actions tab). Layers 1, 3 and 4 cover this gap; pushing any small commit every couple of months also resets it.

---

## Layer 3 — Edge Function + UptimeRobot (also free, ~10 minutes)

Two parts: **(1)** deploy the tiny `ping` function that lives at `supabase/functions/ping/index.ts` in this package (it performs a **real database write** each time it is called), then **(2)** tell the free UptimeRobot service to call it automatically forever.

### Part 1 — Install the Supabase CLI and deploy the function (one time)

The Supabase CLI is a small command-line tool. Pick the instructions for your computer:

**Windows (easiest — via Scoop):**
1. Open **PowerShell** (Start menu → type "PowerShell" → Enter).
2. Install Scoop (a Windows app installer) if you don't have it:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   irm get.scoop.sh | iex
   ```
3. Install the Supabase CLI:
   ```powershell
   scoop bucket add supabase https://github.com/supabase/scoop-bucket.git
   scoop install supabase
   ```

**macOS (via Homebrew):**
```bash
brew install supabase/tap/supabase
```

**Any computer that has Node.js (Windows/macOS/Linux) — no global install needed:**
```bash
npx supabase --version
```
(then use `npx supabase ...` wherever the commands below say `supabase ...`)

4. Confirm it works: `supabase --version` should print a version number.

**Now log in and deploy (run these inside the folder of this site — the folder that contains the `supabase/` subfolder):**

```bash
# 1. Log in — this opens your browser; approve the access token
supabase login

# 2. Link this folder to YOUR project.
#    Find your project-ref: it is the short code in your dashboard URL:
#    https://supabase.com/dashboard/project/THIS-PART   (e.g. abcdefghijklmnop)
supabase link --project-ref YOUR_PROJECT_REF

# 3. Deploy the ping function.
#    --no-verify-jwt makes it callable by UptimeRobot without a login token.
supabase functions deploy ping --no-verify-jwt
```

5. **Test it immediately.** Open this URL in your browser (replace with your real project ref):
   ```
   https://YOUR_PROJECT_REF.supabase.co/functions/v1/ping
   ```
   ✅ You should see JSON like:
   ```json
   {"status":"alive","timestamp":"2026-07-28T10:00:00.000Z","database_heartbeat":"heartbeat written at 2026-07-28T10:00:00+00:00","message":"Supabase free-tier keep-alive ping"}
   ```
   The important part is **`database_heartbeat: "heartbeat written at …"`** — that proves a real database write happened. If it says `rpc error … run database/keep-alive.sql`, run that SQL file once in the SQL Editor and refresh.

### Part 2 — Create the UptimeRobot monitor (calls the function forever)

1. Go to [uptimerobot.com](https://uptimerobot.com) → **Register for FREE** → sign up (email or Google) and confirm your email. The free plan allows **50 monitors** with 5-minute-or-slower intervals — far more than we need.
2. In the dashboard click **+ Add New Monitor** (green button, top-left).
3. Fill the form:

   | Field | Value |
   |---|---|
   | **Monitor Type** | `HTTP(s)` (choose **Keyword** instead if available — see the tip below) |
   | **Friendly Name** | `Supabase keep-alive — <school name>` |
   | **URL (or IP)** | `https://YOUR_PROJECT_REF.supabase.co/functions/v1/ping` |
   | **Monitoring Interval** | every **12 hours** if selectable; otherwise the largest interval offered (even the default 5 minutes is fine — each call is tiny, but 12–24 h conserves your 500k/month Edge-Function quota) |
   | **Alert contacts** | tick your email so you are notified if the ping ever starts failing |

4. Click **Create Monitor**.

**💡 Better: use a Keyword monitor (also free).** Instead of type `HTTP(s)`, choose **Keyword**, set Keyword = `heartbeat written` and condition = **Keyword Not Exists → Down** (i.e. alert when the phrase is missing). Then UptimeRobot doesn't just check that the URL answers — it verifies the **database write actually succeeded**, and emails you the moment it stops.

### How do you KNOW it is working? (verification checklist)

1. **In UptimeRobot:** the monitor's status dot turns **green / "Up"** within a few minutes of creation, and the response-time chart starts filling. If it shows red/"Down", click the monitor and read the reason (wrong URL and forgetting `--no-verify-jwt` at deploy are the two usual causes).
2. **In Supabase (the definitive proof):** SQL Editor →
   ```sql
   select last_ping, last_source, ping_count from public.sc_heartbeat;
   ```
   After the monitor has run, `last_source` shows **`edge-ping`** and `ping_count` keeps increasing day after day. Check it again tomorrow: if the number grew, the whole chain (UptimeRobot → edge function → database) is proven working.
3. **Email test (optional):** temporarily edit the monitor's URL to something wrong, wait for the "Down" email, then fix it back. Now you know alerting works too.

### Bonus — a second monitor for your Vercel site (2 minutes)

This one watches your actual school website, so you learn immediately if the *site itself* ever goes down, and every check also keeps the site's edge cache warm:

1. In UptimeRobot click **+ Add New Monitor** again.
2. Fill it in:

   | Field | Value |
   |---|---|
   | **Monitor Type** | `HTTP(s)` |
   | **Friendly Name** | `School website — <school name>` |
   | **URL (or IP)** | your live site, e.g. `https://yourschool.vercel.app/` |
   | **Monitoring Interval** | 5 minutes (fine here — static pages, no quota concerns) |
   | **Alert contacts** | your email |

3. Click **Create Monitor**. Done — you now have two green monitors: one guarding the **database** (keep-alive) and one guarding the **website** (uptime alerts).
4. Optional: UptimeRobot's free plan also includes one public **status page** (Status Pages → Create) — a professional touch you can share with the school.

> Note: this second monitor does **not** replace the keep-alive one. Fetching a static Vercel page does not touch the Supabase database; only the `/functions/v1/ping` monitor (and Layers 1/2/4) resets the pause timer.

---

## Layer 4 — pg_cron (fully internal, installed automatically)

`complete-schema.sql` (or the standalone `database/keep-alive.sql`) schedules a Postgres cron job that runs `sc_keep_alive('pg_cron')` **every 2 days inside the database itself** — no external service at all. Internal scheduled queries count as database activity. If the pg_cron extension is not available on your project, installation skips it silently and the other layers still protect you.

---

## Layer 5 — Manual heartbeat button (zero setup, human-triggered)

On the **Platform Health Console** (`platform-health.html`) there is now a big **"💓 Send keep-alive heartbeat NOW"** button. Any admin can press it — it performs a real database write via `sc_keep_alive('manual-button')` and instantly shows the confirmed server timestamp plus the updated ping counter.

**When to use it:** once a week during long school holidays, before travel, or any time you want visible, human-confirmed proof that the inactivity timer was just reset. It complements (never replaces) the automated layers — pressing it also lets you *see* on the same page whether the automated layers have been firing (check `last_source` and `ping_count`).

## Layer 6 — cron-job.org (a second, independent free scheduler — optional)

If you want redundancy beyond UptimeRobot, [cron-job.org](https://cron-job.org) is a long-running free service that calls a URL on a schedule:

1. Create a free account → **Create cronjob**.
2. Title: `Supabase keep-alive`; URL: `https://YOUR_PROJECT_REF.supabase.co/functions/v1/ping`
3. Schedule: **every day at 06:00** (once daily is plenty).
4. Save. Under **History** you can see each execution's HTTP 200 response — open one and confirm the body contains `heartbeat written`.

Because it calls the same edge function as Layer 3, it needs no extra setup beyond the function already being deployed. Running BOTH UptimeRobot and cron-job.org means two unrelated companies are independently keeping your database awake.

---

## Existing sites installed before this feature

Run `database/keep-alive.sql` once in the Supabase **SQL Editor** (Dashboard → SQL Editor → paste → Run). It is idempotent and safe to re-run. Then redeploy the site files so the new `app.js` heartbeat is live.

## How to verify the whole system

Run in the SQL Editor:
```sql
select last_ping, last_source, ping_count from public.sc_heartbeat;
```
`last_ping` should never be older than ~4 days. `last_source` tells you which layer fired last (`site-visit`, `github-actions`, `edge-ping`, `pg_cron`, `manual-button`).

## Recommended client handover checklist

- [x] Layer 1 (site-visit) — automatic, nothing to do
- [x] Layer 4 (pg_cron) — automatic when the schema is installed
- [ ] Layer 2: add the two GitHub secrets (Step B/C above), run the workflow once ✅
- [ ] Layer 3: deploy `ping` + two UptimeRobot monitors (keep-alive + website)
- [ ] Verify: `select * from public.sc_heartbeat;`

With Layers 1 + 4 alone the project stays alive automatically; Layers 2, 3 and 6 add independent external redundancy, and Layer 5 gives the admin a one-press manual reset for holiday peace of mind — six safeguards in total, so the portal **never pauses** under any circumstance.

> **Best long-term option for a production school:** the Supabase **Pro plan** ($25/mo) removes pausing entirely and adds 7-day backups. The free layers above are a robust zero-cost alternative.

---
Maintained by HMG Concepts — School Connect Generator


---

## NEW LAYERS (V8.3) — three more independent free schedulers

Research check (2026): the pause rule is unchanged — **any REST/Edge request
resets the 7-day timer; one ping a week is technically enough, two or more
independent pingers is the professional standard** (a single scheduler that
fails silently = paused project). And a caution worth repeating: **pg_cron
alone can never be your safety net** — it runs INSIDE the database, so once a
project pauses, pg_cron is paused with it. External pingers are the real
protection; pg_cron is only a bonus while the project is awake.

### Layer 7 — Vercel Cron (the same account that hosts your site — ~3 minutes)
Your site already lives on Vercel; Vercel's free Hobby plan includes cron jobs
(daily granularity — exactly right for a weekly-scale problem).

1. In the site repository create the file **`api/keepalive.js`**:
   ```js
   export default async function handler(req, res) {
     const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_ANON_KEY;
     if (!url || !key) return res.status(500).json({ ok:false, error:'env missing' });
     const r = await fetch(url + '/rest/v1/rpc/sc_keep_alive', {
       method: 'POST', headers: { apikey:key, Authorization:'Bearer '+key, 'Content-Type':'application/json' },
       body: JSON.stringify({ src:'vercel-cron' })
     });
     return res.status(200).json({ ok:r.ok, status:r.status, at:new Date().toISOString() });
   }
   ```
2. Create **`vercel.json`** in the repo root (or merge into the existing one):
   ```json
   { "crons": [ { "path": "/api/keepalive", "schedule": "0 5 * * *" } ] }
   ```
3. Vercel Dashboard → your project → **Settings → Environment Variables** →
   add `SUPABASE_URL` and `SUPABASE_ANON_KEY` (same values as `assets/js/config.js`).
4. Push. Verify under **Project → Cron Jobs** after the next deploy: the job
   should show a daily successful run. *(Free plan quirk: Vercel may run the
   job at any time within the scheduled hour — irrelevant here.)*

### Layer 8 — Google Apps Script (runs on Google's servers, needs only the school's Gmail)
Completely independent of GitHub/Vercel/UptimeRobot — great third leg.

1. Open **script.google.com** (signed in as the school's Google account) →
   **New project**.
2. Replace the editor contents with:
   ```js
   function keepAlive() {
     const url = 'https://YOUR-PROJECT.supabase.co/rest/v1/rpc/sc_keep_alive';
     const key = 'YOUR_ANON_KEY';
     const res = UrlFetchApp.fetch(url, {
       method: 'post', contentType: 'application/json',
       headers: { apikey:key, Authorization:'Bearer '+key },
       payload: JSON.stringify({ src:'apps-script' }),
       muteHttpExceptions: true
     });
     Logger.log(res.getResponseCode() + ' ' + res.getContentText());
   }
   ```
   (Replace the URL and anon key with the values from `assets/js/config.js`.)
3. Click **Run** once → approve the permission dialog → check the log shows `200`.
4. Left sidebar → **Triggers (alarm-clock icon) → + Add Trigger** →
   function `keepAlive` · event source **Time-driven** · type **Day timer** ·
   pick any hour window → **Save**.
5. Done — Google now pings your database daily, forever, free. Apps Script
   emails the school automatically if the trigger ever starts failing.

### Layer 9 — a second GitHub repository (guards the 60-day Actions freeze)
GitHub disables *scheduled* workflows in repos with no pushes for 60 days.
Two cheap counters:
- **Fork the site repo** to a second GitHub account (a colleague's, or the
  school's own) and enable the same `keep-supabase-alive.yml` workflow there
  with the same two secrets. Two accounts → two independent 60-day clocks.
- OR make the workflow **self-committing** so the clock resets itself: add
  these lines at the end of the workflow's `steps:` (after the ping step):
  ```yaml
      - uses: actions/checkout@v4
      - name: Self-commit to reset the 60-day scheduler clock
        run: |
          git config user.name keepalive-bot && git config user.email bot@school
          date > .github/last-keepalive.txt
          git add .github/last-keepalive.txt && git commit -m "keepalive heartbeat" && git push
  ```

### The complete matrix (9 layers — tick what you have)
| # | Layer | Runs on | Frequency | Setup time |
|---|---|---|---|---|
| 1 | Site-visit heartbeat | every visitor's browser | every visit | 0 |
| 2 | GitHub Actions | GitHub | every 2 days | 5 min |
| 3 | Edge Function + UptimeRobot | UptimeRobot | every 5 min | 10 min |
| 4 | pg_cron `sc-keep-alive` | inside the DB | every 2 days | 0 (bonus only — pauses with the project) |
| 5 | 💓 Manual button | Platform Health page | on demand | 0 |
| 6 | cron-job.org | cron-job.org | daily | 5 min |
| 7 | **Vercel Cron** | Vercel | daily | 3 min |
| 8 | **Google Apps Script** | Google | daily | 5 min |
| 9 | **Second repo / self-commit** | GitHub | scheduled | 5 min |

**Recommended minimum:** Layers 1+2+3 (already the default advice) **plus one
of 7/8** so that three unrelated companies (GitHub, UptimeRobot, Vercel or
Google) are each independently resetting the 7-day timer. The odds of all of
them failing in the same week are effectively zero.
