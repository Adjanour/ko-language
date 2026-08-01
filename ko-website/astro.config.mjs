import { defineConfig } from 'astro/config';
import koLang from './src/shiki/ko-lang.mjs';

export default defineConfig({
  site: 'https://ko-language.dev',
  markdown: {
    shikiConfig: {
      themes: {
        light: 'github-light',
        dark: 'github-dark',
      },
      langs: ['javascript', 'typescript', 'bash', 'json', 'yaml', 'markdown', 'rust', 'c', koLang],
    },
  },
});
