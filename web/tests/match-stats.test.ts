import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeMatchStats, statShare, summaryStats, type MatchStatRow } from '../src/client/matchStats.ts';
const row = (id: string, home: number | null = 0, away: number | null = null): MatchStatRow => ({ id, label: id, group: 'Key stats', headline: true, home, away,
  home_display: home == null ? '—' : String(home), away_display: away == null ? '—' : String(away), home_estimated: false, away_estimated: false });

test('normalization preserves zeroes and missing sides, filters invalid and duplicate rows and periods', () => {
  assert.equal(normalizeMatchStats(undefined), null);
  const stats = normalizeMatchStats({status:'available', periods:[{id:'all',label:'All',rows:[row('zero'),row('zero'),row('bad',NaN),row('absent',null,null)]},
    {id:'first_half',label:'1st half',rows:[]},{id:'all',label:'All',rows:[row('dup')]}]});
  assert.deepEqual(stats?.periods.map(p => p.id), ['all']);
  assert.equal(stats?.periods[0].rows.length, 1);
  assert.equal(stats?.periods[0].rows[0].home, 0);
  assert.equal(stats?.periods[0].rows[0].away, null);
});
test('bars never imply missing or negative values are zero, and zero-zero is neutral', () => {
  assert.equal(statShare(row('zero',0,0)), null);
  assert.equal(statShare(row('missing',3,null)), null);
  assert.equal(statShare(row('negative',-1,2)), null);
  assert.equal(statShare(row('ratio',3,1)), 75);
  assert.equal(statShare(row('one-sided',0,1)), 0);
});
test('momentum summary always uses whole-match possession, xG and shots on target', () => {
  const stats = normalizeMatchStats({status:'available', periods:[{id:'first_half',label:'1st half',rows:[row('xg',1,2)]}]});
  assert.deepEqual(summaryStats(stats), []);
  stats!.periods.push({id:'all',label:'All',rows:[row('ball_possession',50,50),row('xg',2,3),row('total_shots',10,9),row('shots_on_target',4,5)]});
  assert.deepEqual(summaryStats(stats).map(r=>r.id), ['ball_possession','xg','shots_on_target']);
});
