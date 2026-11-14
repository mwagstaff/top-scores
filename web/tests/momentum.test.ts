import test from 'node:test';
import assert from 'node:assert/strict';
import { annotationLanes, normalizeMomentum, momentumPath, type MomentumAnnotation } from '../src/client/momentum.ts';

test('missing momentum stays absent and malformed samples cannot produce SVG NaN', () => {
  assert.equal(normalizeMomentum(undefined), null);
  assert.equal(normalizeMomentum({ end_minute: 0 }), null);
  const result = normalizeMomentum({ status: 'available', end_minute: 90.5, scale: 100,
    annotations: [], ticks: [], segments: [
      { id: 'ok', side: 'home', points: [{ minute: 1, value: 0 }, { minute: 2, value: 20 }] },
      { id: 'bad', side: 'away', points: [{ minute: 1, value: null }, { minute: 2, value: -20 }] },
    ] });
  assert.equal(result?.segments.length, 1);
  assert.ok(!momentumPath(result!.segments[0], result!.end_minute, result!.scale).includes('NaN'));
});

test('overlapping added-time annotations receive separate touch targets on narrow screens', () => {
  const event = (id: string, minute: number, side = 'home') => ({ id, minute, side, time: '90+3′', kind: 'goal', label: 'Goal' } as MomentumAnnotation);
  const annotations = [event('1', 90.5), event('2', 90.5), event('3', 89), event('4', 80), event('5', 90.5, 'away')];
  const markers = annotationLanes(annotations, 'home', 240, 90.5);
  assert.equal(markers.length, 4);
  for (let i = 0; i < markers.length; i++) for (let j = i + 1; j < markers.length; j++) {
    assert.ok(markers[i].lane !== markers[j].lane || Math.abs(markers[i].x - markers[j].x) >= 44);
  }
  assert.deepEqual(annotationLanes(annotations, 'away', 240, 90.5).map(m => m.lane), [0]);
  assert.equal(annotations[0].id, '1', 'layout must not mutate incoming data');
});

test('dark and identical team colours produce visible, distinct chart areas', async () => {
  const { momentumColors } = await import('../src/client/momentum.ts');
  const unknown = { background: '#111111', foreground: '#FFFFFF' };
  const colors = momentumColors(unknown, unknown);
  assert.equal(colors.home.background, '#FFFFFF');
  assert.notEqual(colors.home.background, colors.away.background);
  const teams = momentumColors({background:'#fcdc00',foreground:'#000000'}, {background:'#e6003a',foreground:'#ffffff'});
  assert.equal(teams.home.background, '#fcdc00');
  assert.equal(teams.away.background, '#e6003a');
});
