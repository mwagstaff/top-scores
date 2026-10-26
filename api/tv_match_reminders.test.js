const test = require('node:test');
const assert = require('node:assert/strict');
const { reminderGroups, reminderMessage, createTVReminderScheduler } = require('./tv_match_reminders');
const now = Date.parse('2026-10-25T19:50:00Z');
const user = { deviceToken: 'device', apnsToken: 'push', preferences: { notificationsEnabled: true } };
const match = { id: 'bsd_1', home_team: 'Home', away_team: 'Away', kickoff_at: '2026-10-25T20:00:00Z', tv_channels: ['BBC One'], watchability_index: { score: 70 } };
const channels = m => m.tv_channels || [];
const groups = (prefs = {}, matches = [match], at = now) => reminderGroups({ ...user, preferences: { ...user.preferences, ...prefs } }, matches, at, channels);

test('defaults enabled at 70+, ten minutes before, independent of event choices and spoiler delay', () => {
  assert.equal(groups({ notificationEventTypes: [], notificationDelayMinutes: 10 }).length, 1);
  assert.equal(groups({}, [{ ...match, watchability_index: { score: 69 } }]).length, 0);
  assert.equal(groups({}, [match], now - 1).length, 0);
  assert.equal(groups({}, [match], now + 90_001).length, 0);
});
test('respects opt-outs, selected rating and timing, and unrated all-matches mode', () => {
  for (const prefs of [{ notificationsEnabled: false }, { tvMatchRemindersEnabled: false }, { tvMatchReminderMinimumScore: 85 }]) assert.equal(groups(prefs).length, 0);
  assert.equal(groups({}, [{ ...match, watchability_index: null }]).length, 0);
  assert.equal(groups({ tvMatchReminderMinimumScore: 0 }, [{ ...match, watchability_index: null }]).length, 1);
  for (const minutes of [5, 10, 15, 30]) assert.equal(groups({ tvMatchReminderMinutes: minutes }, [match], Date.parse(match.kickoff_at) - minutes * 60_000).length, 1);
});
test('excludes missing TV, started, cancelled, postponed and changed kick-offs', () => {
  for (const status of ['POSTPONED', 'CANCELLED', 'ABANDONED', 'FT', 'HT', "1'"]) assert.equal(groups({}, [{ ...match, score_status: status }]).length, 0);
  assert.equal(groups({}, [{ ...match, tv_channels: [] }]).length, 0);
  assert.equal(groups({}, [{ ...match, kickoff_at: '2026-10-25T21:00:00Z' }]).length, 0);
  assert.equal(groups({}, [match], Date.parse(match.kickoff_at)).length, 0);
});
test('groups exact kick-offs, deduplicates matches and orders by rating', () => {
  const result = groups({}, [match, match, { ...match, id: 'bsd_2', watchability_index: { score: 85 } }, { ...match, id: 'bsd_3', kickoff_at: '2026-10-25T19:59:00Z' }]);
  assert.equal(result.length, 2);
  assert.deepEqual(result[0].matches.map(m => m.reminderID), ['bsd_2', 'bsd_1']);
  const message = reminderMessage(user, result[0], now);
  assert.equal(message.title, '2 TV Matches Start at 20:00');
  assert.match(message.body, /BBC One/);
  assert.deepEqual(message.payload.matchIDs, ['bsd_2', 'bsd_1']);
});
test('formats the original kickoff in the device timezone and includes all channels', () => {
  const group = groups({}, [{ ...match, tv_channels: ['BBC One', 'BBC iPlayer'] }])[0];
  const message = reminderMessage({ ...user, preferences: { deviceTimeZone: 'America/New_York', deviceLocale: 'en-GB' } }, group, now);
  assert.match(message.title, /16:00/);
  assert.match(message.body, /BBC One, BBC iPlayer/);
});
function harness() {
  const sent = [], claimed = new Set();
  let latestUser = user;
  const deps = { now: () => now, users: async () => [user], user: async () => latestUser,
    matches: async () => [match], visible: ms => ms, channels,
    claim: async id => { const exists = claimed.has(id); claimed.add(id); return { claimed: !exists, source: 'redis' }; },
    send: async (...args) => { sent.push(args); return { success: true }; }, record: async () => {}, error: e => { throw e; } };
  return { deps, sent, setUser: u => { latestUser = u; } };
}
test('shared claims prevent duplicates across evaluations and scheduler restarts', async () => {
  const h = harness();
  await createTVReminderScheduler(h.deps).evaluate();
  await createTVReminderScheduler(h.deps).evaluate();
  assert.equal(h.sent.length, 1);
});
test('rechecks saved preferences and Scores eligibility before delivery', async () => {
  const h = harness();
  h.setUser({ ...user, preferences: { ...user.preferences, tvMatchRemindersEnabled: false } });
  await createTVReminderScheduler(h.deps).evaluate();
  assert.equal(h.sent.length, 0);
  h.setUser(user); h.deps.visible = () => [];
  await createTVReminderScheduler(h.deps).evaluate();
  assert.equal(h.sent.length, 0);
});
test('does not send when durable duplicate protection is unavailable', async () => {
  const h = harness(); h.deps.claim = async () => ({ claimed: true, source: 'degraded' });
  await createTVReminderScheduler(h.deps).evaluate();
  assert.equal(h.sent.length, 0);
});


test('reminder channel names follow the existing Scores channel-family selections', () => {
  const { __testHooks: { tvReminderChannels } } = require('./match_monitor');
  const fixture = { tv_channels: [{ name: 'Sky Sports Main Event' }, 'Sky Sports Premier League', 'TNT Sports 1'] };
  assert.deepEqual(tvReminderChannels(fixture, { channelFilterEnabled: true, selectedChannels: ['Sky (all)'] }), ['Sky Sports Main Event', 'Sky Sports Premier League']);
  assert.deepEqual(tvReminderChannels(fixture, { channelFilterEnabled: true, selectedChannels: ['BBC (all)'] }), []);
  assert.equal(tvReminderChannels(fixture, { channelFilterEnabled: false }).length, 3);
});
