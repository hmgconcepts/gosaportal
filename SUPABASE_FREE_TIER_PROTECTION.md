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

> ✅ **The 60-day caveat is now SOLVED automatically.** GitHub normally disables *scheduled* workflows in repositories with no commits for 60 days. As of V8.9 this workflow is **self-committing**: whenever your repository's last commit is older than 30 days, the workflow itself commits a tiny timestamp file (`.github/last-keepalive.txt`) and pushes it — so the 60-day clock resets itself forever and the freeze can never happen. Full details in **Layer 9** below (including the one checkbox to verify in repo settings).

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

**Step 1 of 4 — Open a terminal INSIDE your site folder.**

All the commands below must run *from inside the folder where you unzipped this site* — the folder that contains the `supabase/` subfolder (alongside `index.html`, `assets/`, `database/`, etc.). The CLI looks for `supabase/functions/ping/index.ts` relative to the folder you are standing in; run it anywhere else and it will say the function does not exist.

- **Windows:** open the site folder in File Explorer → click the address bar → type `powershell` → press **Enter**. A PowerShell window opens already inside that folder.
  *(Or: Shift + right-click an empty area in the folder → "Open PowerShell window here".)*
- **macOS:** open **Terminal** (Cmd+Space → type "Terminal") → type `cd ` (with a trailing space) → drag the site folder from Finder onto the Terminal window → press **Enter**.
- **Any system:** `cd` to the folder, e.g. `cd C:\Users\you\Downloads\my-school-site` or `cd ~/Downloads/my-school-site`.

✅ **Confirm you are in the right place** before continuing:
- Windows PowerShell: `dir supabase\functions\ping` — it should list `index.ts`.
- macOS/Linux: `ls supabase/functions/ping` — it should list `index.ts`.
If you get "cannot find path / no such file or directory", you are in the wrong folder — `cd` into the correct one first.

**Step 2 of 4 — `supabase login` (this logs the CLI into your SUPABASE account — NOT GitHub, NOT Vercel).**

"Logging in" here means giving the command-line tool on your computer permission to act on **your Supabase account** — the same account (email/password or GitHub sign-in) you use at [supabase.com/dashboard](https://supabase.com/dashboard). Nothing else is involved: no GitHub login, no Vercel login, no new account to create.

1. In the terminal, type:
   ```bash
   supabase login
   ```
   *(If you chose the Node.js/npx route earlier, type `npx supabase login` instead — same for every later command.)*
2. **What happens next:** your default web browser opens automatically at a Supabase page. If you are not already signed in to Supabase in that browser, sign in with your normal Supabase account first. The page then shows a token/authorize screen — click the green **confirm / authorize** button. The browser page will say you can close it, and back in the terminal you will see `Finished supabase login.` or `You are now logged in.`
3. **If the browser does not open** (some office PCs block it), do it manually:
   - Go to **[supabase.com/dashboard/account/tokens](https://supabase.com/dashboard/account/tokens)** in any browser (sign in if asked).
   - Click **Generate new token**, give it any name (e.g. `school-cli`), and copy the token that starts with `sbp_`.
   - In the terminal run `supabase login --token sbp_YOUR_TOKEN_HERE` (paste your real token).
4. You only ever do this once per computer — the CLI stores the token securely for all future commands.

**Step 3 of 4 — `supabase link` (points this folder at YOUR project).**

Your Supabase account can hold several projects; this tells the CLI which one the ping function belongs to.

1. Find your **project ref**: open your project at [supabase.com/dashboard](https://supabase.com/dashboard) and look at the browser address bar. The URL looks like
   `https://supabase.com/dashboard/project/abcdefghijklmnop` — the 20-character code after `/project/` is your project ref. (It is also the first part of your Project URL: `https://abcdefghijklmnop.supabase.co`.)
2. Run (with your real ref):
   ```bash
   supabase link --project-ref abcdefghijklmnop
   ```
3. It may ask **"Enter your database password (or leave blank to skip):"** — just press **Enter** to skip. The password is not needed for deploying functions.
4. Success looks like `Finished supabase link.`

**Step 4 of 4 — deploy the ping function.**

```bash
supabase functions deploy ping --no-verify-jwt
```
- `--no-verify-jwt` makes the function callable by UptimeRobot/cron-job.org without a login token (it exposes no data — it only writes a heartbeat timestamp).
- Success looks like: `Deployed Functions on project abcdefghijklmnop: ping`.
- You can confirm in the dashboard too: your project → **Edge Functions** (left sidebar) → `ping` should now be listed.

**Common errors and exactly what they mean:**

| Message | Cause | Fix |
|---|---|---|
| `supabase: command not found` / `'supabase' is not recognized` | CLI not installed, or terminal opened before install finished | Re-run the install step above, then open a NEW terminal window. Or use `npx supabase ...` |
| `Cannot find project ref. Have you run supabase link?` | You skipped Step 3, or you are in a different folder than the one you linked | Run Step 3 again from inside the site folder |
| `Entrypoint path does not exist` / function not found | You are not inside the folder that contains `supabase/functions/ping/index.ts` | `cd` into the site folder (Step 1) and re-run |
| `Access token not provided` / `not logged in` | Step 2 was skipped or failed | Run `supabase login` again (or the `--token sbp_...` fallback) |

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

UptimeRobot is a free monitoring service: you give it a URL and it visits that URL on a schedule, forever, from its own servers. Every visit to your `ping` URL performs a real database write — so once this monitor exists, UptimeRobot keeps your database awake automatically even if nobody opens the school site for months.

**Step 1 — Create the free account (one time).**
1. Go to [uptimerobot.com](https://uptimerobot.com) and click **Register for FREE** (top-right) — or **Sign up** on the pricing page. You can register with an email + password or with your Google account.
2. If you registered by email, open the confirmation email and click the verification link. You cannot create monitors until the email is verified.
3. The free plan includes **50 monitors** with intervals of 5 minutes or slower — we only need 1–2 monitors, so the free plan is more than enough, permanently.

**Step 2 — Build your ping URL before opening the form.**
Take your project ref from Layer 3 Part 1 (the 20-character code, e.g. `abcdefghijklmnop`) and write out:
```
https://abcdefghijklmnop.supabase.co/functions/v1/ping
```
Paste it into a browser tab first — you must see the JSON with `"database_heartbeat": "heartbeat written at …"`. **Do not create the monitor until this test passes**; a monitor pointed at a broken URL protects nothing.

**Step 3 — Create the monitor.**
1. In the UptimeRobot dashboard click **+ Add New Monitor** (green button, usually top-left; on the new dashboard it may say **+ New monitor**).
2. Fill the form exactly like this:

   | Field | What to enter | Why |
   |---|---|---|
   | **Monitor Type** | `HTTP(s)` — or better, **Keyword** (see Step 4) | Both are free |
   | **Friendly Name** | `Supabase keep-alive — <school name>` | Just a label so you recognise it later |
   | **URL (or IP)** | your ping URL from Step 2 | The exact URL UptimeRobot will call |
   | **Monitoring Interval** | drag/select **12 hours** if available; otherwise the largest offered. Even the default **5 minutes** is safe | Each call is tiny; a longer interval simply conserves your 500k/month Edge-Function quota (5-min checks ≈ 8,640 calls/month — still under 2% of quota) |
   | **Alert contacts** | tick your email address | You get an automatic email the moment pings start failing — this is your early-warning system |

3. Leave every other field at its default and click **Create Monitor**.

**Step 4 — Recommended upgrade: make it a Keyword monitor (also free, catches silent failures).**
A plain HTTP(s) monitor only proves the URL *answered*; it would stay green even if the function answered with an error message. A **Keyword** monitor reads the response body and alerts you when an expected phrase is missing:
1. Choose Monitor Type = **Keyword** (instead of HTTP(s)).
2. **Keyword** = `heartbeat written` (exactly, without quotes).
3. **Alert When** / keyword condition = **Keyword Not Exists** (i.e. treat the monitor as *Down* when the phrase is missing).
4. Everything else identical to Step 3.
Now UptimeRobot verifies **the actual database write succeeded** on every single check, and emails you the instant it stops. This is the configuration we recommend.

**Step 5 — Watch it go green.**
Within one interval (a few minutes) the monitor's status dot turns **green/Up**. Click the monitor to see its response-time chart and event history — every green dot on that chart is your database being kept awake.

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

## Layer 6 — cron-job.org (a second, independent free scheduler — optional but recommended)

[cron-job.org](https://cron-job.org) is a long-established free service (run by a German non-profit) that does one thing: it calls a URL of your choice on a schedule, from its own servers, forever. It is completely unrelated to UptimeRobot, GitHub, Vercel and Google — which is exactly the point: if any one company has an outage or retires its free plan, the others still keep your database awake.

**Prerequisite:** the `ping` Edge Function from Layer 3 Part 1 must already be deployed (this layer calls the same URL). If you have not done Layer 3 Part 1 yet, do that first.

**Step 1 — Create the free account.**
1. Go to [cron-job.org](https://cron-job.org) → click **Sign up** (top-right).
2. Register with your email + a password (or Google sign-in), then click the link in the confirmation email. The free plan is permanent and allows dozens of scheduled jobs — we need one.

**Step 2 — Create the cron job.**
1. After logging in you land on the **Cronjobs** dashboard. Click **CREATE CRONJOB** (orange button).
2. Fill in the form:

   | Field | What to enter |
   |---|---|
   | **Title** | `Supabase keep-alive — <school name>` |
   | **URL** | `https://YOUR_PROJECT_REF.supabase.co/functions/v1/ping` (same URL you tested in a browser for Layer 3 — replace `YOUR_PROJECT_REF` with your real 20-character project ref) |
   | **Enable job** | leave ON |
   | **Execution schedule** | choose **Every day** and pick a time, e.g. **06:00**. Once a day is far more than enough (the danger line is 7 *days* of silence) |

3. Optional but recommended — open the **Advanced** tab of the same form:
   - **Request method:** leave `GET` (the ping function accepts GET).
   - **Notifications / alerts:** enable **"Notify me on failure"** (wording varies slightly) so cron-job.org emails you if the ping ever starts failing.
   - **Save responses:** enable it if offered — it lets you read the response body in the History view (used in Step 3).
4. Click **CREATE** / **Save**.

**Step 3 — Verify it actually worked (do this once).**
1. On the Cronjobs dashboard click your new job → open the **History** tab.
2. You can either wait for the first scheduled run or press **"Run now" / test execution** if the button is offered.
3. A successful execution shows **status 200 (OK)**. Open the execution's details and check the response body contains **`heartbeat written`** — that is the proof of a real database write, not just a reachable URL.
4. Cross-check in Supabase → SQL Editor:
   ```sql
   select last_ping, last_source, ping_count from public.sc_heartbeat;
   ```
   `last_source` should read `edge-ping` and `last_ping` should be within the last few minutes of the execution.

**That's it — fully automatic from here.** cron-job.org fires daily forever; with UptimeRobot (Layer 3) also running, two unrelated companies are now independently resetting your 7-day timer every single day, and BOTH will email you if the ping ever breaks.

---

## Existing sites installed before this feature

Run `database/keep-alive.sql` once in the Supabase **SQL Editor** (Dashboard → SQL Editor → paste → Run). It is idempotent and safe to re-run. Then redeploy the site files so the new `app.js` heartbeat is live.

## How to verify the whole system

Run in the SQL Editor:
```sql
select last_ping, last_source, ping_count from public.sc_heartbeat;
```
`last_ping` should never be older than ~4 days. `last_source` tells you which layer fired last (`site-visit`, `github-actions`, `edge-ping`, `pg_cron`, `manual-button`, `vercel-cron`, `apps-script`, `auto-restore-watchdog`).

## Recommended client handover checklist

- [x] Layer 1 (site-visit) — automatic, nothing to do
- [x] Layer 4 (pg_cron) — automatic when the schema is installed
- [x] Layer 9 (self-committing workflow) — automatic; just confirm repo Settings → Actions → General → Workflow permissions = "Read and write permissions"
- [ ] Layer 2: add the two GitHub secrets (Step B/C above), run the workflow once ✅
- [ ] Layer 3: deploy `ping` + two UptimeRobot monitors (keep-alive + website)
- [ ] Layer 6: cron-job.org daily job on the same `ping` URL (5 min)
- [ ] Layer 7/8: Vercel Cron env vars, or the Google Apps Script trigger (pick at least one)
- [ ] Layer 10: add `SUPABASE_ACCESS_TOKEN` + `SUPABASE_PROJECT_REF` secrets → auto-restore active
- [ ] Verify: `select * from public.sc_heartbeat;`

With Layers 1 + 4 alone the project stays alive automatically; Layers 2, 3, 6, 7 and 8 add independent external redundancy; Layer 5 gives the admin a one-press manual reset; Layer 9 keeps the GitHub schedulers themselves alive forever; and Layer 10 automatically un-pauses the project if the impossible ever happens — ten safeguards in total, every one of them automated.

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

### Layer 9 — the 60-day Actions freeze, SOLVED automatically (self-committing workflow — built in as of V8.9)

**The problem this layer solves.** GitHub automatically disables *scheduled* workflows in any repository that has had **no commits for 60 days**. If that happened, Layer 2 (the twice-weekly GitHub Actions heartbeat) would silently stop. GitHub does email a warning first and one click re-enables it — but a protection layer that depends on a human reading an email is not automation.

**The fix (already installed — nothing to write yourself).** As of V8.9, `.github/workflows/keep-supabase-alive.yml` is **self-committing**: the workflow resets GitHub's 60-day clock *by itself*. Here is exactly what it does on every scheduled run (Monday and Thursday):

1. **Pings the database** (the Layer 2 heartbeat), and — new in V8.9 — **verifies** the response actually says `heartbeat written` (an HTTP 200 with an error body now fails loudly instead of passing silently).
2. **Checks the age of the repository's last commit** (`git log -1 --format=%ct`).
3. **If the last commit is less than 30 days old:** does nothing more — your repo is active, the 60-day freeze is not a risk, and no noise is added to your history.
4. **If the last commit is 30+ days old:** the workflow writes one line (the current UTC timestamp) into `.github/last-keepalive.txt`, commits it as `sc-keepalive-bot`, and pushes. That push is a real commit → **GitHub's 60-day inactivity clock resets to zero automatically.**

**Why this can never freeze:** the workflow runs twice a week; the self-commit triggers at 30 days of repo inactivity; the freeze needs 60 days. The repository can therefore never get past ~30–34 days without a fresh commit — half the distance to the freeze line. The commit message contains `[skip ci]` so the push does not trigger other workflows or a pointless redeploy, and at most ~12 tiny one-line commits per year are added (only in months where nobody pushed anything).

**One-time check (do this once, 30 seconds).** The self-commit needs the workflow's built-in token to have write permission (the workflow file already declares `permissions: contents: write`, and the standard GITHUB_TOKEN honours it on most repos). Verify the repository allows it:
1. Repo → **Settings** → **Actions** → **General**.
2. Scroll to **Workflow permissions**.
3. Select **"Read and write permissions"** → **Save**. (If it was already selected, you're done.)

**How to verify it works end-to-end (optional).** Run the workflow manually once (Actions tab → *Keep Supabase Alive* → *Run workflow*). In the run's log, the step *"Self-commit to reset the 60-day scheduler clock"* prints either:
- `✅ Repository is active (last commit < 30 days). No self-commit needed…` — correct on a repo you pushed to recently, **or**
- `✅ Self-commit pushed. GitHub's 60-day scheduled-workflow freeze clock has been reset automatically.` — and you will see a new commit by `sc-keepalive-bot` touching only `.github/last-keepalive.txt`.
If it prints a **warning about push being rejected**, the usual cause is branch protection on your default branch or the Workflow permissions checkbox above — fix the checkbox, or add the bot as an allowed pusher in the branch-protection rule.

**Optional belt-and-braces (a second, independent 60-day clock).** If you want redundancy for this layer too, **fork the site repo** into a second GitHub account (a colleague's or the school's own), add the same two secrets (`SUPABASE_URL`, `SUPABASE_ANON_KEY`) in the fork's Settings → Secrets → Actions, and enable the workflow on the fork's Actions tab (forks need one manual enable click). Two accounts → two schedulers, each keeping itself alive. This is optional: the self-committing workflow alone already makes the freeze unreachable.

### Layer 10 (V8.9) — Auto-Restore Watchdog: if a pause EVER happens, it un-pauses itself

Layers 1–9 all *prevent* the pause. Layer 10 is different — it is the last line of defence that **automatically reverses** a pause if one ever slips through (e.g. every external pinger fails in the same week). It uses Supabase's official **Management API** — the same mechanism behind the dashboard's "Restore project" button — so the restore is exactly what you would have done manually, just without the human.

**What it does (file: `.github/workflows/supabase-auto-restore.yml`, already in this package):**
1. Every day, GitHub asks the Management API for your project's status.
2. Status `ACTIVE_HEALTHY` → nothing to do, the run ends green.
3. Status `INACTIVE` (paused) → it calls the official restore endpoint (`POST /v1/projects/{ref}/restore`), then polls up to 10 minutes until the project reports healthy again, then immediately writes a heartbeat so the 7-day timer restarts from zero.
4. Any failure makes the run fail loudly → GitHub emails you automatically.

**One-time setup (~2 minutes) — two more repository secrets:**
1. Create a **Personal Access Token**: [supabase.com/dashboard/account/tokens](https://supabase.com/dashboard/account/tokens) → **Generate new token** → name it `auto-restore` → copy the `sbp_...` value.
   ⚠️ This token can manage your whole Supabase account. Store it **only** as a GitHub secret — never in code, config files, or anywhere the browser can see.
2. Repo → **Settings → Secrets and variables → Actions → New repository secret**, twice:

   | Name | Secret |
   |---|---|
   | `SUPABASE_ACCESS_TOKEN` | the `sbp_...` token from step 1 |
   | `SUPABASE_PROJECT_REF` | your 20-character project ref (from the dashboard URL) |

3. Test once: **Actions** tab → *Supabase Auto-Restore Watchdog* → **Run workflow**. A healthy project logs `✅ Project is up (status: ACTIVE_HEALTHY). Nothing to do.`
Without these two secrets the workflow simply skips with a notice — it never fails a repo that hasn't opted in.

> Note: this workflow lives in the same repository as Layer 2, so the Layer 9 self-commit keeps **both** schedules alive automatically.

### The complete matrix (10 layers — tick what you have)
| # | Layer | Runs on | Frequency | Setup time | Kind |
|---|---|---|---|---|---|
| 1 | Site-visit heartbeat | every visitor's browser | every visit | 0 | prevent |
| 2 | GitHub Actions | GitHub | Mon + Thu | 5 min | prevent |
| 3 | Edge Function + UptimeRobot | UptimeRobot | every 5 min–12 h | 10 min | prevent + alert |
| 4 | pg_cron `sc-keep-alive` | inside the DB | every 2 days | 0 (bonus only — pauses with the project) | prevent |
| 5 | 💓 Manual button | Platform Health page | on demand | 0 | prevent |
| 6 | cron-job.org | cron-job.org | daily | 5 min | prevent + alert |
| 7 | **Vercel Cron** | Vercel | daily | 3 min | prevent |
| 8 | **Google Apps Script** | Google | daily | 5 min | prevent + alert |
| 9 | **Self-committing workflow** (built in — V8.9) | GitHub | auto, when repo idle 30 days | 30 sec (one checkbox) | keeps Layer 2/10 alive |
| 10 | **Auto-Restore Watchdog** (V8.9) | GitHub | daily | 2 min (two secrets) | **cure** — un-pauses automatically |

**Recommended minimum:** Layers 1+2+3 (already the default advice) **plus one
of 7/8** so that three unrelated companies (GitHub, UptimeRobot, Vercel or
Google) are each independently resetting the 7-day timer — **plus Layer 10**,
so that even the theoretical worst case (every pinger failing in the same
week) heals itself within a day. Layer 9 is now built into the workflow file
itself, so GitHub's 60-day freeze is permanently off the table. The odds of
all of these failing in the same week are effectively zero — and if they did,
Layer 10 un-pauses the project the next morning without any human involved.
