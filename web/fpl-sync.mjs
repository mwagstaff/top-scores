import Database from 'better-sqlite3';
import express from 'express';
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import QRCode from 'qrcode';

const hash = value => createHash('sha256').update(value).digest('hex');
const secret = () => randomBytes(32).toString('base64url');
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const fail = (status, message, extra = {}) => { throw Object.assign(new Error(message), { status, ...extra }); };
const lifetime = 180 * 86400_000;
export function validatePreferences(value) {
  const validID = n => Number.isSafeInteger(n) && n > 0 && n < 1e9;
  if (!value || (value.manager !== null && !validID(value.manager)) ||
      !Array.isArray(value.rivals) || value.rivals.length > 100 || !value.rivals.every(validID) ||
      (value.leagueOrder !== undefined && (!Array.isArray(value.leagueOrder) || value.leagueOrder.length > 100 || !value.leagueOrder.every(validID))) ||
      !Array.isArray(value.leagues) || value.leagues.length > 100 ||
      !value.leagues.every(l => l && validID(l.id) && typeof l.name === 'string' && l.name.length <= 200)) {
    fail(400, 'Invalid FPL preferences. Use up to 100 rivals and 100 leagues.');
  }
  return { manager: value.manager, rivals: [...new Set(value.rivals)].filter(id => id !== value.manager),
    leagues: [...new Map(value.leagues.map(l => [l.id, { id: l.id, name: l.name }])).values()],
    ...(value.leagueOrder !== undefined ? { leagueOrder: [...new Set(value.leagueOrder)] } : {}) };
}

// Three-way merge: independent additions/removals combine; competing edits and
// reorders require an explicit choice. Display names do not create conflicts.
export function mergePreferences(base, local, remote) {
  const conflicts = [];
  const merge = (key, b, l, r) => {
    if (equal(l, b)) return r;
    if (equal(r, b) || equal(l, r)) return l;
    if (key === 'manager') { conflicts.push(key); return r; }
    const common = b.filter(id => l.includes(id) && r.includes(id));
    const lo = l.filter(id => common.includes(id)), ro = r.filter(id => common.includes(id));
    if (!equal(lo, common) && !equal(ro, common) && !equal(lo, ro)) conflicts.push(key);
    const removed = b.filter(id => !l.includes(id) || !r.includes(id));
    const order = !equal(lo, common) ? l : r;
    return [...new Set([...order, ...l, ...r])].filter(id => !removed.includes(id));
  };
  const manager = merge('manager', base.manager, local.manager, remote.manager);
  const rivals = merge('rivals', base.rivals, local.rivals, remote.rivals).filter(id => id !== manager);
  const leagueIDs = merge('leagues', base.leagues.map(l => l.id), local.leagues.map(l => l.id), remote.leagues.map(l => l.id));
  const names = new Map([...local.leagues, ...remote.leagues].map(l => [l.id, l]));
  const order = [base, local, remote].some(p => p.leagueOrder !== undefined) ? { leagueOrder: merge('leagueOrder', base.leagueOrder || [], local.leagueOrder ?? base.leagueOrder ?? [], remote.leagueOrder ?? base.leagueOrder ?? []) } : {};
  return { preferences: { manager, rivals, leagues: leagueIDs.map(id => names.get(id)), ...order }, conflicts };
}

export function createSyncStore(filename = ':memory:', now = Date.now) {
  if (filename !== ':memory:') mkdirSync(dirname(filename), { recursive: true, mode: 0o700 });
  const db = new Database(filename);
  if (filename !== ':memory:') chmodSync(filename, 0o600);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.exec(`CREATE TABLE IF NOT EXISTS spaces (id TEXT PRIMARY KEY, preferences TEXT NOT NULL, revision INTEGER NOT NULL, touched INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, space TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE, token TEXT UNIQUE NOT NULL, label TEXT NOT NULL, expires INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS pairs (token TEXT PRIMARY KEY, code TEXT UNIQUE NOT NULL, space TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE, issuer TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE, expires INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS devices_space ON devices(space);
    CREATE TABLE IF NOT EXISTS browser_pairs (
      id TEXT PRIMARY KEY, owner TEXT UNIQUE NOT NULL, scan TEXT UNIQUE NOT NULL,
      code TEXT NOT NULL, preferences TEXT NOT NULL, mode TEXT NOT NULL, once_only INTEGER NOT NULL,
      expires INTEGER NOT NULL, space TEXT REFERENCES spaces(id) ON DELETE CASCADE,
      approver TEXT REFERENCES devices(id) ON DELETE CASCADE,
      device TEXT REFERENCES devices(id) ON DELETE CASCADE, imported TEXT
    );`);
  const snapshot = id => {
    const row = db.prepare('SELECT * FROM spaces WHERE id = ?').get(id);
    return { preferences: JSON.parse(row.preferences), revision: row.revision };
  };
  const device = token => {
    const row = db.prepare('SELECT * FROM devices WHERE token = ? AND expires > ?').get(hash(token || ''), now());
    if (!row) fail(401, 'Connection expired or disconnected. Pair again to resume sync.');
    db.prepare('UPDATE devices SET expires = ? WHERE id = ?').run(now() + lifetime, row.id);
    db.prepare('UPDATE spaces SET touched = ? WHERE id = ?').run(now(), row.space);
    return row;
  };
  const addDevice = (space, label) => {
    const token = secret(), id = randomUUID();
    db.prepare('INSERT INTO devices VALUES (?, ?, ?, ?, ?)').run(id, space, hash(token), label === 'ios' ? 'iPhone / iPad' : 'Web browser', now() + lifetime);
    return { token, deviceID: id, ...snapshot(space) };
  };
  const save = (space, preferences) => {
    preferences = validatePreferences(preferences);
    if (!equal(snapshot(space).preferences, preferences)) db.prepare('UPDATE spaces SET preferences = ?, revision = revision + 1, touched = ? WHERE id = ?').run(JSON.stringify(preferences), now(), space);
    return snapshot(space);
  };
  const pair = input => {
    if (typeof input !== 'string' || input.length > 100) fail(400, 'Enter a valid pairing code or open the link from the app.');
    const row = db.prepare('SELECT * FROM pairs WHERE (token = ? OR code = ?) AND expires > ?').get(hash(input), hash(input.replace(/[ -]/g, '').toUpperCase()), now());
    if (!row) fail(410, 'This link or code has expired or was already used. Create a new one in the app.');
    return row;
  };
  const browserPair = (value, column, id) => {
    if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(value)) fail(410, 'This QR code has expired or was cancelled. Generate a new one on the website.');
    const row = db.prepare(`SELECT * FROM browser_pairs WHERE ${column} = ? AND expires > ?`).get(hash(value), now());
    if (!row || (id && row.id !== id)) fail(410, 'This QR code has expired or was cancelled. Generate a new one on the website.');
    return row;
  };
  return {
    close: () => db.close(),
    cleanup: () => db.transaction(() => {
      db.prepare('DELETE FROM pairs WHERE expires <= ?').run(now());
      db.prepare('DELETE FROM browser_pairs WHERE expires <= ?').run(now());
      db.prepare('DELETE FROM devices WHERE expires <= ?').run(now());
      db.prepare('DELETE FROM spaces WHERE touched < ? OR NOT EXISTS (SELECT 1 FROM devices WHERE devices.space = spaces.id)').run(now() - lifetime);
    })(),
    create: db.transaction((preferences, label) => {
      preferences = validatePreferences(preferences);
      const space = randomUUID();
      db.prepare('INSERT INTO spaces VALUES (?, ?, 1, ?)').run(space, JSON.stringify(preferences), now());
      return addDevice(space, label);
    }),
    beginBrowserPair: db.transaction((owner, input) => {
      const preferences = validatePreferences(input.preferences);
      if (!['replace', 'merge'].includes(input.mode)) fail(400, 'Choose how to import your settings.');
      const scan = secret(), id = randomUUID(), expiresAt = now() + 600_000;
      const code = String(randomBytes(4).readUInt32BE() % 1_000_000).padStart(6, '0');
      db.prepare('DELETE FROM browser_pairs WHERE owner = ?').run(hash(owner));
      db.prepare('INSERT INTO browser_pairs (id, owner, scan, code, preferences, mode, once_only, expires) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
        .run(id, hash(owner), hash(scan), code, JSON.stringify(preferences), input.mode, input.once === true ? 1 : 0, expiresAt);
      return { requestID: id, secret: scan, code, expiresAt };
    }),
    inspectBrowserPair: scan => {
      const p = browserPair(scan, 'scan');
      if (p.space) fail(409, 'This browser has already been approved. Return to the website.');
      return { code: p.code, expiresAt: p.expires, mode: p.mode, once: !!p.once_only };
    },
    approveBrowserPair: db.transaction((token, scan) => {
      const d = device(token), p = browserPair(scan, 'scan');
      if (p.space) {
        if (p.approver !== d.id) fail(409, 'This browser has already been connected by another device.');
        return { ok: true }; // A lost phone response can safely retry.
      }
      if (!snapshot(d.space).preferences.manager) fail(400, 'Set up your FPL team in the app before connecting the website.');
      db.prepare('UPDATE browser_pairs SET space = ?, approver = ? WHERE id = ?').run(d.space, d.id, p.id);
      return { ok: true };
    }),
    finishBrowserPair: db.transaction((owner, id, oldToken) => {
      if (typeof id !== 'string' || !id) fail(400, 'Missing pairing request.');
      const p = browserPair(owner, 'owner', id);
      if (!p.space) return { status: 'waiting' };
      if (p.imported && p.once_only) return { status: 'connected', once: true, ...JSON.parse(p.imported) };
      if (p.device) {
        const d = db.prepare('SELECT * FROM devices WHERE id = ? AND expires > ?').get(p.device, now());
        if (!d) fail(410, 'This connection was revoked. Generate a new QR code.');
        if (d.token === hash(oldToken || '')) return { status: 'connected', once: false, ...snapshot(p.space) };
        // Recover a lost Set-Cookie response using the browser-only request cookie.
        const token = secret(); db.prepare('UPDATE devices SET token = ? WHERE id = ?').run(hash(token), d.id);
        return { status: 'connected', once: false, token, ...snapshot(p.space) };
      }
      const remote = snapshot(p.space), local = JSON.parse(p.preferences);
      const preferences = p.mode === 'replace' ? remote.preferences : validatePreferences({
        manager: remote.preferences.manager,
        rivals: [...new Set([...remote.preferences.rivals, ...local.rivals])],
        leagues: [...new Map([...local.leagues, ...remote.preferences.leagues].map(l => [l.id, l])).values()],
        ...(remote.preferences.leagueOrder !== undefined ? { leagueOrder: remote.preferences.leagueOrder } : {}),
      });
      if (p.once_only) {
        const result = { preferences, revision: remote.revision };
        db.prepare('UPDATE browser_pairs SET imported = ? WHERE id = ?').run(JSON.stringify(result), p.id);
        if (oldToken) db.prepare('DELETE FROM devices WHERE token = ?').run(hash(oldToken));
        return { status: 'connected', once: true, ...result };
      }
      if (db.prepare('SELECT count(*) AS n FROM devices WHERE space = ?').get(p.space).n >= 20) fail(400, 'Disconnect an unused device before connecting another.');
      save(p.space, preferences);
      // Do not revoke the approving phone even if a caller supplies its token.
      if (oldToken && hash(oldToken) !== db.prepare('SELECT token FROM devices WHERE id = ?').get(p.approver)?.token) db.prepare('DELETE FROM devices WHERE token = ?').run(hash(oldToken));
      const added = addDevice(p.space, 'web');
      db.prepare('UPDATE browser_pairs SET device = ? WHERE id = ?').run(added.deviceID, p.id);
      return { status: 'connected', once: false, ...added };
    }),
    cancelBrowserPair: (owner, id) => db.prepare('DELETE FROM browser_pairs WHERE owner = ? AND id = ?').run(hash(owner || ''), id || ''),
    read: token => {
      const d = device(token);
      return { ...snapshot(d.space), deviceID: d.id, devices: db.prepare('SELECT id, label FROM devices WHERE space = ? AND expires > ?').all(d.space, now()) };
    },
    update: db.transaction((token, input) => {
      const d = device(token), remote = snapshot(d.space);
      const base = validatePreferences(input.base?.preferences), local = validatePreferences(input.preferences);
      if (!Number.isSafeInteger(input.base?.revision) || input.base.revision < 1 || input.base.revision > remote.revision) fail(400, 'Invalid sync revision.');
      const merged = mergePreferences(base, local, remote.preferences);
      if (merged.conflicts.length) fail(409, 'These settings changed on another device. Choose which version to keep.', { snapshot: remote, conflicts: merged.conflicts });
      return save(d.space, merged.preferences);
    }),
    issue: db.transaction(token => {
      const d = device(token);
      db.prepare('DELETE FROM pairs WHERE issuer = ?').run(d.id);
      const tokenValue = secret(), code = randomBytes(5).toString('hex').toUpperCase(), expiresAt = now() + 600_000;
      db.prepare('INSERT INTO pairs VALUES (?, ?, ?, ?, ?)').run(hash(tokenValue), hash(code), d.space, d.id, expiresAt);
      return { secret: tokenValue, code, expiresAt };
    }),
    preview: input => { const p = pair(input); return { ...snapshot(p.space), expiresAt: p.expires }; },
    redeem: db.transaction((input, oldToken, label) => {
      const p = pair(input.secret), remote = snapshot(p.space), local = validatePreferences(input.preferences);
      if (input.revision !== remote.revision) fail(409, 'The app settings changed. Review the updated import.', { snapshot: remote });
      if (!['merge', 'replace'].includes(input.mode)) fail(400, 'Choose merge or replace.');
      if (local.manager && remote.preferences.manager && local.manager !== remote.preferences.manager && !['local', 'remote'].includes(input.manager)) fail(400, 'Choose which team to keep.');
      const preferences = input.mode === 'replace' ? remote.preferences : validatePreferences({
        manager: input.manager === 'local' ? local.manager : remote.preferences.manager || local.manager,
        rivals: [...new Set([...remote.preferences.rivals, ...local.rivals])],
        leagues: [...new Map([...local.leagues, ...remote.preferences.leagues].map(l => [l.id, l])).values()],
        ...(remote.preferences.leagueOrder !== undefined ? { leagueOrder: remote.preferences.leagueOrder } : {}),
      });
      db.prepare('DELETE FROM pairs WHERE token = ?').run(p.token);
      if (input.once === true) {
        if (oldToken) db.prepare('DELETE FROM devices WHERE token = ?').run(hash(oldToken));
        return { preferences, revision: remote.revision };
      }
      if (db.prepare('SELECT count(*) AS n FROM devices WHERE space = ?').get(p.space).n >= 20) fail(400, 'Disconnect an unused device before connecting another.');
      save(p.space, preferences);
      // Re-pairing replaces this browser's old credential, not its other devices.
      if (oldToken) db.prepare('DELETE FROM devices WHERE token = ?').run(hash(oldToken));
      return addDevice(p.space, label);
    }),
    disconnect: db.transaction((token, id) => {
      const d = device(token);
      db.prepare('DELETE FROM devices WHERE space = ? AND id = ?').run(d.space, id || d.id);
    }),
  };
}

export function registerFantasySync(app, { store = createSyncStore(process.env.FPL_SYNC_DB || join(homedir(), '.local/share/top-scores-web/fpl-sync.sqlite')), origin = process.env.TOP_SCORES_WEB_ORIGIN || 'https://top-scores.skynolimit.dev', secure = process.env.NODE_ENV === 'production' } = {}) {
  const router = express.Router(), limits = new Map();
  // Both public hosts serve this app. Keep the QR URL on the configured
  // Universal Link host, while allowing each website's same-origin requests.
  const allowedOrigins = new Set([origin, 'https://top-scores.com', 'https://top-scores.skynolimit.dev']);
  const cookieName = secure ? '__Host-fpl-sync' : 'fpl-sync';
  const pendingCookie = secure ? '__Host-fpl-pair' : 'fpl-pair';
  const readCookie = (req, name) => req.headers.cookie?.split(';').map(v => v.trim()).find(v => v.startsWith(`${name}=`))?.slice(name.length + 1) || '';
  const native = req => req.get('X-FPL-Client') === 'ios';
  const token = req => req.get('Authorization')?.replace(/^Bearer /, '') || req.headers.cookie?.split(';').map(v => v.trim()).find(v => v.startsWith(`${cookieName}=`))?.slice(cookieName.length + 1) || '';
  const send = (req, res, result) => {
    if (result.token && !native(req)) {
      res.cookie(cookieName, result.token, { httpOnly: true, secure, sameSite: 'strict', path: '/', maxAge: lifetime });
      const { token: _token, ...body } = result;
      return res.json(body);
    }
    return res.json(result);
  };
  router.use((req, res, next) => {
    res.set({ 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' });
    if (req.get('Origin') && !allowedOrigins.has(req.get('Origin'))) return res.status(403).json({ error: 'This website address is not supported for FPL sync. Please use https://top-scores.com/fpl.' });
    if (req.get('Sec-Fetch-Site') === 'cross-site') return res.status(403).json({ error: 'Cross-site requests are not allowed.' });
    if (req.method !== 'GET' && !req.is('application/json')) return res.status(415).json({ error: 'JSON required.' });
    const sensitive = ['/session', '/preview', '/redeem', '/pair', '/browser-pair', '/browser-pair/inspect', '/browser-pair/approve'].includes(req.path);
    const peer = req.socket.remoteAddress || '';
    const ip = /^(::ffff:)?127\.|^::1$/.test(peer) ? req.get('CF-Connecting-IP') || peer : peer;
    const key = `${ip}:${sensitive ? 'pair' : 'sync'}`, time = Date.now();
    if (limits.size > 10_000) for (const [k, v] of limits) if (v.until <= time) limits.delete(k);
    if (limits.size > 20_000) return res.status(429).json({ error: 'Please try again shortly.' });
    const bucket = limits.get(key) || { n: 0, until: time + 60_000 };
    if (bucket.until <= time) { bucket.n = 0; bucket.until = time + 60_000; }
    limits.set(key, bucket);
    if (++bucket.n > (sensitive ? 20 : 180)) return res.status(429).set('Retry-After', '60').json({ error: 'Too many attempts. Please wait a minute.' });
    next();
  });
  router.use(express.json({ limit: '32kb' }));
  const route = fn => (req, res, next) => { try { Promise.resolve(fn(req, res)).catch(next); } catch (error) { next(error); } };
  router.post('/browser-pair', route(async (req, res) => {
    const previous = readCookie(req, pendingCookie);
    const owner = /^[A-Za-z0-9_-]{43}$/.test(previous) ? previous : secret();
    const pair = store.beginBrowserPair(owner, req.body);
    const url = `${origin}/fpl/connect#pair=${pair.secret}`;
    const qr = await QRCode.toDataURL(url, { width: 280, margin: 4, errorCorrectionLevel: 'M' });
    res.cookie(pendingCookie, owner, { httpOnly: true, secure, sameSite: 'strict', path: '/', maxAge: 600_000 });
    res.json({ requestID: pair.requestID, code: pair.code, expiresAt: pair.expiresAt, url, qr, mode: req.body.mode, once: req.body.once === true });
  }));
  router.post('/browser-pair/inspect', route((req, res) => res.json(store.inspectBrowserPair(req.body.secret))));
  router.post('/browser-pair/approve', route((req, res) => res.json(store.approveBrowserPair(token(req), req.body.secret))));
  router.post('/browser-pair/status', route((req, res) => {
    const result = store.finishBrowserPair(readCookie(req, pendingCookie), req.body.requestID, token(req));
    if (result.status === 'connected' && result.once) res.clearCookie(cookieName, { httpOnly: true, secure, sameSite: 'strict', path: '/' });
    // Always use a cookie here, including when someone spoofs the native header.
    if (result.token) {
      res.cookie(cookieName, result.token, { httpOnly: true, secure, sameSite: 'strict', path: '/', maxAge: lifetime });
      const { token: _token, ...body } = result; res.json(body);
    } else res.json(result);
  }));
  router.post('/browser-pair/cancel', route((req, res) => { store.cancelBrowserPair(readCookie(req, pendingCookie), req.body.requestID); res.json({ ok: true }); }));
  router.post('/session', route((req, res) => send(req, res, store.create(req.body.preferences, native(req) ? 'ios' : 'web'))));
  router.get('/state', route((req, res) => res.json(store.read(token(req)))));
  router.put('/state', route((req, res) => res.json(store.update(token(req), req.body))));
  router.post('/pair', route((req, res) => res.json(store.issue(token(req)))));
  router.post('/preview', route((req, res) => res.json(store.preview(req.body.secret))));
  router.post('/redeem', route((req, res) => {
    const result = store.redeem(req.body, token(req), native(req) ? 'ios' : 'web');
    if (req.body.once === true) res.clearCookie(cookieName, { httpOnly: true, secure, sameSite: 'strict', path: '/' });
    send(req, res, result);
  }));
  router.post('/disconnect', route((req, res) => {
    store.disconnect(token(req), req.body.deviceID);
    if (!req.body.deviceID) res.clearCookie(cookieName, { httpOnly: true, secure, sameSite: 'strict', path: '/' });
    res.json({ ok: true });
  }));
  router.use((error, _req, res, _next) => res.status(error.status || 500).json({ error: error.status ? error.message : 'Sync is temporarily unavailable. Your local settings are safe.', ...(error.snapshot ? { snapshot: error.snapshot, conflicts: error.conflicts } : {}) }));
  app.use('/api/fpl-sync', router);
  store.cleanup();
  const cleanup = setInterval(() => store.cleanup(), 3600_000); cleanup.unref();
  return { store, close: () => { clearInterval(cleanup); store.close(); } };
}
