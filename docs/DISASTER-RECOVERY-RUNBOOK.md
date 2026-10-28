# 🚑 Disaster Recovery Runbook — Total Project Loss
**School Connect (HMG Concepts) · Scenario: the school's Supabase project is paused/deleted forever, but backups exist in the school's Google Drive.**

> Even the most careless school is safe if this runbook is followed. Total recovery time: **about 30–45 minutes**, all free tools.

## When to use this
- The Supabase project was paused for so long it was **deleted** (free-tier policy), or
- Access to the old Supabase account is permanently lost, or
- The database is irreparably corrupted.

If the project is merely **paused**, do NOT use this — just log into supabase.com and click **Restore project**, then press the 💓 heartbeat button on the Platform Health Console.

## What survives a total loss
| Asset | Survives? | Where |
|---|---|---|
| All school data (students, results, fees, CBT, settings…) | ✅ | Google Drive backups (folder "School Connect Backups — <school>") + any local JSON exports |
| The website itself | ✅ | GitHub repo + Vercel (unaffected by Supabase loss) |
| User login accounts | ❌ | Auth accounts die with the old project — users sign up again (5 minutes each) and are re-approved |
| Files in the old Archive Vault | ❌ | Vault lives inside the dead project — this is why Google Drive is the off-site layer |

## Step-by-step recovery

### Step 1 — Create the fresh Supabase project (5 min)
1. [supabase.com](https://supabase.com) → New project (any region close to the school).
2. Project Settings → API: copy the new **Project URL** and **anon public key**.

### Step 2 — Install the database (5 min)
1. SQL Editor → paste the entire `database/complete-schema.sql` from the site repo → Run.
2. Wait for `installed successfully ✅`. This also installs keep-alive, the vault bucket, Drive-sync and security settings automatically.

### Step 3 — Reconnect the website (5 min)
1. In the site repo, edit `assets/js/config.js`: replace the old `SUPABASE_URL` and `SUPABASE_ANON_KEY` with the new values.
2. Commit/push — Vercel redeploys automatically. The same site is now talking to the fresh project.

### Step 4 — Recreate the first admin (5 min)
1. Open the site → **Login → Request access** → sign up with the admin's email.
2. In Supabase → Table Editor → `profiles` → set that row's `role` to `super_admin` and `status` to `approved` (the standard first-admin bootstrap, same as original installation).

### Step 5 — 🚑 One-click data recovery from Google Drive (10–20 min)
1. Sign in as the admin → **Admin Data** → card **"☁️ Google Drive Backup & Sync"**.
2. Expand **⚙️ Setup** → paste the school's Google OAuth **Client ID** (same one as before — it is tied to the site URL, not to Supabase, so it still works; if lost, recreate it in 5 minutes via `docs/GOOGLE-DRIVE-SYNC-GUIDE.md` §1).
3. Click **📂 List Drive backups** → authorise with the school's Google account → every past backup appears.
4. On the newest backup click **🚑 Recover to new project** (NOT plain Restore). Recovery mode:
   - imports every school record;
   - **skips dead user accounts** and clears stale ownership references so foreign keys can't reject your data;
   - retries row-by-row, so one bad row never blocks the other rows;
   - verifies the backup's SHA-256 integrity seal before touching anything.
5. Read the per-table report: `saved` = rows recovered. Small `failed` counts on account-linked rows are expected and harmless.

### Step 6 — Re-onboard people (rolling)
1. Staff/parents/students sign up again with their emails (send one broadcast message).
2. Approve them on **Approvals** — student/staff records recovered in Step 5 re-link by admission/staff number and email.

### Step 7 — Re-arm ALL the safeguards (10 min) — do not skip
- 💓 Press **Send keep-alive heartbeat NOW** on the Platform Health Console.
- Re-add the two GitHub Action secrets with the NEW URL/key (Layer 2).
- Redeploy the edge ping + point UptimeRobot/cron-job.org at the NEW project URL (Layers 3/6).
- Turn Google Drive **auto-sync back ON** and run one fresh backup.
- Check every tile on the Platform Health Console is green.

## Prevention beats recovery
The loss scenario only happens when ALL keep-alive layers are absent. After onboarding any school, confirm on the Platform Health Console: heartbeat healthy · Drive auto-sync ON · last backup < schedule days. That takes 10 seconds and makes this runbook unnecessary.
