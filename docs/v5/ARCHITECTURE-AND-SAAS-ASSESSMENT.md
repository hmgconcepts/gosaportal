# Architecture, Full-Stack and SaaS Assessment

## Is School Connect full stack?

**Yes, when deployed with Supabase.** The browser/PWA is the presentation tier; Supabase Auth is identity; PostgreSQL tables/functions/triggers are business/data tiers; RLS is the authorisation boundary. “Traditional” means no custom Node server—not “frontend only.”

Without configured Supabase credentials/schema it is only an offline/static preview and cannot be called a working full-stack deployment.

## Is it a SaaS platform?

There are two meanings:

1. **Managed per-school SaaS delivery:** yes. HMG can generate, host, onboard and support an isolated deployment for each client. This is the recommended model on free tiers.
2. **One shared database/application serving many tenant schools:** not yet complete. A few tables carry `school_id`, but the entire 97-module data model is not consistently tenant-keyed and tenant-RLS-tested. The optional Next tenant files are a scaffold, not a finished control plane.

The package now states this accurately rather than overclaiming.

## Recommended free-tier architecture

- One GitHub repository + Vercel/Cloudflare project per school.
- One Supabase project per school where feasible.
- Public anon key in the browser; RLS enabled; no service-role browser key.
- Separate demo and production projects.
- Browser print/PDF, device-native messaging links and Drive/direct links to limit paid dependencies.

This maximises isolation and makes backup/deletion requests school-specific. Trade-offs are more deployments to maintain and free-project quotas/pausing.

## Traditional delivery

- Static HTML/CSS/JS/PWA.
- Full Supabase schema/RLS/RPC backend.
- 183 verified generated entries.
- No compile step; works on Vercel, Cloudflare Pages, Netlify and GitHub Pages.
- Best fit for schools needing low cost and transparent ownership.

## Modern delivery

- Complete traditional portal copied under `modern/public` after all assets exist.
- Next.js app router, health API, tenant-host parser, browser Supabase helper and security middleware.
- 387 verified entries.
- Useful for future server APIs, managed routing and a control plane.
- It does not move existing browser business logic to React automatically; that would be a planned migration, not a ZIP checkbox.

## Enterprise capabilities now strengthened

- Server-authoritative CBT scoring and per-subject result breakdown.
- Idempotent submissions, retry queue, offline backup export and original-index grading.
- UTME tabs and retroactive bank repair.
- Role/status governance, family scope, audit tables and RLS.
- Sample-matched official outputs and database-authoritative fee balances.
- Inventory audit fields, admissions, HR/payroll, support, facilities, compliance and analytics data.
- Cache/version controls, security headers, integrity auditing and repeatable build verification.

## Before shared multi-tenant SaaS

A future version needs all of the following:

1. Mandatory `tenant_id` on every tenant-owned table and storage object.
2. Membership/role tables and tenant derived from authenticated membership—not untrusted host/query values.
3. RLS tests proving cross-tenant denial for every table/RPC/view.
4. Tenant-aware unique constraints, functions, triggers, realtime topics, exports and background jobs.
5. Subscription/billing provider, entitlement enforcement and audit-safe administrator override.
6. Control-plane onboarding, domain verification, backup/restore, observability, incident response and data deletion.
7. Migration plan from existing per-school projects.
8. Legal/privacy terms and Nigerian NDPA/other applicable compliance review.

Until then, isolated per-school projects are the safer enterprise architecture.

## Capacity statement

The code includes indexes, lean exam fetches and idempotent writes, but no honest audit can guarantee 1,000 simultaneous candidates on an unspecified free Supabase project/network. Conduct a realistic load rehearsal, check current provider quotas, coordinate school Wi-Fi/power, stagger starts if needed and retain offline recovery procedures.
