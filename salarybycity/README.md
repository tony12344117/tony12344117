# SalaryByCity.com

Programmatic SEO site: U.S. salary data by occupation × state. Built with
**Astro v5** (fully static), **TailwindCSS v4**, deployed to **Cloudflare Workers**
(static assets).

## Status

- [x] **Phase 1** — Astro project setup, folder structure, Cloudflare Workers config
- [x] **Phase 2** — Sample templates: 10 occupations × 5 states = 50 salary pages
- [x] **Phase 3** — Scaled to 50 × 50 = 2,500 salary pages (+100 hub pages); BLS API
  pipeline in `scripts/fetch-bls.mjs` (needs a free `BLS_API_KEY` to pull exact values)
- [x] **Phase 4** — AdSense policy pages (About, Salary Methodology, Privacy, Terms, Contact)
- [x] **Phase 5** — sitemap.xml (2,600+ URLs) + robots.txt

Build: **2,609 pages in ~7s**, dist ≈ 73 MB.

## Commands

```bash
npm install
npm run dev        # local dev server
npm run build      # static build → dist/ (2,609 pages, ~7s)
npm run preview    # preview the built site
npm run deploy     # astro build && wrangler deploy (Cloudflare Workers)
npm run fetch-data # pull real BLS OEWS data (requires BLS_API_KEY, see below)
```

## Refreshing data from the BLS API

1. Register a free key (~1 minute): <https://data.bls.gov/registrationEngine/> —
   enter an email, the key arrives by mail.
2. `export BLS_API_KEY=<your key>` (or put it in `.env`; it's gitignored).
3. `npm run fetch-data` — fetches ~15,300 series in ~306 batched requests
   (fits in one day's registered quota of 500), with 250ms pacing, exponential
   backoff on rate limits, and response caching in `scripts/.cache/` so re-runs
   never re-fetch. Exact state×occupation percentiles are written into
   `states.json` as `stateWages`; suppressed BLS cells fall back to the factor
   model automatically.
4. `npm run build` — bakes the refreshed JSON into all pages.

Builds never call the API — only `fetch-data` does, on demand.

## Architecture

```
scripts/
  fetch-bls.mjs        # BLS OEWS API pipeline (rate-limited, cached, resumable)
src/
  data/
    occupations.json   # 50 occupations (national percentile wages, SOC codes)
    states.json        # 50 states (FIPS, wage factors, COL index, taxes, neighbors)
  lib/
    salary.ts          # ALL page logic: wage math, copy/FAQ/meta generation, JSON-LD
  components/          # PercentileChart, ComparisonTable, RelatedJobs, FaqSection, ...
  layouts/BaseLayout.astro
  pages/
    salary/[occupation]/[state].astro   # 1 template → 2,500 salary pages
    salary/[occupation]/index.astro     # 50 occupation hubs (salary by state table)
    states/[state].astro                # 50 state hubs (salary by occupation table)
    jobs/index.astro                    # occupation directory
    states/index.astro                  # state directory
    about / methodology / privacy / terms / contact  # AdSense policy pages
    index.astro / 404.astro
```

### How pages are generated

Every salary page is prerendered at build time from the two JSON files.
`getStaticPaths()` produces the occupation × state matrix, and `src/lib/salary.ts`
derives everything else deterministically:

- **Wages** — exact BLS percentiles (`stateWages`, written by the fetch script)
  when available; otherwise national percentiles × the factor model
  (`occupationFactors[slug]` → `salaryFactor × categoryFactors[category]`).
- **Body copy** — 5 sections (~350–400 words) assembled from template variants
  selected by a hash of `occupation|state`, so phrasing varies across pages
  while numbers stay data-driven.
- **SEO** — unique title + meta description per page, `Occupation` +
  `FAQPage` + `BreadcrumbList` JSON-LD, canonical URLs, sitemap via
  `@astrojs/sitemap` (referenced from `public/robots.txt`).

## Data disclaimer

Current figures are **modeled on** BLS OEWS statistics (May 2024 vintage,
adjusted to 2026): real national percentile distributions per occupation,
adjusted per state by a curated factor model. Running `npm run fetch-data` with
a `BLS_API_KEY` replaces the modeled state values with exact per-cell BLS
percentiles (`stateWages`); BLS-suppressed cells keep the factor fallback. The
public methodology page (`/methodology/`) describes exactly this behavior.
