import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://foodmapper.app',
  output: 'static',
  outDir: '../docs',
  build: {
    assets: '_astro'
  }
});
