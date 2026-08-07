# Cloud Backup & Sync — Complete Setup Guide (2026 edition)
**School Connect (HMG Concepts) · 100% free tools, no server, school owns its data forever**

> **Updated for the NEW Google Cloud Console.** In 2024 Google renamed the old
> "OAuth consent screen" to **Google Auth Platform** and split it into three
> tabs: **Branding**, **Audience** and **Clients**. Every step below matches
> the console as it looks **today** — if a screen ever differs slightly, the
> tab names in bold are what to look for. This guide also covers **Microsoft
> OneDrive** and two extra free backup routes, so every school can pick what
> suits them.

---

## What this feature does

Writes the **entire school database** (restorable portable-JSON archives) directly into the **school's own cloud storage**:

- **One-click backup:** Admin Data → "☁️⬇ Back up now to Google Drive".
- **One-click restore:** Admin Data → "📂 List Drive backups" → **↩ Restore**.
- **Automatic sync:** turn it on once (default every 7 days) — backups then happen by themselves whenever an admin uses the portal (§5 explains how).

**Privacy by design:** the connection uses Google's `drive.file` permission — the portal can *only* see backup files it created itself, inside one folder ("School Connect Backups — <school name>"). It can never read the school's other Drive documents. Nothing passes through any third-party server. The newest **15** backups are kept automatically.

---

## 1. Google Drive setup — step by step (NEW console, ~10 minutes, once per school)

Google requires each website that talks to Drive to have a free **OAuth Client ID**. It is public by design (not a password) — it just tells Google which website is asking. **Billing is NOT required for any step.**

### Step A — Create a free Google Cloud project
1. Go to **[console.cloud.google.com](https://console.cloud.google.com)** and sign in with the **school's** Google account (the one that should own the backups).
2. Top bar → **project selector** (next to the Google Cloud logo) → **New project** → name it e.g. `school-portal-backup` → **Create**.
3. Make sure the new project is **selected** in the top bar before continuing (the #1 cause of "my settings disappeared" is being in the wrong project).

### Step B — Enable the Google Drive API
1. Left ☰ menu → **APIs & Services → Library** (or type "Drive API" in the top search bar).
2. Open **Google Drive API** → click **Enable**.

### Step C — Configure Google Auth Platform *(this replaced the old "OAuth consent screen")*
1. Left ☰ menu → **APIs & Services → OAuth consent screen**. You will land on the **Google Auth Platform** page. On a fresh project it says *"Google Auth Platform not configured yet"* — click **Get started**.
   *(Direct link: `console.cloud.google.com/auth/branding` — pick your project when asked.)*
2. A short 4-step wizard opens:
   - **App information** — App name = the school's name; User support email = the school's email. → **Next**.
   - **Audience** — choose **External** (Internal is only for paid Google Workspace organisations). → **Next**.
   - **Contact information** — the school's email again. → **Next**.
   - **Finish** — tick the user-data-policy agreement → **Continue** → **Create**.
3. You now see the Google Auth Platform dashboard with tabs on the left: **Branding · Audience · Clients · Data access · Verification centre**.
4. Open the **Audience** tab → under **Test users** click **+ Add users** → add the Google address(es) of every school admin who will run backups (up to 100). → **Save**.
   > **Why:** a new app starts in *Testing* mode. Only listed test users can authorise it — anyone else gets `Error 403: access_denied`. For one school's private backups this is perfect: **you never need Google's app-verification process**, and Testing mode has no expiry for the users you list.
5. *(Optional but tidy)* Open the **Data access** tab → **Add or remove scopes** → tick `https://www.googleapis.com/auth/drive.file` ("See, edit, create and delete only the specific Google Drive files that you use with this app") → **Update** → **Save**. The portal requests this scope at runtime either way; listing it here just makes the consent screen explicit.

### Step D — Create the OAuth Client ID
1. Still inside Google Auth Platform, open the **Clients** tab → **+ Create client**.
   *(Same thing is reachable via APIs & Services → Credentials → + Create credentials → OAuth client ID.)*
2. **Application type:** `Web application`. **Name:** `School portal` (any label).
3. Under **Authorized JavaScript origins** → **+ Add URI** → enter the site's exact origin, **no trailing slash, no path**:
   - `https://yourschool.vercel.app`
   - *(optional, for local testing)* `http://localhost:3000`
   > Leave **Authorized redirect URIs** empty — the portal uses Google Identity Services token flow, which only needs the JavaScript origin.
4. Click **Create** → copy the **Client ID** (looks like `1234567890-abc123.apps.googleusercontent.com`).
   *(If a client secret is shown, ignore it — this integration never uses it and never needs it stored anywhere.)*

### Step E — Paste the Client ID into the portal
1. Portal → sign in as owner/admin → **Admin Data** → card **"☁️ Google Drive Backup & Sync"** → expand **"⚙️ Setup & automatic sync schedule"**.
2. Paste the Client ID, set **Automatic backup = On**, interval **7 days**, click **💾 Save Drive settings**. Stored in the database → applies to every admin device at once.
3. Databases installed before this feature: run `database/drive-sync.sql` once in the Supabase SQL Editor (fresh `complete-schema.sql` installs already include it).

### Step F — First backup (this also authorises Google)
1. Click **"☁️⬇ Back up now to Google Drive"**.
2. A Google window opens → pick the school account → **Continue / Allow**. *(Nothing opens? The browser blocked the popup — allow popups for the site and click again.)*
3. Watch: *Collecting all tables… → Uploading…* → green toast **"✅ Backup uploaded to Google Drive"**.
4. **Verify:** open [drive.google.com](https://drive.google.com) → folder **"School Connect Backups — <school name>"** → the JSON file is there. That file **is** the school's complete data, in their own hands.

### Troubleshooting map (new console)
| Symptom | Cause → Fix |
|---|---|
| Can't find "OAuth consent screen" anywhere | It was **renamed to Google Auth Platform** (2024). APIs & Services → OAuth consent screen still lands on it, or go to `console.cloud.google.com/auth/branding`. |
| `Error 403: access_denied` when authorising | The Google account is not on the **Audience → Test users** list. Add it, wait ~1 minute, retry. |
| `idpiframe / origin mismatch` or popup closes instantly | The site origin isn't (exactly) in **Authorized JavaScript origins** — no trailing slash, correct `https://`, correct subdomain. Edits take up to 5 minutes to propagate. |
| "To create an OAuth client ID, you must first configure your consent screen" | Finish the Step C wizard first; also try disabling ad-blockers on console.cloud.google.com (known to break the Clients tab). |
| Popup opens but school sees "unverified app" warning | Normal in Testing mode. Click **Continue** — only listed test users can do this, which is the private-use design. |
| Backup worked before, now silent sync fails | Google's browser authorisation expired. Click **Back up now** once — re-authorise, silent syncs resume. |

---

## 2. Microsoft OneDrive route (free alternative)

Prefer Microsoft? Every free Microsoft account includes **5 GB OneDrive**. Two ways, both free:

### 2a. Zero-setup manual route (recommended for most schools)
1. Admin Data → **"⬇ Export full archive (JSON)"** — a complete sealed archive downloads to the computer.
2. Install the **OneDrive desktop app** (built into Windows 10/11; free on Mac) and save the file into the OneDrive folder, e.g. `OneDrive\School Backups\`.
3. Done — OneDrive uploads it automatically. Restore any time via Admin Data → **"📂 Import archive"**.
> The same trick works with the **Google Drive for desktop** app, **Dropbox** (2 GB free), or any synced folder: the platform's export **is** the backup; the sync app does the "auto" part. This is the most robust route because nothing can ever expire.

### 2b. Full API integration (advanced, for developers)
Microsoft's equivalent of the Google setup uses **Microsoft Entra ID app registration** (free):
1. [portal.azure.com](https://portal.azure.com) → **Microsoft Entra ID → App registrations → New registration** (Supported account types: *Personal Microsoft accounts and organisational*).
2. **Authentication** → Add platform → **Single-page application** → add the site origin.
3. **API permissions** → Microsoft Graph → Delegated → `Files.ReadWrite` (this is the OneDrive analogue of `drive.file`-style scoping: app-created files).
4. Use the MSAL.js library + Graph `PUT /me/drive/root:/SchoolBackups/{name}.json:/content` upload.
> This is not wired into the portal UI (Google Drive is the built-in integration); it's documented here so a school's IT person can add it. For non-developers, route 2a achieves the same result with zero code.

---

## 3. Bonus route — GitHub Actions full-database dump (true off-site, fully automatic)

For technically-minded owners who want **server-side** backups that run even when nobody opens the portal (the JSON routes above run in the browser):

1. Create a **private** GitHub repository, e.g. `school-db-backups`.
2. Supabase Dashboard → **Project Settings → Database** → copy the **Connection string** (URI, Session pooler). Replace `[YOUR-PASSWORD]` with the database password.
3. GitHub repo → **Settings → Secrets and variables → Actions → New repository secret** → Name `SUPABASE_DB_URL`, value = that connection string.
4. Add this file as `.github/workflows/db-backup.yml`:
   ```yaml
   name: Weekly database backup
   on:
     schedule: [{cron: '0 2 * * 0'}]   # Sundays 02:00 UTC
     workflow_dispatch: {}              # + a manual Run button
   jobs:
     backup:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - name: Dump database
           run: |
             sudo apt-get -y install postgresql-client >/dev/null
             pg_dump "$SUPABASE_DB_URL" --no-owner --format=plain \
               --file="backup-$(date +%F).sql"
           env:
             SUPABASE_DB_URL: ${{ secrets.SUPABASE_DB_URL }}
         - name: Commit backup (keep last 8)
           run: |
             git config user.name backup-bot && git config user.email bot@school
             ls -1t backup-*.sql | tail -n +9 | xargs -r rm --
             git add -A && git commit -m "Backup $(date +%F)" && git push
   ```
5. **Actions** tab → run it once manually → a dated `.sql` file appears in the repo. It now repeats weekly, forever, free.
> **Restore:** new Supabase project → SQL Editor → run `complete-schema.sql` → then feed the dump via `psql "$NEW_DB_URL" < backup-YYYY-MM-DD.sql` (or ask HMG). Keep the repo **private** — it contains school data.

---

## 4. One-click restore (Google Drive route)

1. Admin Data → **"📂 List Drive backups"** — every backup with size and date.
2. **↩ Restore** → confirm. The archive is verified (SHA-256 seal) and imported through the portable-import engine (**upsert**: same-id rows update, missing rows re-create, **nothing is deleted**). A per-table report follows.
3. **Moving to a brand-new Supabase project?** Run `complete-schema.sql` there first, create/adopt the admin users, then restore (profile UUIDs belong to Supabase Auth, so accounts must exist first). For catastrophic loss see `docs/DISASTER-RECOVERY-RUNBOOK.md` and the 🚑 Recover button.

## 5. How "automatic" works on a 100% free stack (honest explanation)

A static site has no server, and a closed browser cannot run code. So: **every time an owner/admin opens any portal page**, the platform checks the schedule stored in the database. If a backup is due, it silently requests a Google token (no popup — Google remembers the authorisation in that browser) and uploads in the background, then stamps the shared "last backup" time so other admin devices don't duplicate it. Toast: *"☁️ Automatic Google Drive backup completed."*

- Normal school usage (admins log in most days) ⇒ effectively hands-free.
- Nobody opens the portal past the due date ⇒ backup waits for the next admin visit. Want clockwork regardless? Add the §3 GitHub Actions route on top.
- Silent token expired ⇒ a gentle toast asks for one click of "Back up now"; silent syncs resume after.
- The public demo site never auto-syncs.

## 6. Layered safety summary

| Layer | Where the copy lives | Automatic? | Best for |
|---|---|---|---|
| Archive Vault (`storage.html`) | Supabase Storage (1 GB) | manual, one click | freeing DB space, instant in-app restore |
| Local JSON/CSV export | admin's computer | manual | ad-hoc snapshots, spreadsheets |
| **Google Drive Sync** | school's Drive (15 GB) | **yes, on admin visits** | off-site recovery, data ownership |
| OneDrive / Drive desktop folder (§2a) | school's OneDrive/Drive | yes (folder sync) | zero-setup cloud copies |
| GitHub Actions pg_dump (§3) | private GitHub repo | **yes, server-side cron** | true unattended full-SQL backups |

Recommended: Google Drive auto-sync ON (weekly) **+** the termly vault-archive routine (`docs/FREE-TIER-CAPACITY-GUIDE.md`). Add §3 if the school wants clockwork backups independent of anyone logging in.
