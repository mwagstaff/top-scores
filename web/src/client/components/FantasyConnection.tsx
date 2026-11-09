import { useEffect, useRef, useState } from 'react';
import { syncRequest, type useFantasyPreferences } from '../fantasySync';
import FantasyBrowserPairer, { hasPendingBrowserPair } from './FantasyBrowserPairer';

export default function FantasyConnection({ sync, onImport }: { sync: ReturnType<typeof useFantasyPreferences>; onImport: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [open, setOpen] = useState(false), [replacing, setReplacing] = useState(false);
  const [error, setError] = useState(''), [busy, setBusy] = useState(false);
  const run = async (fn: () => Promise<void>) => { setBusy(true); setError(''); try { await fn(); } catch (e) { setError(e instanceof Error ? e.message : 'Unable to connect. Please try again.'); } finally { setBusy(false); } };
  useEffect(() => { if (hasPendingBrowserPair()) { setOpen(true); setReplacing(true); } }, []);
  useEffect(() => { if (sync.conflict) setOpen(true); }, [sync.conflict]);
  useEffect(() => { if (open) dialog.current?.showModal(); else dialog.current?.close(); }, [open]);
  return <div className="fpl-sync-control" aria-label="Sync FPL settings">
    <button disabled={busy} aria-haspopup="dialog" onClick={() => { setOpen(true); if (sync.connected) void run(sync.loadDevices); }}>{sync.conflict ? 'Resolve sync' : sync.connected ? 'Manage sync' : 'Connect to app'}</button>
    <dialog ref={dialog} className="fpl-sync-dialog" aria-label="FPL sync" onCancel={e => { e.preventDefault(); setOpen(false); setReplacing(false); }}>
    <div className="fpl-section-heading"><h2>{sync.connected ? 'Manage sync' : 'Connect to app'}</h2><button onClick={() => { setOpen(false); setReplacing(false); }}>Close</button></div>
    {sync.status && <p className="fpl-muted" role="status">{sync.status}</p>}
    {sync.conflict && <div role="alert"><p>Settings changed on another device. Keep this browser’s settings or use the synced settings? Your choices stay here until you decide.</p><button onClick={() => void run(() => sync.resolve('local'))} disabled={busy}>Keep this browser</button> <button onClick={() => void run(() => sync.resolve('remote'))} disabled={busy}>Use synced settings</button></div>}
    {open && <div className="fpl-connection-content">
      {sync.connected && !replacing ? <><p>Team ID, rivals, saved leagues and league order sync automatically while this page and the app are open. Returning to either device checks for changes. No FPL password or private squad data is shared.</p><div className="fpl-connection-actions"><button disabled={busy} onClick={() => void run(sync.sync)}>Sync now</button><button disabled={busy} onClick={() => void run(sync.disconnect)}>Disconnect this browser</button></div>{sync.devices?.map(device => <div className="fpl-connection-bar" key={device.id}><span>{device.label}</span><button disabled={busy} onClick={() => void run(async () => { await syncRequest('disconnect', { deviceID: device.id }); await sync.loadDevices(); })}>Disconnect device</button></div>)}<button onClick={() => setReplacing(true)}>Connect another app</button></> : <FantasyBrowserPairer sync={sync} onComplete={() => { onImport(); setOpen(false); setReplacing(false); }} />}
    </div>}
    {error && <p role="alert" className="fpl-error">{error}</p>}
    </dialog>
  </div>;
}
