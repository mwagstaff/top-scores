import { useState } from 'react';
import type { useFantasyPreferences } from '../fantasySync';
import FantasyBrowserPairer from './FantasyBrowserPairer';

export default function FantasyConnection({ sync, onImport }: { sync: ReturnType<typeof useFantasyPreferences>; onImport: (manager: number | null) => void }) {
  const [error, setError] = useState(''), [busy, setBusy] = useState(false);
  const run = async (fn: () => Promise<void>) => { setBusy(true); setError(''); try { await fn(); } catch (e) { setError(e instanceof Error ? e.message : 'Unable to connect. Please try again.'); } finally { setBusy(false); } };
  if (!sync.connectionChecked) return <p role="status">{sync.status || 'Checking app connection…'}</p>;
  return <section className="fpl-connection fpl-connection-content" aria-label="App connection">
    {sync.connected ? <>
      <h2>Connected to the Top Scores app</h2>
      <p>Unsyncing keeps your team, rivals and leagues on this browser.</p>
      <button disabled={busy} onClick={() => void run(sync.disconnect)}>Unsync this browser</button>
      {sync.conflict && <div role="alert"><p>Your settings changed on both devices. Which settings would you like to keep?</p>
        <button disabled={busy} onClick={() => void run(() => sync.resolve('local'))}>Keep browser settings</button>{' '}
        <button disabled={busy} onClick={() => void run(() => sync.resolve('remote'))}>Use app settings</button>
      </div>}
    </> : <FantasyBrowserPairer sync={sync} onComplete={onImport} />}
    {sync.status && <p className="fpl-muted" role="status">{sync.status}</p>}
    {error && <p role="alert" className="fpl-error">{error}</p>}
  </section>;
}
