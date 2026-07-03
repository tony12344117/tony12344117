# SalaryByCity.com

Programmatic SEO site: U.S. salary data by occupation × state. Built with
**Astro v5** (fully static), **TailwindCSS v4**, deployed to **Cloudflare Workers**
(static assets).

## Status

- [x] **Phase 1** — Astro project setup, folder structure, Cloudflare Workers config
- [x] **Phase 2** — Sample templates: 10 occupations × 5 states = 50 salary pages
- [ ] **Phase 3** — BLS OEWS data pipeline → scale to 50 × 50 = 2,500 pages
- [ ] **Phase 4** — AdSense policy pages (About, Salary Methodology, Privacy, Terms, Contact)
- [ ] **Phase 5** — Final sitemap/robots review (sitemap + robots.txt already wired)

## Commands

```bash
npm install
npm run dev        # local dev server
npm run build      # static build → dist/ (54 pages currently)
npm run preview    # preview the built site
npm run deploy     # astro build && wrangler deploy (Cloudflare Workers)
```

## Architecture

```
src/
  data/
    occupations.json   # occupation master data (national percentile wages, SOC codes)
    states.json        # state master data (wage factors, COL index, taxes, cities)
  lib/
    salary.ts          # ALL page logic: wage math, copy/FAQ/meta generation, JSON-LD
  components/          # PercentileChart, ComparisonTable, RelatedJobs, FaqSection, ...
  layouts/BaseLayout.astro
  pages/
    salary/[occupation]/[state].astro   # 1 template → every salary page
    jobs/index.astro                    # occupation directory
    states/index.astro                  # state directory
    index.astro / 404.astro
```

### How pages are generated

Every salary page is prerendered at build time from the two JSON files.
`getStaticPaths()` produces the occupation × state matrix, and `src/lib/salary.ts`
derives everything else deterministically:

- **Wages** — national percentile wages × per-state occupation factor
  (`occupationFactors[slug]`, falling back to the state-wide `salaryFactor`).
- **Body copy** — 5 sections (~350–400 words) assembled from template variants
  selected by a hash of `occupation|state`, so phrasing varies across pages
  while numbers stay data-driven.
- **SEO** — unique title + meta description per page, `Occupation` +
  `FAQPage` + `BreadcrumbList` JSON-LD, canonical URLs, sitemap via
  `@astrojs/sitemap` (referenced from `public/robots.txt`).

### Scaling to 2,500 pages (Phase 3)

The template needs **zero changes** to scale — only the JSON grows. The planned
pipeline (a `scripts/fetch-bls.ts` build step) will pull OEWS state × occupation
wage tables from the BLS public API, normalize them into the same
`occupations.json` / `states.json` shape (real per-state percentiles can replace
the factor model by writing exact values into `occupationFactors`), and the
build fans out to 50 × 50 automatically.

## Data disclaimer

Current sample figures are **modeled on** BLS OEWS statistics (May 2024 vintage,
adjusted to 2026) — realistic but hand-curated for template development. Phase 3
replaces them with API-sourced values.
