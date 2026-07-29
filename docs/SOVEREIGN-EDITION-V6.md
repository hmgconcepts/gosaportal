# School Connect V6.0 "Sovereign Edition" — Feature Addendum
**HMG Concepts Ecosystem · "Recurring payments should not keep your schools from having online presences."**

This release turns that motto into architecture. A school that pays once must be **safe** (nothing lost), **sovereign** (data always in its own hands), **secure** (protected on shared school computers), and **self-servicing** (one page tells a non-technical proprietor that everything is healthy — no support contract required).

## What was added

### 1. 🔏 Tamper-evident portable archives (SHA-256 sealing) — `data-portability.js`
Every export — local JSON, Archive Vault file, Google Drive backup — is now cryptographically **sealed**: a SHA-256 checksum of the entire table payload is embedded in the envelope (`integrity` block). On **every import/restore**, the seal is re-computed and verified:
- Seal intact → "🔏 Archive integrity verified" toast, import proceeds.
- Seal broken (file corrupted in transit, edited, truncated) → import **refuses** with a clear explanation.
- Legacy unsealed archives still import (backwards compatible).
Zero dependencies — uses the browser's built-in WebCrypto. This gives one-time-payment schools *provable* backup integrity, a feature usually reserved for enterprise systems.

### 2. 🛡️ Platform Health Console — `platform-health.html` (new page)
A single owner cockpit answering the question every proprietor asks: *"Is my portal okay?"*
- **Keep-Alive tile:** live `sc_heartbeat` status — last ping age, source layer, total pings; warns before the 7-day pause window.
- **Database Space tile:** `storage_health()` gauge against the 500 MB free tier with links to the Archive Vault.
- **Google Drive tile:** configured? auto-sync schedule? last backup overdue?
- **License tile:** proudly shows "Lifetime license — no recurring fees ✓".
- **Security Controls:** idle auto-lock minutes + emergency lockdown switch + lockdown message (owner-only, saved school-wide).
- **Login audit viewer:** last 25 sign-in/sign-out/idle-lock events with device info.
Linked from Admin Data and Storage Manager; emitted by the generator on every client site.

### 3. 🔐 Runtime security layer — `security-guard.js` (new, loaded on every page)
| Feature | What it does | Why it matters for the audience |
|---|---|---|
| **Idle session auto-lock** | Signs out after N idle minutes (default 30; 0 = off) | School computers are shared: staff room, front desk, ICT lab. An abandoned admin session can no longer expose results/fees |
| **Login audit trail** | Feeds the (previously dormant) `login_audit` table on every sign-in/sign-out/idle-lock, deduplicated across token refreshes | Accountability: "who accessed the portal and when" — demanded by proprietors after any incident |
| **Emergency lockdown** | One owner switch instantly locks out all non-admin roles with a professional notice; admins keep working | Exam-leak investigations, fee fraud, compromised accounts — the school reacts in seconds without calling a developer |
| **Password strength meter** | Live strength bar on password fields, flags common weak choices | Weakest link in school deployments is weak passwords; zero-cost mitigation |
Settings live in `school_settings` (new `database/security-hardening.sql`, embedded in `complete-schema.sql`) so one change applies to every device. Everything fails safe: if a column or table is missing, features quietly disable instead of breaking pages.

## Complete data-sovereignty stack (after V5.9 + V6.0)

| Layer | Copy lives in | Sealed? | Automated? |
|---|---|---|---|
| Supabase database (live) | Supabase 500 MB | — | — |
| Archive Vault | Supabase File Storage 1 GB | ✅ SHA-256 | manual, guided |
| Local JSON/CSV exports | School's computer | ✅ SHA-256 | manual |
| **Google Drive Backup & Sync** | **School's own Drive (15 GB)** | ✅ SHA-256 | ✅ scheduled |
| Keep-alive (4 layers) | — | — | ✅ fully automated |

## Upgrading an existing deployment
1. Deploy the updated site files (new/changed: `security-guard.js`, `data-portability.js`, `app.js`, `platform-health.html`, `admin-data.html`, `storage.html`, `sw.js`).
2. Run once in the Supabase SQL Editor: `database/security-hardening.sql` (new installs of `complete-schema.sql` already include it).
3. Open **Platform Health Console** → confirm all four tiles are green → set the idle-lock minutes → done.
