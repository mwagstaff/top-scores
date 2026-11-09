import test from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
import React, { act } from 'react';
import { create } from 'react-test-renderer';
import { createSyncStore } from '../fpl-sync.mjs';

registerHooks({
  resolve(specifier, context, next) {
    try { return next(specifier, context); } catch (error) {
      if (error.code !== 'ERR_MODULE_NOT_FOUND' || !specifier.startsWith('.')) throw error;
      return next(`${specifier}.ts`, context);
    }
  },
  load(url, context, next) {
    if (!/\.tsx?$/.test(url)) return next(url, context);
    return { format: 'module', shortCircuit: true, source: ts.transpileModule(readFileSync(new URL(url), 'utf8'), { compilerOptions: { jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText };
  },
});

test('QR component completes automatically after phone approval without a browser click', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const { default: Pairer } = await import('../src/client/components/FantasyBrowserPairer.tsx');
  const store = createSyncStore(), initial = { manager: 1, rivals: [2], leagues: [] };
  const app = store.create(initial, 'ios'), owner = 'b'.repeat(43), storage = new Map();
  globalThis.sessionStorage = { getItem: k => storage.get(k) || null, setItem: (k, v) => storage.set(k, v), removeItem: k => storage.delete(k) };
  const original = globalThis.fetch;
  let pending, browserToken, accepted, completed = 0, root;
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    if (url.endsWith('/browser-pair')) {
      pending = store.beginBrowserPair(owner, body);
      return new Response(JSON.stringify({ ...pending, qr: 'data:image/png;base64,', url: 'https://example.test/fpl/connect', mode: body.mode, once: body.once }));
    }
    if (url.endsWith('/status')) {
      const result = store.finishBrowserPair(owner, body.requestID, browserToken);
      if (result.token) browserToken = result.token;
      return new Response(JSON.stringify(result));
    }
    store.cancelBrowserPair(owner, body.requestID);
    return new Response('{"ok":true}');
  };
  try {
    await act(async () => { root = create(React.createElement(Pairer, { sync: { preferences: { manager: null, rivals: [], leagues: [] }, pause() {}, resume() {}, accept(snapshot, linked) { accepted = { snapshot, linked }; } }, onComplete() { completed++; } })); });
    assert.equal(completed, 0);
    assert.ok(pending);
    store.approveBrowserPair(app.token, pending.secret);
    await act(async () => { t.mock.timers.tick(2000); });
    assert.equal(completed, 1);
    assert.equal(accepted.linked, true);
    assert.deepEqual(accepted.snapshot.preferences, initial);
    assert.equal(storage.size, 0);
    assert.deepEqual(store.read(browserToken).preferences, initial);
    await act(async () => { t.mock.timers.tick(4000); });
    assert.equal(completed, 1, 'completion is applied only once');
  } finally { if (root) await act(async () => root.unmount()); globalThis.fetch = original; store.close(); }
});
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
globalThis.document = { hidden: false, addEventListener() {}, removeEventListener() {} };
globalThis.window = { setInterval, addEventListener() {}, removeEventListener() {} };
const { useFantasyPreferences } = await import('../src/client/fantasySync.ts');

test('actual client keeps offline and in-flight edits, merges remote changes and retains local preferences on revocation', async () => {
  const store = createSyncStore(), initial = { manager: 1, rivals: [2], leagues: [] };
  const app = store.create(initial, 'ios'), link = store.issue(app.token);
  const web = store.redeem({ secret: link.secret, revision: 1, preferences: initial, mode: 'replace' }, '', 'web');
  const storage = new Map([
    ['top-scores.web.fpl.v1', JSON.stringify(initial)],
    ['top-scores.web.fpl.sync.v1', JSON.stringify({ revision: 1, preferences: initial })],
  ]);
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: { getItem: k => storage.get(k) || null, setItem: (k, v) => storage.set(k, v), removeItem: k => storage.delete(k) } });
  let offline = true, hold = false, release, state, root;
  const original = globalThis.fetch;
  globalThis.fetch = async (_url, init) => {
    if (offline) throw new Error('offline');
    let response;
    try { response = new Response(JSON.stringify(init.body ? store.update(web.token, JSON.parse(init.body)) : store.read(web.token))); }
    catch (e) { response = new Response(JSON.stringify({ error: e.message, snapshot: e.snapshot }), { status: e.status }); }
    if (hold) { hold = false; await new Promise(resolve => { release = resolve; }); }
    return response;
  };
  function Harness() { state = useFantasyPreferences(); return null; }
  try {
    await act(async () => { root = create(React.createElement(Harness)); });
    await act(async () => { state.persist({ ...initial, rivals: [2, 3] }); });
    await act(async () => { root.unmount(); });
    offline = false;
    await act(async () => { root = create(React.createElement(Harness)); });
    assert.deepEqual(store.read(app.token).preferences.rivals, [2, 3], 'offline change survives reload');
    const remote = store.read(app.token);
    store.update(app.token, { base: remote, preferences: { ...remote.preferences, rivals: [2, 3, 4] } });
    hold = true;
    let pending;
    await act(async () => { pending = state.sync(); await Promise.resolve(); });
    await act(async () => { state.persist({ ...state.preferences, rivals: [2, 3, 5] }); });
    await act(async () => { release(); await pending; });
    await act(async () => { await state.sync(); });
    assert.deepEqual(state.preferences.rivals, [2, 3, 4, 5], 'in-flight local edit and remote addition both survive');
    assert.deepEqual(store.read(app.token).preferences.rivals, [2, 3, 4, 5]);
    store.disconnect(app.token, web.deviceID);
    await act(async () => { await state.sync(); });
    assert.equal(state.connected, false);
    assert.deepEqual(state.preferences.rivals, [2, 3, 4, 5], 'revocation keeps local data');
  } finally {
    if (root) await act(async () => root.unmount());
    globalThis.fetch = original; store.close();
  }
});
