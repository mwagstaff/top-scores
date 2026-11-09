import { useEffect, useRef, useState, type FormEvent } from 'react';
import { useSearchParams } from 'react-router-dom';
import { chipName, fetchFantasy, money, parseFplID, playerImage, teamName, type LeagueData, type Player, type PlayerData, type Preferences, type Profile, type Squad, type SquadPlayer } from '../fantasyData';
import '../fantasy.css';
import { useInitialSeed } from '../bootstrap';
import { useFantasyPreferences } from '../fantasySync';
import FantasyConnection from './FantasyConnection';

function useResource<T>(path: string | null, interval = 0, initial?: { path: string; data: T }) {
  const [state, setState] = useState<{ path: string | null; data?: T; error?: string; loading: boolean }>({ path: initial?.path || null, data: initial?.data, loading: false });
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    if (!path) return;
    let running = false, stopped = false;
    const controller = new AbortController();
    const load = async () => {
      if (running || stopped || document.visibilityState === 'hidden') return;
      running = true;
      setState(old => ({ path, data: old.path === path ? old.data : undefined, loading: true }));
      try {
        const data = await fetchFantasy<T>(path, controller.signal);
        if (!stopped) setState({ path, data, loading: false });
      } catch (error) {
        if (!stopped) setState(old => ({ ...old, path, loading: false, error: error instanceof Error ? error.message : 'Unable to load FPL data.' }));
      } finally { running = false; }
    };
    void load();
    const timer = interval ? window.setInterval(load, interval) : undefined;
    document.addEventListener('visibilitychange', load);
    return () => { stopped = true; controller.abort(); clearInterval(timer); document.removeEventListener('visibilitychange', load); };
  }, [path, interval, revision]);
  return { data: state.path === path ? state.data : undefined, error: state.path === path ? state.error : undefined, loading: state.path !== path || state.loading, retry: () => setRevision(value => value + 1) };
}

export default function FantasyScreen() {
  const [params, setParams] = useSearchParams();
  const seed = useInitialSeed();
  const sync = useFantasyPreferences();
  const { preferences, ready, persist } = sync;
  const [message, setMessage] = useState('');
  const [setup, setSetup] = useState(false);
  const [metric, setMetric] = useState('opponent');
  const [view, setView] = useState('pitch');
  const section = ['team', 'leagues', 'assistant'].includes(params.get('section') || '') ? params.get('section')! : 'team';
  const entry = parseFplID(params.get('entry') || '') || preferences.manager;
  const event = parseFplID(params.get('event') || '');
  const player = parseFplID(params.get('player') || '');
  const league = parseFplID(params.get('league') || '');
  const squad = useResource<Squad>((ready || seed?.fantasy) && entry ? `/api/fpl/entry/${entry}${event ? `?event=${event}` : ''}` : null, 30_000, seed?.fantasy && seed.fantasyPath ? { path: seed.fantasyPath, data: seed.fantasy } : undefined);
  const data = squad.data;
  const change = (values: Record<string, string | number | null>) => {
    const next = new URLSearchParams(params);
    for (const [key, value] of Object.entries(values)) value === null ? next.delete(key) : next.set(key, String(value));
    setParams(next);
  };
  const selectManager = (id: number) => change({ entry: id, player: null });
  const openPlayer = (id: number) => change({ player: id });
  const saveManager = async (id: number) => {
    await fetchFantasy<Profile>(`/api/fpl/profile/${id}`);
    persist({ ...preferences, manager: id }); setSetup(false); change({ entry: id, event: null });
  };
  const addRival = async (id: number) => {
    if (preferences.rivals.length >= 100) throw new Error('You can follow up to 100 rivals. Remove one first.');
    await fetchFantasy<Profile>(`/api/fpl/profile/${id}`);
    persist({ ...preferences, rivals: [...new Set([...preferences.rivals, id])].filter(value => value !== preferences.manager) });
  };
  return <div className="fpl-page">
    <header className="fpl-heading"><div><span className="eyebrow">FANTASY PREMIER LEAGUE</span><h1>Your gameweek.</h1></div><img src="/generated-assets/fpl-lion.png" width="48" height="56" alt="" /></header>
    <FantasyConnection sync={sync} onImport={() => { setSetup(false); change({ entry: null, event: null, player: null, league: null }); }} />
    {!entry || setup ? <section className="fpl-setup">
      <h2>{entry ? 'Change your team' : 'Bring your team into the picture'}</h2>
      <p>Follow your published squad, live points and rivals with your FPL manager ID. No password needed.</p>
      <IDForm label="Manager ID or FPL team link" onSubmit={saveManager} button="Follow my team" />
      <p className="fpl-muted">Find your ID in the address of your Points page on the official FPL website, for example /entry/123456/event/12.</p>
      <p className="fpl-muted">Saved on this browser. Pre-deadline transfers and private lineups are not available.</p>
      <a href="https://fantasy.premierleague.com/" target="_blank" rel="noreferrer">Open Fantasy Premier League ↗</a>
      {entry && <button onClick={() => setSetup(false)}>Cancel</button>}
    </section> : <>
      <nav className="fpl-tabs" aria-label="Fantasy sections">{[['team', 'My team'], ['leagues', 'Leagues'], ['assistant', 'Assistant Manager']].map(([key, label]) => <button key={key} aria-current={section === key ? 'page' : undefined} onClick={() => change({ section: key, player: null })}>{label}</button>)}<button className="fpl-change-team" onClick={() => setSetup(true)}>Change team</button></nav>
      {message && <p role="status">{message}</p>}
      <div className="fpl-toolbar"><div>{data ? <><h2>{data.profile.name}</h2><span className="fpl-muted">{data.profile.player_first_name} {data.profile.player_last_name}</span></> : <h2>Manager {entry}</h2>}</div>
        {entry !== preferences.manager && preferences.manager && <button onClick={() => selectManager(preferences.manager!)}>Back to my team</button>}
        {data && <label>Gameweek<select aria-label="Gameweek" value={data.event.id} onChange={e => change({ event: Number(e.target.value) })}>{[...data.events].reverse().map(gw => <option key={gw.id} value={gw.id}>{gw.name}</option>)}</select></label>}
        <button onClick={squad.retry} disabled={squad.loading}> {squad.loading ? 'Refreshing…' : 'Refresh'}</button>
        <button onClick={async () => { try { const url = new URL(location.href); url.searchParams.set('entry', String(entry)); await navigator.clipboard.writeText(url.href); setMessage('Link copied. It shares public FPL data only.'); } catch { setMessage('Copy the page address to share this team.'); } }}>Share</button>
      </div>
      {squad.error && <p className="fpl-error" role="alert">{squad.error} {data && 'Showing the last successful update.'} <button onClick={squad.retry}>Retry</button></p>}
      {!data && !squad.error && <div className="fpl-loading" role="status">Loading published squad…</div>}
      {data && <>
        <p className="fpl-context">Published picks · {data.event.name} · {data.finalized ? 'Confirmed' : 'Provisional scores'} · Updated {new Date(data.updatedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}<span>Private pre-deadline changes are not included.</span></p>
        {section === 'team' && <>
          <div className="fpl-summary"><Metric label="Net gameweek points" value={data.points} /><Metric label="Gameweek average" value={data.event.average_entry_score} />{data.nextExpectedPoints !== null && <Metric label="Next GW xP · published XI" value={data.nextExpectedPoints.toFixed(1)} />}<Metric label="Overall points (official)" value={data.history.total_points?.toLocaleString()} /><Metric label="Overall rank (official)" value={data.history.overall_rank?.toLocaleString() || '—'} />{data.chip && <Metric label="Active chip" value={chipName(data.chip)} />}</div>
          <div className="fpl-dashboard"><section aria-label="Squad"><div className="fpl-section-heading"><h2>{data.event.name} squad</h2><div className="fpl-view-switch"><button aria-pressed={view === 'pitch'} onClick={() => setView('pitch')}>Pitch</button><button aria-pressed={view === 'table'} onClick={() => setView('table')}>Table</button></div></div>
            <div className="fpl-metric-select"><label>Player detail <select value={metric} onChange={e => setMetric(e.target.value)}>{[['opponent', 'Opposition'], ['now_cost', 'Price'], ['difficulty', 'Difficulty'], ['selected_by_percent', 'Ownership %'], ['ownership_count', 'Ownership count'], ['form', 'Form'], ['points_per_game', 'Points / match'], ['total_points', 'Total points'], ['minutes', 'Minutes / start'], ['ep_next', 'Next GW expected points']].map(([key, name]) => <option key={key} value={key}>{name}</option>)}</select></label></div>
            {view === 'pitch' ? <><div className="fpl-pitch">{[1, 2, 3, 4].map(position => <div className="fpl-position" key={position}>{data.players.filter(p => p.pickPosition <= 11 && p.element_type === position).map(p => <PlayerCard key={p.id} player={p} data={data} metric={metric} onClick={() => openPlayer(p.id)} />)}</div>)}</div><div className="fpl-bench"><h3>Bench <span>In substitution order</span></h3><div className="fpl-position">{data.players.filter(p => p.pickPosition > 11).map(p => <PlayerCard key={p.id} player={p} data={data} metric={metric} onClick={() => openPlayer(p.id)} />)}</div></div></> : <div className="fpl-table-scroll"><table className="fpl-table"><thead><tr><th>Player</th><th>Role</th><th>Points</th><th>Price</th><th>Form</th><th>Owned</th></tr></thead><tbody>{data.players.map(p => <tr key={p.id}><th><button onClick={() => openPlayer(p.id)}>{p.web_name}</button></th><td>{p.isCaptain ? 'Captain' : p.isViceCaptain ? 'Vice captain' : p.pickPosition > 11 ? 'Bench' : 'Starter'}</td><td>{p.rawPoints} × {p.multiplier}</td><td>{money(p.now_cost)}</td><td>{p.form}</td><td>{p.selected_by_percent}%</td></tr>)}</tbody></table></div>}
            <details className="fpl-breakdown" open={data.notes.length > 0}><summary>How your score is calculated · {data.points} pts</summary><p>{data.grossPoints} squad points − {data.transferCost} transfer cost = <strong>{data.points} net points</strong>.</p>{data.notes.map(note => <p key={note}>{note}</p>)}<p className="fpl-muted">{data.finalized ? 'Official FPL multipliers and substitutions are applied.' : 'Points may change. Substitutions are projected after all of a player’s fixtures finish; official confirmation follows.'}</p></details>
          </section><aside className="fpl-rivals"><div className="fpl-section-heading"><h2>Rivals</h2><span>GW {data.event.id}</span></div><p className="fpl-muted">See the scores. Explore their squads.</p>
            {[...new Set([preferences.manager || entry, ...preferences.rivals])].map(id => <Rival key={`${id}-${data.event.id}`} id={id} event={data.event.id} selected={id === entry} own={id === preferences.manager} removable={preferences.rivals.includes(id)} onSelect={() => selectManager(id)} onRemove={() => persist({ ...preferences, rivals: preferences.rivals.filter(value => value !== id) })} />)}
            <IDForm label="Add rival ID or team link" button="Add rival" onSubmit={addRival} />
            <h3>Your leagues</h3>{data.profile.leagues.classic.filter(l => l.entry_rank).slice(0, 5).map(l => <button className="fpl-league-link" key={l.id} onClick={() => change({ section: 'leagues', league: l.id })}><span>{l.name}</span><strong>#{l.entry_rank.toLocaleString()}</strong></button>)}
          </aside></div>
        </>}
        {section === 'leagues' && <Leagues key={entry} data={data} selected={league} preferences={preferences} persist={persist} select={id => change({ league: id })} selectManager={id => change({ entry: id, section: 'team', player: null })} />}
        {section === 'assistant' && <Assistant entry={entry} onPlayer={openPlayer} />}
      </>}
    </>}
    {player && <PlayerPanel key={player} id={player} onClose={() => change({ player: null })} />}
  </div>;
}
function Metric({ label, value }: { label: string; value: string | number | undefined }) { return <div><span>{label}</span><strong>{value ?? '—'}</strong></div>; }
function IDForm({ label, onSubmit, button, kind = 'entry' }: { label: string; onSubmit: (id: number) => Promise<void>; button: string; kind?: 'entry' | 'league' }) {
  const [input, setInput] = useState(''), [error, setError] = useState(''), [busy, setBusy] = useState(false);
  const submit = async (e: FormEvent) => { e.preventDefault(); const id = parseFplID(input, kind); if (!id) { setError(`Enter a valid ${kind === 'entry' ? 'manager' : 'league'} ID or official FPL link.`); return; } setBusy(true); setError(''); try { await onSubmit(id); setInput(''); } catch (error) { setError(error instanceof Error ? error.message : 'Unable to save.'); } finally { setBusy(false); } };
  return <form className="fpl-id-form" onSubmit={submit}><label>{label}<input value={input} onChange={e => setInput(e.target.value)} placeholder="e.g. 123456" required maxLength={300} /></label><button disabled={busy} type="submit">{busy ? 'Checking…' : button}</button>{error && <p className="fpl-error" role="alert">{error}</p>}</form>;
}
function PlayerCard({ player: p, data, metric, onClick }: { player: SquadPlayer; data: Squad; metric: string; onClick: () => void }) {
  const incoming = data.substitutions.some(s => s.incoming === p.id), outgoing = data.substitutions.some(s => s.outgoing === p.id);
  let detail: string;
  if (metric === 'opponent') detail = p.fixtures.map(f => `${teamName(data.teams, f.team_h === p.team ? f.team_a : f.team_h, true)} (${f.team_h === p.team ? 'H' : 'A'})`).join(' · ') || 'No fixture';
  else if (metric === 'difficulty') detail = p.fixtures.map(f => `FDR ${f.team_h === p.team ? f.team_h_difficulty : f.team_a_difficulty}/5`).join(' · ') || 'No fixture';
  else if (metric === 'now_cost') detail = money(p.now_cost);
  else if (metric === 'ownership_count') detail = `≈ ${Math.round(data.totalPlayers * Number(p.selected_by_percent) / 100).toLocaleString()}`;
  else if (metric === 'minutes') detail = `${Math.round(p.minutes / Math.max(p.starts, 1))} mins / start`;
  else detail = String(p[metric as keyof Player] ?? '—') + (metric === 'selected_by_percent' ? '%' : metric === 'ep_next' ? ' xP' : '');
  return <button className={`fpl-player${p.inPlay ? ' is-live' : ''}${incoming ? ' is-incoming' : ''}${outgoing ? ' is-outgoing' : ''}`} onClick={onClick} aria-label={`${p.first_name} ${p.second_name}, ${p.rawPoints} points${p.isCaptain ? ', captain' : ''}${incoming ? ', included substitute' : ''}${outgoing ? ', replaced starter' : ''}`}>
    <span className="fpl-player-photo" data-initials={p.web_name.slice(0, 2).toUpperCase()}><img src={playerImage(p)} alt="" width="66" height="84" loading="lazy" onError={e => { e.currentTarget.style.visibility = 'hidden'; e.currentTarget.parentElement?.classList.add('missing'); }} />{(p.isCaptain || p.isViceCaptain) && <b>{p.isCaptain ? 'C' : 'V'}</b>}{p.status !== 'a' && <span title={p.news || 'Availability concern'} aria-label={p.news || 'Availability concern'}>!</span>}</span>
    <strong>{p.web_name}</strong><span className="fpl-player-score">{p.started || p.stats.minutes ? p.rawPoints : '—'}{p.multiplier > 1 && <small> ×{p.multiplier}</small>}{p.inPlay && <small> LIVE</small>}</span><span className="fpl-player-detail">{detail}</span><span className="fpl-player-events">{p.stats.goals_scored > 0 && <span title="Goals">⚽{p.stats.goals_scored}</span>}{p.stats.assists > 0 && <span title="Assists">A{p.stats.assists}</span>}{p.stats.yellow_cards > 0 && <span title="Yellow card">🟨</span>}{p.stats.red_cards > 0 && <span title="Red card">🟥</span>}</span>{incoming && <small>↑ Included</small>}{outgoing && <small>↓ Replaced</small>}
  </button>;
}
function Rival({ id, event, selected, own, removable, onSelect, onRemove }: { id: number; event: number; selected: boolean; own: boolean; removable: boolean; onSelect: () => void; onRemove: () => void }) {
  const state = useResource<Squad>(`/api/fpl/entry/${id}?event=${event}`, 30_000);
  return <div className={`fpl-rival${selected ? ' selected' : ''}`}><button onClick={onSelect}><span><strong>{state.data?.profile.name || `Manager ${id}`}{own ? ' · You' : ''}</strong><small>{state.error ? 'Refresh unavailable' : state.data ? `${state.data.profile.player_first_name} ${state.data.profile.player_last_name}` : 'Loading…'}</small></span><span><strong>{state.data?.points ?? '—'}</strong><small>{state.data?.players.some(p => p.inPlay) ? 'Live · GW' : 'GW'}</small></span><span><strong>{state.data?.history.total_points?.toLocaleString() ?? '—'}</strong><small>Official total</small></span></button>{removable && !own && <button className="fpl-remove" aria-label={`Remove rival ${state.data?.profile.name || id}`} onClick={onRemove}>×</button>}</div>;
}
function Leagues({ data, selected, preferences, persist, select, selectManager }: { data: Squad; selected: number | null; preferences: Preferences; persist: (p: Preferences) => void; select: (id: number) => void; selectManager: (id: number) => void }) {
  const [page, setPage] = useState(1);
  const leagues = [...preferences.leagues, ...data.profile.leagues.classic.filter(l => !preferences.leagues.some(saved => saved.id === l.id))];
  const id = selected || leagues[0]?.id;
  const result = useResource<LeagueData>(id ? `/api/fpl/league/${id}?page=${page}` : null, 60_000);
  useEffect(() => setPage(1), [id]);
  return <div className="fpl-leagues"><aside><h2>Leagues</h2><p className="fpl-muted">Saved leagues appear first.</p>{leagues.map((l, index) => <div className="fpl-league-choice" key={l.id}><button aria-pressed={id === l.id} onClick={() => { setPage(1); select(l.id); }}>{l.name}</button>{preferences.leagues.some(saved => saved.id === l.id) ? <><button aria-label={`Move ${l.name} up`} disabled={index === 0} onClick={() => { const next = [...preferences.leagues]; [next[index - 1], next[index]] = [next[index], next[index - 1]]; persist({ ...preferences, leagues: next }); }}>↑</button><button aria-label={`Unsave ${l.name}`} onClick={() => persist({ ...preferences, leagues: preferences.leagues.filter(saved => saved.id !== l.id) })}>×</button></> : <button aria-label={`Save ${l.name}`} onClick={() => persist({ ...preferences, leagues: [...preferences.leagues, { id: l.id, name: l.name }] })}>＋</button>}</div>)}<IDForm kind="league" label="League ID or link" button="Save league" onSubmit={async id => { const value = await fetchFantasy<LeagueData>(`/api/fpl/league/${id}`); persist({ ...preferences, leagues: [...preferences.leagues.filter(l => l.id !== id), value.league] }); select(id); }} /></aside><section>
    <h2>{result.data?.league.name || 'League standings'}</h2><p className="fpl-muted">Official FPL standings update independently of live squad scores. GW points use FPL’s current gameweek.</p>
    {result.error && <p role="alert">{result.error} <button onClick={result.retry}>Retry</button></p>}{!id && <p>Add a classic league to see its standings.</p>}{id && result.loading && <p role="status">Updating standings…</p>}
    {result.data && <><div className="fpl-table-scroll"><table className="fpl-table"><thead><tr><th>Rank</th><th>Change</th><th>Team / manager</th><th>GW</th><th>Overall</th></tr></thead><tbody>{result.data.standings.results.map(row => <tr key={row.entry} className={row.entry === preferences.manager ? 'is-you' : ''}><td>{row.rank.toLocaleString()}</td><td>{row.last_rank ? row.last_rank - row.rank > 0 ? `↑ ${row.last_rank - row.rank}` : row.last_rank - row.rank < 0 ? `↓ ${row.rank - row.last_rank}` : '—' : 'New'}</td><th><button onClick={() => selectManager(row.entry)}>{row.entry_name}{row.entry === preferences.manager ? ' · You' : ''}<small>{row.player_name}</small></button></th><td>{row.event_total}</td><td>{row.total.toLocaleString()}</td></tr>)}</tbody></table></div><div className="fpl-pagination"><button disabled={page <= 1} onClick={() => setPage(p => p - 1)}>Previous</button><span>Page {page}</span><button disabled={!result.data.standings.has_next} onClick={() => setPage(p => p + 1)}>Next</button></div></>}
  </section></div>;
}
function PlayerPanel({ id, onClose }: { id: number; onClose: () => void }) {
  const state = useResource<PlayerData>(`/api/fpl/player/${id}`);
  const [tab, setTab] = useState('overview');
  const [comparison, setComparison] = useState<number[]>([]);
  const [category, setCategory] = useState<'similar_value' | 'budget'>('similar_value');
  const recommendations = useResource<{ similar_value: { element_id: number }[]; budget: { element_id: number }[]; stale?: boolean }>(tab === 'comparison' ? `/api/v1/fantasy/transfers/recommendations/${id}` : null);
  const panel = useRef<HTMLDialogElement>(null);
  useEffect(() => { const previous = document.activeElement as HTMLElement; panel.current?.showModal(); return () => previous?.focus(); }, []);
  const data = state.data, p = data?.player;
  const alternatives = (recommendations.data?.[category] || []).flatMap(item => { const candidate = data?.alternatives.find(p => p.id === item.element_id); return candidate ? [candidate] : []; });
  const metrics: [string, (p: Player) => string | number][] = [['Price', p => money(p.now_cost)], ['Next GW xP', p => p.ep_next || '—'], ['Form', p => p.form], ['Points / match', p => p.points_per_game], ['Total points', p => p.total_points], ['Ownership', p => `${p.selected_by_percent}%`], ['Minutes', p => p.minutes], ['Goals', p => p.goals_scored], ['Assists', p => p.assists], ['Clean sheets', p => p.clean_sheets], ['Bonus', p => p.bonus], ['Expected goals', p => p.expected_goals], ['Expected assists', p => p.expected_assists], ['ICT index', p => p.ict_index]];
  return <dialog className={`fpl-player-panel${tab === 'comparison' ? ' fpl-panel-wide' : ''}`} ref={panel} aria-labelledby="fpl-player-title" onCancel={e => { e.preventDefault(); onClose(); }}><div className="fpl-panel-inner"><div className="fpl-section-heading"><h2 id="fpl-player-title">{p ? `${p.first_name} ${p.second_name}` : 'Player details'}</h2><button autoFocus onClick={onClose} aria-label="Close player details">×</button></div>
    {state.error && <p role="alert">{state.error} <button onClick={state.retry}>Retry</button></p>}{state.loading && <p role="status">Loading player analysis…</p>}
    {data && p && <><div className="fpl-player-hero"><img src={playerImage(p)} width="110" height="140" alt="" onError={e => { e.currentTarget.style.visibility = 'hidden'; }} /><div><p>{teamName(data.teams, p.team)}</p><strong>{money(p.now_cost)}</strong><p className="fpl-xp">{p.ep_next ?? '—'} expected points next GW</p></div></div>{p.news && <p className="fpl-availability">{p.news}</p>}
      <nav className="fpl-tabs" aria-label="Player analysis">{['overview', 'history', 'stats', 'comparison'].map(name => <button key={name} aria-current={tab === name ? 'page' : undefined} onClick={() => setTab(name)}>{name[0].toUpperCase() + name.slice(1)}</button>)}</nav>
      {tab === 'overview' && <><div className="fpl-player-metrics">{metrics.slice(0, 6).map(([label, fn]) => <Metric key={label} label={label} value={fn(p)} />)}</div><h3>Upcoming fixtures</h3><div className="fpl-table-scroll"><table className="fpl-table"><thead><tr><th>GW</th><th>Opponent</th><th>Difficulty</th></tr></thead><tbody>{data.fixtures.slice(0, 10).map(f => <tr key={f.id}><td>{f.event || 'TBC'}</td><th>{teamName(data.teams, f.is_home ? f.team_a : f.team_h)} ({f.is_home ? 'H' : 'A'})</th><td><span className={`fpl-difficulty difficulty-${f.difficulty}`}>{f.difficulty ?? '—'} / 5</span></td></tr>)}</tbody></table></div>{!data.fixtures.length && <p>No upcoming fixtures published.</p>}</>}
      {tab === 'history' && <><h3>Gameweek history</h3><div className="fpl-table-scroll"><table className="fpl-table"><thead><tr><th>GW</th><th>Opponent</th><th>Pts</th><th>Mins</th><th>Goals</th><th>Assists</th><th>Bonus</th></tr></thead><tbody>{[...data.history].reverse().map(h => <tr key={h.fixture}><td>{h.round}</td><th>{teamName(data.teams, h.opponent_team)} ({h.was_home ? 'H' : 'A'})</th><td><strong>{h.total_points}</strong></td><td>{h.minutes}</td><td>{h.goals_scored}</td><td>{h.assists}</td><td>{h.bonus}</td></tr>)}</tbody></table></div>{!data.history.length && <p>No match history yet.</p>}</>}
      {tab === 'stats' && <><div className="fpl-player-metrics">{metrics.map(([label, fn]) => <Metric key={label} label={label} value={fn(p)} />)}</div><p className="fpl-muted">ICT combines influence, creativity and threat. Expected points are forecasts, not earned points.</p></>}
      {tab === 'comparison' && <><h3>Compare replacements</h3><p className="fpl-muted">Ranked by the same Top Scores recommendations used in the app. Select up to three players to compare.</p><div className="fpl-view-switch"><button aria-pressed={category === 'similar_value'} onClick={() => setCategory('similar_value')}>Similar value</button><button aria-pressed={category === 'budget'} onClick={() => setCategory('budget')}>Budget</button></div>{recommendations.loading && <p role="status">Finding replacements…</p>}{recommendations.error && <p role="alert">{recommendations.error} <button onClick={recommendations.retry}>Retry</button></p>}{recommendations.data?.stale && <p className="fpl-muted">Showing cached recommendations while they refresh.</p>}{recommendations.data && !alternatives.length && <p>No recommendations in this category.</p>}<div className="fpl-comparison-picks">{alternatives.map(candidate => <label key={candidate.id}><input type="checkbox" checked={comparison.includes(candidate.id)} disabled={comparison.length >= 3 && !comparison.includes(candidate.id)} onChange={e => setComparison(ids => e.target.checked ? [...ids, candidate.id] : ids.filter(value => value !== candidate.id))} />{candidate.web_name} <small>{money(candidate.now_cost)}</small></label>)}</div><div className="fpl-table-scroll"><table className="fpl-table"><thead><tr><th>Metric</th>{[p, ...data.alternatives.filter(candidate => comparison.includes(candidate.id))].map(candidate => <th key={candidate.id}>{candidate.web_name}</th>)}</tr></thead><tbody>{metrics.map(([label, fn]) => <tr key={label}><th>{label}</th>{[p, ...data.alternatives.filter(candidate => comparison.includes(candidate.id))].map(candidate => <td key={candidate.id}>{fn(candidate)}</td>)}</tr>)}</tbody></table></div></>}
    </>}
  </div></dialog>;
}
interface TransferPlan { title?: string; summary?: string; projected_gain_next_gameweek: number; reasons?: string[]; transfers: { out_element_id: number; in_element_id: number; out_player_name: string; in_player_name: string; in_price_millions: number; projected_gain_next_gameweek: number; reasons: string[] }[] }
interface AssistantData { sync_status?: { state: string; last_error?: string }; ready: boolean; stale?: boolean; generated_at?: string; current_event_name?: string; algorithm_summary?: string; top_single_transfer?: TransferPlan; top_double_transfers?: TransferPlan; top_triple_transfers?: TransferPlan; money_no_object_transfers?: TransferPlan; captain_recommendations?: { summary?: string; captain: { element_id: number; player_name: string; opponent_label: string; expected_points_next_gameweek: number; reasons: string[] }[] }; expected_points?: { starters: ExpectedPlayer[]; bench: ExpectedPlayer[] }; ideal_squad?: { starters: Record<string, ExpectedPlayer[]>; bench: ExpectedPlayer[] }; }
interface ExpectedPlayer { element_id: number; player_name: string; opponent_label?: string; expected_points_next_gameweek: number; is_captain?: boolean }
function Assistant({ entry, onPlayer }: { entry: number; onPlayer: (id: number) => void }) {
  const result = useResource<AssistantData>(`/api/v1/fantasy/assistant-manager/${entry}`, 30_000);
  const data = result.data;
  return <section className="fpl-assistant"><div className="fpl-section-heading"><div><span className="eyebrow">PLAN YOUR NEXT MOVE</span><h2>Assistant Manager</h2></div><button onClick={result.retry} disabled={result.loading}>Refresh analysis</button></div><p className="fpl-muted">Based on published picks. Changes made privately since the deadline are not included. Recommendations do not make transfers.</p>
    {result.error && <p className="fpl-error" role="alert">{result.error} <button onClick={result.retry}>Retry</button></p>}
    {(!data || !data.ready) && !result.error && <p className="fpl-loading" role="status">{data?.sync_status?.last_error ? 'Analysis is temporarily unavailable. Use Refresh analysis to retry.' : 'Preparing your recommendations. This can take a little longer on the first visit.'}</p>}
    {data?.ready && <>{data.stale && <p role="status">Showing previous analysis while it refreshes.</p>}<p>{data.algorithm_summary}</p>{data.generated_at && <p className="fpl-muted">Generated {new Date(data.generated_at).toLocaleString()} · {data.current_event_name}</p>}
      <div className="fpl-assistant-columns"><div>{!data.top_single_transfer && !data.top_double_transfers && !data.top_triple_transfers && <p>No beneficial transfer plan was found for this published squad.</p>}{[['One transfer', data.top_single_transfer], ['Two transfers', data.top_double_transfers], ['Three transfers', data.top_triple_transfers], ['Money no object', data.money_no_object_transfers]].map(([title, raw]) => { const plan = raw as TransferPlan | undefined; return plan && <section className="fpl-transfer-plan" key={String(title)}><h3>{plan.title || String(title)}</h3><p>{plan.summary}</p>{plan.transfers.map(t => <div className="fpl-transfer" key={`${t.out_element_id}-${t.in_element_id}`}><div><button onClick={() => onPlayer(t.out_element_id)}>{t.out_player_name}</button><span aria-label="to"> → </span><button onClick={() => onPlayer(t.in_element_id)}>{t.in_player_name}</button><strong className="fpl-xp">{t.projected_gain_next_gameweek >= 0 ? '+' : ''}{t.projected_gain_next_gameweek.toFixed(1)} xP</strong></div><ul>{t.reasons.map(reason => <li key={reason}>{reason}</li>)}</ul></div>)}{plan.reasons?.map(reason => <p key={reason}>{reason}</p>)}</section>; })}</div>
      <aside><h3>Captain choices</h3><p>{data.captain_recommendations?.summary}</p>{data.captain_recommendations?.captain.map(c => <div className="fpl-captain" key={c.element_id}><button onClick={() => onPlayer(c.element_id)}>{c.player_name}</button><strong className="fpl-xp">{c.expected_points_next_gameweek.toFixed(1)} xP</strong><p>{c.opponent_label}</p>{c.reasons.map(reason => <p className="fpl-muted" key={reason}>{reason}</p>)}</div>)}{data.expected_points && <ExpectedList title="Your squad · next GW" data={data.expected_points} onPlayer={onPlayer} />}</aside></div>
      {data.ideal_squad && <ExpectedList title="Suggested ideal squad" data={{ starters: Object.values(data.ideal_squad.starters).flat(), bench: data.ideal_squad.bench }} onPlayer={onPlayer} />}
    </>}
  </section>;
}
function ExpectedList({ title, data, onPlayer }: { title: string; data: { starters: ExpectedPlayer[]; bench: ExpectedPlayer[] }; onPlayer: (id: number) => void }) {
  return <section><h3>{title}</h3><div className="fpl-table-scroll"><table className="fpl-table"><thead><tr><th>Player</th><th>Role</th><th>Next GW xP</th></tr></thead><tbody>{[...(data.starters || []), ...(data.bench || [])].map((p, index) => <tr key={p.element_id}><th><button onClick={() => onPlayer(p.element_id)}>{p.player_name}{p.is_captain ? ' (C)' : ''}</button></th><td>{index < data.starters.length ? 'Starter' : 'Bench'}</td><td className="fpl-xp">{p.expected_points_next_gameweek.toFixed(1)}</td></tr>)}</tbody></table></div></section>;
}
