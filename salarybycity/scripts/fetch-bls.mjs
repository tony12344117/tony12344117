#!/usr/bin/env node
/**
 * fetch-bls.mjs — pulls real OEWS wage data from the BLS Public Data API v2
 * and bakes it into src/data/occupations.json + src/data/states.json.
 *
 * Usage:
 *   BLS_API_KEY=xxxx node scripts/fetch-bls.mjs           # fetch + write
 *   BLS_API_KEY=xxxx node scripts/fetch-bls.mjs --dry-run # fetch + report only
 *   node scripts/fetch-bls.mjs --from-cache               # rebuild JSON from cache, no network
 *
 * Getting a key (free, ~1 minute):
 *   1. Open https://data.bls.gov/registrationEngine/
 *   2. Enter your email + organization, submit — the key arrives by email.
 *   3. export BLS_API_KEY=<key>  (or put it in .env, which is gitignored)
 *
 * Why a key matters: unregistered v2 access allows 25 requests/day with 25
 * series each (max 625 series/day). This script needs 50 occupations × 50
 * states × 6 series = 15,000 state series + 300 national series, i.e. ~306
 * requests at the registered limits (500/day, 50 series/request) — one run
 * fits comfortably in a single day's registered quota, but not unregistered.
 *
 * Design:
 *   - Batches of 50 series per POST (the registered maximum).
 *   - Rate-limit handling: 250ms pacing between requests, plus exponential
 *     backoff (2s/4s/8s/16s) on HTTP 429/5xx and on BLS "REQUEST_NOT_PROCESSED".
 *   - Every successful batch response is cached in scripts/.cache/ keyed by a
 *     hash of the series list, so re-runs (or --from-cache) never re-fetch
 *     data they already have. Builds NEVER hit the API — only this script does.
 *   - OEWS suppression handling: BLS withholds some state×occupation cells
 *     ("-") and top-codes very high wages ("#" ≈ $239,200+). Suppressed cells
 *     fall back to the modeled factor estimate already in the JSON; top-coded
 *     percentiles are written as the top-code threshold.
 *
 * OEWS series ID anatomy (25 chars), e.g. OEUS480000000000015125213:
 *   OE            prefix
 *   U             not seasonally adjusted
 *   S | N         area type: S = statewide, N = national
 *   SS00000       area code (state FIPS + 00000; 0000000 national)
 *   000000        industry code (cross-industry total)
 *   151252        SOC occupation code, no dot
 *   01..15        data type (01 employment, 11..15 annual 10/25/50/75/90 pct)
 */

import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const CACHE_DIR = join(ROOT, 'scripts', '.cache');
const OCC_PATH = join(ROOT, 'src', 'data', 'occupations.json');
const STATE_PATH = join(ROOT, 'src', 'data', 'states.json');

const API_URL = 'https://api.bls.gov/publicAPI/v2/timeseries/data/';
const API_KEY = process.env.BLS_API_KEY ?? '';
const DRY_RUN = process.argv.includes('--dry-run');
const FROM_CACHE = process.argv.includes('--from-cache');
const BATCH_SIZE = API_KEY ? 50 : 25;
const PACE_MS = 250;
const TOP_CODE_ANNUAL = 239200; // BLS annual wage top-code threshold ("#")

// Annual wage percentile data type codes.
const DATA_TYPES = { 11: 'p10', 12: 'p25', 13: 'median', 14: 'p75', 15: 'p90' };
const EMPLOYMENT_TYPE = '01';

const occupations = JSON.parse(readFileSync(OCC_PATH, 'utf8'));
const states = JSON.parse(readFileSync(STATE_PATH, 'utf8'));

const missingFips = states.filter((s) => !s.fips);
if (missingFips.length) {
  console.error('states.json entries missing "fips":', missingFips.map((s) => s.slug).join(', '));
  process.exit(1);
}

/* ------------------------------------------------------------------ */
/* Series ID construction                                              */
/* ------------------------------------------------------------------ */

const soc = (occ) => occ.socCode.replace('-', '');

function stateSeries(occ, state) {
  const area = `${state.fips}00000`;
  return [...Object.keys(DATA_TYPES), EMPLOYMENT_TYPE].map(
    (dt) => `OEUS${area}000000${soc(occ)}${dt}`,
  );
}

function nationalSeries(occ) {
  return [...Object.keys(DATA_TYPES), EMPLOYMENT_TYPE].map(
    (dt) => `OEUN0000000000000${soc(occ)}${dt}`,
  );
}

/* ------------------------------------------------------------------ */
/* Fetch with caching, pacing, and backoff                             */
/* ------------------------------------------------------------------ */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function cachePath(seriesIds) {
  const hash = createHash('sha256').update(seriesIds.join(',')).digest('hex').slice(0, 16);
  return join(CACHE_DIR, `bls-${hash}.json`);
}

async function fetchBatch(seriesIds) {
  const cached = cachePath(seriesIds);
  if (existsSync(cached)) {
    return JSON.parse(readFileSync(cached, 'utf8'));
  }
  if (FROM_CACHE) {
    console.warn(`  cache miss (skipped, --from-cache): ${seriesIds.length} series`);
    return null;
  }

  const body = JSON.stringify({
    seriesid: seriesIds,
    // OEWS is an annual snapshot; latest=true returns the newest vintage.
    latest: true,
    ...(API_KEY ? { registrationkey: API_KEY } : {}),
  });

  const backoffs = [2000, 4000, 8000, 16000];
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(API_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    }).catch((err) => ({ ok: false, status: 0, statusText: String(err) }));

    if (res.ok) {
      const json = await res.json();
      if (json.status === 'REQUEST_SUCCEEDED') {
        mkdirSync(CACHE_DIR, { recursive: true });
        writeFileSync(cached, JSON.stringify(json));
        return json;
      }
      // Daily quota exhausted is not retryable — fail loudly with guidance.
      const msg = (json.message ?? []).join(' | ');
      if (/threshold|daily/i.test(msg)) {
        throw new Error(`BLS daily quota exhausted: ${msg}\nRe-run tomorrow — completed batches are cached and will not be re-fetched.`);
      }
      if (attempt >= backoffs.length) throw new Error(`BLS API kept failing: ${msg}`);
      console.warn(`  BLS ${json.status} (${msg}) — retrying in ${backoffs[attempt] / 1000}s`);
    } else {
      if (attempt >= backoffs.length) {
        throw new Error(`HTTP ${res.status} ${res.statusText} after ${attempt} retries`);
      }
      console.warn(`  HTTP ${res.status} — retrying in ${backoffs[attempt] / 1000}s`);
    }
    await sleep(backoffs[attempt]);
  }
}

/* ------------------------------------------------------------------ */
/* Value parsing                                                       */
/* ------------------------------------------------------------------ */

function parseValue(series) {
  const point = series.data?.[0];
  if (!point) return null;
  const v = point.value;
  if (v === '-' || v === '' || v == null) return null; // suppressed
  if (v === '#') return TOP_CODE_ANNUAL; // top-coded
  const n = Number(String(v).replace(/,/g, ''));
  return Number.isFinite(n) ? n : null;
}

function indexResults(json, into) {
  for (const series of json?.Results?.series ?? []) {
    into.set(series.seriesID, parseValue(series));
  }
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

async function main() {
  if (!API_KEY && !FROM_CACHE) {
    console.warn(
      'WARNING: BLS_API_KEY is not set. Unregistered access is limited to 25 requests/day\n' +
        'of 25 series each — a full refresh will NOT fit. Register a free key at\n' +
        'https://data.bls.gov/registrationEngine/ and export BLS_API_KEY=<key>.\n',
    );
  }

  // Build the full series list: national first (used for fallback factors).
  const allSeries = [];
  for (const occ of occupations) allSeries.push(...nationalSeries(occ));
  for (const occ of occupations) for (const st of states) allSeries.push(...stateSeries(occ, st));

  const batches = [];
  for (let i = 0; i < allSeries.length; i += BATCH_SIZE) {
    batches.push(allSeries.slice(i, i + BATCH_SIZE));
  }
  console.log(
    `Fetching ${allSeries.length} series in ${batches.length} batches of ≤${BATCH_SIZE}` +
      (API_KEY ? ' (registered key)' : ' (UNREGISTERED)'),
  );

  const values = new Map();
  let done = 0;
  for (const batch of batches) {
    const json = await fetchBatch(batch);
    if (json) indexResults(json, values);
    done++;
    if (done % 25 === 0 || done === batches.length) {
      console.log(`  ${done}/${batches.length} batches`);
    }
    if (!FROM_CACHE) await sleep(PACE_MS);
  }

  /* ---- write occupations.json national percentiles ---- */
  let natUpdated = 0;
  for (const occ of occupations) {
    const ids = nationalSeries(occ);
    const pct = {};
    for (const id of ids) {
      const dt = id.slice(-2);
      if (DATA_TYPES[dt]) pct[DATA_TYPES[dt]] = values.get(id) ?? null;
    }
    const emp = values.get(ids[ids.length - 1]);
    if (Object.values(pct).every((v) => v != null)) {
      occ.national = pct;
      natUpdated++;
    }
    if (emp != null) occ.employmentNational = emp;
  }

  /* ---- write per-state exact percentiles into stateWages ---- */
  let cells = 0;
  let suppressed = 0;
  for (const st of states) {
    st.stateWages = st.stateWages ?? {};
    for (const occ of occupations) {
      const ids = stateSeries(occ, st);
      const pct = {};
      for (const id of ids) {
        const dt = id.slice(-2);
        if (DATA_TYPES[dt]) pct[DATA_TYPES[dt]] = values.get(id) ?? null;
      }
      if (Object.values(pct).every((v) => v != null)) {
        st.stateWages[occ.slug] = pct;
        cells++;
      } else {
        // Suppressed cell: leave it out — the site falls back to the
        // factor model (occupationFactors / categoryFactors / salaryFactor).
        delete st.stateWages[occ.slug];
        suppressed++;
      }
    }
  }

  console.log(`\nNational percentiles updated: ${natUpdated}/${occupations.length} occupations`);
  console.log(`State×occupation cells with exact BLS data: ${cells}`);
  console.log(`Suppressed/missing cells falling back to factor model: ${suppressed}`);

  if (DRY_RUN) {
    console.log('\n--dry-run: not writing JSON.');
    return;
  }
  writeFileSync(OCC_PATH, JSON.stringify(occupations, null, 2) + '\n');
  writeFileSync(STATE_PATH, JSON.stringify(states, null, 2) + '\n');
  console.log(`\nWrote ${OCC_PATH}\nWrote ${STATE_PATH}\nRun \`npm run build\` to bake the pages.`);
}

main().catch((err) => {
  console.error('\nFATAL:', err.message);
  process.exit(1);
});
