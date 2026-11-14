import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeMatchContext, isContextPrematch } from '../src/client/matchContext.ts';

test('cached preview and predictions expire exactly at kickoff, including without a network update', () => {
  const context = normalizeMatchContext({ is_upcoming: true, kickoff_at: '2026-11-14T15:00:00Z', lineup_status: 'predicted',
    match_preview: { text: 'Preview' }, fun_facts: ['Fact'], refresh_after_seconds: 30 });
  assert.equal(isContextPrematch(context, Date.parse('2026-11-14T14:59:59Z')), true);
  assert.equal(isContextPrematch(context, Date.parse('2026-11-14T15:00:00Z')), false);
  assert.equal(isContextPrematch({ ...context!, is_upcoming: false }, Date.parse('2026-11-14T14:59:59Z')), false);
  assert.deepEqual(context?.fun_facts, ['Fact']);
});

test('unknown fields, partial history and absent metadata never manufacture facts or scores', () => {
  assert.equal(normalizeMatchContext(undefined), null);
  const context = normalizeMatchContext({ lineup_status: 'future_unknown', fun_facts: [' ', 'Fact', 'Fact', null],
    head_to_head: { total_matches: 2, home_wins: null, away_wins: 1, draws: 1,
      recent_matches: [{ date: '2026-01-01', home_team: 'A', away_team: 'B', home_score: null, away_score: '0', match_id: 'bad' }] } });
  assert.equal(context?.lineup_status, 'unavailable');
  assert.equal(context?.match_preview, null);
  assert.deepEqual(context?.fun_facts, ['Fact']);
  assert.equal(context?.head_to_head?.home_wins, null);
  assert.equal(context?.head_to_head?.recent_matches[0].home_score, null);
  assert.equal(context?.head_to_head?.recent_matches[0].away_score, null);
  assert.equal(context?.head_to_head?.recent_matches[0].match_id, null);
});
