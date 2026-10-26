import test from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
registerHooks({ resolve(specifier, context, next) {
  try { return next(specifier, context); } catch (error) {
    if (error.code === 'ERR_MODULE_NOT_FOUND' && specifier.startsWith('.') && !/\.[a-z]+$/i.test(specifier)) return next(`${specifier}.ts`, context);
    throw error;
  }
} });
const { loadTeam, watchTeam } = await import('../src/client/teamData.ts');
test('team loading resolves aliases, coalesces requests and separates fixtures from results', async () => {
  const original = globalThis.fetch;
  const requests: string[] = [];
  globalThis.fetch = async input => {
    const url = String(input); requests.push(url);
    let data: unknown;
    if (url.includes('/teams/catalog')) data = { teams: [{ name: 'Manchester United', aliases: ['Man Utd'], source_team_ids: ['17'] }] };
    else if (url.includes('/matches?')) data = [{match_details_id:'upcoming',home_team:'Manchester United',score_status:'NS'}, {match_details_id:'finished',home_team:'Manchester United',score_status:'FT'}];
    else if (url.endsWith('/tables')) data = { leagues: [] };
    else if (url.endsWith('/squad')) data = { players: [{id:'9', name:'Player'}] };
    else data = {id:'831',name:'Manager'};
    return Response.json(data);
  };
  try {
    const pending = loadTeam('Man Utd');
    assert.equal(loadTeam('Man Utd'), pending);
    const data = await pending;
    assert.equal(data.id, '17');
    assert.ok(data.names.includes('Manchester United'));
    assert.deepEqual(data.fixtures.map(m => m.id), ['upcoming']);
    assert.deepEqual(data.results.map(m => m.id), ['finished']);
    assert.equal(data.players[0].name, 'Player');
    assert.equal(data.manager?.name, 'Manager');
    assert.deepEqual(data.errors, []);
    assert.equal(requests.length, 6);
    assert.ok(requests.filter(url => url.includes('/matches?')).every(url => new URL(url,'https://test').searchParams.get('page_size') === '200'));
  } finally { globalThis.fetch = original; }
});
test('a squad failure preserves available team sections and supplied BSD identifiers', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async input => {
    const url = String(input);
    if (url.includes('/catalog') || url.endsWith('/squad')) return new Response('', {status:503});
    return Response.json(url.endsWith('/tables') ? {leagues:[]} : url.endsWith('/manager') ? {id:'7',name:'Manager'} : []);
  };
  try {
    const data = await loadTeam('Other team','123');
    assert.equal(data.manager?.name, 'Manager');
    assert.deepEqual(data.errors,['Players']);
    assert.ok(data.tables);
  } finally { globalThis.fetch = original; }
});

test('season data is published before a slow squad finishes', async () => {
  const original = globalThis.fetch;
  let release: () => void = () => {};
  const gate = new Promise<void>(resolve => { release = resolve; });
  const updates: any[] = [];
  globalThis.fetch = async input => {
    const url = String(input);
    if (url.endsWith('/squad')) await gate;
    return Response.json(url.endsWith('/tables') ? {leagues:[]} : url.includes('/catalog') ? {teams:[]} : url.endsWith('/squad') ? {players:[]} : url.endsWith('/manager') ? {id:'1'} : []);
  };
  const stop = watchTeam('Progressive','55', data => updates.push(data));
  try {
    const pending = loadTeam('Progressive','55');
    await new Promise(resolve => setImmediate(resolve));
    assert.ok(updates.some(data => data.tables && data.pending.includes('Players')));
    release(); await pending;
    assert.deepEqual(updates.at(-1).pending, []);
  } finally { release(); stop(); globalThis.fetch = original; }
});
test('competition date counts deduplicate paginated matches and exclude unfinished results', async () => {
  const { competitionDateCounts } = await import('../src/client/competitionDates.ts');
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return Response.json([{match_details_id:'1',league:'Premier League',date:'2026-10-23',score_status:'FT'}, {match_details_id:'live',league:'Premier League',date:'2026-10-23',score_status:'45'}, {match_details_id:String(calls+1),league:'Premier League',date:'2026-10-24',score_status:'NS'}], {headers:{'X-Has-More':String(calls===1)}});
  };
  try {
    assert.deepEqual(await competitionDateCounts(['Premier League'],'2026-10-21','2026-10-27',true), {
      counts: {'2026-10-23':1}, liveDates: {'2026-10-23':true}, finishedDates: {'2026-10-23':false, '2026-10-24':false},
    });
    assert.equal(calls,2);
  } finally { globalThis.fetch = original; }
});

test('competition date activity keeps total counts and marks dates with live matches', async () => {
  const { competitionDateCounts } = await import('../src/client/competitionDates.ts');
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return Response.json(calls === 1
      ? [{match_details_id:'live',league:'Premier League',date:'2026-11-01',score_status:'45'}, {match_details_id:'future',league:'Premier League',date:'2026-11-01',score_status:'NS'}]
      : [{match_details_id:'live',league:'Premier League',date:'2026-11-01',score_status:'45'}, {match_details_id:'done',league:'Premier League',date:'2026-11-02',score_status:'FT'}, {match_details_id:'mixed-done',league:'Premier League',date:'2026-11-03',score_status:'FT'}, {match_details_id:'mixed-upcoming',league:'Premier League',date:'2026-11-03',score_status:'NS'}],
      {headers:{'X-Has-More':String(calls===1)}});
  };
  try {
    assert.deepEqual(await competitionDateCounts(['Premier League'],'2026-11-01','2026-11-03',false), {
      counts: {'2026-11-01':2, '2026-11-02':1, '2026-11-03':2},
      liveDates: {'2026-11-01':true},
      finishedDates: {'2026-11-01':false, '2026-11-02':true, '2026-11-03':false},
    });
    assert.equal(calls,2);
  } finally { globalThis.fetch = original; }
});

test('competition entry prefers next fixture and falls back to latest past match', async () => {
  const { preferredCompetitionDate } = await import('../src/client/competitionDates.ts');
  const original = globalThis.fetch;
  const queries: URLSearchParams[] = [];
  let future = true;
  globalThis.fetch = async input => {
    const query = new URL(String(input), 'https://test').searchParams; queries.push(query);
    return Response.json(query.get('sort') === 'asc' ? (future ? [{date:'2026-10-23'}] : []) : [{date:'2026-10-19'}]);
  };
  try {
    assert.equal(await preferredCompetitionDate(['Premier League'],'2026-10-22'), '2026-10-23');
    assert.equal(queries.length,1);
    future = false;
    assert.equal(await preferredCompetitionDate(['Premier League'],'2026-10-22'), '2026-10-19');
    assert.equal(queries.at(-1)?.get('sort'),'desc');
    assert.ok(queries.every(query => query.get('page_size') === '1'));
    assert.equal(await preferredCompetitionDate(['Premier League'],'2026-10-22',true), '2026-10-19');
    assert.equal(queries.at(-1)?.get('mode'),'results');
  } finally { globalThis.fetch = original; }
});
