import test from 'node:test';
import assert from 'node:assert/strict';
import { compareCompetitions } from '../src/client/competitionOrdering.ts';
test('app tiers take precedence over weights, including World Cup qualifier order', () => {
 const names = ['FIFA World Cup 2026','UEFA Champions League','La Liga','Premier League','Championship','Scottish Premiership','FA Cup','UEFA Nations League','Copa del Rey','World Cup Qualifying CAF','World Cup Qualifying UEFA'];
 const sorted = names.map(name => ({id:name,name})).sort(compareCompetitions).map(item => item.name);
 assert.deepEqual(sorted,['Premier League','FA Cup','Championship','Scottish Premiership','La Liga','Copa del Rey','UEFA Champions League','UEFA Nations League','FIFA World Cup 2026','World Cup Qualifying UEFA','World Cup Qualifying CAF']);
 assert.ok(compareCompetitions({id:'a',name:'Championship',weight:1},{id:'b',name:'UEFA Champions League',weight:100}) < 0);
 assert.ok(compareCompetitions({id:'a',name:'FA Cup',weight:101},{id:'b',name:'Premier League',weight:100}) < 0);
});
