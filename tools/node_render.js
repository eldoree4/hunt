/**
 * node_render.js
 * Headless Puppeteer helper for Hunt v2 (Author: JFlow)
 * Usage: node node_render.js <url>
 *
 * This script renders the page and prints the rendered HTML to stdout.
 * Keep this script minimal and safe (no file writes). It times out after 20s.
 *
 * Requirements: node, npm install puppeteer (or playwright)
 */

const puppeteer = require('puppeteer');

(async () => {
  try {
    const url = process.argv[2];
    if (!url) {
      console.error('Usage: node node_render.js <url>');
      process.exit(2);
    }
    const browser = await puppeteer.launch({
      args: ['--no-sandbox', '--disable-setuid-sandbox'],
      headless: true,
    });
    const page = await browser.newPage();
    // Set conservative timeout and user agent
    await page.setUserAgent('Hunt-Scanner/2.1-prod (JFlow)');
    await page.setDefaultNavigationTimeout(20000);
    await page.goto(url, { waitUntil: 'networkidle2' });
    const content = await page.content();
    console.log(content);
    await browser.close();
    process.exit(0);
  } catch (err) {
    console.error('ERROR_RENDER', err.message || err);
    process.exit(1);
  }
})();
