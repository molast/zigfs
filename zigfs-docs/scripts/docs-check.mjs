import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';

const required = ['en', 'zh'];
for (const locale of required) {
  /** @type {{ pages: string[] }} */
  const meta = JSON.parse(await readFile(join('content', locale, 'meta.json'), 'utf8'));
  if (!Array.isArray(meta.pages) || meta.pages.length < 2) throw new Error(`${locale}/meta.json has no navigation pages`);
  const missing = [];
  for (const page of meta.pages.filter((p) => !p.startsWith('---'))) {
    const path = page === 'index' ? join('content', locale, 'index.mdx') : join('content', locale, page, 'index.mdx');
    try { await readFile(path); } catch { missing.push(path); }
  }
  if (missing.length) throw new Error(`Missing pages: ${missing.join(', ')}`);
}
console.log('docs-check: navigation and locale entry points are valid');
