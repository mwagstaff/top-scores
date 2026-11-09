import { useEffect, useRef, useState } from 'react';
import { SyncError, syncRequest, type Snapshot, type useFantasyPreferences } from '../fantasySync';

interface Pairing { requestID: string; url: string; qr: string; code: string; expiresAt: number; mode: string; once: boolean }
type PairingStatus = { status: 'waiting' } | ({ status: 'connected'; once: boolean } & Snapshot);
export const pendingPairKey = 'top-scores.web.fpl.pending-pair.v1';
export function hasPendingBrowserPair() {
  try { return JSON.parse(sessionStorage.getItem(pendingPairKey) || 'null')?.expiresAt > Date.now(); } catch { return false; }
}

export default function FantasyBrowserPairer({ sync, onComplete }: { sync: ReturnType<typeof useFantasyPreferences>; onComplete: () => void }) {
  const [pair, setPair] = useState<Pairing | null>(null), [busy, setBusy] = useState(false);
  const [error, setError] = useState(''), [waiting, setWaiting] = useState('Waiting for your phone…');
  const [mode, setMode] = useState('replace'), [once, setOnce] = useState(false);
  const callbacks = useRef({ sync, onComplete }); callbacks.current = { sync, onComplete };
  const mounted = useRef(false), activeRequest = useRef<string | null>(null);
  const hasLocal = !!(sync.preferences.manager || sync.preferences.rivals.length || sync.preferences.leagues.length);
  const remember = (value: Pairing | null) => {
    try { value ? sessionStorage.setItem(pendingPairKey, JSON.stringify(value)) : sessionStorage.removeItem(pendingPairKey); } catch { /* Pairing works without browser storage. */ }
  };
  const generate = async (nextMode = mode, nextOnce = once) => {
    setBusy(true); setError(''); setPair(null); remember(null);
    callbacks.current.sync.pause();
    try {
      const value = await syncRequest<Pairing>('browser-pair', { preferences: callbacks.current.sync.preferences, mode: nextMode, once: nextOnce });
      if (!mounted.current) { void syncRequest('browser-pair/cancel', { requestID: value.requestID }).catch(() => {}); return; }
      activeRequest.current = value.requestID;
      remember(value); setPair(value); setWaiting('Waiting for your phone…');
    } catch (e) { if (mounted.current) setError(e instanceof Error ? e.message : 'Unable to generate a QR code.'); }
    finally { if (mounted.current) setBusy(false); }
  };
  useEffect(() => {
    mounted.current = true; callbacks.current.sync.pause();
    let saved: Pairing | null = null;
    try { if (hasPendingBrowserPair()) saved = JSON.parse(sessionStorage.getItem(pendingPairKey)!); } catch { /* Start a new request. */ }
    if (saved) { activeRequest.current = saved.requestID; setPair(saved); setMode(saved.mode); setOnce(saved.once); }
    else void generate();
    return () => {
      mounted.current = false;
      if (activeRequest.current) void syncRequest('browser-pair/cancel', { requestID: activeRequest.current }).catch(() => {});
      remember(null); callbacks.current.sync.resume();
    };
  }, []);
  useEffect(() => {
    if (!pair) return;
    let stopped = false, inFlight = false;
    const poll = async () => {
      if (stopped || inFlight || document.hidden) return;
      if (Date.now() >= pair.expiresAt) { setError('This QR code has expired. Generate a new one to connect.'); setPair(null); remember(null); return; }
      inFlight = true;
      try {
        const state = await syncRequest<PairingStatus>('browser-pair/status', { requestID: pair.requestID });
        if (stopped) return;
        if (state.status === 'connected') {
          stopped = true; activeRequest.current = null; remember(null);
          callbacks.current.sync.accept(state, !state.once);
          void syncRequest('browser-pair/cancel', { requestID: pair.requestID }).catch(() => {});
          callbacks.current.onComplete();
        } else setWaiting('Waiting for your phone…');
      } catch (e) {
        if (stopped) return;
        if (e instanceof SyncError && [400, 401, 410].includes(e.status)) { setError(e.message); setPair(null); remember(null); }
        else setWaiting('Connection interrupted. Retrying automatically…');
      } finally { inFlight = false; }
    };
    void poll();
    const timer = setInterval(poll, 2000); document.addEventListener('visibilitychange', poll);
    return () => { stopped = true; clearInterval(timer); document.removeEventListener('visibilitychange', poll); };
  }, [pair]);

  return <div>
    <h2>Scan with your phone</h2>
    <div className="fpl-pair-layout">
      <div className="fpl-pair-qr">{pair ? <img src={pair.qr} width="280" height="280" alt="Scan this QR code with your phone camera to connect Top Scores" /> : <p role="status">{busy ? 'Creating your QR code…' : error ? 'Couldn’t create your QR code. Please try again.' : 'Ready to create a new QR code.'}</p>}</div>
      <div><ol><li>Open your phone’s camera and scan the code.</li><li>Open Top Scores and tap <strong>Connect this browser</strong>.</li><li>Your team, rivals and leagues appear here automatically.</li></ol>
        {pair && <><p>Check that your phone shows <strong className="fpl-pair-code">{pair.code.slice(0, 3)} {pair.code.slice(3)}</strong></p><p role="status" className="fpl-muted">{waiting}</p><a href={pair.url}>On this phone? Open Top Scores ↗</a></>}
        <p className="fpl-muted">No login needed. Requires an app version with website pairing. The QR code expires after 10 minutes.</p>
        {hasLocal && <label>Existing browser settings<select value={mode} disabled={busy} onChange={e => { setMode(e.target.value); void generate(e.target.value, once); }}><option value="replace">Use the app’s team, rivals and leagues</option><option value="merge">Use the app’s team and merge rivals and leagues</option></select></label>}
        <label><input type="checkbox" checked={once} disabled={busy} onChange={e => { setOnce(e.target.checked); void generate(mode, e.target.checked); }} /> Import once only</label>
        <p className="fpl-muted">{once ? 'Keep this browser independent after importing.' : 'Future changes will sync across your connected devices.'}</p>
        <button disabled={busy} onClick={() => void generate()}>{pair ? 'Generate a new QR code' : 'Try again'}</button>
      </div>
    </div>
    {error && <p role="alert" className="fpl-error">{error}</p>}
  </div>;
}
