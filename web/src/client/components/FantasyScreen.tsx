import { useEffect, useRef, useState, type FormEvent } from 'react';
import { Link, useLocation, useNavigate, useSearchParams } from 'react-router-dom';
import { managerInitials, seasonTotal, sortSquads, visibleLeagues, fetchFantasy, money, parseFplID, playerImageCandidates, teamName, type LeagueData, type Player, type PlayerData, type Preferences, type Profile, type Squad, type SquadPlayer } from '../fantasyData';
import '../fantasy.css';
import { displayTime, localDate, matchPath } from '../football';
import { displayStatus, isMatchFinished, isMatchLive } from '../matchState';
import { fetchTableMatches } from '../tableScores';
import { teamIdentityKeys, useTeamColorCatalog } from '../teamColors';
import { normalizeMatchDetails } from '../api';
import { buildPlayerNameLookup, matchPlayerNameLookup } from '../matchPlayerNames';
import type { Match, MatchDetails } from '../types';
import { useInitialSeed } from '../bootstrap';
import { useFantasyPreferences } from '../fantasySync';
import { PageMeta } from './PageMeta';
import FantasyConnection from './FantasyConnection';

function useResource<T>(path: string | null, interval = 0, initial?: { path: string; data: T }, fetchData: (path: string, signal: AbortSignal) => Promise<T> = fetchFantasy) {
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
        const data = await fetchData(path, controller.signal);
        if (!stopped) setState({ path, data, loading: false });
      } catch (error) {
        if (!stopped) setState(old => ({ ...old, path, loading: false, error: error instanceof Error ? error.message : 'Unable to load FPL data.' }));
      } finally { running = false; }
    };
    void load();
    const timer = interval ? window.setInterval(load, interval) : undefined;
    document.addEventListener('visibilitychange', load);
    return () => { stopped = true; controller.abort(); clearInterval(timer); document.removeEventListener('visibilitychange', load); };
  }, [path, interval, revision, fetchData]);
  return { data: state.path === path ? state.data : undefined, error: state.path === path ? state.error : undefined, loading: state.path !== path || state.loading, retry: () => setRevision(value => value + 1) };
}

export default function FantasyScreen() {
  const [params, setParams] = useSearchParams();
  const seed = useInitialSeed();
  const sync = useFantasyPreferences();
  const { preferences, ready, persist } = sync;
  const [message, setMessage] = useState('');
  const route = useLocation();
  const navigate = useNavigate();
  const setup = route.pathname === '/fpl/settings';
  const [metric, setMetric] = useState('opponent');
  const [view, setView] = useState('pitch');
  const section = ['team', 'leagues'].includes(params.get('section') || '') ? params.get('section')! : 'team';
  const entry = parseFplID(params.get('entry') || '') || preferences.manager;
  const event = parseFplID(params.get('event') || '');
  const player = parseFplID(params.get('player') || '');
  const league = parseFplID(params.get('league') || '');
  const squad = useResource<Squad>(!setup && (ready || seed?.fantasy) && entry ? `/api/fpl/entry/${entry}${event ? `?event=${event}` : ''}` : null, 30_000, seed?.fantasy && seed.fantasyPath ? { path: seed.fantasyPath, data: seed.fantasy } : undefined);
  const data = squad.data;
  const pitch = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const element = pitch.current;
    if (!element) return;
    const fit = () => {
      const height = Math.max(360, window.innerHeight - (element.getBoundingClientRect().top + window.scrollY) - 12);
      element.style.setProperty('--pitch-available-height', `${height}px`);
    };
    fit();
    const observer = new ResizeObserver(fit);
    observer.observe(element.closest('.fpl-page')!);
    const header = document.querySelector('.site-header');
    if (header) observer.observe(header);
    window.addEventListener('resize', fit);
    return () => { observer.disconnect(); window.removeEventListener('resize', fit); };
  }, [!!data, section, view, setup]);
  const [addingRival, setAddingRival] = useState(false);
  const addRivalForm = useRef<HTMLDivElement>(null);
  useEffect(() => { if (addingRival) { addRivalForm.current?.scrollIntoView({ block: 'nearest' }); addRivalForm.current?.querySelector('input')?.focus(); } }, [addingRival]);
  const rivalIDs = [...new Set([preferences.manager || entry, ...preferences.rivals].filter((id): id is number => !!id))];
  const rivals = useRivalSquads(setup ? [] : rivalIDs.filter(id => id !== entry), data?.event.id);
  const pool = rivalIDs.flatMap(id => { const value = data?.profile.id === id ? data : rivals[id]; return value ? [value] : []; });
  const trackedRivalIDs = rivalIDs.filter(id => id !== (preferences.manager || entry));
  const trackedSquads = pool.filter(team => trackedRivalIDs.includes(team.profile.id));
  const completeRanks = pool.length === rivalIDs.length && pool.every(team => team.previousTotal != null);
  const ownSquad = pool.find(s => s.profile.id === (preferences.manager || entry));
  const ownProfile = ownSquad?.profile;
  const historical = data && data.event.id !== data.events.at(-1)?.id;
  const currentOwn = useResource<Squad>(historical && section === 'team' && (preferences.manager || entry)
    ? `/api/fpl/entry/${preferences.manager || entry}` : null, 30_000);
  useTeamColorCatalog();
  const date = localDate();
  const games = useResource<Match[]>(data && section === 'team' && !setup ? date : null, 30_000, undefined, fetchGames);
  const details = usePitchMatchDetails(games.data, data, view === 'pitch');
  const exits = playerExits(data, games.data, details);
  const leagues = visibleLeagues(ownProfile, preferences.leagues, preferences.leagueOrder);
  const deadline = data?.nextDeadline ? new Date(data.nextDeadline) : null;
  const deadlineClose = !!deadline && deadline.getTime() - Date.now() < 24 * 60 * 60 * 1000 && deadline.getTime() > Date.now();
  const change = (values: Record<string, string | number | null>) => {
    const next = new URLSearchParams(params);
    for (const [key, value] of Object.entries(values)) value === null ? next.delete(key) : next.set(key, String(value));
    setParams(next);
  };
  const selectManager = (id: number) => change({ entry: id === preferences.manager ? null : id, player: null });
  const openPlayer = (id: number) => change({ player: id });
  const saveManager = async (id: number) => {
    await fetchFantasy<Profile>(`/api/fpl/profile/${id}`);
    persist({ ...preferences, manager: id });
    navigate('/fpl?entry=' + id);
  };
  const addRival = async (id: number) => {
    if (preferences.rivals.length >= 100) throw new Error('You can follow up to 100 rivals. Remove one first.');
    await fetchFantasy<Profile>(`/api/fpl/profile/${id}`);
    persist({ ...preferences, rivals: [...new Set([...preferences.rivals, id])].filter(value => value !== preferences.manager) });
  };
  return <div className="fpl-page">
    <PageMeta title={setup ? 'FPL team settings' : 'Fantasy Premier League'} description={setup ? 'Connect your Top Scores app or choose your FPL team.' : 'Follow your FPL squad, live points, rivals and leagues.'} />
    <header className="fpl-heading"><div><h1>{setup ? 'FPL team settings' : data ? `${data.event.name}: ${data.profile.name}` : 'Fantasy Premier League'}</h1>{!setup && deadline && <p className={`fpl-deadline${deadlineClose ? ' is-close' : ''}`}>Next transfer deadline · <time dateTime={deadline.toISOString()}>{deadline.toLocaleString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</time>{deadlineClose && <strong> · Less than 24 hours</strong>}</p>}</div>{entry && !setup && <div className="fpl-toolbar">{data && <label><select aria-label="Gameweek" value={data.event.id} onChange={e => change({ event: Number(e.target.value) })}>{[...data.events].reverse().map(gw => <option key={gw.id} value={gw.id}>{gw.name}</option>)}</select></label>}
        <button onClick={squad.retry} disabled={squad.loading}> {squad.loading ? 'Refreshing…' : 'Refresh'}</button>
        <button onClick={async () => { try { const url = new URL(location.href); url.searchParams.set('entry', String(entry)); await navigator.clipboard.writeText(url.href); setMessage('Link copied. It shares public FPL data only.'); } catch { setMessage('Copy the page address to share this team.'); } }}>Share</button>
</div>}</header>
    {!entry || setup ? <>
      <FantasyConnection sync={sync} onImport={id => navigate(id ? '/fpl?entry=' + id : '/fpl')} />
      <section className="fpl-setup">
      <h2>{sync.connected ? 'Change your FPL team' : 'Or add your FPL team manually'}</h2>
      <p>Follow your published squad, live points and rivals with your FPL manager ID. No password needed.</p>
      <IDForm label="Manager ID or FPL team link" onSubmit={saveManager} button="Follow my team" />
      <p className="fpl-muted">Find your ID in the address of your Points page on the official FPL website, for example /entry/123456/event/12.</p>
      <p className="fpl-muted">{sync.connected ? 'Changing your team here also updates it in the app.' : 'Saved on this browser.'} Pre-deadline transfers and private lineups are not available.</p>
      <a href="https://fantasy.premierleague.com/" target="_blank" rel="noreferrer">Open Fantasy Premier League ↗</a>
      {setup && <button onClick={() => route.state?.fromFpl ? navigate(-1) : navigate('/fpl')}>Back to FPL</button>}
    </section></> : <>
      {message && <p role="status">{message}</p>}
      {squad.error && <p className="fpl-error" role="alert">{squad.error} {data && 'Showing the last successful update.'} <button onClick={squad.retry}>Retry</button></p>}
      {!data && !squad.error && <div className="fpl-loading" role="status">Loading published squad…</div>}
      {data && <>
        {section === 'team' && <>
          <div className="fpl-manager-strip" aria-label="Your team and rivals by gameweek score">{[...pool.filter(team => team.profile.id === preferences.manager), ...sortSquads(pool.filter(team => team.profile.id !== preferences.manager))].map(team => <button className={`fpl-manager-pill${team.profile.id === preferences.manager ? ' is-you has-rival-separator' : ''}`} key={team.profile.id} aria-pressed={team.profile.id === entry} aria-label={`${team.profile.name}${team.profile.id === preferences.manager ? ', your team' : ''}, ${team.points} points`} onClick={() => selectManager(team.profile.id)}><span className="fpl-manager-circle"><ManagerBadge profile={team.profile} /><b>{team.points}</b></span><span>{managerInitials(team.profile)}</span></button>)}<button className="fpl-manager-add" onClick={() => setAddingRival(value => !value)} aria-expanded={addingRival}><span>＋</span>Add</button></div>
          {addingRival && <div ref={addRivalForm}><IDForm label="Rival manager ID or team link" button="Add rival" onSubmit={async id => { await addRival(id); setAddingRival(false); }} /></div>}
          <div className="fpl-dashboard"><section aria-label="Squad"><div className="fpl-pitch-controls"><div className="fpl-view-switch"><button aria-pressed={view === 'pitch'} onClick={() => setView('pitch')}>Pitch</button><button aria-pressed={view === 'table'} onClick={() => setView('table')}>Table</button></div>
            <div className="fpl-metric-select"><label>Player detail <select value={metric} onChange={e => setMetric(e.target.value)}>{[['opponent', 'Opposition'], ['now_cost', 'Price'], ['difficulty', 'Difficulty'], ['selected_by_percent', 'Ownership %'], ['ownership_count', 'Ownership count'], ['form', 'Form'], ['points_per_game', 'Points / match'], ['total_points', 'Total points'], ['minutes', 'Minutes / start'], ['ep_next', 'Next GW expected points']].map(([key, name]) => <option key={key} value={key}>{name}</option>)}</select></label></div></div>
            {view === 'pitch' ? <><div className="fpl-pitch" ref={pitch}><PitchMarkings /><div className="fpl-pitch-stat fpl-points-stat"><span>{data.finalized ? 'Final points' : 'Live points'}</span><strong>{data.points}</strong><small>GW average: {data.event.average_entry_score}</small></div><div className="fpl-pitch-stat fpl-value-stat"><span>Team value</span><strong>{money(data.history.value)}</strong></div>{[1, 2, 3, 4].map(position => <div className="fpl-position" key={position}>{data.players.filter(p => p.pickPosition <= 11 && p.element_type === position).map(p => <PlayerCard key={p.id} exit={exits.get(p.id)} player={p} data={data} metric={metric} onClick={() => openPlayer(p.id)} />)}</div>)}</div><div className="fpl-bench"><h3>Bench <span>In substitution order</span></h3><div className="fpl-position">{data.players.filter(p => p.pickPosition > 11).map(p => <PlayerCard key={p.id} exit={exits.get(p.id)} player={p} data={data} metric={metric} onClick={() => openPlayer(p.id)} />)}</div></div></> : <div className="fpl-table-scroll"><table className="fpl-table"><thead><tr><th>Player</th><th>Role</th><th>Points</th><th>Price</th><th>Form</th><th>Owned</th></tr></thead><tbody>{data.players.map(p => <tr key={p.id}><th><button onClick={() => openPlayer(p.id)}>{p.web_name}</button></th><td>{p.isCaptain ? 'Captain' : p.isViceCaptain ? 'Vice captain' : p.pickPosition > 11 ? 'Bench' : 'Starter'}</td><td>{p.rawPoints} × {p.multiplier}</td><td>{money(p.now_cost)}</td><td>{p.form}</td><td>{p.selected_by_percent}%</td></tr>)}</tbody></table></div>}
            <details className="fpl-breakdown" open={data.notes.length > 0}><summary>How your score is calculated · {data.points} pts</summary><p>{data.grossPoints} squad points − {data.transferCost} transfer cost = <strong>{data.points} net points</strong>.</p>{data.notes.map(note => <p key={note}>{note}</p>)}<p className="fpl-muted">{data.finalized ? 'Official FPL multipliers and substitutions are applied.' : 'Points may change. Substitutions are projected after all of a player’s fixtures finish; official confirmation follows.'}</p></details>
          </section><aside className="fpl-rivals"><TodaysGames date={date} games={games} squad={historical ? currentOwn.data : ownSquad} /><div className="fpl-section-heading"><h2>Rivals</h2><span>GW {data.event.id}</span></div><div className="fpl-rivals-labels"><span>Team</span><span>GW</span><span>Total</span></div>
            {sortSquads(pool, true).map(team => <Rival key={team.profile.id} data={team}
              rank={1 + pool.filter(other => seasonTotal(other) > seasonTotal(team)).length}
              previous={completeRanks ? 1 + pool.filter(other => other.previousTotal! > team.previousTotal!).length : 0}
              selected={team.profile.id === entry} own={team.profile.id === preferences.manager} onSelect={() => selectManager(team.profile.id)} onRemove={() => persist({ ...preferences, rivals: preferences.rivals.filter(value => value !== team.profile.id) })} />)}
            {pool.length < rivalIDs.length && <p className="fpl-muted">Some teams are still loading. Retrying automatically.</p>}
            <button className="fpl-add-rival" onClick={() => setAddingRival(value => !value)}>＋ Add rival</button>
            <div className="fpl-section-heading"><h3>Your leagues</h3><button className="fpl-league-manage" onClick={() => change({ section: 'leagues' })}>Manage</button></div>{leagues.map(l => <button className="fpl-league-link" key={l.id} onClick={() => change({ section: 'leagues', league: l.id })}><span className="fpl-league-initial">{l.name[0]}</span><span>{l.name}</span><strong>{l.entry_rank ? `#${l.entry_rank.toLocaleString()}` : '›'}</strong><LeagueTrend rank={l.entry_rank} previous={l.entry_last_rank} /></button>)}{!leagues.length && <p className="fpl-muted">No private leagues yet.</p>}
          </aside></div>
        </>}
        {section === 'leagues' && <><button className="fpl-back-to-pitch" onClick={() => change({ section: 'team', league: null })}>← Back to pitch</button><Leagues key={preferences.manager} data={data} profile={ownProfile} selected={league} preferences={preferences} persist={persist} select={id => change({ league: id })} selectManager={id => change({ entry: id, section: 'team', player: null })} /></>}

      </>}
    </>}
    {entry && !setup && <footer className="fpl-settings"><Link to="/fpl/settings" state={{ fromFpl: true }}>{sync.conflict ? 'Resolve sync in FPL team settings' : 'FPL team settings'}</Link></footer>}
    {!setup && player && <PlayerPanel key={player} id={player} ownSquad={preferences.manager ? ownSquad : undefined} rivals={trackedSquads} picksComplete={ready && (!preferences.manager || !!ownSquad) && trackedSquads.length === trackedRivalIDs.length} onClose={() => change({ player: null })} />}
  </div>;
}
function Metric({ label, value }: { label: string; value: string | number | undefined }) { return <div><span>{label}</span><strong>{value ?? '—'}</strong></div>; }
function IDForm({ label, onSubmit, button, kind = 'entry' }: { label: string; onSubmit: (id: number) => Promise<void>; button: string; kind?: 'entry' | 'league' }) {
  const [input, setInput] = useState(''), [error, setError] = useState(''), [busy, setBusy] = useState(false);
  const submit = async (e: FormEvent) => { e.preventDefault(); const id = parseFplID(input, kind); if (!id) { setError(`Enter a valid ${kind === 'entry' ? 'manager' : 'league'} ID or official FPL link.`); return; } setBusy(true); setError(''); try { await onSubmit(id); setInput(''); } catch (error) { setError(error instanceof Error ? error.message : 'Unable to save.'); } finally { setBusy(false); } };
  return <form className="fpl-id-form" onSubmit={submit}><label>{label}<input value={input} onChange={e => setInput(e.target.value)} placeholder="e.g. 123456" required maxLength={300} /></label><button disabled={busy} type="submit">{busy ? 'Checking…' : button}</button>{error && <p className="fpl-error" role="alert">{error}</p>}</form>;
}
type PitchExit = 'sent off' | 'substituted off';
function PlayerCard({ player: p, data, metric, onClick, exit }: { exit?: PitchExit; player: SquadPlayer; data: Squad; metric: string; onClick: () => void }) {
  const incoming = data.substitutions.some(s => s.incoming === p.id), outgoing = data.substitutions.some(s => s.outgoing === p.id);
  const sentOff = exit === 'sent off' || (p.fixtures.length === 1 ? p.stats.red_cards > 0 :
    p.fixtures.some(f => f.started && !f.finished && !f.finished_provisional && p.redCardFixtures?.includes(f.id)));
  const live = p.inPlay && !exit && !sentOff;
  const displayPoints = p.pickPosition <= 11 ? p.rawPoints * p.multiplier : p.rawPoints;
  let detail: string;
  if (metric === 'opponent') detail = p.fixtures.map(f => `${teamName(data.teams, f.team_h === p.team ? f.team_a : f.team_h, true)} (${f.team_h === p.team ? 'H' : 'A'})`).join(' · ') || 'No fixture';
  else if (metric === 'difficulty') detail = p.fixtures.map(f => `FDR ${f.team_h === p.team ? f.team_h_difficulty : f.team_a_difficulty}/5`).join(' · ') || 'No fixture';
  else if (metric === 'now_cost') detail = money(p.now_cost);
  else if (metric === 'ownership_count') detail = `≈ ${Math.round(data.totalPlayers * Number(p.selected_by_percent) / 100).toLocaleString()}`;
  else if (metric === 'minutes') detail = `${Math.round(p.minutes / Math.max(p.starts, 1))} mins / start`;
  else detail = String(p[metric as keyof Player] ?? '—') + (metric === 'selected_by_percent' ? '%' : metric === 'ep_next' ? ' xP' : '');
  return <button className={`fpl-player${live ? ' is-live' : ''}${incoming ? ' is-incoming' : ''}${outgoing ? ' is-outgoing' : ''}`} onClick={onClick} aria-label={`${p.first_name} ${p.second_name}, ${displayPoints} points${sentOff ? ', sent off' : exit ? ', substituted off' : ''}${p.isCaptain ? ', captain' : ''}${incoming ? ', included substitute' : ''}${outgoing ? ', replaced starter' : ''}`}>
    <span className={`fpl-player-detail difficulty-${p.fixtures[0] ? (p.fixtures[0].team_h === p.team ? p.fixtures[0].team_h_difficulty : p.fixtures[0].team_a_difficulty) : 0}`}>{detail}</span><span className="fpl-player-photo" data-initials={p.web_name.slice(0, 2).toUpperCase()}><PlayerPortrait key={p.code} player={p} />{(p.isCaptain || p.isViceCaptain) && <b>{p.isCaptain ? 'C' : 'V'}</b>}{p.status !== 'a' && <span title={p.news || 'Availability concern'} aria-label={p.news || 'Availability concern'}>!</span>}</span>
    <strong>{p.web_name}</strong><span className="fpl-player-score">{p.started || p.stats.minutes ? displayPoints : '—'}{live && <small> LIVE</small>}</span><span className="fpl-player-events">{p.stats.goals_scored > 0 && <span title="Goals">⚽{p.stats.goals_scored}</span>}{p.stats.assists > 0 && <span title="Assists" aria-label={`${p.stats.assists} assists`}><b className="fpl-assist-icon">A</b>{p.stats.assists}</span>}{p.stats.yellow_cards > 0 && <span title="Yellow card">🟨</span>}{(sentOff || p.stats.red_cards > 0) && <span title="Sent off">🟥</span>}{exit === 'substituted off' && !sentOff && <span className="fpl-sub-off" title="Substituted off">↓</span>}</span>{incoming && <small>↑ Included</small>}{outgoing && <small>↓ Replaced</small>}
  </button>;
}
function PlayerPortrait({ player }: { player: Player }) {
  const [source, setSource] = useState(0);
  const candidates = playerImageCandidates(player);
  return source < candidates.length ? <img src={candidates[source]} width="110" height="140" alt="" loading="lazy" onError={() => setSource(value => value + 1)} /> : <span className="fpl-portrait-fallback" aria-label="Portrait unavailable">{player.web_name.slice(0, 2).toUpperCase()}</span>;
}
function ManagerBadge({ profile }: { profile: Pick<Profile, 'id' | 'club_badge_src' | 'player_first_name' | 'player_last_name'> }) {
  const [failed, setFailed] = useState(false);
  return <span className={`fpl-manager-badge colour-${profile.id % 6}`}>{profile.club_badge_src && !failed ? <img src={profile.club_badge_src} alt="" width="64" height="64" loading="lazy" onError={() => setFailed(true)} /> : <span>{managerInitials(profile)}</span>}</span>;
}
function LeagueTrend({ rank, previous }: { rank: number; previous: number }) {
  const direction = !rank || !previous ? 'new' : rank < previous ? 'up' : rank > previous ? 'down' : 'same';
  const label = direction === 'new' ? 'No previous rank' : direction === 'same' ? 'Rank unchanged' : `${direction === 'up' ? 'Up' : 'Down'} ${Math.abs(previous - rank)} places`;
  return <span className={`fpl-league-trend trend-${direction}`} aria-label={label} title={label}>{direction === 'up' ? '↑' : direction === 'down' ? '↓' : direction === 'same' ? '=' : '—'}</span>;
}
const fetchGames = (date: string, signal: AbortSignal) => fetchTableMatches(['Premier League'], date, signal);

function matchPlayers(match: Match, squad: Squad) {
  const clubIDs = (name: string, short?: string | null) => {
    const keys = [...teamIdentityKeys(name), ...teamIdentityKeys(short || name)];
    return squad.teams.filter(team => [team.name, team.short_name].some(alias =>
      teamIdentityKeys(alias).some(key => keys.includes(key)))).map(team => team.id);
  };
  const home = clubIDs(match.homeTeam, match.homeShortName);
  const away = clubIDs(match.awayTeam, match.awayShortName);
  return squad.players.flatMap(player => {
    const fixture = player.fixtures.find(f => (home.includes(f.team_h) || away.includes(f.team_a))
      && f.kickoff_time && localDate(new Date(f.kickoff_time)) === match.date);
    return fixture ? [{ player, fixture, isHome: fixture.team_h === player.team }] : [];
  });
}

function usePitchMatchDetails(matches: Match[] | undefined, squad: Squad | undefined, enabled: boolean) {
  const [details, setDetails] = useState<Record<string, MatchDetails>>({});
  const ids = enabled && squad ? (matches || []).filter(m => m.matchDetailsId && (isMatchLive(m) || isMatchFinished(m))
    && matchPlayers(m, squad).length).map(m => m.matchDetailsId!).join(',') : '';
  useEffect(() => {
    if (!ids) return;
    const controller = new AbortController();
    void Promise.all(ids.split(',').map(async id => {
      try {
        const raw = await fetchFantasy<Record<string, unknown>>(`/api/v1/matches/${encodeURIComponent(id)}`, controller.signal);
        const detail = normalizeMatchDetails(raw);
        if (!controller.signal.aborted) setDetails(old => ({ ...old, [id]: detail }));
      } catch { /* Retain the last incidents until the next scores refresh. */ }
    }));
    return () => controller.abort();
  }, [ids, matches]);
  return details;
}

function playerExits(squad: Squad | undefined, matches: Match[] | undefined, details: Record<string, MatchDetails>) {
  const exits = new Map<number, PitchExit>();
  if (!squad) return exits;
  for (const match of matches || []) {
    const detail = details[match.matchDetailsId || ''];
    if (!detail) continue;
    for (const { player, fixture, isHome } of matchPlayers(match, squad)) {
      if (player.inPlay && (fixture.finished || fixture.finished_provisional)) continue;
      const full = buildPlayerNameLookup([player.first_name, player.second_name].filter(Boolean).join(' '));
      const short = buildPlayerNameLookup(player.web_name);
      const samePlayer = (name: string) => {
        const candidate = buildPlayerNameLookup(name);
        return candidate.full === short.full || matchPlayerNameLookup(candidate, full) >= 2
          || (!candidate.full.includes(' ') && candidate.full === full.last);
      };
      const lineup = isHome ? detail.teamLineups?.home : detail.teamLineups?.away;
      if ((isHome ? detail.homeRedCards : detail.awayRedCards).some(card => samePlayer(card.player))) exits.set(player.id, 'sent off');
      else if (lineup?.substitutions.some(sub => samePlayer(sub.playerOff.name))) exits.set(player.id, 'substituted off');
    }
  }
  return exits;
}

function matchContribution(match: Match, squad?: Squad) {
  if (!squad) return null;
  let points = 0;
  const names: string[] = [];
  for (const { player, fixture } of matchPlayers(match, squad)) {
    names.push(player.web_name);
    points += player.multiplier * (player.fixtures.length === 1 ? player.rawPoints : player.fixturePoints?.[fixture.id] ?? 0);
  }
  return names.length ? { names, points } : null;
}

function pointsColour(points: number) {
  if (points < 1) return 'red';
  if (points <= 2) return 'orange';
  if (points <= 4) return 'amber';
  if (points <= 7) return 'light-green';
  return 'green';
}

function TodaysGames({ squad, date, games }: { squad?: Squad; date: string; games: { data?: Match[]; error?: string } }) {
  const matches = (games.data || []).filter(match => match.date === date && match.league === 'Premier League')
    .sort((a, b) => a.time.localeCompare(b.time));
  if (!matches.length && !games.error) return null;
  return <section className="fpl-games"><div className="fpl-section-heading"><h2>Today's games</h2></div>
    {games.error && <small>{matches.length ? 'Scores may be delayed.' : 'Scores temporarily unavailable.'}</small>}
    {matches.map(match => {
      const contribution = matchContribution(match, squad);
      const score = match.homeScore != null && match.awayScore != null ? `${match.homeScore}–${match.awayScore}` : 'v';
      const live = isMatchLive(match);
      return <Link className="fpl-game" key={match.id} to={matchPath(match)} state={{ match }}>
        <small className={live ? 'fixture-state live-clock' : undefined}>{live && <><span className="live-dot" aria-hidden="true" /><span className="sr-only">Live </span></>}
          {match.scoreStatus === 'NS' ? displayTime(match.time) : displayStatus(match)}</small><span>{match.homeShortName || match.homeTeam}</span>
        <strong>{score}</strong><span>{match.awayShortName || match.awayTeam}</span>
        {contribution && <b className="fpl-game-points" data-colour={pointsColour(contribution.points)} title={contribution.names.join(', ')}
          aria-label={`${contribution.points} FPL points from ${contribution.names.join(', ')}`}>{contribution.points} {Math.abs(contribution.points) === 1 ? 'pt' : 'pts'}</b>}
      </Link>;
    })}
  </section>;
}

function Rival({ rank, previous, data, selected, own, onSelect, onRemove }: { rank: number; previous: number; data: Squad; selected: boolean; own: boolean; onSelect: () => void; onRemove: () => void }) {
  return <div className={`fpl-rival${own ? ' is-you' : ''}${selected ? ' selected' : ''}`}><button onClick={onSelect}><ManagerBadge profile={data.profile} /><span><strong>{data.profile.name}{own ? ' · You' : ''}</strong><small>{data.profile.player_first_name} {data.profile.player_last_name}</small></span><strong>{data.points}</strong><strong>{seasonTotal(data).toLocaleString()}</strong><LeagueTrend rank={rank} previous={previous} /></button>{own ? <span className="fpl-remove-space" aria-hidden="true" /> : <button className="fpl-remove" aria-label={`Remove rival ${data.profile.name}`} onClick={onRemove}>×</button>}</div>;
}
function useRivalSquads(ids: number[], event?: number) {
  const [squads, setSquads] = useState<Record<number, Squad>>({});
  const key = ids.join(',');
  useEffect(() => {
    if (!event) return;
    let stopped = false, running = false;
    const controller = new AbortController();
    const load = async () => {
      if (running || document.hidden) return;
      running = true;
      const queue = key.split(',').filter(Boolean).map(Number);
      await Promise.all(Array.from({ length: Math.min(6, queue.length) }, async () => {
        while (queue.length && !stopped) {
          const id = queue.shift()!;
          try { const value = await fetchFantasy<Squad>(`/api/fpl/entry/${id}?event=${event}`, controller.signal); if (!stopped) setSquads(previous => ({ ...previous, [id]: value })); } catch { /* Keep the last successful score and retry. */ }
        }
      }));
      running = false;
    };
    void load();
    const timer = setInterval(load, 30_000); document.addEventListener('visibilitychange', load);
    return () => { stopped = true; controller.abort(); clearInterval(timer); document.removeEventListener('visibilitychange', load); };
  }, [key, event]);
  return Object.fromEntries(Object.entries(squads).filter(([, value]) => value.event.id === event));
}
function PitchMarkings() {
  return <svg className="fpl-pitch-markings" viewBox="0 0 600 800" preserveAspectRatio="none" aria-hidden="true"><rect x="12" y="12" width="576" height="776" rx="18" /><path d="M12 400H588M160 12V150H440V12M230 12V65H370V12M160 788V650H440V788M230 788V735H370V788" /><circle cx="300" cy="400" r="75" /><circle cx="300" cy="400" r="3" /><path d="M240 150Q300 205 360 150M240 650Q300 595 360 650" /></svg>;
}
function Leagues({ data, profile, selected, preferences, persist, select, selectManager }: { data: Squad; profile?: Profile; selected: number | null; preferences: Preferences; persist: (p: Preferences) => void; select: (id: number) => void; selectManager: (id: number) => void }) {
  const [page, setPage] = useState(1);
  const leagues = visibleLeagues(profile, preferences.leagues, preferences.leagueOrder);
  const id = selected || leagues[0]?.id;
  const result = useResource<LeagueData>(id ? `/api/fpl/league/${id}?page=${page}` : null, 60_000);
  useEffect(() => setPage(1), [id]);
  return <div className="fpl-leagues"><aside><h2>Leagues</h2>{leagues.map((l, index) => <div className="fpl-league-choice" key={l.id}><button aria-pressed={id === l.id} onClick={() => { setPage(1); select(l.id); }}>{l.name}</button><button aria-label={`Move ${l.name} up`} disabled={index === 0} onClick={() => { const next = leagues.map(l => l.id); [next[index - 1], next[index]] = [next[index], next[index - 1]]; persist({ ...preferences, leagueOrder: next }); }}>↑</button>{preferences.leagues.some(saved => saved.id === l.id) && !profile?.leagues.classic.some(owned => owned.id === l.id && owned.league_type === 'x') && <button aria-label={`Unsave ${l.name}`} onClick={() => persist({ ...preferences, leagues: preferences.leagues.filter(saved => saved.id !== l.id) })}>×</button>}</div>)}<IDForm kind="league" label="League ID or link" button="Save league" onSubmit={async id => { const value = await fetchFantasy<LeagueData>(`/api/fpl/league/${id}`); persist({ ...preferences, leagues: [...preferences.leagues.filter(l => l.id !== id), value.league] }); select(id); }} /></aside><section>
    <h2>{result.data?.league.name || 'League standings'}</h2><p className="fpl-muted">Official FPL standings update independently of live squad scores. GW points use FPL’s current gameweek.</p>
    {result.error && <p role="alert">{result.error} <button onClick={result.retry}>Retry</button></p>}{!id && <p>Add a classic league to see its standings.</p>}{id && result.loading && <p role="status">Updating standings…</p>}
    {result.data && <><div className="fpl-table-scroll"><table className="fpl-table"><thead><tr><th>Rank</th><th>Change</th><th>Team / manager</th><th>GW</th><th>Overall</th></tr></thead><tbody>{result.data.standings.results.map(row => <tr key={row.entry} onClick={() => selectManager(row.entry)} className={row.entry === preferences.manager ? 'is-you' : ''}><td>{row.rank.toLocaleString()}</td><td>{row.last_rank ? row.last_rank - row.rank > 0 ? `↑ ${row.last_rank - row.rank}` : row.last_rank - row.rank < 0 ? `↓ ${row.rank - row.last_rank}` : '—' : 'New'}</td><th><button className="fpl-league-team"><ManagerBadge profile={{ id: row.entry, club_badge_src: row.club_badge_src || undefined, player_first_name: row.player_name.split(/\s+/)[0], player_last_name: row.player_name.split(/\s+/).slice(1).join(' ') }} /><span>{row.entry_name}{row.entry === preferences.manager ? ' · You' : ''}<small>{row.player_name}</small></span></button></th><td>{row.event_total}</td><td>{row.total.toLocaleString()}</td></tr>)}</tbody></table></div><div className="fpl-pagination"><button disabled={page <= 1} onClick={() => setPage(p => p - 1)}>Previous</button><span>Page {page}</span><button disabled={!result.data.standings.has_next} onClick={() => setPage(p => p + 1)}>Next</button></div></>}
  </section></div>;
}
function PlayerPanel({ id, ownSquad, rivals, picksComplete, onClose }: {
  id: number; ownSquad?: Squad; rivals: Squad[]; picksComplete: boolean; onClose: () => void;
}) {
  const pickedPlayer = (team: Squad) => team.players.some(player => player.id === id);
  const owners = sortSquads(rivals.filter(pickedPlayer));
  if (ownSquad && pickedPlayer(ownSquad)) owners.unshift(ownSquad);
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
    {data && p && <><div className="fpl-player-hero"><PlayerPortrait key={p.code} player={p} /><div><p>{teamName(data.teams, p.team)}</p><strong>{money(p.now_cost)}</strong></div></div>
      {owners.length > 0 && <section aria-label="Picked by"><h3>Picked by</h3>
        <ul className="fpl-manager-strip fpl-picked-by">{owners.map(({ profile }) => <li className={profile.id === ownSquad?.profile.id && owners.length > 1 ? "fpl-manager-pill has-rival-separator" : "fpl-manager-pill"} key={profile.id}>
          <ManagerBadge profile={profile} /><span>{profile.id === ownSquad?.profile.id ? 'You' : [profile.player_first_name, profile.player_last_name].filter(Boolean).join(' ') || profile.name}</span>
        </li>)}</ul>
      </section>}
      {(!picksComplete || owners.length === 0) && <p className="fpl-muted">{picksComplete ? 'None of your rivals have picked this player' : 'Some picks are unavailable for this gameweek'}</p>}
      <p className="fpl-xp">{p.ep_next ?? '—'} expected points next GW</p>{p.news && <p className="fpl-availability">{p.news}</p>}
      <nav className="fpl-tabs" aria-label="Player analysis">{['overview', 'history', 'stats', 'comparison'].map(name => <button key={name} aria-current={tab === name ? 'page' : undefined} onClick={() => setTab(name)}>{name[0].toUpperCase() + name.slice(1)}</button>)}</nav>
      {tab === 'overview' && <><div className="fpl-player-metrics">{metrics.slice(0, 6).map(([label, fn]) => <Metric key={label} label={label} value={fn(p)} />)}</div><h3>Upcoming fixtures</h3><div className="fpl-table-scroll"><table className="fpl-table"><thead><tr><th>GW</th><th>Opponent</th><th>Difficulty</th></tr></thead><tbody>{data.fixtures.slice(0, 10).map(f => <tr key={f.id}><td>{f.event || 'TBC'}</td><th>{teamName(data.teams, f.is_home ? f.team_a : f.team_h)} ({f.is_home ? 'H' : 'A'})</th><td><span className={`fpl-difficulty difficulty-${f.difficulty}`}>{f.difficulty ?? '—'} / 5</span></td></tr>)}</tbody></table></div>{!data.fixtures.length && <p>No upcoming fixtures published.</p>}</>}
      {tab === 'history' && <><h3>Gameweek history</h3><div className="fpl-table-scroll"><table className="fpl-table"><thead><tr><th>GW</th><th>Opponent</th><th>Pts</th><th>Mins</th><th>Goals</th><th>Assists</th><th>Bonus</th></tr></thead><tbody>{[...data.history].reverse().map(h => <tr key={h.fixture}><td>{h.round}</td><th>{teamName(data.teams, h.opponent_team)} ({h.was_home ? 'H' : 'A'})</th><td><strong>{h.total_points}</strong></td><td>{h.minutes}</td><td>{h.goals_scored}</td><td>{h.assists}</td><td>{h.bonus}</td></tr>)}</tbody></table></div>{!data.history.length && <p>No match history yet.</p>}</>}
      {tab === 'stats' && <><div className="fpl-player-metrics">{metrics.map(([label, fn]) => <Metric key={label} label={label} value={fn(p)} />)}</div><p className="fpl-muted">ICT combines influence, creativity and threat. Expected points are forecasts, not earned points.</p></>}
      {tab === 'comparison' && <><h3>Compare replacements</h3><p className="fpl-muted">Ranked by the same Top Scores recommendations used in the app. Select up to three players to compare.</p><div className="fpl-view-switch"><button aria-pressed={category === 'similar_value'} onClick={() => setCategory('similar_value')}>Similar value</button><button aria-pressed={category === 'budget'} onClick={() => setCategory('budget')}>Budget</button></div>{recommendations.loading && <p role="status">Finding replacements…</p>}{recommendations.error && <p role="alert">{recommendations.error} <button onClick={recommendations.retry}>Retry</button></p>}{recommendations.data?.stale && <p className="fpl-muted">Showing cached recommendations while they refresh.</p>}{recommendations.data && !alternatives.length && <p>No recommendations in this category.</p>}<div className="fpl-comparison-picks">{alternatives.map(candidate => <label key={candidate.id}><input type="checkbox" checked={comparison.includes(candidate.id)} disabled={comparison.length >= 3 && !comparison.includes(candidate.id)} onChange={e => setComparison(ids => e.target.checked ? [...ids, candidate.id] : ids.filter(value => value !== candidate.id))} />{candidate.web_name} <small>{money(candidate.now_cost)}</small></label>)}</div><div className="fpl-table-scroll"><table className="fpl-table"><thead><tr><th>Metric</th>{[p, ...data.alternatives.filter(candidate => comparison.includes(candidate.id))].map(candidate => <th key={candidate.id}>{candidate.web_name}</th>)}</tr></thead><tbody>{metrics.map(([label, fn]) => <tr key={label}><th>{label}</th>{[p, ...data.alternatives.filter(candidate => comparison.includes(candidate.id))].map(candidate => <td key={candidate.id}>{fn(candidate)}</td>)}</tr>)}</tbody></table></div></>}
    </>}
  </div></dialog>;
}
