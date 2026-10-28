# School Connect V5.8 — Deployment and Upgrade Guide

> **V5.7:** run only the updated complete schema. It installs institutional signatories, public exam campaigns/RPCs, report comment bands and role boundaries. Then deploy every file and hard-refresh. Frontend-only deployment is insufficient.

> **V5.8:** the updated complete schema is mandatory for persistent deletion, configured ID generation, retention RPCs and the embedded-media guard.

## A. Fresh production deployment (GOSA or another client)

1. **Use the correct folder.** Deploy the contents of `generated-sites/gosa` for GOSA, or generate a new client ZIP from `school-connect-generator/builder.html`.
2. **Create a free Supabase project.** Record the Project URL and **anon public** key. Never put the service-role key in a browser file.
3. **Install the database once.** Supabase → SQL Editor → New query → paste all of `database/complete-schema.sql` → Run. Wait for the final V5.6.1 self-sufficiency success row.
4. **Create the first administrator.** Authentication → Users → Add user, auto-confirm. Then set the matching `profiles.role` to `admin`/`super_admin` and `status` to `approved` in SQL/Table Editor. Do not expose an admin password in Git.
5. **Configure the portal.** Edit `assets/js/config.js`: set `SUPABASE_URL`, `SUPABASE_ANON_KEY`, school identity, correct `siteUrl` and logo extension. Keep the existing public anon key only if this is the intended project.
6. **Confirm RLS.** In Table Editor, verify RLS is enabled. Test a student and parent account before adding real records.
7. **Deploy static files.** See hosting recipes below.
8. **Smoke test:** login/approval, add a class/student/subject, enter report scores, print all four sample-matched documents, create a two-subject CBT, answer one text-key and one letter-key question, submit and verify the nonzero server score.
9. **Production readiness:** replace synthetic content, configure school settings/signatures, review roles, publish privacy/retention policies and make a database backup.

Do **not** run `demo-seed.sql` on a real school database.

## B. Existing deployment upgrade (complete V5.6.1)

**Use one SQL path for every existing deployment.** Back up Supabase and run the
entire updated `database/complete-schema.sql`. It includes all V5.1–V5.6.1 repairs:
CBT scoring/getters, open multi-subject identity, report integrity, recovery support,
timetables, metrics, daily fees, controlled result reset and strict teacher RLS.
It is safe to re-run and ends with a self-sufficiency check.

Do not run `cbt-v5.1-*` or any `v5.x-*.sql` afterward. Those files are historical
focused references and are already folded into the complete schema. The only extra
SQL allowed is `demo-users.sql` + `demo-seed.sql` in a separate demo project.
1. Supabase → Database → Backups/export: create a restorable backup. Export `cbt_exams`, `cbt_results`, `assessment_columns`, `report_scores`, `results`, payments and identities.
2. Put the site in a short maintenance window; do not begin an examination during the database upgrade.
3. Run the full new `database/complete-schema.sql` for V5.6.1. Do not run any focused/versioned pack afterward. Wait for the exact final success row: `School Connect V5.6.1 complete cumulative schema installed successfully ✅ — no other production SQL is required`.
4. Confirm SQL functions exist:
   ```sql
   select routine_name from information_schema.routines
   where routine_schema='public'
     and routine_name in ('cbt_get_public_exam_v6','cbt_submit_v6','cbt_diagnose_exam','cbt_repair_exam_scoring','sc_cbt_answer_matches','cbt_clear_exam_results','teacher_can_manage_subject_class','teacher_can_manage_student','generate_timetable','cbt_import_backup');
   ```
5. Deploy all updated files, especially the critical list in `BUG-FIX-REPORT.md`. Do not deploy only `cbt-engine.js`.
6. Supabase Authentication → URL Configuration: set the production Site URL and add `https://YOUR-DOMAIN/change-password.html?recovery=1` to Redirect URLs so password-recovery emails return safely.
7. Wait for hosting deployment completion. The new service-worker literal purges the former cache. On a test device, close all portal tabs, reopen and perform one hard refresh.
8. Create a disposable exam whose correct answers mix `B`, exact option text, `True`, numeric tolerance and multi-select. Submit and inspect `cbt_results.score`, `total`, `percent`, counts and `subject_scores`.
9. For old multi-subject exams, open CBT Manager → **Repair Tabs**. Verify each subject and count. Then open the candidate page with an **open** multi-subject code and no admission number; it must load without `record "s" is not assigned yet`. Candidate reload is network-first.
10. In Fees, compare today, the previous day and month-to-date; export the selected-day CSV and reconcile it with the ledger.
11. As the exam creator/admin, export then clear a disposable exam and confirm another teacher is denied; remember that official `report_scores` are intentionally not deleted.
12. Test a teacher’s assigned subject/class and an unassigned subject/class. Confirm the first succeeds, the second is denied, and admin still has full access.
13. Reopen normal operations only after report/receipt, CBT reset and role-scope smoke tests pass.

## C. Demo deployment

1. Create a separate free Supabase project—never reuse production.
2. Run `database/complete-schema.sql`.
3. Authentication → Users → Add user five times using the accounts in `demo-site/DEMO-SETUP.md`; enable Auto Confirm.
4. Run `database/demo-users.sql` to adopt/approve the profiles.
5. Run `database/demo-seed.sql`. The former `alumni.occupation`, numeric `amount` and ambiguous `exam_id` failures are fixed. The executed test runs the seed twice.
6. Configure the demo project URL/anon key in `assets/js/config.js` and set `siteUrl=https://schoolconnectdemo.vercel.app` (or your actual host).
7. Deploy and test all five roles. Use `DEMO-UTME` to demonstrate subject tabs.
8. Schedule manual periodic reset/backup. Free tools do not provide an unlimited automatic reset service.

## D. Vercel (recommended for the supplied repos)

1. Push the selected folder to its own GitHub repository.
2. Vercel → Add New → Project → import repository.
3. Framework preset: **Other**. Build command: leave empty. Output directory: `.`. Install command: leave empty.
4. Deploy. `vercel.json` applies security and no-stale-JS headers.
5. Add the custom domain; update `siteUrl`, `robots.txt`, `sitemap.xml` and redeploy.
6. Do not put Supabase service secrets in Vercel client environment variables. This static build needs only public values in `config.js`.

## E. Cloudflare Pages / Netlify

- Connect the repository, no build command, output directory `.`.
- `_headers` applies CSP/security and revalidation controls on Cloudflare/Netlify-compatible hosting.
- If the host rejects `_headers`, configure equivalent headers in its dashboard.

## F. GitHub Pages

1. Repository Settings → Pages → Deploy from branch → `main` / root.
2. The generator uses relative PWA paths, so project subpaths work.
3. GitHub Pages ignores `_headers`; use it only for a non-sensitive demo or front it with Cloudflare for headers.
4. Ensure `.nojekyll` exists in freshly generated ZIPs.

## G. Modern build

1. In builder choose **Modern full-stack delivery** and generate.
2. Extract ZIP → `modern/`.
3. `cp .env.example .env.local`; fill only `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` if using the Next helper.
4. Run `npm install`, `npm run build`, `npm start`.
5. Deploy `modern/` as the Vercel project root.
6. The complete static portal is in `modern/public`; `/` redirects to `/index.html`. Health endpoint: `/api/health`.
7. `modern/database/tenant-schema.sql` is a future control-plane scaffold. Do not run it as a claim of completed shared tenancy.

## H. Rollback

1. Restore the previous hosting deployment from Vercel/Cloudflare history.
2. Restore the pre-upgrade database backup if the schema execution failed partway or data changed unexpectedly.
3. Do not restore only the old frontend while retaining partially upgraded SQL without testing RPC compatibility.
4. Record the error, browser console, Supabase Logs request ID, exam code (not answer keys) and timestamp.

## I. Required acceptance checklist

- [ ] No console syntax errors.
- [ ] `complete-schema.sql` final V5.6.1 self-sufficiency status is visible.
- [ ] Admin, teacher, parent, student and bursar scope tested.
- [ ] Correct CBT answers produce nonzero marks.
- [ ] Randomised questions grade by original index.
- [ ] Open multi-subject exam loads with no admission number and no unassigned-record error.
- [ ] Multi-subject tabs switch both ways and retain answers.
- [ ] School logo/name/motto/contact appear on exam page.
- [ ] Report card, class broadsheet, subject broadsheet and receipt visually match samples.
- [ ] Demo seed completes; the audit reports 80/80 CRUD modules plus 16 specialised datasets.
- [ ] Selected-day fee total/ledger/CSV reconcile; previous-day and month-to-date totals load.
- [ ] CBT export-then-clear works for owner/admin and is denied to a non-owner.
- [ ] Assigned teacher writes succeed; foreign subject/class writes fail; admin override succeeds.
- [ ] PWA update removes old cached runtime.
- [ ] No service-role key or real student data is committed.
