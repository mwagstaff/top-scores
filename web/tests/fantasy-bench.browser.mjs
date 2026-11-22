import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const css = await readFile(new URL('../src/client/fantasy.css', import.meta.url), 'utf8');

test('a bench booking overlays the portrait and keeps all points strips flush', async () => {
  const browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL || 'chrome' });
  try {
    const page = await browser.newPage();
    const cards = ['Kinsky', 'Yalcouyé', 'Mitchell', 'Diop'].map((name, i) => `
      <button class="fpl-player">
        <span class="fpl-player-detail">TOT (A)</span><span class="fpl-player-photo"></span>
        <strong>${name}</strong><span class="fpl-player-score">${[7, 0, 1, 0][i]}</span>
        <span class="fpl-player-events">${name === 'Diop' ? '<span title="Yellow card">🟨</span>' : ''}</span>
      </button>`);
    await page.setContent(`<style>${css}</style><div class="fpl-page"><div class="fpl-bench">
      <div class="fpl-position">${cards.join('')}</div></div></div>`);
    for (const width of [390, 768, 1440]) {
      await page.setViewportSize({ width, height: 900 });
      const scores = await page.locator('.fpl-player-score').evaluateAll(nodes => nodes.map(node => {
        const rect = node.getBoundingClientRect();
        return { top: rect.top, gap: node.parentElement.getBoundingClientRect().bottom - rect.bottom };
      }));
      assert.ok(scores.every(score => score.top === scores[0].top && score.gap <= 1), `points strips at ${width}px`);
      const badge = await page.getByTitle('Yellow card').boundingBox();
      const photo = await page.locator('.fpl-player-photo').last().boundingBox();
      assert.ok(badge.y >= photo.y && badge.y + badge.height <= photo.y + photo.height, `booking at ${width}px`);
    }
  } finally {
    await browser.close();
  }
});
