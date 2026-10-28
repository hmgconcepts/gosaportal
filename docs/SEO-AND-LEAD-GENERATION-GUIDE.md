# 🔎 SEO & Lead-Generation Guide — Make Every School Site Searchable
**School Connect (HMG Concepts) · Step-by-step, using only free tools**

Goal: when anyone searches the school's name on Google/Bing, the **client site** (e.g. `https://gosaportal.vercel.app`) appears — and every school site quietly links back to the **HMG CONCEPTS Ecosystem** so each deployed school becomes a lead-generation channel.

## What is already built into every site (nothing to do)
- `robots.txt` welcoming crawlers (+ absolute sitemap URL) and `sitemap.xml` of the public pages.
- Meta titles/descriptions/keywords + Open Graph/Twitter cards on every page.
- **JSON-LD structured data** (`@type: School`) on the landing page with `sameAs` links to HMG Concepts, HMG Technologies and the 📢 HMG WhatsApp Channel — search engines learn the school AND its provider.
- An ecosystem footer on the landing page: *"Part of the HMG CONCEPTS Ecosystem …"* with follow links (search engines treat these as endorsement links to your ecosystem = lead-gen equity), plus the 📢 HMG Channel link in every page footer.
- The generator writes the school's real domain into all of this from the **Site URL** field in the builder — so **every future generated site is search-ready and ecosystem-linked out of the box**.

## One-time steps per school (~20 minutes total)

### Step 1 — Confirm the domain inside the site files (2 min)
When a site moves (e.g. gosasite → **gosaportal**.vercel.app), the repo must say so:
1. Check `robots.txt` ends with `Sitemap: https://gosaportal.vercel.app/sitemap.xml`.
2. Check `sitemap.xml` `<loc>` entries use `https://gosaportal.vercel.app/...`.
3. Push → Vercel redeploys. (Already done for GOSA in this release.)
4. If the old domain is still live, keep it as a Vercel *redirect*: Vercel → old project → Settings → Domains → add a redirect to the new domain (stops split indexing).

### Step 2 — Google Search Console (10 min) — this is what makes Google index you
1. Go to **search.google.com/search-console** → sign in with the HMG (or school) Google account.
2. **+ Add property** → choose **URL prefix** → enter `https://gosaportal.vercel.app` → Continue.
3. Verification: pick the **HTML tag** method → copy the `<meta name="google-site-verification" content="…">` tag → paste it inside `<head>` of `index.html` → push → back in Search Console click **Verify**. ✅
4. Left menu → **Sitemaps** → enter `sitemap.xml` → **Submit**. Status becomes "Success".
5. Top search bar → paste `https://gosaportal.vercel.app/` → **Request indexing**. Repeat for `about.html` and `apply.html` (your two best landing pages).
6. Expect the site in Google within **a few days to 2 weeks**. Track under **Performance**.

### Step 3 — Bing Webmaster Tools (5 min)
1. Go to **bing.com/webmasters** → sign in.
2. Easiest: **Import from Google Search Console** (one click imports the verified site + sitemap). Otherwise: Add site → verify with the HTML meta tag (same method as Google) → submit `sitemap.xml`.
3. Bing also feeds Yahoo/DuckDuckGo — one submission covers three engines.

### Step 4 — Turn on the lead-generation loop (5 min)
1. On the **HMG Concepts / HMG Technologies sites**, add each new school to a "Schools powered by us" page and link to `https://gosaportal.vercel.app` — backlinks in BOTH directions are what raise ranking for both sides.
2. Post the school's launch on the **📢 HMG WhatsApp Channel** (link + one screenshot).
3. Ask the school to link the portal from their social pages (Facebook page "Website" field, WhatsApp Business profile, Google Business Profile if they have one — that last one alone often wins the local "school near me" searches).
4. Optional but powerful: create a **Google Business Profile** for the school (business.google.com) with the portal URL — schools are local businesses; this puts them on Maps + local results within days.

### Step 5 — Verify it worked (after ~1–2 weeks)
- Search `site:gosaportal.vercel.app` on Google — pages listed = indexed.
- Search the school's exact name — the portal should appear (rank improves as backlinks/GBP mature).
- Search Console → Performance shows real queries people used — share these with the school; it's great marketing feedback.

## Domain-move checklist (what we did for GOSA, for future reference)
| Step | Action |
|---|---|
| 1 | Replace the old domain in `robots.txt`, `sitemap.xml`, canonicals/og:url in pages, `config.js` siteUrl ✅ (done in repo) |
| 2 | Deploy to the new Vercel project (`gosaportal`) |
| 3 | Old project → Settings → Domains → redirect old → new (or delete the old project) |
| 4 | Search Console: add the NEW property, verify, submit sitemap, request indexing |
| 5 | If the old property was verified, use Search Console → Settings → **Change of address** (tells Google explicitly) |

## For future generated sites (automatic)
The builder's **Site URL** field drives everything: sitemap, robots, canonical URLs, JSON-LD and the ecosystem links are generated pointing at that domain, with `sameAs`/provider links to HMG Concepts sites baked in. Your only manual work per client is Steps 2–4 above (~20 minutes) — a nice, billable "launch & be found on Google" service.

---
Maintained by HMG Concepts — School Connect Generator
