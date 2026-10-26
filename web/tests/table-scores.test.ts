import test from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import type { Match } from '../src/client/types.ts';

registerHooks({ resolve(specifier, context, next) {
  try { return next(specifier, context); } catch (error) {
    if (error.code === 'ERR_MODULE_NOT_FOUND' && specifier.startsWith('.') && !/\.[a-z]+$/i.test(specifier)) return next(`${specifier}.ts`, context);
    throw error;
  }
} });
const { tableScoresByTeam, fetchTableMatches } = await import('../src/client/tableScores.ts');
const { teamIdentityKeys } = await import('../src/client/teamColors.ts');
const date = '2026-10-24';
const match = (overrides: Partial<Match> = {}): Match => ({
  id: '1', date, time: '15:00', homeTeam: 'Manchester City', awayTeam: 'Arsenal',
  league: 'Premier League', tvChannels: [], homeScore: 1, awayScore: 2, scoreStatus: 'FT', ...overrides,
});
const scoreFor = (matches: Match[], team = 'Manchester City') => tableScoresByTeam(matches, date).get(teamIdentityKeys(team)[0]);

test('scores and result colours use each team’s perspective', () => {
  assert.equal(scoreFor([match()])?.outcome, 'loss');
  assert.equal(scoreFor([match()])?.label, 'Full time: Lost 1 to 2');
  const away = scoreFor([match()], 'Arsenal');
  assert.equal(away?.outcome, 'win');
  assert.equal(away?.scored, 2);
  assert.equal(away?.conceded, 1);
  assert.equal(scoreFor([match({ homeScore: 0, awayScore: 0, scoreStatus: 'HT' })])?.label, 'Live: Drawing 0 to 0');
});

test('only today’s started or finished matches with both scores produce pills', () => {
  for (const overrides of [
    { date: '2026-10-23' }, { scoreStatus: null }, { scoreStatus: 'POSTPONED' },
    { homeScore: null }, { awayScore: null },
  ]) assert.equal(scoreFor([match(overrides)]), undefined);
});

test('live scores take precedence over results and later results over earlier ones', () => {
  const live = match({ id: 'live', time: '12:00', scoreStatus: '75', homeScore: 3 });
  assert.equal(scoreFor([live, match()])?.match.id, 'live');
  assert.equal(scoreFor([match({ id: 'late', time: '20:00' }), match()])?.match.id, 'late');
});

test('match requests are date-scoped, paginated and cancellable', async () => {
  const originalFetch = globalThis.fetch;
  const controller = new AbortController();
  const requests: URL[] = [];
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input), 'http://localhost');
    requests.push(url);
    assert.equal(init?.signal, controller.signal);
    return Response.json([{ id: String(requests.length) }], { headers: { 'X-Has-More': requests.length === 1 ? 'true' : 'false' } });
  };
  try {
    assert.equal((await fetchTableMatches(['Premier League'], date, controller.signal)).length, 2);
    assert.deepEqual(requests.map(url => url.searchParams.get('page')), ['1', '2']);
    for (const url of requests) {
      assert.equal(url.searchParams.get('start'), date);
      assert.equal(url.searchParams.get('end'), date);
      assert.equal(url.searchParams.get('league'), 'Premier League');
      assert.equal(url.searchParams.get('page_size'), '200');
    }
    globalThis.fetch = async () => new Response(null, { status: 503 });
    await assert.rejects(fetchTableMatches(['Premier League'], date, controller.signal), /unavailable/);
  } finally { globalThis.fetch = originalFetch; }
});
