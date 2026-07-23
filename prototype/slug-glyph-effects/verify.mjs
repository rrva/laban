// PROTOTYPE — throwaway one-off verification script, not part of the demo.
//
// Pixel-diffs a crop of the row a newly typed line lands in (idle vs.
// post-typing) instead of trusting HUD state alone. The first pass of this
// script only checked console errors + HUD text and missed a real bug
// (SlugGeometry.addGlyph() never flags aScaleBias/etc. for GPU re-upload —
// see NOTES.md) where new lines were silently invisible while the HUD
// reported everything as fine.
import { createHash } from 'node:crypto';
import { chromium } from 'playwright';

const BASE = 'http://localhost:8737/';
const VARIANTS = ['A', 'B', 'C'];
const shotsDir = new URL('./verify-shots/', import.meta.url);
await import('node:fs/promises').then((fs) => fs.mkdir(shotsDir, { recursive: true }));

const browser = await chromium.launch();
let anyError = false;

for (const variant of VARIANTS) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const consoleErrors = [];
  const pageErrors = [];
  page.on('console', (msg) => {
    if (msg.type() === 'error') consoleErrors.push(msg.text());
  });
  page.on('pageerror', (err) => pageErrors.push(String(err)));

  await page.goto(`${BASE}?variant=${variant}`, { waitUntil: 'networkidle' });
  await page.waitForSelector('#loading', { state: 'detached', timeout: 10000 }).catch(() => {});
  await page.waitForTimeout(300);

  await page.screenshot({ path: new URL(`variant-${variant}-idle.png`, shotsDir).pathname });

  // Row 9 (index 8) is where the very first auto-typed/demo line must land
  // (MARGIN_TOP=70, CELL_H=20 -> top of row 8 is y=230 in main.js's layout).
  // Hash this crop now (guaranteed background-only: only 8 seed lines exist)
  // and again after typing; equal hashes mean nothing actually rendered
  // there, regardless of what the HUD claims.
  const newRowClip = { x: 10, y: 225, width: 400, height: 30 };
  const hash = (buf) => createHash('sha1').update(buf).digest('hex');
  const idleRowHash = hash(await page.screenshot({ clip: newRowClip }));

  // Exercise: keystroke demo, then a bell mid-type (bell restamps every cell).
  await page.keyboard.press('k');
  await page.waitForTimeout(300);
  await page.screenshot({ path: new URL(`variant-${variant}-typing.png`, shotsDir).pathname });
  const typingRowHash = hash(await page.screenshot({ clip: newRowClip }));
  await page.keyboard.press('b');
  await page.waitForTimeout(60);
  await page.screenshot({ path: new URL(`variant-${variant}-bell.png`, shotsDir).pathname });

  // Poll for park instead of a fixed sleep — the auto-typed command length
  // varies, so a fixed wait races the demo's own setTimeout chain. Reads
  // window.__testState(), a headless-only hook — nothing renders from it on
  // screen (see main.js: no live HUD, so it doesn't distract from the effect
  // being judged).
  let testState = await page.evaluate(() => window.__testState());
  const deadline = Date.now() + 4000;
  while (testState.running && Date.now() < deadline) {
    await page.waitForTimeout(150);
    testState = await page.evaluate(() => window.__testState());
  }

  const liveCanvas = await page.evaluate(() => {
    const c = document.querySelector('canvas');
    return c ? { width: c.width, height: c.height } : null;
  });

  const newRowRendered = idleRowHash !== typingRowHash;
  const parked = !testState.running && testState.liveCount === 0;

  console.log(`--- variant ${variant} ---`);
  console.log('canvas:', JSON.stringify(liveCanvas));
  console.log('state (after typing+bell, settled):', JSON.stringify(testState));
  console.log('new-row pixel diff (idle vs. post-typing):', newRowRendered ? 'CHANGED (ok)' : 'IDENTICAL (bug: nothing rendered)');
  console.log('consoleErrors:', consoleErrors.length, consoleErrors.slice(0, 5));
  console.log('pageErrors:', pageErrors.length, pageErrors.slice(0, 5));
  if (consoleErrors.length || pageErrors.length || !liveCanvas || !parked || !newRowRendered) {
    anyError = true;
  }
  await page.close();
}

await browser.close();
console.log(anyError ? '\nRESULT: FAIL (see above)' : '\nRESULT: OK');
process.exit(anyError ? 1 : 0);
