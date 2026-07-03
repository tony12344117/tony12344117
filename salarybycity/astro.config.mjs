// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';

// Static-first programmatic SEO site. Every salary page is prerendered at
// build time from src/data/*.json — no runtime data fetching.
export default defineConfig({
  site: 'https://salarybycity.com',
  trailingSlash: 'always',
  output: 'static',
  integrations: [sitemap()],
  vite: {
    plugins: [tailwindcss()],
  },
});
