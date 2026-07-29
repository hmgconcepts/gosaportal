# Running a 500-Student / 30-Staff School on Supabase Free Tier
**Expert capacity guide — School Connect (HMG Concepts)**

## 1. The free-tier limits that actually matter to you

| Limit | Free tier | Your realistic usage (500 students + 30 staff) | Verdict |
|---|---|---|---|
| Database size | **500 MB** | ~40–120 MB/year of *pure data* (see §2) | ✅ Safe **if** you follow the retention routine |
| File storage | **1 GB** | Near zero (platform stores links, not files) — now also used by the Archive Vault | ✅ Plenty |
| Monthly active users (auth) | 50,000 | ≤ ~1,100 accounts (students+parents+staff) | ✅ Nowhere near the limit |
| Bandwidth (egress) | 5 GB/month | Text-only API responses; site assets served by Vercel, not Supabase | ✅ Fine for normal use |
| Edge function calls | 500k/month | Keep-alive pings only | ✅ Trivial |
| Inactivity pause | Pauses after ~7 idle days | Solved by the 4-layer keep-alive | ✅ Handled |
| Backups | **None on free tier** | — | ⚠️ **You must self-backup** (see §4) |
| Projects per org | 2 active free projects | 1 per school | ✅ OK |

## 2. What 500 students actually writes into the database

Text rows are tiny. Rough per-year arithmetic for a 500-student school:

- **Results/report scores:** 500 students × 12 subjects × 3 terms × ~6 score rows ≈ 108k rows ≈ **25–40 MB**
- **Attendance:** 500 × ~190 school days ≈ 95k rows ≈ **15–25 MB**
- **CBT attempts:** heavy usage ≈ 50–100k rows ≈ **20–40 MB**
- **Everything else** (fees, messages, notifications, logs) ≈ **10–30 MB**

So a *disciplined* year is roughly **70–135 MB — you fit 3–5 school years in 500 MB**, and far more once you use the Archive Vault + purge routine. The things that would kill you are **not** student records; they are:

1. **Embedded files/images pasted as base64** — one phone photo pasted as data-URL = ~3–8 MB, i.e. a thousand times bigger than a result row. *The schema now blocks this at database level* (`sc_prevent_embedded_media` trigger) — keep using Google Drive links.
2. **Unbounded logs** — `activity_log`, `login_audit`, `notifications`, check-in/clock tables grow forever if never pruned. This is what the Storage Manager's retention + vault + purge workflow is for.

## 3. What you SHOULD do (the safe-operation routine)

1. **Keep the "links only" policy.** Photos, documents, signatures → Google Drive links. Never paste base64/data-URLs (the DB now rejects them anyway).
2. **Once per term (10 minutes), open Storage Manager (`storage.html`):**
   - Click **Analyse health** — stay below the 75% warning line.
   - Click **List retention candidates** — see which log tables have eligible old rows.
   - **Archive Vault:** archive old rows of each candidate table into File Storage (1 GB side), confirm the archive appears in the list, then **Purge** the same table/days. Database shrinks; nothing is lost — every archive is restorable with one click.
3. **Once per term, export a full portable archive** (Admin Data page → full JSON export) and keep it on Google Drive **outside** Supabase. This is your backup — remember the free tier has none.
4. **End of session:** export + vault-archive the finished session's CBT results, check-ins and logs. Keep results/report_scores in the DB only for the years you actively reprint.
5. **Keep the 4 keep-alive layers active** (see `SUPABASE_FREE_TIER_PROTECTION.md`) and glance at UptimeRobot's green dot monthly.
6. **Watch the dashboard:** Supabase Dashboard → Settings → Usage shows official DB size. Check monthly.

## 4. What you should NOT do

- ❌ Don't upload or paste files/images into the database (blocked, but don't try workarounds).
- ❌ Don't purge without archiving/exporting first — free tier has **no backup to rescue you**.
- ❌ Don't run the demo seed SQL on a production school.
- ❌ Don't share or embed the `service_role` key anywhere — the site only ever needs the anon key.
- ❌ Don't create per-class or per-term duplicate projects "for space" — use the vault/purge routine instead (2 free projects max anyway).
- ❌ Don't set UptimeRobot to 5-minute pings on the edge function — 12–24 h is enough; save the function quota.
- ❌ Don't ignore the pause-warning emails Supabase sends — they mean a layer is misconfigured.

## 5. Honest expert verdict

For 500 students + 30 staff, the free tier is **operationally safe for years** *provided* the termly archive-and-purge routine and off-site JSON backups actually happen. The real risk on free tier is not capacity — it is **zero backups** and the pause/delete policy for idle projects. If the school's reports and fee records ever become mission-critical (they will), the professional recommendation is to budget the **Supabase Pro plan ($25/month)**: no pausing, 7-day automatic backups, 8 GB database. Until then, the routine above keeps you comfortably and safely within free limits.
