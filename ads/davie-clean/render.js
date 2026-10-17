// Renders each ad-*.html in this folder to a 1080x1350 PNG next to it.
// Usage: node ads/davie-clean/render.js
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

(async () => {
  const dir = __dirname;
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1080, height: 1350 } });
  for (const file of fs.readdirSync(dir).filter((f) => /^ad-.*\.html$/.test(f))) {
    await page.goto('file://' + path.join(dir, file), { waitUntil: 'networkidle' });
    await page.evaluate(() => document.fonts.ready);
    const out = path.join(dir, file.replace(/\.html$/, '.png'));
    await page.screenshot({ path: out });
    console.log('wrote', out);
  }
  await browser.close();
})();
