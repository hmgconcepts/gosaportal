# School Connect V5 — Technical Analysis

## Systems reviewed

- Generator: <https://hmgschoolconnect.vercel.app> / `hmgconcepts/schoolconnect`
- Generated client: <https://gosasite.vercel.app> / `hmgconcepts/gosa`
- Prospective-client demo: <https://schoolconnectdemo.vercel.app> / `hmgconcepts/schoolconnectdemo`

The repositories were downloaded at the commit hashes recorded in the separate original-source archives. The deployed pages matched the downloaded critical CBT assets at the time of review.

## What the product is

School Connect is a configurable school operations platform and browser ZIP generator. The generator gathers a school’s identity, theme, modules, deployment type and optional Supabase public configuration, then emits a branded portal. The portal covers student/staff records, academics, CBT, report cards, fees, communications, HR, admissions, facilities and enterprise operations.

It is not an AI-dependent application. The frontend is static HTML/CSS/JavaScript/PWA. The backend is Supabase: PostgreSQL, Auth, Row-Level Security, SQL functions and optional realtime/browser-push facilities. Browser print supplies PDF output. Google Drive/direct links can avoid paid file storage.

## Repository architecture

### Generator

- `builder.html`, `wizard.js`, `catalog.js`: configuration UI and 97-module catalogue.
- `generator.js`: in-browser JSZip build pipeline, traditional and modern output, branding, SQL packaging and integrity audit.
- `templates.js` plus `assets/templates/pages/`: generic shell and rich page templates.
- Root HTML files: field-tested reference pages.
- `complete-schema.sql`: dependency-ordered fresh install plus cumulative repair sections.
- `demo-seed.sql` / `demo-users.sql`: synthetic showcase data and guest-profile adoption.

### Generated sites

- Static role-aware portal pages.
- `assets/js/config.js`: school identity and public Supabase URL/anon key.
- Shared operational engines: `app.js`, `crud.js`, `cbt-engine.js`, `report-engine.js`, notification, voting and enterprise helpers.
- Supabase is the data/security authority; the anon key is intentionally public, while RLS restricts rows.
- `sw.js` + `manifest.json`: installable PWA and offline fallback.

## Core data flows

1. **Authentication:** Supabase Auth session → profile role/status → page navigation guard → RLS policy.
2. **Academic:** setup/lookups → students/classes/subjects → subject score entry → `report_scores` → report engine → student report/class broadsheet/subject broadsheet.
3. **CBT:** private server question bank → public RPC strips answer keys → candidate UI → answer payload carrying original indexes → server-authoritative matcher → `cbt_results` and per-subject breakdown.
4. **Fees:** class fee structure → payment row → database balance trigger → sample-matched e-receipt → analytics.
5. **Communications:** records/announcements/messages/polls → in-app notifications and optional free device-native email, WhatsApp and SMS links.
6. **Demo:** five dashboard-created Auth users are adopted into approved profiles; the idempotent seed connects synthetic academic, fee, CBT and enterprise data.

## Security model

- Answer keys stay inside PostgreSQL; the public exam getter removes `answer`, `correct`, `correct_answer`, `correctAnswer`, `key` and explanations.
- Final marks are recalculated server-side; browser score fields are not trusted.
- RLS is enabled across operational tables and family pages apply an additional UI scope.
- Public RPCs expose only the narrow fields needed for examination/admission/certificate workflows.
- No service-role key belongs in `config.js` or any browser file.
- Static headers apply frame, MIME, referrer and browser-permission controls. JavaScript/service-worker caching is revalidated so security and grading fixes are not pinned indefinitely.

## Deployment models

- **Traditional:** static PWA + Supabase backend. It is a full-stack deployment in the BaaS sense and is the simplest free-tier production model.
- **Modern:** Next.js wrapper containing the complete portal under `modern/public`, health/tenant API scaffolds and Supabase browser support.
- **SaaS assessment:** the production data model is deliberately one school per generated deployment/Supabase project. This provides strong tenant isolation. The modern package includes an optional future control-plane scaffold, but it must not be marketed as a completed shared-database multi-tenant SaaS. See `ARCHITECTURE-AND-SAAS-ASSESSMENT.md`.

## Scale and operational observations

- The CBT list avoids downloading full JSON question banks for every exam.
- Public exam reads are code-indexed, submissions are client-reference idempotent and original-index aware.
- Supabase free-tier quotas, connection limits, browser/device quality and internet reliability remain external constraints. A 1,000-candidate event requires load rehearsal, project quota review and staged network testing; code changes alone cannot guarantee third-party capacity.
- PWA offline support is resilience, not a substitute for a network during first exam load. Failed submissions are queued locally and can be downloaded for authorised recovery.
