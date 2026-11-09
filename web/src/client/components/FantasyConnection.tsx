import { useEffect, useState } from 'react';
import { syncRequest, type useFantasyPreferences } from '../fantasySync';
import FantasyBrowserPairer, { hasPendingBrowserPair } from './FantasyBrowserPairer';

export default function FantasyConnection({ sync, onImport }: { sync: ReturnType<typeof useFantasyPreferences>; onImport: () => void }) {
  const [open, setOpen] = useState(false), [replacing, setReplacing] = useState(false);
  const [error, setError] = useState(''), [busy, setBusy] = useState(false);
  const run = async (fn: () => Promise<void>) => { setBusy(true); setError(''); try { await fn(); } catch (e) { setError(e instanceof Error ? e.message : 'Unable to connect. Please try again.'); } finally { setBusy(false); } };
  useEffect(() => { if (hasPendingBrowserPair()) { setOpen(true); setReplacing(true); } }, []);
  return <section className="fpl-connection" aria-label="Sync FPL settings">
    <div className="fpl-connection-bar"><span>{sync.connected ? 'Connected · FPL settings sync across devices' : 'Already set up in the app?'}</span><button disabled={busy} aria-expanded={open} onClick={() => { setOpen(!open); if (open) setReplacing(false); if (!open && sync.connected) void run(sync.loadDevices); }}>{open ? 'Close' : sync.connected ? 'Manage sync' : 'Connect to app'}</button></div>
    {sync.status && <p className="fpl-muted" role="status">{sync.status}</p>}
    {sync.conflict && <div role="alert"><p>Settings changed on another device. Keep this browser’s settings or use the synced settings? Your choices stay here until you decide.</p><button onClick={() => void run(() => sync.resolve('local'))} disabled={busy}>Keep this browser</button> <button onClick={() => void run(() => sync.resolve('remote'))} disabled={busy}>Use synced settings</button></div>}
    {open && <div className="fpl-connection-content">
      {sync.connected && !replacing ? <><p>Team ID, rivals and saved leagues sync when either device opens FPL. No FPL password or private squad data is shared.</p><div className="fpl-connection-actions"><button disabled={busy} onClick={() => void run(sync.sync)}>Sync now</button><button disabled={busy} onClick={() => void run(sync.disconnect)}>Disconnect this browser</button></div>{sync.devices?.map(device => <div className="fpl-connection-bar" key={device.id}><span>{device.label}</span><button disabled={busy} onClick={() => void run(async () => { await syncRequest('disconnect', { deviceID: device.id }); await sync.loadDevices(); })}>Disconnect device</button></div>)}<button onClick={() => setReplacing(true)}>Connect another app</button></> : <FantasyBrowserPairer sync={sync} onComplete={() => { onImport(); setOpen(false); setReplacing(false); }} />}
    </div>}
    {error && <p role="alert" className="fpl-error">{error}</p>}
  </section>;
}
