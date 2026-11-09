import test from 'node:test';
import assert from 'node:assert/strict';
import { parseFplID, readPreferences, visibleLeagues, sortSquads, managerInitials, playerImageCandidates } from '../src/client/fantasyData.ts';
test('manager and league links are parsed only from the official origin', () => {
  assert.equal(parseFplID('123456'), 123456);
  assert.equal(parseFplID('https://fantasy.premierleague.com/entry/123456/event/10'), 123456);
  assert.equal(parseFplID('https://fantasy.premierleague.com/leagues/99/standings/c', 'league'), 99);
  for (const input of ['0', '-1', '1.5', 'https://evil.test/entry/1/', 'https://fantasy.premierleague.com.evil.test/entry/1/']) assert.equal(parseFplID(input), null);
});
test('storage unavailable is a usable empty setup state', () => {
  assert.deepEqual(readPreferences(), {manager:null,rivals:[],leagues:[]});
});

test('your leagues excludes automatic leagues and respects shared private league order', () => {
 const profile = { leagues: { classic: [{id:1,name:'Overall',league_type:'s'}, {id:2,name:'Shirley Super League',league_type:'x'}, {id:3,name:'Friends',league_type:'x'}] } } as any;
 assert.deepEqual(visibleLeagues(profile, [{id:4,name:'Saved league'},{id:1,name:'Overall'}], [3,2]).map(l => l.id), [3,2,4]);
 assert.equal(visibleLeagues(profile, [{id:2,name:'League 2'}])[0].name, 'Shirley Super League');
});
test('manager strip sorts by gameweek and rivals table by total points', () => {
 const squads = [{profile:{id:1}, points:65,history:{total_points:625}}, {profile:{id:2},points:80,history:{total_points:600}}] as any;
 assert.deepEqual(sortSquads(squads).map(s => s.profile.id), [2,1]);
 assert.deepEqual(sortSquads(squads,true).map(s => s.profile.id), [1,2]);
 assert.equal(managerInitials({player_first_name:'Mike',player_last_name:'Wagstaff'} as any),'MW');
});
test('portraits use current assets before the legacy fallback', () => {
 for (const code of [494521,465730]) {
  const urls=playerImageCandidates({code} as any);
  assert.match(urls[0],new RegExp(`premierleague25/photos/players/110x140/${code}.png$`));
  assert.match(urls[1],new RegExp(`/p${code}.png$`));
 }
});
