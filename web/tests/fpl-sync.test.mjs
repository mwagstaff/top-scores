import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createSyncStore, registerFantasySync, mergePreferences, validatePreferences } from '../fpl-sync.mjs';
import { randomBytes } from 'node:crypto';
import { registerFantasyAppLinks } from '../fpl-app-links.mjs';

const prefs = (manager = 1, rivals = [2], leagues = [{ id: 10, name: 'Friends' }]) => ({ manager, rivals, leagues });
const redeem = (store, link, local = prefs(null, [], []), extra = {}) => store.redeem({ secret: link.secret, revision: store.preview(link.secret).revision, preferences: local, mode: 'merge', ...extra }, '', 'web');

test('pair previews are non-consuming, redemption is single-use, credentials are independent', () => {
  const s = createSyncStore();
  try {
    const app = s.create(prefs(), 'ios'), link = s.issue(app.token);
    assert.equal(s.preview(link.secret).preferences.manager, 1);
    assert.equal(s.preview(link.code.toLowerCase()).preferences.manager, 1);
    const web = redeem(s, link);
    assert.notEqual(app.token, web.token);
    assert.deepEqual(s.read(web.token).preferences, prefs());
    assert.throws(() => redeem(s, link), { status: 410 });
    s.disconnect(web.token);
    assert.throws(() => s.read(web.token), { status: 401 });
    assert.deepEqual(s.read(app.token).preferences, prefs());
  } finally { s.close(); }
});

test('expiry, replaced links and issuer revocation invalidate pairing', () => {
  let now = 1_000; const s = createSyncStore(':memory:', () => now);
  try {
    const app = s.create(prefs(), 'ios'), old = s.issue(app.token), fresh = s.issue(app.token);
    assert.throws(() => s.preview(old.secret), { status: 410 });
    now += 600_001;
    assert.throws(() => s.preview(fresh.secret), { status: 410 });
    const last = s.issue(app.token); s.disconnect(app.token);
    assert.throws(() => s.preview(last.secret), { status: 410 });
  } finally { s.close(); }
});

test('concurrent independent edits merge and offline removals do not resurrect', () => {
  const s = createSyncStore();
  try {
    const app = s.create(prefs(), 'ios'), web = redeem(s, s.issue(app.token));
    const base = s.read(app.token);
    s.update(app.token, { base, preferences: prefs(1, [2, 3]) });
    const result = s.update(web.token, { base, preferences: prefs(1, [], [{ id: 11, name: 'Work' }]) });
    assert.deepEqual(result.preferences, prefs(1, [3], [{ id: 11, name: 'Work' }]));
    assert.deepEqual(s.update(web.token, { base, preferences: prefs(1, [], [{ id: 11, name: 'Work' }]) }).preferences, result.preferences, 'lost response can retry without reverting changes');
  } finally { s.close(); }
});

test('simultaneous team changes conflict; explicit resolution uses latest base', () => {
  const s = createSyncStore();
  try {
    const a = s.create(prefs(), 'ios'), b = redeem(s, s.issue(a.token)), base = s.read(a.token);
    s.update(a.token, { base, preferences: prefs(4) });
    assert.throws(() => s.update(b.token, { base, preferences: prefs(5) }), e => e.status === 409 && e.snapshot.preferences.manager === 4);
    assert.equal(s.update(b.token, { base: s.read(b.token), preferences: prefs(5) }).preferences.manager, 5);
  } finally { s.close(); }
});

test('reorders merge with independent additions but competing reorders conflict', () => {
  const b = prefs(1, [2, 3, 4]);
  assert.deepEqual(mergePreferences(b, prefs(1, [3, 2, 4]), prefs(1, [2, 3, 4, 5])).preferences.rivals, [3, 2, 4, 5]);
  assert.deepEqual(mergePreferences(b, prefs(1, [3, 2, 4]), prefs(1, [4, 3, 2])).conflicts, ['rivals']);
});

test('import requires team choice, deduplicates, and removes own team from rivals', () => {
  const s = createSyncStore();
  try {
    const a = s.create(prefs(), 'ios'), link = s.issue(a.token);
    assert.throws(() => redeem(s, link, prefs(3, [1, 2, 4])), { status: 400 });
    const b = redeem(s, link, prefs(3, [1, 2, 4]), { manager: 'local' });
    assert.deepEqual(b.preferences, prefs(3, [2, 1, 4]));
    assert.deepEqual(s.read(a.token).preferences, b.preferences);
  } finally { s.close(); }
});

test('import once does not modify source, creates no credential and disconnects old browser atomically', () => {
  const s = createSyncStore();
  try {
    const a = s.create(prefs(), 'ios'), old = s.create(prefs(8), 'web'), link = s.issue(a.token);
    const result = s.redeem({ secret: link.secret, revision: 1, preferences: prefs(8, [9]), manager: 'local', mode: 'merge', once: true }, old.token, 'web');
    assert.equal(result.token, undefined); assert.equal(result.preferences.manager, 8);
    assert.deepEqual(s.read(a.token).preferences, prefs());
    assert.throws(() => s.read(old.token), { status: 401 });
  } finally { s.close(); }
});

test('stale import preview is rejected without consuming link or altering data', () => {
  const s = createSyncStore();
  try {
    const a = s.create(prefs(), 'ios'), link = s.issue(a.token);
    s.update(a.token, { base: s.read(a.token), preferences: prefs(4) });
    assert.throws(() => s.redeem({ secret: link.secret, revision: 1, preferences: prefs(), mode: 'replace' }, '', 'web'), { status: 409 });
    assert.equal(s.preview(link.secret).preferences.manager, 4);
  } finally { s.close(); }
});

test('data and connections survive restart; arbitrary credentials cannot access a space', () => {
  const dir = mkdtempSync(join(tmpdir(), 'fpl-sync-')), file = join(dir, 'state.sqlite');
  let s = createSyncStore(file);
  try {
    const a = s.create(prefs(), 'ios'), link = s.issue(a.token); s.close(); s = createSyncStore(file);
    assert.deepEqual(s.read(a.token).preferences, prefs());
    assert.equal(redeem(s, link).preferences.manager, 1);
    assert.throws(() => s.read('wrong'), { status: 401 });
    const outsider = s.create(prefs(9), 'web'); s.disconnect(outsider.token, a.deviceID);
    assert.equal(s.read(a.token).preferences.manager, 1);
  } finally { s.close(); rmSync(dir, { recursive: true }); }
});

test('invalid and over-limit preferences fail instead of silently truncating', () => {
  for (const p of [prefs(-1), prefs(1, [NaN]), prefs(1, Array(101).fill(2)), prefs(1, [], [{ id: 2, name: 'x'.repeat(201) }])]) assert.throws(() => validatePreferences(p), { status: 400 });
  assert.deepEqual(validatePreferences(prefs(1, [1, 2, 2])), prefs());
});

test('HTTP cookies, CSRF protection, no-store, revocation and rate limits', async () => {
  const app = express(), service = registerFantasySync(app, { store: createSyncStore(), origin: 'https://example.test', secure: true });
  const server = app.listen(0, '127.0.0.1'); await new Promise(resolve => server.once('listening', resolve));
  const url = `http://127.0.0.1:${server.address().port}/api/fpl-sync/`;
  const request = (path, body, headers = {}) => fetch(url + path, { method: body ? 'POST' : 'GET', headers: { 'Content-Type': 'application/json', ...headers }, body: body ? JSON.stringify(body) : undefined });
  try {
    assert.equal((await request('session', { preferences: prefs() }, { Origin: 'https://evil.test' })).status, 403);
    assert.equal((await request('session', { preferences: prefs() }, { 'Sec-Fetch-Site': 'cross-site' })).status, 403);
    const session = await request('session', { preferences: prefs() }, { 'X-FPL-Client': 'ios' });
    const source = await session.json(); assert.ok(source.token);
    const link = await (await request('pair', {}, { Authorization: `Bearer ${source.token}` })).json();
    const response = await request('redeem', { secret: link.secret, revision: 1, preferences: prefs(null, [], []), mode: 'merge' });
    assert.equal(response.headers.get('cache-control'), 'no-store');
    const cookie = response.headers.get('set-cookie'); assert.match(cookie, /HttpOnly/); assert.match(cookie, /Secure/); assert.match(cookie, /SameSite=Strict/);
    assert.equal((await response.json()).token, undefined);
    const headers = { Cookie: cookie.split(';')[0] };
    assert.equal((await request('state', undefined, headers)).status, 200);
    assert.equal((await request('disconnect', {}, headers)).status, 200);
    assert.equal((await request('state', undefined, headers)).status, 401);
    let rate; for (let i = 0; i < 22; i++) rate = await request('preview', { secret: 'bad' });
    assert.equal(rate.status, 429);
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); service.close(); }
});

const ownerSecret = () => randomBytes(32).toString('base64url');
test('website QR can only be completed by its originating browser after phone approval', () => {
  const s = createSyncStore();
  try {
    const owner = ownerSecret(), a = s.create(prefs(), 'ios');
    const pending = s.beginBrowserPair(owner, { preferences: prefs(null, [], []), mode: 'replace' });
    assert.deepEqual(s.finishBrowserPair(owner, pending.requestID, ''), { status: 'waiting' });
    assert.equal(s.inspectBrowserPair(pending.secret).code, pending.code);
    assert.equal(s.inspectBrowserPair(pending.secret).code, pending.code, 'scan previews do not approve');
    assert.throws(() => s.approveBrowserPair('', pending.secret), { status: 401 });
    assert.throws(() => s.finishBrowserPair(pending.secret, pending.requestID, ''), { status: 410 }, 'QR secret cannot claim browser credential');
    assert.throws(() => s.finishBrowserPair(ownerSecret(), pending.requestID, ''), { status: 410 });
    s.approveBrowserPair(a.token, pending.secret);
    const result = s.finishBrowserPair(owner, pending.requestID, '');
    assert.equal(result.status, 'connected'); assert.deepEqual(result.preferences, prefs());
    assert.notEqual(result.token, a.token);
    assert.equal(s.read(result.token).preferences.manager, 1);
    assert.equal(s.finishBrowserPair(owner, pending.requestID, result.token).token, undefined);
    assert.equal(s.read(a.token).devices.length, 2);
  } finally { s.close(); }
});

test('lost phone and browser responses can retry; revocation cannot be undone by polling', () => {
  const s = createSyncStore();
  try {
    const owner = ownerSecret(), a = s.create(prefs(), 'ios');
    const p = s.beginBrowserPair(owner, { preferences: prefs(null, [], []), mode: 'replace' });
    s.approveBrowserPair(a.token, p.secret); s.approveBrowserPair(a.token, p.secret);
    const lost = s.finishBrowserPair(owner, p.requestID, '');
    const recovered = s.finishBrowserPair(owner, p.requestID, '');
    assert.throws(() => s.read(lost.token), { status: 401 });
    assert.equal(s.read(recovered.token).preferences.manager, 1);
    const devices = s.read(a.token).devices;
    assert.equal(devices.length, 2);
    s.disconnect(a.token, devices.find(d => d.id !== a.deviceID).id);
    assert.throws(() => s.finishBrowserPair(owner, p.requestID, recovered.token), { status: 410 });
  } finally { s.close(); }
});

test('cancelled, superseded, wrong-tab and expired QR requests cannot connect', () => {
  let now = 100; const s = createSyncStore(':memory:', () => now);
  try {
    const owner = ownerSecret(), a = s.create(prefs(), 'ios');
    const p = s.beginBrowserPair(owner, { preferences: prefs(), mode: 'replace' });
    s.cancelBrowserPair(ownerSecret(), p.requestID);
    assert.equal(s.inspectBrowserPair(p.secret).code, p.code);
    const next = s.beginBrowserPair(owner, { preferences: prefs(), mode: 'replace' });
    assert.throws(() => s.inspectBrowserPair(p.secret), { status: 410 });
    assert.throws(() => s.finishBrowserPair(owner, p.requestID, ''), { status: 410 });
    s.approveBrowserPair(a.token, next.secret); s.cancelBrowserPair(owner, next.requestID);
    assert.throws(() => s.finishBrowserPair(owner, next.requestID, ''), { status: 410 });
    const last = s.beginBrowserPair(owner, { preferences: prefs(), mode: 'replace' }); now += 600_001;
    assert.throws(() => s.approveBrowserPair(a.token, last.secret), { status: 410 });
    assert.equal(s.read(a.token).devices.length, 1);
  } finally { s.close(); }
});

test('QR import once keeps source unchanged, supports merge and can retry completion', () => {
  const s = createSyncStore();
  try {
    const owner = ownerSecret(), a = s.create(prefs(), 'ios'), old = s.create(prefs(9), 'web');
    const p = s.beginBrowserPair(owner, { preferences: prefs(9, [3]), mode: 'merge', once: true });
    s.approveBrowserPair(a.token, p.secret);
    const result = s.finishBrowserPair(owner, p.requestID, old.token);
    assert.deepEqual(result.preferences, prefs(1, [2, 3])); assert.equal(result.once, true); assert.equal(result.token, undefined);
    assert.deepEqual(s.finishBrowserPair(owner, p.requestID, ''), result);
    assert.deepEqual(s.read(a.token).preferences, prefs());
    assert.throws(() => s.read(old.token), { status: 401 });
  } finally { s.close(); }
});

test('QR approval cannot be stolen by a second source and revoking the approver invalidates it', () => {
  const s = createSyncStore();
  try {
    const owner = ownerSecret(), a = s.create(prefs(), 'ios'), b = s.create(prefs(8), 'ios');
    const p = s.beginBrowserPair(owner, { preferences: prefs(), mode: 'replace' });
    s.approveBrowserPair(a.token, p.secret);
    assert.throws(() => s.approveBrowserPair(b.token, p.secret), { status: 409 });
    s.disconnect(a.token);
    assert.throws(() => s.finishBrowserPair(owner, p.requestID, ''), { status: 410 });
  } finally { s.close(); }
});

test('HTTP QR handoff sets browser-only credentials and serves scoped Universal Links', async () => {
  const app = express(), service = registerFantasySync(app, { store: createSyncStore(), origin: 'https://example.test', secure: true });
  registerFantasyAppLinks(app);
  const server = app.listen(0, '127.0.0.1'); await new Promise(resolve => server.once('listening', resolve));
  const root = `http://127.0.0.1:${server.address().port}`;
  const request = (path, body, headers = {}) => fetch(root + '/api/fpl-sync/' + path, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) });
  try {
    const response = await request('browser-pair', { preferences: prefs(null, [], []), mode: 'replace' });
    const p = await response.json(), owner = response.headers.get('set-cookie').split(';')[0];
    assert.match(owner, /^__Host-fpl-pair=/); assert.match(p.qr, /^data:image\/png;base64,/);
    assert.match(p.url, /^https:\/\/example.test\/fpl\/connect#pair=/);
    assert.equal(p.owner, undefined);
    const scan = new URLSearchParams(new URL(p.url).hash.slice(1)).get('pair');
    const a = await (await request('session', { preferences: prefs() }, { 'X-FPL-Client': 'ios' })).json();
    const approval = await request('browser-pair/approve', { secret: scan }, { Authorization: `Bearer ${a.token}` });
    assert.deepEqual(await approval.json(), { ok: true });
    const finish = await request('browser-pair/status', { requestID: p.requestID }, { Cookie: owner, 'X-FPL-Client': 'ios' });
    assert.match(finish.headers.get('set-cookie'), /__Host-fpl-sync=.*HttpOnly; Secure/);
    const result = await finish.json(); assert.equal(result.token, undefined); assert.equal(result.status, 'connected');
    const association = await (await fetch(root + '/.well-known/apple-app-site-association')).json();
    assert.deepEqual(association.applinks.details[0].appIDs, ['SJ8X4DLAN9.topscores.dev.skynolimit']);
    assert.equal(association.applinks.details[0].components[0]['/'], '/fpl/connect');
    const fallback = await fetch(root + '/fpl/connect');
    assert.equal(fallback.status, 200); assert.equal(fallback.headers.get('referrer-policy'), 'no-referrer');
    assert.match(await fallback.text(), /topscores:\/\/fpl-connect#pair=/);
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); service.close(); }
});


test('both public website origins can create and complete QR pairing, while untrusted origins are rejected', async () => {
  const app = express(), origin = 'https://top-scores.skynolimit.dev';
  const service = registerFantasySync(app, { store: createSyncStore(), origin, secure: true });
  const server = app.listen(0, '127.0.0.1'); await new Promise(resolve => server.once('listening', resolve));
  const url = `http://127.0.0.1:${server.address().port}/api/fpl-sync/`;
  const request = (path, body, headers = {}) => fetch(url + path, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) });
  try {
    const source = await (await request('session', { preferences: prefs() }, { 'X-FPL-Client': 'ios' })).json();
    for (const website of ['https://top-scores.com', origin]) {
      const headers = { Origin: website, 'Sec-Fetch-Site': 'same-origin' };
      const begin = await request('browser-pair', { preferences: prefs(null, [], []), mode: 'replace' }, headers);
      assert.equal(begin.status, 200, website);
      const p = await begin.json(), cookie = begin.headers.get('set-cookie').split(';')[0];
      assert.match(p.qr, /^data:image\/png;base64,/);
      assert.equal(new URL(p.url).origin, origin, 'QR keeps the app-supported Universal Link host');
      const secret = new URLSearchParams(new URL(p.url).hash.slice(1)).get('pair');
      assert.equal((await request('browser-pair/approve', { secret }, { Authorization: `Bearer ${source.token}` })).status, 200);
      const finish = await request('browser-pair/status', { requestID: p.requestID }, { ...headers, Cookie: cookie });
      assert.equal(finish.status, 200);
      assert.equal((await finish.json()).status, 'connected');
      assert.match(finish.headers.get('set-cookie'), /__Host-fpl-sync=.*HttpOnly; Secure/);
    }
    for (const website of ['https://evil.test', 'https://top-scores.com.evil.test', 'http://top-scores.com', 'null']) {
      const response = await request('browser-pair', {}, { Origin: website });
      assert.equal(response.status, 403);
      assert.match((await response.json()).error, /website address is not supported/);
    }
    assert.equal((await request('browser-pair', {}, { Origin: origin, 'Sec-Fetch-Site': 'cross-site' })).status, 403);
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); service.close(); }
});

test('league order syncs both ways and older clients preserve it', () => {
 const s=createSyncStore();
 try {
  const app=s.create({...prefs(),leagueOrder:[10,11,12]},'ios');
  const web=redeem(s,s.issue(app.token));
  assert.deepEqual(web.preferences.leagueOrder,[10,11,12]);
  const base=s.read(web.token);
  s.update(web.token,{base,preferences:{...base.preferences,leagueOrder:[12,10,11]}});
  const phone=s.read(app.token);
  assert.deepEqual(phone.preferences.leagueOrder,[12,10,11]);
  const updated=s.update(app.token,{base:phone,preferences:{...phone.preferences,leagueOrder:[11,12,10]}});
  assert.deepEqual(s.read(web.token).preferences.leagueOrder,[11,12,10]);
  s.update(web.token,{base:updated,preferences:prefs(1,[2,3])});
  assert.deepEqual(s.read(app.token).preferences.leagueOrder,[11,12,10]);
  assert.deepEqual(s.read(app.token).preferences.rivals,[2,3]);
 } finally {s.close();}
 assert.throws(()=>validatePreferences({...prefs(),leagueOrder:[-1]}),{status:400});
});
