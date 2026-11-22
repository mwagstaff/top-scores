import assert from 'node:assert/strict';
import test from 'node:test';

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');

test('league standings open the selected team from any column or the keyboard', async () => {
  const browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL || 'chrome' });
  try {
    const page = await browser.newPage();
    const origin = process.env.KEYBOARD_TEST_URL || 'http://127.0.0.1:5178';
    const teams = ['Home team', 'Away team'];
    const league = { id: 7, name: 'Test league', league_type: 'x' };
    const event = { id: 11, name: 'Gameweek 11' };
    await page.addInitScript(() => localStorage.setItem('top-scores.web.fpl.v1', '{"manager":1}'));
    await page.route('**/api/**', async route => {
      const path = new URL(route.request().url()).pathname;
      let json = [];
      if (path === '/api/fpl/league/7') {
        json = { league, standings: { results: teams.map((entry_name, i) => ({
          entry: i + 1, player_name: 'Test Manager', entry_name, rank: i + 1, last_rank: 2, event_total: 37, total: 662,
        })) } };
      } else if (path.startsWith('/api/fpl/entry/')) {
        const id = Number(path.split('/').pop());
        json = { profile: { id, name: teams[id - 1], player_first_name: 'Test', player_last_name: 'Manager', leagues: { classic: [league] } },
          event, events: [event], teams: [], players: [], notes: [], points: 37, history: { total_points: 662, value: 1000 } };
      }
      await route.fulfill({ json });
    });
    await page.goto(origin + '/fpl?section=leagues&league=7&event=11');
    const row = page.getByRole('row').filter({ hasText: 'Away team' });
    const button = row.getByRole('button');
    const background = () => row.evaluate(el => getComputedStyle(el).backgroundColor);
    const rest = await background();
    const verifyTeam = async () => {
      await page.getByRole('heading', { name: 'Gameweek 11: Away team' }).waitFor();
      const params = new URL(page.url()).searchParams;
      assert.equal(params.get('entry'), '2');
      assert.equal(params.get('event'), '11');
      await page.goBack();
      await row.waitFor();
    };
    for (const cell of await row.locator('td, th').all()) {
      await cell.hover();
      assert.notEqual(await background(), rest);
      await cell.click();
      await verifyTeam();
    }
    await page.mouse.move(0, 0);
    await page.keyboard.press('Tab');
    await button.focus();
    assert.equal(await row.evaluate(el => getComputedStyle(el).outlineStyle), 'solid');
    await page.keyboard.press('Enter');
    await verifyTeam();
  } finally {
    await browser.close();
  }
});
