// Run against a Vite frontend (no API server required):
// KEYBOARD_TEST_URL=http://127.0.0.1:5178 PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node --test tests/keyboard-navigation.browser.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');

test('keyboard navigation, view restoration, focus, typing and compact layouts', async t => {
  const browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL || 'chrome' });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1050 }, timezoneId: 'Europe/London' });
  page.setDefaultTimeout(5000);
  page.setDefaultNavigationTimeout(5000);
  const origin = process.env.KEYBOARD_TEST_URL || 'http://127.0.0.1:5178';
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.clock.install({ time: new Date('2026-11-14T15:00:00Z') });
  let removed = false;
  const fixture = (id, date, home, league, status = 'NS') => ({
    match_details_id: id, date, time: '15:00', league,
    home_team: home, away_team: 'Visitors', home_score: status === 'NS' ? null : 1,
    away_score: status === 'NS' ? null : 0, score_status: status,
    tv_channels: [{ name: 'BBC One', country_code: 'GB' }],
  });
  await page.route('**/api/**', async route => {
    const url = new URL(route.request().url());
    let body = [];
    if (url.pathname.endsWith('/competitions/catalog')) body = { competitions: [
      { id: 'premier-league', name: 'Premier League', aliases: [], weight: 100, supports_table: true },
      { id: 'championship', name: 'Championship', aliases: [], weight: 50, supports_table: true },
    ] };
    else if (url.pathname.endsWith('/matches')) {
      const date = url.searchParams.get('start') || '2026-11-14';
      body = [fixture('arsenal', date, 'Arsenal', 'Premier League', 'LIVE'), fixture('chelsea', date, 'Chelsea', 'Premier League'), fixture('norwich', date, 'Norwich', 'Championship', 'FT')];
      if (removed) body = body.filter(item => item.match_details_id !== 'chelsea');
      if (url.searchParams.has('epl_only') || url.searchParams.has('view_option')) body = body.filter(item => item.league === 'Premier League');
    } else if (url.pathname.endsWith('/tables')) body = { leagues: [] };
    else if (url.pathname.endsWith('/teams/catalog')) body = { teams: [] };
    else if (url.pathname.includes('/matches/')) body = fixture(url.pathname.split('/').at(-1), '2026-11-14', 'Arsenal', 'Premier League', 'LIVE');
    else if (url.pathname.includes('/fantasy') || url.pathname.includes('/fpl')) {
      await route.fulfill({ status: 503, contentType: 'application/json', body: JSON.stringify({ error: 'Test offline' }) }); return;
    }
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  await page.route('**/competition-weights', route => route.fulfill({ json: [] }));
  await page.route('**/logos/**', route => route.fulfill({ status: 204 }));
  const press = async key => { await page.keyboard.press(key); await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))); };
  const query = () => new URL(page.url()).searchParams;
  const waitQuery = async (key, value) => { try { await page.waitForURL(url => url.searchParams.get(key) === value); } catch(error) { throw new Error(`Expected ${key}=${value}, got ${page.url()}; errors: ${errors.join('; ')}`, { cause: error }); } };
  const screenshot = name => process.env.KEYBOARD_SCREENSHOTS ? page.screenshot({ path: `${process.env.KEYBOARD_SCREENSHOTS}/${name}.png`, fullPage: true }) : Promise.resolve();
  const selected = () => page.locator('[data-keyboard-selected] .fixture-details-link');
  const focusBody = () => page.evaluate(() => document.activeElement?.blur());
  try {
    await page.goto(`${origin}/?date=2026-11-14&scope=top&details=0`);
    await page.locator('.fixture-details-link').first().waitFor();
    await t.test('P restores Top teams and D toggles details without repeating', async () => {
      await press('p'); await waitQuery('scope', 'epl');
      await press('p'); await waitQuery('scope', 'top');
      await press('d'); await waitQuery('details', '1');
      await page.evaluate(() => window.dispatchEvent(new KeyboardEvent('keydown', { key: 'd', repeat: true })));
      assert.equal(query().get('details'), '1');
    });
    await t.test('arrows select links, Enter opens, Escape restores filters and focus', async () => {
      await press('ArrowDown'); assert.match(await selected().getAttribute('aria-label'), /Arsenal/);
      await press('ArrowDown'); assert.match(await selected().getAttribute('aria-label'), /Chelsea/);
      await screenshot('keyboard-match-selector');
      await press('Enter'); await page.waitForURL(url => url.pathname === '/matches/chelsea');
      await press('Escape'); await page.waitForURL(url => url.pathname === '/');
      await selected().waitFor();
      assert.equal(query().get('scope'), 'top'); assert.equal(query().get('details'), '1');
      assert.equal(await selected().evaluate(el => el === document.activeElement), true);
      assert.match(await selected().getAttribute('aria-label'), /Chelsea/);
    });
    await t.test('V uses selected date and Escape restores it', async () => {
      await press('p'); await waitQuery('scope', 'epl');
      await press('ArrowRight'); await waitQuery('date', '2026-11-15');
      await press('v'); await page.waitForURL(url => url.pathname === '/tv');
      assert.equal(query().get('date'), '2026-11-15'); assert.equal(query().get('scope'), 'all');
      await press('Escape'); await page.waitForURL(url => url.pathname === '/');
      assert.equal(query().get('date'), '2026-11-15'); assert.equal(query().get('scope'), 'epl');
      await press('p'); await waitQuery('scope', 'top');
      await press('d'); assert.equal(query().has('details'), false);
    });
    await t.test('slash focuses search, preserves text and types normally inside inputs', async () => {
      await press('/');
      const input = page.getByRole('searchbox');
      assert.equal(await input.evaluate(el => el === document.activeElement), true);
      assert.equal(await input.inputValue(), '');
      await input.fill('Chelsea');
      await input.press('/');
      assert.equal(await input.inputValue(), 'Chelsea/');
      await input.press('p'); await input.press('ArrowLeft');
      assert.equal(query().get('scope'), 'top'); assert.equal(query().get('date'), '2026-11-15');
      await input.fill('Chelsea'); await focusBody(); await press('/');
      assert.equal(await input.evaluate(el => el === document.activeElement), true);
      assert.equal(await input.inputValue(), 'Chelsea');
      await focusBody(); await press('t'); await page.waitForURL(url => url.pathname === '/tables');
      await page.getByRole('heading', { name: 'League tables', exact: true }).waitFor();
      await press('/');
      await page.waitForURL(url => url.pathname === '/');
      assert.equal(await input.inputValue(), 'Chelsea');
      assert.equal(await input.evaluate(el => el === document.activeElement), true);
    });
    await t.test('A and O toggle their filters, with hints, without changing date or search', async () => {
      await focusBody();
      for (const [label, key] of [['All competitions', 'A'], ['Top teams', 'O'], ['Premier League teams', 'P']]) {
        assert.equal(await page.getByRole('button', { name: label, exact: true }).locator('kbd').textContent(), key);
      }
      await press('a'); await waitQuery('scope', 'all');
      assert.equal(query().get('date'), '2026-11-15');
      assert.equal(await page.getByRole('searchbox').inputValue(), 'Chelsea');
      await press('a'); await waitQuery('scope', 'top');
      await press('o'); await waitQuery('scope', 'all');
      await press('o'); await waitQuery('scope', 'top');
      await press('a'); await waitQuery('scope', 'all');
      await page.getByRole('searchbox').fill(''); await focusBody();
    });
    await t.test('S matches the Scores & fixtures menu and has its helper label', async () => {
      assert.equal(await page.getByRole('link', { name: 'Scores & fixtures' }).locator('kbd').textContent(), 'S');
      await press('t'); await page.waitForURL(url => url.pathname === '/tables');
      await page.getByRole('heading', { name: 'League tables', exact: true }).waitFor();
      await press('s'); await page.waitForURL(url => url.pathname === '/');
      assert.equal(query().get('scope'), 'all');
      await page.waitForFunction(() => document.querySelectorAll('.scores-primary .fixture-details-link').length === 3);
      await press('ArrowLeft'); await waitQuery('date', '2026-11-13');
      await press('ArrowRight'); await waitQuery('date', '2026-11-14');
    });
    await t.test('competition focus owns arrows, Enter opens, and Escape returns home', async () => {
      await press('c');
      assert.equal(await page.evaluate(() => document.activeElement?.textContent?.includes('Premier League')), true);
      await press('ArrowDown'); assert.equal(query().get('date'), '2026-11-14');
      assert.equal(await page.evaluate(() => document.activeElement?.textContent?.includes('Championship')), true);
      await press('Enter'); await page.waitForURL('**/competitions/Championship**');
      await press('Escape'); await page.waitForURL(url => url.pathname === '/');
    });
    await t.test('R and F route correctly; FPL exposes the competition picker', async () => {
      await press('r'); await page.waitForURL(url => url.pathname === '/results');
      await press('f'); await page.waitForURL(url => url.pathname === '/fpl');
      await page.locator('.site-layout-fantasy').waitFor();
      await press('c'); await page.locator('dialog[open] .keyboard-competition-list a').first().waitFor();
      await press('ArrowDown'); await press('Enter');
      await page.waitForURL('**/competitions/Championship**');
      assert.equal(await page.locator('dialog[open]').count(), 0);
      await press('Escape'); await page.waitForURL(url => url.pathname === '/');
    });
    await t.test('help traps focus; opt-out persists and preserves arrows', async () => {
      await press('?'); await page.locator('dialog[open]').waitFor();
      await screenshot('keyboard-help');
      await page.getByLabel('Single-letter shortcuts').uncheck();
      await press('Tab');
      assert.equal(await page.evaluate(() => document.activeElement === document.body || Boolean(document.activeElement?.closest('dialog'))), true);
      await press('Escape'); assert.equal(await page.locator('dialog[open]').count(), 0);
      const before = page.url(); await press('f'); assert.equal(page.url(), before);
      await press('ArrowRight'); await waitQuery('date', '2026-11-15');
      await page.reload(); await page.locator('.fixture-details-link').first().waitFor();
      await press('f'); assert.equal(new URL(page.url()).pathname, '/');
      await page.getByRole('button', { name: 'Keyboard help', exact: true }).click();
      await page.getByLabel('Single-letter shortcuts').check();
      await press('Escape');
    });
    await t.test('native modifiers are ignored and live row removal preserves useful focus', async () => {
      await focusBody(); await press('s'); await page.waitForURL(url => url.pathname === '/');
      await press('ArrowLeft'); await waitQuery('date', '2026-11-13');
      await press('ArrowRight'); await waitQuery('date', '2026-11-14');
      const before = page.url(); await press('Alt+ArrowRight'); assert.equal(page.url(), before);
      await page.evaluate(() => window.dispatchEvent(new KeyboardEvent('keydown', { key: 'f', isComposing: true })));
      assert.equal(page.url(), before);
      await press('ArrowDown'); await press('ArrowDown'); await press('ArrowDown');
      assert.match(await selected().getAttribute('aria-label'), /Chelsea/);
      removed = true;
      await page.clock.fastForward(11_000);
      await page.waitForFunction(() => !document.querySelector('[aria-label="Match details: Chelsea v Visitors"]'));
      await selected().waitFor();
      assert.equal(await selected().evaluate(el => el === document.activeElement), true);
      assert.match(await selected().getAttribute('aria-label'), /Arsenal/);
    });
    await t.test('narrow layouts have no horizontal overflow and C opens a picker', async () => {
      await page.setViewportSize({ width: 390, height: 844 });
      await focusBody(); await press('c'); await page.locator('dialog[open]').waitFor();
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await screenshot('keyboard-mobile-competitions');
      await press('Escape');
      await press('?'); await page.locator('dialog[open]').waitFor();
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    });
    assert.deepEqual(errors, []);
  } finally { await browser.close(); }
});
