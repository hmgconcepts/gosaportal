# Google Drive Backup & Sync — Setup and User Guide
**School Connect (HMG Concepts) · 100% free tools, no server, school owns its data forever**

## Why this exists

Schools that pay once should never be locked in or lose data. This feature writes the **entire school database** (the same restorable portable-JSON archives used across the platform) directly into the **school's own Google Drive** (15 GB free per Google account):

- **One-click backup:** Admin Data → "☁️⬇ Back up now to Google Drive".
- **One-click restore:** Admin Data → "📂 List Drive backups" → **↩ Restore** next to any backup.
- **Automatic sync:** turn it on once, choose the schedule (default every 7 days), and backups happen by themselves whenever an admin uses the portal (details in §4).

**Privacy & safety by design:** the connection uses Google's `drive.file` permission — the portal can *only* see the backup files it created itself, inside one folder ("School Connect Backups — <school name>"). It can never read the school's other Drive documents. Nothing passes through any third-party server: the browser talks directly to Google. The newest **15** backups are kept; older ones are trimmed automatically so Drive never fills up.

---

## 1. One-time setup (~10 minutes, done once per school at handover)

Google requires each website that talks to Drive to have a free **OAuth Client ID**. It is **public by design** (it is not a password or secret) — it just tells Google which website is asking.

### Step A — Create a free Google Cloud project
1. Go to [console.cloud.google.com](https://console.cloud.google.com) and sign in with the **school's** Google account (the one that should own the backups).
2. Top bar → project dropdown → **New Project** → name it e.g. `school-portal-backup` → **Create**, then make sure it is selected.

### Step B — Enable the Drive API
1. Left menu → **APIs & Services → Library**.
2. Search **Google Drive API** → open it → click **Enable**.

### Step C — Configure the consent screen
1. **APIs & Services → OAuth consent screen** (on new consoles: **Google Auth Platform → Branding/Audience**).
2. Choose **External** → fill only the required fields (App name = school name, support email, developer email) → save through the steps.
3. Under **Audience / Test users**, click **+ Add users** and add the Google address(es) of the school admin(s) who will run backups. *(In "Testing" mode only listed users can authorise — perfect for one school. You do not need Google's app verification for this private use.)*

### Step D — Create the Client ID
1. **APIs & Services → Credentials → + Create credentials → OAuth client ID**.
2. **Application type:** `Web application`. Name: `School portal`.
3. Under **Authorized JavaScript origins** click **+ Add URI** and add the site's exact origin(s), no trailing slash:
   - `https://yourschool.vercel.app`
   - (optional, for testing) `http://localhost:3000`
4. Click **Create** and copy the **Client ID** — it looks like `1234567890-abc123def.apps.googleusercontent.com`. (Ignore the client secret if shown; the site never uses it.)

### Step E — Paste it into the portal
1. Log into the portal as the owner/admin → **Admin Data** page → card **"☁️ Google Drive Backup & Sync"** → expand **"⚙️ Setup & automatic sync schedule"**.
2. Paste the Client ID, set **Automatic backup = On** and the interval (7 days is a good default), click **💾 Save Drive settings**. The setting is stored in the database, so it applies to **all** admin devices at once.
3. For databases installed before this feature, run `database/drive-sync.sql` once in the Supabase SQL Editor first (new installs of `complete-schema.sql` already include it).

### Step F — First backup (also authorises Google)
1. Click **"☁️⬇ Back up now to Google Drive"**.
2. A Google window opens → choose the school account → **Allow**. (If nothing opens, the browser blocked the popup — allow popups for the site and click again.)
3. Watch the progress line: *Collecting all tables… → Uploading X MB…* and then the green toast: **"✅ Backup uploaded to Google Drive: school-connect-backup-…json"**.
4. **Verify:** open [drive.google.com](https://drive.google.com) — you'll find the folder **"School Connect Backups — <school name>"** containing the file. That file *is* the school's complete data, in their own hands.

---

## 2. One-click restore

1. Admin Data → **"📂 List Drive backups"** — every backup appears with size and date.
2. Click **↩ Restore** on the one you want → confirm.
3. The archive is downloaded from Drive and imported through the standard portable-import engine (**upsert**: existing rows with the same id are updated, missing rows are re-created, **nothing is deleted**). A full per-table report (saved/failed) is shown when it finishes.
4. **Moving to a brand-new Supabase project?** Run `complete-schema.sql` there first, create/adopt the admin users, then restore. (Auth note: profile UUIDs belong to Supabase Auth — operational data restores cleanly; user accounts must exist first.)

## 3. Where this fits among the other safety layers

| Layer | Where the copy lives | Best for |
|---|---|---|
| Archive Vault (`storage.html`) | Supabase File Storage (1 GB) | Freeing the 500 MB DB of old rows, instant in-platform restore |
| Local JSON/CSV export (`admin-data.html`) | The admin's computer | Ad-hoc snapshots, spreadsheets |
| **Google Drive Backup & Sync** | **The school's own Google Drive (15 GB)** | **Off-site disaster recovery, true data ownership, scheduled automation** |

Recommended: keep auto-sync ON (weekly) **and** do the termly vault-archive + purge routine (`docs/FREE-TIER-CAPACITY-GUIDE.md`).

## 4. How "automatic" works on a 100% free stack (honest explanation)

A static site has no server, and a closed browser cannot run code. So automatic sync works like this: **every time an owner/admin opens any page of the portal**, the platform checks the schedule stored in the database. If a backup is due (e.g. 7+ days since the last one), it silently requests a Google token (no popup — Google remembers the earlier authorisation in that browser) and uploads a fresh backup in the background, then stamps the shared "last backup" time so other admin devices don't duplicate it. You'll simply see a toast: *"☁️ Automatic Google Drive backup completed"*.

Practical implications:
- With normal school usage (admins log in most days), backups are effectively hands-free.
- If **no admin opens the portal at all** past the due date, the backup waits for the next admin visit — combine with the keep-alive layers so the project itself never pauses.
- If the silent token fails (e.g. Google authorisation expired in that browser), a gentle toast asks the admin to click "Back up now" once — that re-authorises and future silent syncs resume.
- The public demo site never auto-syncs.

## 5. Troubleshooting

| Symptom | Cause → Fix |
|---|---|
| *"Google Drive is not configured yet"* | Client ID not saved — §1 Step E |
| Google shows **Error 403: access_denied** | The signing-in account isn't in **Test users** — §1 Step C.3 |
| Google shows **Error 400: origin_mismatch / redirect_uri_mismatch** | Site URL missing from **Authorized JavaScript origins** (must match exactly, https, no trailing slash) — §1 Step D.3 |
| *"The browser blocked the Google sign-in popup"* | Allow popups for the site, click again |
| *"Could not save Drive settings"* | Signed-in user isn't an admin — only admin roles may change settings |
| Restore reports failures on `profiles` | Normal on a different Supabase project — Auth users must exist first (§2.4) |
| Auto-sync never fires on a device | That browser hasn't authorised Google yet — click "Back up now" once on it |

## 6. What you should still do

- Test a restore once after setup (create a backup, restore it — takes 2 minutes) so the school has *seen* recovery work.
- Keep at least one termly local JSON export too (defence in depth).
- If the school changes its Google account, redo §1 with the new account; old backups can be shared/moved in Drive as normal files.
