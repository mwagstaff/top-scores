import test from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';

registerHooks({ resolve(specifier, context, next) {
  try { return next(specifier, context); } catch (error) {
    if (error.code === 'ERR_MODULE_NOT_FOUND' && specifier.startsWith('.') && !/\.[a-z]+$/i.test(specifier)) return next(`${specifier}.ts`, context);
    throw error;
  }
} });

const { fetchMatchRatings } = await import('../src/client/api.ts');

test('match ratings use the performance endpoint and omit invalid or unavailable values', async () => {
  const originalFetch = globalThis.fetch;
  const controller = new AbortController();
  let requestedUrl = '';
  let requestedSignal: AbortSignal | undefined;
  globalThis.fetch = async (input, init) => {
    requestedUrl = String(input);
    requestedSignal = init?.signal ?? undefined;
    return Response.json({ players: [
      { player_id: '1', stats: { rating: 8.7 } },
      { player_id: '2', stats: { rating: null } },
      { player_id: '3', stats: { rating: 0 } },
      { player_id: '4', stats: { rating: 10.1 } },
    ] });
  };
  try {
    assert.deepEqual(await fetchMatchRatings('209606', controller.signal), { '1': 8.7 });
    assert.equal(requestedUrl, '/api/v1/matches/209606/player-stats');
    assert.equal(requestedSignal, controller.signal);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
