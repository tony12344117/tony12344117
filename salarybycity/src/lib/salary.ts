import occupationsData from '../data/occupations.json';
import statesData from '../data/states.json';

export const DATA_YEAR = 2026;
export const SOURCE_NOTE =
  'Modeled on U.S. Bureau of Labor Statistics (BLS) Occupational Employment and Wage Statistics (OEWS), adjusted to 2026.';

export interface Percentiles {
  p10: number;
  p25: number;
  median: number;
  p75: number;
  p90: number;
}

export interface Occupation {
  slug: string;
  title: string;
  plural: string;
  socCode: string;
  blsTitle: string;
  category: string;
  education: string;
  shortDesc: string;
  national: Percentiles;
  employmentNational: number;
  outlookNote: string;
  related: string[];
}

export interface StateInfo {
  slug: string;
  name: string;
  abbrev: string;
  region: string;
  population: number;
  salaryFactor: number;
  costOfLivingIndex: number;
  incomeTax: { hasIncomeTax: boolean; summary: string; note: string };
  topCities: string[];
  majorIndustries: string[];
  neighbors: string[];
  laborNote: string;
  occupationFactors: Record<string, number>;
}

export const occupations = occupationsData as Occupation[];
export const states = statesData as StateInfo[];

const occupationBySlug = new Map(occupations.map((o) => [o.slug, o]));
const stateBySlug = new Map(states.map((s) => [s.slug, s]));

export function getOccupation(slug: string): Occupation | undefined {
  return occupationBySlug.get(slug);
}

export function getState(slug: string): StateInfo | undefined {
  return stateBySlug.get(slug);
}

function stateFactor(occ: Occupation, state: StateInfo): number {
  return state.occupationFactors[occ.slug] ?? state.salaryFactor;
}

/** State-adjusted percentile wages, rounded to the nearest $10. */
export function getSalary(occ: Occupation, state: StateInfo): Percentiles {
  const f = stateFactor(occ, state);
  const adj = (v: number) => Math.round((v * f) / 10) * 10;
  return {
    p10: adj(occ.national.p10),
    p25: adj(occ.national.p25),
    median: adj(occ.national.median),
    p75: adj(occ.national.p75),
    p90: adj(occ.national.p90),
  };
}

export function fmtUSD(n: number): string {
  return '$' + Math.round(n).toLocaleString('en-US');
}

export function fmtCompact(n: number): string {
  return n >= 1000 ? '$' + Math.round(n / 1000) + 'K' : fmtUSD(n);
}

export function hourly(annual: number): string {
  return '$' + (annual / 2080).toFixed(2);
}

/** Signed percent difference vs national median, e.g. "+16%" / "−9%". */
export function pctVsNational(occ: Occupation, state: StateInfo): string {
  const pct = Math.round((stateFactor(occ, state) - 1) * 100);
  return pct >= 0 ? `+${pct}%` : `−${Math.abs(pct)}%`;
}

/** Median divided by cost-of-living index: what the salary buys locally. */
export function colAdjustedMedian(occ: Occupation, state: StateInfo): number {
  const s = getSalary(occ, state);
  return Math.round(s.median / (state.costOfLivingIndex / 100) / 10) * 10;
}

/**
 * Comparison states: geographic neighbors first (when present in the
 * dataset), topped up with the remaining highest-paying states so the
 * table always has 4 rows even in the sample dataset.
 */
export function getComparisonStates(occ: Occupation, state: StateInfo): StateInfo[] {
  const neighbors = state.neighbors
    .map((slug) => stateBySlug.get(slug))
    .filter((s): s is StateInfo => Boolean(s));
  const rest = states
    .filter((s) => s.slug !== state.slug && !neighbors.includes(s))
    .sort((a, b) => getSalary(occ, b).median - getSalary(occ, a).median);
  return [...neighbors, ...rest].slice(0, 4);
}

/** Related occupations: curated list first, then same-category fill, 3–4 total. */
export function getRelatedOccupations(occ: Occupation): Occupation[] {
  const curated = occ.related
    .map((slug) => occupationBySlug.get(slug))
    .filter((o): o is Occupation => Boolean(o));
  const sameCategory = occupations.filter(
    (o) => o.slug !== occ.slug && !curated.includes(o) && o.category === occ.category,
  );
  const rest = occupations.filter(
    (o) => o.slug !== occ.slug && !curated.includes(o) && !sameCategory.includes(o),
  );
  return [...curated, ...sameCategory, ...rest].slice(0, 4);
}

export function salaryPath(occSlug: string, stateSlug: string): string {
  return `/salary/${occSlug}/${stateSlug}/`;
}

/* ------------------------------------------------------------------ */
/* Deterministic template variation for programmatic uniqueness        */
/* ------------------------------------------------------------------ */

function hashCode(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (Math.imul(31, h) + s.charCodeAt(i)) | 0;
  }
  return Math.abs(h);
}

function pick<T>(variants: T[], seed: string): T {
  return variants[hashCode(seed) % variants.length]!;
}

/* ------------------------------------------------------------------ */
/* Page copy generation (~350+ words, unique per occupation × state)   */
/* ------------------------------------------------------------------ */

export interface ContentSection {
  heading: string;
  paragraphs: string[];
}

export function buildStateContent(occ: Occupation, state: StateInfo): ContentSection[] {
  const s = getSalary(occ, state);
  const seed = `${occ.slug}|${state.slug}`;
  const above = stateFactor(occ, state) >= 1;
  const pctAbs = Math.abs(Math.round((stateFactor(occ, state) - 1) * 100)) + '%';
  const colAdj = colAdjustedMedian(occ, state);
  const colDiff = Math.round(state.costOfLivingIndex - 100);
  const cities = state.topCities;
  const industries = state.majorIndustries;

  const overview = pick(
    [
      `${occ.title}s in ${state.name} earn a median annual salary of ${fmtUSD(s.median)} as of ${DATA_YEAR} — roughly ${pctAbs} ${above ? 'above' : 'below'} the national median of ${fmtUSD(occ.national.median)} for ${occ.blsTitle.toLowerCase()}. Pay spans a wide range: the bottom 10% of earners in the state take home around ${fmtUSD(s.p10)}, while the top 10% clear ${fmtUSD(s.p90)} or more. Where you fall on that curve depends mostly on experience, employer type, and which ${state.abbrev} metro you work in.`,
      `As of ${DATA_YEAR}, the typical ${occ.title.toLowerCase()} in ${state.name} makes ${fmtUSD(s.median)} per year, which is about ${pctAbs} ${above ? 'more' : 'less'} than the U.S. median for this occupation (${fmtUSD(occ.national.median)}). Entry-level pay in the state starts near ${fmtUSD(s.p10)}, mid-career professionals cluster between ${fmtUSD(s.p25)} and ${fmtUSD(s.p75)}, and the most senior 10% earn upwards of ${fmtUSD(s.p90)}.`,
    ],
    seed + 'overview',
  );

  const col = pick(
    [
      `${state.name}'s cost of living runs about ${Math.abs(colDiff)}% ${colDiff >= 0 ? 'above' : 'below'} the national average (index ${state.costOfLivingIndex}). Adjusted for local prices, a ${fmtUSD(s.median)} salary in ${state.abbrev} has the purchasing power of roughly ${fmtUSD(colAdj)} elsewhere in the country. ${colDiff >= 10 ? `That gap matters: housing is the biggest driver, so a nominally ${above ? 'higher' : 'competitive'} paycheck stretches less in ${cities[0]} than the headline number suggests.` : colDiff <= -5 ? `That works in workers' favor — ${above ? 'above-average pay combined with' : 'even slightly lower nominal pay paired with'} below-average living costs means real take-home value in ${state.name} beats many higher-paying coastal markets.` : `In practice, ${state.name} sits close to the national norm on everyday costs, so the headline salary is a fair proxy for real purchasing power.`}`,
      `On paper, ${occ.plural} in ${state.name} earn ${fmtUSD(s.median)} at the median — but cost of living changes what that money is worth. With ${state.abbrev}'s cost index at ${state.costOfLivingIndex} (U.S. = 100), that salary buys what roughly ${fmtUSD(colAdj)} would buy in an average American market. ${colDiff >= 10 ? `Housing around ${cities[0]} and ${cities[1]} is the main squeeze, and it eats a meaningful share of the pay premium.` : colDiff <= -5 ? `Lower housing and grocery costs across metros like ${cities[0]} and ${cities[2]} mean the effective value of a ${state.abbrev} paycheck is stronger than the raw number.` : `Costs in ${state.abbrev} track the national average closely, so nominal and real pay tell nearly the same story.`}`,
    ],
    seed + 'col',
  );

  const employment = pick(
    [
      `Most ${occ.plural} in ${state.name} work in and around ${cities[0]}, ${cities[1]}, and ${cities[2]}, where the state's ${industries[0]} and ${industries[1]} sectors concentrate hiring. ${occ.outlookNote} Larger metros generally pay toward the upper quartile (${fmtUSD(s.p75)}+), while smaller markets like ${cities[4] ?? cities[3]} tend to sit closer to the state median.`,
      `Hiring for ${occ.plural} in ${state.abbrev} clusters in ${cities[0]}, ${cities[1]}, and ${cities[3]}, driven by the state's strength in ${industries[0]}, ${industries[1]}, and ${industries[2]}. ${occ.outlookNote} Expect offers near the ${fmtUSD(s.p75)} mark in the biggest metros, versus closer to ${fmtUSD(s.median)} in mid-size cities.`,
    ],
    seed + 'employment',
  );

  const takeHomeLine = state.incomeTax.hasIncomeTax
    ? `After state and federal taxes, expect meaningfully less than the gross figure — budgeting off net pay is essential here.`
    : `With no state tax on wages, a ${fmtUSD(s.median)} salary in ${state.abbrev} nets noticeably more take-home pay than the same salary in a high-tax state like California or New York.`;

  const tax = pick(
    [
      `Taxes and labor rules shape what ${occ.plural} actually keep. ${state.incomeTax.summary}. ${state.incomeTax.note} ${takeHomeLine} ${state.laborNote}`,
      `${state.name}'s tax picture matters as much as the gross salary. ${state.incomeTax.summary}. ${state.incomeTax.note} ${state.laborNote} ${takeHomeLine}`,
    ],
    seed + 'tax',
  );

  const spreadRatio = (s.p90 / s.p10).toFixed(1);
  const careerPath = pick(
    [
      `Career stage drives most of the spread. In ${state.name}, a ${occ.title.toLowerCase()} at the 90th percentile earns about ${spreadRatio}× what someone at the 10th percentile makes — ${fmtUSD(s.p90)} versus ${fmtUSD(s.p10)}. The typical path to the upper end starts with ${occ.education.toLowerCase()}, then compounds through years of experience, specialization, and moving into the state's highest-demand employers around ${cities[0]}. Switching employers remains the fastest lever: candidates who change jobs in a tight ${state.abbrev} market routinely reset their pay to the current market rate rather than waiting on annual raises.`,
      `The gap between new and senior ${occ.plural} in ${state.name} is wide: ${fmtUSD(s.p10)} at the 10th percentile versus ${fmtUSD(s.p90)} at the 90th — a ${spreadRatio}× spread. Getting to the top band usually means ${occ.education.toLowerCase()} plus sustained experience, and often relocating within the state toward ${cities[0]} or ${cities[1]}, where employers in ${industries[0]} and ${industries[1]} pay the strongest premiums. Negotiating with competing offers is the most reliable way to climb the curve in ${state.abbrev}'s market.`,
    ],
    seed + 'career',
  );

  return [
    { heading: `${occ.title} pay in ${state.name}: the ${DATA_YEAR} picture`, paragraphs: [overview] },
    { heading: `Salary vs. cost of living in ${state.name}`, paragraphs: [col] },
    { heading: `Where ${occ.plural} work in ${state.name}`, paragraphs: [employment] },
    { heading: `How ${occ.plural} earn more in ${state.name}`, paragraphs: [careerPath] },
    { heading: `Taxes and take-home pay in ${state.name}`, paragraphs: [tax] },
  ];
}

/* ------------------------------------------------------------------ */
/* FAQ generation (3 per page, combo-specific)                         */
/* ------------------------------------------------------------------ */

export interface Faq {
  question: string;
  answer: string;
}

export function buildFaqs(occ: Occupation, state: StateInfo): Faq[] {
  const s = getSalary(occ, state);
  const above = stateFactor(occ, state) >= 1;
  const pctAbs = Math.abs(Math.round((stateFactor(occ, state) - 1) * 100)) + '%';

  return [
    {
      question: `What is the average ${occ.title.toLowerCase()} salary in ${state.name} in ${DATA_YEAR}?`,
      answer: `The median ${occ.title.toLowerCase()} salary in ${state.name} is ${fmtUSD(s.median)} per year (about ${hourly(s.median)} per hour) as of ${DATA_YEAR}. Half of ${occ.plural} in the state earn more and half earn less; the middle 50% earn between ${fmtUSD(s.p25)} and ${fmtUSD(s.p75)}.`,
    },
    {
      question: `Do ${occ.plural} in ${state.name} earn more than the national average?`,
      answer: `${above ? 'Yes' : 'No'} — pay for ${occ.plural} in ${state.name} runs about ${pctAbs} ${above ? 'above' : 'below'} the national median of ${fmtUSD(occ.national.median)}. ${state.incomeTax.hasIncomeTax ? `Keep in mind ${state.name} levies a state income tax, which reduces take-home pay relative to no-tax states.` : `Because ${state.name} has no state income tax on wages, take-home pay compares even more favorably than the gross figure suggests.`}`,
    },
    {
      question: `How much do the highest-paid ${occ.plural} make in ${state.name}?`,
      answer: `The top 10% of ${occ.plural} in ${state.name} earn ${fmtUSD(s.p90)} or more per year. Reaching that tier typically requires senior-level experience${occ.education.toLowerCase().includes('degree') ? `, credentials beyond the typical ${occ.education.toLowerCase()},` : ''} and working in a major metro such as ${state.topCities[0]}.`,
    },
  ];
}

/* ------------------------------------------------------------------ */
/* SEO helpers                                                         */
/* ------------------------------------------------------------------ */

export function buildMetaDescription(occ: Occupation, state: StateInfo): string {
  const s = getSalary(occ, state);
  const above = stateFactor(occ, state) >= 1;
  return `${occ.title}s in ${state.name} earn a median ${fmtUSD(s.median)}/year in ${DATA_YEAR} (${pctVsNational(occ, state)} vs. national, range ${fmtCompact(s.p10)}–${fmtCompact(s.p90)}). See ${state.abbrev} pay percentiles, cost-of-living value, top cities, taxes, and how ${above ? 'far ahead' : 'close'} nearby states pay.`;
}

export function buildPageTitle(occ: Occupation, state: StateInfo): string {
  const s = getSalary(occ, state);
  return `${occ.title} Salary in ${state.name} (${DATA_YEAR}): ${fmtCompact(s.median)} Median`;
}

/** schema.org Occupation with salary estimate distribution + location. */
export function buildOccupationJsonLd(occ: Occupation, state: StateInfo, url: string) {
  const s = getSalary(occ, state);
  return {
    '@context': 'https://schema.org/',
    '@type': 'Occupation',
    name: occ.title,
    description: occ.shortDesc,
    occupationalCategory: occ.socCode,
    occupationLocation: [{ '@type': 'State', name: state.name }],
    estimatedSalary: [
      {
        '@type': 'MonetaryAmountDistribution',
        name: 'base',
        currency: 'USD',
        duration: 'P1Y',
        percentile10: s.p10,
        percentile25: s.p25,
        median: s.median,
        percentile75: s.p75,
        percentile90: s.p90,
      },
    ],
    mainEntityOfPage: {
      '@type': 'WebPage',
      '@id': url,
      lastReviewed: `${DATA_YEAR}-01-15`,
    },
  };
}

export function buildFaqJsonLd(faqs: Faq[]) {
  return {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: faqs.map((f) => ({
      '@type': 'Question',
      name: f.question,
      acceptedAnswer: { '@type': 'Answer', text: f.answer },
    })),
  };
}

export function buildBreadcrumbJsonLd(occ: Occupation, state: StateInfo, siteUrl: string) {
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: [
      { '@type': 'ListItem', position: 1, name: 'Home', item: siteUrl + '/' },
      { '@type': 'ListItem', position: 2, name: 'Jobs', item: siteUrl + '/jobs/' },
      { '@type': 'ListItem', position: 3, name: occ.title, item: siteUrl + salaryPath(occ.slug, states[0]!.slug) },
      { '@type': 'ListItem', position: 4, name: `${occ.title} in ${state.name}`, item: siteUrl + salaryPath(occ.slug, state.slug) },
    ],
  };
}
