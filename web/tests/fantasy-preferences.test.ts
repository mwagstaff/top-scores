import test from 'node:test';
import assert from 'node:assert/strict';
import { parseFplID, readPreferences } from '../src/client/fantasyData.ts';
test('manager and league links are parsed only from the official origin', () => {
  assert.equal(parseFplID('123456'), 123456);
  assert.equal(parseFplID('https://fantasy.premierleague.com/entry/123456/event/10'), 123456);
  assert.equal(parseFplID('https://fantasy.premierleague.com/leagues/99/standings/c', 'league'), 99);
  for (const input of ['0', '-1', '1.5', 'https://evil.test/entry/1/', 'https://fantasy.premierleague.com.evil.test/entry/1/']) assert.equal(parseFplID(input), null);
});
test('storage unavailable is a usable empty setup state', () => {
  assert.deepEqual(readPreferences(), {manager:null,rivals:[],leagues:[]});
});
