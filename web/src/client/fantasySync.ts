import { useEffect, useRef, useState } from 'react';
import { readPreferences, savePreferences, type Preferences } from './fantasyData';

export interface Snapshot { preferences: Preferences; revision: number }
export interface SyncState extends Snapshot { deviceID?: string; devices?: { id: string; label: string }[] }
export class SyncError extends Error {
  constructor(message: string, public status: number, public snapshot?: Snapshot) { super(message); }
}
export async function syncRequest<T>(path: string, body?: unknown, method = 'POST'): Promise<T> {
  const response = await fetch(`/api/fpl-sync/${path}`, { method: body === undefined ? 'GET' : method,
    credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15_000) });
  const data = await response.json();
  if (!response.ok) throw new SyncError(data.error || 'Unable to sync. Your local settings are safe.', response.status, data.snapshot);
  return data;
}
const baseKey = 'top-scores.web.fpl.sync.v1';
const equal = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
export function useFantasyPreferences() {
  const [preferences, setPreferences] = useState<Preferences>({ manager: null, rivals: [], leagues: [] });
  const [ready, setReady] = useState(false), [connected, setConnected] = useState(false);
  const [status, setStatus] = useState(''), [conflict, setConflict] = useState<Snapshot | null>(null);
  const [devices, setDevices] = useState<SyncState['devices']>([]);
  const current = useRef(preferences), base = useRef<Snapshot | null>(null), running = useRef(false), blocked = useRef(false);
  const mounted = useRef(false);
  const paused = useRef(false), generation = useRef(0);
  const remember = (value: Snapshot | null) => {
    base.current = value;
    try { value ? localStorage.setItem(baseKey, JSON.stringify(value)) : localStorage.removeItem(baseKey); }
    catch { setStatus('Browser storage is unavailable. Keep this page open to sync your changes.'); }
    setConnected(!!value);
  };
  const persist = (value: Preferences) => {
    if (equal(current.current, value)) return;
    current.current = value; setPreferences(value);
    if (!savePreferences(value)) setStatus('Browser storage is unavailable. Your choices will last for this visit only.');
  };
  const accept = (snapshot: Snapshot, linked: boolean) => {
    generation.current++; paused.current = false;
    persist(snapshot.preferences); remember(linked ? snapshot : null);
    blocked.current = false; setConflict(null); setStatus(linked ? 'Connected. Your FPL settings stay in sync.' : 'Imported. Settings are saved on this browser.');
  };
  const sync = async () => {
    if (running.current || blocked.current || paused.current || !mounted.current || document.hidden) return;
    const epoch = generation.current;
    running.current = true;
    try {
      if (!base.current) {
        const state = await syncRequest<SyncState>('state');
        if (!mounted.current || epoch !== generation.current) return;
        setDevices(state.devices);
        if (current.current.manager || current.current.rivals.length || current.current.leagues.length) {
          blocked.current = true; setConflict(state); remember(state);
          setStatus('This browser has a connection and different local settings. Choose which to keep.');
        } else accept(state, true);
      } else {
        const captured = current.current;
        const state = await syncRequest<Snapshot>('state', { base: base.current, preferences: captured }, 'PUT');
        if (!mounted.current || epoch !== generation.current) return;
        if (equal(current.current, captured)) { persist(state.preferences); remember(state); }
        else remember({ revision: state.revision, preferences: captured }); // Preserve edits made while the request was in flight.
        setStatus('Settings synced');
      }
    } catch (error) {
      if (!mounted.current || epoch !== generation.current) return;
      if (error instanceof SyncError && error.status === 401) {
        if (base.current) setStatus(error.message);
        remember(null);
      } else if (error instanceof SyncError && error.snapshot) {
        blocked.current = true; setConflict(error.snapshot); setStatus(error.message);
      } else if (base.current) setStatus('Sync unavailable. Your changes are saved here and will retry automatically.');
    } finally { running.current = false; }
  };
  useEffect(() => {
    mounted.current = true; persist(readPreferences());
    try { const saved = JSON.parse(localStorage.getItem(baseKey) || 'null'); if (saved?.revision && saved?.preferences) remember(saved); } catch { /* No previous connection. */ }
    setReady(true); void sync();
    const timer = window.setInterval(() => { if (base.current) void sync(); }, 15_000);
    const wake = () => { if (base.current) void sync(); };
    const storage = (e: StorageEvent) => {
      if (e.key === 'top-scores.web.fpl.v1') { current.current = readPreferences(); setPreferences(current.current); }
      if (e.key === baseKey) { try { base.current = JSON.parse(e.newValue || 'null'); setConnected(!!base.current); } catch { /* Ignore invalid storage. */ } }
    };
    document.addEventListener('visibilitychange', wake); window.addEventListener('online', wake); window.addEventListener('storage', storage);
    return () => { mounted.current = false; clearInterval(timer); document.removeEventListener('visibilitychange', wake); window.removeEventListener('online', wake); window.removeEventListener('storage', storage); };
  }, []);
  useEffect(() => { if (!ready || !connected) return; const timer = setTimeout(sync, 600); return () => clearTimeout(timer); }, [preferences, ready, connected]);
  const resolve = async (choice: 'local' | 'remote') => {
    if (!conflict) return;
    if (choice === 'remote') persist(conflict.preferences);
    remember(conflict); blocked.current = false; setConflict(null); await sync();
  };
  const disconnect = async () => {
    if (running.current) throw new Error('Please wait for the current sync to finish.');
    await syncRequest('disconnect', {}); remember(null); blocked.current = false; setConflict(null); setStatus('Disconnected. Your settings remain on this browser.');
  };
  const loadDevices = async () => { const state = await syncRequest<SyncState>('state'); setDevices(state.devices?.filter(d => d.id !== state.deviceID)); };
  const pause = () => { paused.current = true; generation.current++; };
  const resume = () => { paused.current = false; void sync(); };
  return { preferences, ready, persist, connected, status, conflict, sync, accept, resolve, disconnect, devices, loadDevices, pause, resume };
}
