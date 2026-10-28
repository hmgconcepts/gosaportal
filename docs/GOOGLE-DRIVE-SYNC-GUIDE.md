# Google Drive Backup & Sync — Exact Setup Guide
**School Connect (HMG Concepts) · 100% free · verified word-for-word against Google's own documentation**

> **Where every step comes from.** This guide mirrors, word for word, the
> screens and button names in Google's own current documentation:
>
> - *Google Drive API — JavaScript quickstart* (developers.google.com/workspace/drive/api/quickstart/js) — this is exactly the kind of app the portal is (browser JavaScript + Drive API);
> - *Configure the OAuth consent screen* (developers.google.com/workspace/guides/configure-oauth-consent);
> - *Manage OAuth Clients* (support.google.com/cloud/answer/15549257) — the official rules for JavaScript origins and the exact error names.
>
> Each step below tells you the **exact link to open**, the **exact text you
> will see**, and the **exact button to click**. Where Google's console shows
> different screens to different accounts, both variants are given.

---

## What you are setting up (1-minute overview)

The portal backs up the **whole school database** into the school's own Google Drive (15 GB free). To let a website talk to Drive, Google requires a free **OAuth Client ID** — a public identifier (Google's Help page compares it to a *username*, not a password). Creating it takes four short parts:

| Part | What you do | Where |
|---|---|---|
| A | Create a Google Cloud project | console.cloud.google.com |
| B | Enable the Google Drive API | one click via a direct link |
| C | Configure the consent screen + add the admins as test users | "Google Auth platform" pages |
| D | Create the Web application Client ID | "Clients" page |
| E–F | Paste the ID into the portal and run the first backup | the portal |

**No billing / credit card is required at any point.** If Google ever offers a "free trial" with billing, skip it — nothing here needs it.

**Before you start:** open a browser where **only the school's Google account** is signed in (or use a private/incognito window and sign in with it). With several accounts signed in, Google sometimes opens the console under the wrong one — always check the avatar at the top-right.

---

## PART A — Create a Google Cloud project

1. Open **https://console.cloud.google.com/projectcreate**
   *You see:* a page titled **New Project** with a **Project name** field.
   *(First visit ever? Google shows a Terms of Service checkbox first — tick and continue.)*
2. In **Project name**, type something memorable, e.g. `school-portal-backup`. Leave **Location** as *No organisation*.
3. Click **CREATE**.
4. Wait ~15 seconds. A notification (bell icon, top-right) says the project was created — click **SELECT PROJECT** inside that notification.
   *(Missed the notification? Click the project name dropdown in the top bar — left of the search box — and pick `school-portal-backup` from the list.)*

✅ **Checkpoint:** the top bar of the console now shows `school-portal-backup`. Every later step depends on this — if any later screen looks wrong, the selected project is the first thing to re-check.

---

## PART B — Enable the Google Drive API

*(Source: the quickstart's own "Enable the API" button uses exactly this link.)*

1. Open **https://console.cloud.google.com/flows/enableapi?apiid=drive.googleapis.com**
   *You see:* a page titled **Enable access to APIs** (or the Google Drive API product page) with your project shown; **Google Drive API** is pre-selected.
2. Confirm the project is `school-portal-backup`, then click **NEXT**, then **ENABLE** (some accounts see a single **ENABLE** button).

✅ **Checkpoint:** you land on the **Google Drive API** page and the blue button now reads **MANAGE** — meaning it is enabled.
*(Link didn't work? Manual path: ☰ menu → **APIs & Services** → **Library** → search "Google Drive API" → open it → **ENABLE**.)*

---

## PART C — Configure the consent screen and add test users

*(Source: quickstart §"Configure the OAuth consent screen" and the Configure-OAuth-consent guide — steps and button names copied exactly.)*

1. Open **https://console.developers.google.com/auth/branding**
   *(This is the link Google's documentation itself uses; it redirects into your console. Manual path: ☰ menu → **Google Auth platform** → **Branding**.)*

2. **What you see now is ONE of these two screens:**

   **Screen 1 — a message that says "Google Auth platform not configured yet"** *(normal for a fresh project)* → click **Get Started**. A wizard opens; Google's documentation lists its steps exactly like this:
   1. Under **App Information**, in **App name**, enter a name for the app — use the school's name.
   2. In **User support email**, choose a support email address.
   3. Click **Next**.
   4. Under **Audience**, select **External**.
      *(Google's quickstart says "Internal" — that option only exists for paid Google Workspace organisations. For a normal Gmail account, **Internal is greyed out and External is the only choice** — and it is the right one. Google's consent guide then says: "If you selected External for user type, add test users" — we do that in step 4 below.)*
   5. Click **Next**.
   6. Under **Contact Information**, enter an **Email address**.
   7. Click **Next**.
   8. Under **Finish**, review the Google API Services User Data Policy and select **I agree to the Google API Services: User Data Policy**.
   9. Click **Continue**.
   10. Click **Create**.

   **Screen 2 — a Branding form already showing App name / logo / support email** *(project configured earlier, or an account still on the classic layout)* → just confirm App name + support email are filled and click **SAVE** if you changed anything.

3. ✅ **Checkpoint:** you are now on the **Google Auth platform** section. Its pages are: **Branding · Audience · Clients · Data Access · Verification Center** (visible as a left-side list or as links on the page).

4. **Add the test users** — this is the step that makes everything work. *(Source: Configure-OAuth-consent guide, quoted verbatim: "Click Audience. Under Test users, click Add users. Enter your email address and any other authorized test users, then click Save.")*
   1. Open **https://console.developers.google.com/auth/audience** (or click **Audience** in the left list).
      *You see:* **Publishing status: Testing**, **User type: External**, and lower down a **Test users** section.
   2. Under **Test users**, click **Add users**.
   3. Enter the Gmail address of **every school admin who will run backups** (up to 100 allowed).
   4. Click **Save**.

   > **Why this matters — read once, save hours:** an External app starts with
   > Publishing status **Testing**. In Testing, **only the accounts listed under
   > Test users can authorise the app**; anyone else gets **"Error 403:
   > access_denied"**. For a private school backup, Testing is the **permanent,
   > intended state**: it works immediately and forever for the people you list,
   > and you never need Google's app-verification review. **Do not click
   > "Publish app"** — publishing is what triggers verification requirements.

5. **Scopes — deliberately skipped.** Google's own quickstart says at this exact point: *"For now, you can skip adding scopes."* The portal requests the only scope it needs (`drive.file` — "See, edit, create and delete **only the specific Google Drive files that you use with this app**") at runtime, and Google shows it on the consent popup automatically. Adding it on the **Data Access** page is optional documentation, nothing more.

---

## PART D — Create the OAuth Client ID (Web application)

*(Source: quickstart §"Authorize credentials for a web application" — steps copied exactly.)*

1. Open **https://console.developers.google.com/auth/clients**
   *(Manual path: ☰ menu → **Google Auth platform** → **Clients**.)*
   *You see:* a **Clients** page with a **+ Create Client** button.
   - *It insists you configure the consent screen first?* Part C wasn't finished — complete it.
   - *The button does nothing?* Disable ad-blockers on this page (known console issue) or clear the site's cookies and retry.
2. Click **Create Client**.
3. Click **Application type** → select **Web application**.
4. In the **Name** field, type e.g. `School portal` — Google notes this name is *"only shown in the Google Cloud Console"*.
5. Under **Authorized JavaScript origins**, click **Add URI** and enter the portal's address — **scheme + domain only**. Google's Help page gives the exact rules:
   - must be **HTTPS** (only `localhost` may use http);
   - **no path, no query, no fragment** — so no trailing slash and nothing after the domain;
   - no wildcards; if you use a port other than 80/443, include it.

   Correct examples:
   - `https://yourschool.vercel.app`
   - *(optional, for local testing)* `http://localhost:3000`

   Wrong: `https://yourschool.vercel.app/` (trailing slash) · `https://yourschool.vercel.app/login.html` (path) · `yourschool.vercel.app` (missing scheme).
6. **Authorized redirect URIs — leave empty.** Per Google's quickstart, redirect URIs are for *"Server-side apps (Java, Python, and more)"*; the portal is a client-side JavaScript app and needs only the JavaScript origin.
7. Click **Create**.
8. *You see:* the new credential listed under **OAuth 2.0 Client IDs**. Copy the **Client ID** — a long string ending in **`.apps.googleusercontent.com`**.

   > **About the client secret:** Google's quickstart states it verbatim —
   > *"Note that client secrets aren't used for Web applications."* If the
   > console shows one anyway, ignore it. You do not need it, the portal never
   > uses it, and you don't need to download any JSON file.

✅ **Checkpoint:** you have a Client ID like `1234567890-abc123def456.apps.googleusercontent.com` in your clipboard. That single string is the entire output of Parts A–D.

> **Timing note (from Google's Help page):** *"It may take 5 minutes to a few
> hours for changes made to these settings to take effect."* In practice origins
> work within minutes — but if the very first authorisation attempt fails,
> wait a few minutes and try again.

---

## PART E — Paste the Client ID into the portal

1. Portal → sign in as owner/admin → **Admin Data** page → card **"☁️ Google Drive Backup & Sync"** → expand **"⚙️ Setup & automatic sync schedule"**.
2. Paste the Client ID → set **Automatic backup = On** → interval `7` days → click **💾 Save Drive settings**.
   *(Saved into the school database → applies to every admin device at once.)*
3. Only for databases installed before this feature existed: run `database/drive-sync.sql` once in the Supabase SQL Editor. Fresh `complete-schema.sql` installs already include it.

## PART F — First backup (this authorises Google, once per browser)

1. Click **"☁️⬇ Back up now to Google Drive"**.
2. A Google popup opens: choose the school account → Google shows the app name from Part C and the permission *"See, edit, create and delete only the specific Google Drive files that you use with this app"* → click **Continue** / **Allow**.
   *(Because the app is in Testing mode, Google may first show "Google hasn't verified this app" — for a listed test user this is normal and expected; click **Continue**.)*
3. Watch the progress line: *Collecting all tables… → Uploading…* → green toast **"✅ Backup uploaded to Google Drive"**.
4. **See it with your own eyes:** open **https://drive.google.com** → folder **"School Connect Backups — <school name>"** → today's `.json` file is inside. That file **is** the school's complete data, owned by the school.

---

## If something goes wrong — exact errors and exact fixes

| Exact error / symptom | Meaning | Fix |
|---|---|---|
| **Error 403: access_denied** | The Google account authorising is **not on the Test users list** | Part C step 4 — add that Gmail under **Audience → Test users**, wait a minute, retry |
| **origin_mismatch** (or popup opens and closes instantly) | The site's address is not entered **exactly** under Authorized JavaScript origins | Part D step 5 — check https, exact subdomain, **no trailing slash, no path**; allow up to a few minutes to propagate |
| **redirect_uri_mismatch** | Something was typed into Authorized *redirect* URIs | Remove it — that field must stay **empty** for this app (Part D step 6) |
| **"Google hasn't verified this app"** with a Continue link | Normal for Testing mode | Test users click **Continue**. Do **not** publish the app |
| **"To create an OAuth client ID, you must first configure your consent screen"** | Part C not completed for THIS project | Finish Part C; confirm the correct project in the top bar |
| Create Client button unresponsive | Console bug with ad-blockers | Disable ad-blocker on console pages, or clear cookies for the console site |
| No popup at all when clicking Back up now | Browser blocked the popup | Allow popups for the portal site, click again |
| Menus don't match any guide | Console layouts differ per account | Use the **direct links** in Parts A–D — they land correctly regardless of menu layout. Then verify the project name in the top bar |
| Worked for weeks, silent sync stopped | That browser's Google authorisation expired | Click **Back up now** once → re-allow → silent syncs resume |
| Second admin's device won't back up | Their Gmail is not a test user, or that browser never authorised | Add them in Part C step 4; have them click **Back up now** once on their device |

---

## Microsoft OneDrive route (free alternative)

Every free Microsoft account includes **5 GB OneDrive**.

### Zero-setup route (recommended — nothing can ever expire)
1. Admin Data → **"⬇ Export full archive (JSON)"** — a complete sealed archive downloads.
2. Save it into the **OneDrive folder** (built into Windows 10/11; free app on Mac), e.g. `OneDrive\School Backups\`. OneDrive uploads it automatically.
3. Restore any time via Admin Data → **"📂 Import archive"**.
> Works identically with **Google Drive for desktop** or **Dropbox** (2 GB): the platform's export *is* the backup; the sync app does the "auto" part.

### Full API route (for IT people)
Microsoft's equivalent of Parts C–D is a free **Microsoft Entra ID app registration**: portal.azure.com → Microsoft Entra ID → **App registrations** → **New registration** (account types: *personal Microsoft accounts + organisational*) → **Authentication** → Add a platform → **Single-page application** → add the portal origin → **API permissions** → Microsoft Graph → Delegated → **Files.ReadWrite** → upload with MSAL.js + Graph (`PUT /me/drive/root:/SchoolBackups/{name}.json:/content`). Not wired into the portal UI; documented for schools standardised on Microsoft.

---

## GitHub Actions route — server-side weekly SQL dump (fully unattended)

The browser routes run when an admin visits. For **clockwork backups even if nobody opens the portal**:

1. Create a **private** GitHub repository, e.g. `school-db-backups`.
2. Supabase Dashboard → **Project Settings → Database** → copy the **Connection string** (URI / Session pooler); put the database password into it.
3. GitHub repo → **Settings → Secrets and variables → Actions → New repository secret** → Name `SUPABASE_DB_URL`, value = that string.
4. Add `.github/workflows/db-backup.yml`:
   ```yaml
   name: Weekly database backup
   on:
     schedule: [{cron: '0 2 * * 0'}]   # Sundays 02:00 UTC
     workflow_dispatch: {}              # adds a manual "Run workflow" button
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
5. **Actions** tab → **Run workflow** once → a dated `.sql` file appears in the repo. It now repeats weekly, free, forever.
> **Restore:** new Supabase project → run `complete-schema.sql` → `psql "$NEW_DB_URL" < backup-YYYY-MM-DD.sql`. Keep the repo **private** — it contains school data.

---

## One-click restore (Google Drive route)

1. Admin Data → **"📂 List Drive backups"** — every backup with size + date.
2. Click **↩ Restore** → confirm. The archive's SHA-256 seal is verified, then imported through the portable engine (**upsert**: same-id rows update, missing rows re-create, **nothing is deleted**). A per-table report follows.
3. **Brand-new Supabase project?** Run `complete-schema.sql` there first, create/adopt the admin users, then restore. Catastrophic loss → `docs/DISASTER-RECOVERY-RUNBOOK.md` and the 🚑 Recover button.

## How "automatic" works on a 100% free stack (honest explanation)

A static site has no server, and a closed browser cannot run code. So: **whenever an owner/admin opens any portal page**, the platform checks the schedule stored in the database. If a backup is due, it silently obtains a Google token (no popup — Google remembers that browser's Part-F authorisation) and uploads in the background, then stamps the shared "last backup" time so other admin devices don't duplicate it. Toast: *"☁️ Automatic Google Drive backup completed."*

- Admins log in most days ⇒ effectively hands-free.
- Nobody opens the portal past the due date ⇒ the backup waits for the next visit. Want true clockwork? Add the GitHub Actions route above.
- Silent token expired ⇒ one click of **Back up now** re-authorises; silent syncs resume.
- The public demo site never auto-syncs.

## Layered safety summary

| Layer | Where the copy lives | Automatic? | Best for |
|---|---|---|---|
| Archive Vault (`storage.html`) | Supabase Storage (1 GB) | manual, one click | freeing DB space, instant in-app restore |
| Local JSON/CSV export | admin's computer | manual | ad-hoc snapshots, spreadsheets |
| **Google Drive Sync** | school's Drive (15 GB) | **yes, on admin visits** | off-site recovery, data ownership |
| OneDrive / Drive-desktop folder | school's OneDrive/Drive | yes (folder sync) | zero-setup cloud copies |
| GitHub Actions pg_dump | private GitHub repo | **yes, server-side cron** | unattended full-SQL backups |

Recommended: Google Drive auto-sync ON (weekly) **+** the termly vault-archive routine (`docs/FREE-TIER-CAPACITY-GUIDE.md`). Add the GitHub Actions route for backups independent of anyone logging in.
