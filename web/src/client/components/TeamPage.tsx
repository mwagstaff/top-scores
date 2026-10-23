import { lazy, Suspense, useEffect, useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { loadTeam, cachedTeam, watchTeam, teamNameKey, type TeamData } from '../teamData';
import { competitionPath, dateLabel } from '../football';
import { FixtureRow, TeamCrest } from './FixtureRow';
import { StadiumBackdrop } from './StadiumBackdrop';
import { PageMeta } from './PageMeta';
import type { Match, LeagueTable } from '../types';
const PlayerDialog = lazy(() => import('./MatchCard').then(module => ({ default: module.PlayerDetailsDialog })));
function Form({ values }: { values: string[] }) {
  return <span className="team-form" aria-label={`Recent form: ${values.join(', ')}`}>{values.slice(-5).map((value, index) => <span className={`form-${value.toLowerCase()}`} key={index}>{value}</span>)}</span>;
}
function TeamMatches({ title, matches, results = false, tables, loading }: { loading?: boolean; title: string; matches: Match[]; results?: boolean; tables: LeagueTable[] }) {
  const [expanded, setExpanded] = useState(false);
  return <section className="team-section"><h2>{title}</h2>{!matches.length && <p>{loading ? `Loading ${title.toLowerCase()}…` : `No ${title.toLowerCase()} available.`}</p>}{(expanded ? matches : matches.slice(0, 5)).map(match => <div key={match.id}><div className="team-fixture-meta"><span>{dateLabel(match.date)}</span><Link to={competitionPath(match.league)}>{match.league}</Link></div><div className="team-match-form">{[match.homeTeam, match.awayTeam].map(team => { const league = tables.find(table => table.leagueName === match.league); const row = [...(league?.rows || []), ...(league?.groups.flatMap(group => group.rows) || [])].find(row => teamNameKey(row.team) === teamNameKey(team)); return <span key={team}>{row && <><span>{row.position} · </span><Form values={row.form} /></>}</span>; })}</div><FixtureRow match={match} showBroadcast={!results} /></div>)}{matches.length > 5 && <button className="load-more" onClick={() => setExpanded(!expanded)}>{expanded ? 'Show fewer' : `View all (${matches.length})`}</button>}</section>;
}
export default function TeamPage() {
  const { name = '' } = useParams();
  const [params] = useSearchParams();
  const id = params.get('id') || undefined;
  const competition = params.get('competition');
  const [data, setData] = useState<TeamData>(() => cachedTeam(name, id) || { names: [name], fixtures: [], results: [], players: [], errors: [], pending: ['Current season', 'Upcoming fixtures', 'Previous matches', 'Players', 'Manager'] });
  const [revision, setRevision] = useState(0);
  const [sort, setSort] = useState('value');
  const [player, setPlayer] = useState<{ id: string; name: string }>();
  useEffect(() => { const stop = watchTeam(name, id, setData); void loadTeam(name, id, revision > 0); return stop; }, [name, id, revision]);
  const names = (data?.names || [name]).map(teamNameKey);
  const standings = (data?.tables?.leagues || []).flatMap(league => {
    const row = [...league.rows, ...league.groups.flatMap(group => group.rows)].find(row => names.includes(teamNameKey(row.team)) || Boolean(data?.id && row.id === data.id));
    return row ? [{ league, row }] : [];
  }).sort((a, b) => Number(b.league.leagueName === competition) - Number(a.league.leagueName === competition));
  const players = [...(data?.players || [])].sort((a, b) => sort === 'name' ? a.name.localeCompare(b.name) : sort === 'number' ? (a.jersey_number || 999) - (b.jersey_number || 999) : (b.market_value_gbp || 0) - (a.market_value_gbp || 0));
  const manager = data?.manager;
  return <article className="team-page">
    <PageMeta title={`${name} · Team details`} description={`${name} season statistics, form, fixtures, results, players and manager.`} />
    <div className="breadcrumbs"><Link to="/">← Football</Link></div>
    <header className="team-hero"><StadiumBackdrop teamName={name} teamId={id} /><TeamCrest name={name} large /><h1>{name}</h1>{competition && <Link to={competitionPath(competition)}>{competition}</Link>}</header>
    {!data ? <p role="status">Loading team details…</p> : <>
      {data.errors.length > 0 && <div className="refresh-notice">Unable to load: {data.errors.join(', ')}. <button onClick={() => setRevision(value => value + 1)}>Retry</button></div>}
      <section className="team-section"><h2>Current season</h2>{!standings.length && <p role={data.pending?.includes('Current season') ? 'status' : undefined}>{data.pending?.includes('Current season') ? 'Loading season statistics…' : 'No current standings available.'}</p>}{standings.map(({ league, row }) => <section className="team-season" key={league.id}><div className="team-section-heading"><h3>{league.leagueName}</h3><Link to={`${competitionPath(league.leagueName)}?section=table`}>View table →</Link></div><dl className="team-stats">{[['Position', row.position], ['Played', row.played], ['Won', row.won], ['Drawn', row.drawn], ['Lost', row.lost], ['Goals for', row.goalsFor], ['Goals against', row.goalsAgainst], ['Goal difference', row.goalDifference], ['Points', row.points]].map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl><div className="team-section-heading"><span>Recent form</span><Form values={row.form} /></div></section>)}</section>
      <TeamMatches key={`${name}-fixtures`} title="Upcoming fixtures" loading={data.pending?.includes('Upcoming fixtures')} matches={data.fixtures} tables={data.tables?.leagues || []} />
      <TeamMatches key={`${name}-results`} title="Previous matches" loading={data.pending?.includes('Previous matches')} matches={data.results} tables={data.tables?.leagues || []} results />
      <section className="team-section"><div className="team-section-heading"><h2>Players</h2><select aria-label="Sort players" value={sort} onChange={event => setSort(event.target.value)}><option value="value">Value</option><option value="name">Name</option><option value="number">Shirt number</option></select></div>{!players.length && <p>{data.pending?.includes('Players') ? 'Loading players…' : 'No squad information available.'}</p>}<ul className="team-squad">{players.map(entry => <li key={entry.id}><button onClick={() => setPlayer(entry)}><span>{entry.jersey_number ?? '–'}</span>{(entry.fpl_profile_url || entry.cutout_url) && <img src={entry.fpl_profile_url || entry.cutout_url} width="44" height="52" alt="" loading="lazy" />}<span><strong>{entry.name}</strong><small>{[entry.nationality, entry.specific_position || entry.position].filter(Boolean).join(' · ')}</small></span>{entry.availability && entry.availability !== 'available' && <span title={entry.injury_type || entry.availability} aria-label={entry.injury_type || entry.availability}>⚠</span>}<span>{entry.market_value_gbp != null ? new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP', notation: 'compact', maximumFractionDigits: 1 }).format(entry.market_value_gbp) : '–'}</span><span aria-hidden="true">›</span></button></li>)}</ul></section>
      <section className="team-section"><h2>Manager</h2>{manager ? <div className="team-season"><div className="team-section-heading">{manager.image_url && <img src={manager.image_url} width="64" height="64" alt="" loading="lazy" />}<h3>{manager.name}</h3><span>{manager.country}</span></div><p>{[manager.preferred_formation, manager.tactical_profile].filter(Boolean).join(' · ')}</p><dl className="team-stats">{[['Matches', manager.matches_total], ['Wins', manager.wins], ['Draws', manager.draws], ['Losses', manager.losses], ['Win rate', manager.win_pct == null ? '–' : `${manager.win_pct}%`]].map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value ?? '–'}</dd></div>)}</dl><ManagerCareer id={manager.id} /></div> : <p>{data.pending?.includes('Manager') ? 'Loading manager…' : 'No manager information available.'}</p>}</section>
    </>}
    {player && <Suspense fallback={<p role="status">Loading player…</p>}><PlayerDialog player={{ name: player.name, idPlayer: player.id, number: 0 }} onClose={() => setPlayer(undefined)} /></Suspense>}
  </article>;
}

function ManagerCareer({ id }: { id: string }) {
  const [open, setOpen] = useState(false);
  const [career, setCareer] = useState<{ team_name: string; date_from: string; date_to?: string; matches: number; wins: number; draws: number; losses: number; win_pct: number }[]>();
  const [error, setError] = useState(false);
  useEffect(() => {
    if (!open || career) return;
    const controller = new AbortController();
    fetch(`/api/v1/managers/${encodeURIComponent(id)}/career`, { signal: AbortSignal.any([controller.signal, AbortSignal.timeout(15000)]) }).then(async response => { if (!response.ok) throw new Error(); setCareer((await response.json()).tenures || []); }).catch(() => { if (!controller.signal.aborted) setError(true); });
    return () => controller.abort();
  }, [id, open, career]);
  return <><button className="load-more" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? 'Hide career' : 'Manager career'}</button>{open && (error ? <p>Career information unavailable.</p> : !career ? <p role="status">Loading career…</p> : career.map((tenure, index) => <div className="team-career" key={index}><strong>{tenure.team_name}</strong><p>{tenure.date_from} – {tenure.date_to || 'Present'}</p><p>{tenure.matches} matches · {tenure.wins} wins · {tenure.draws} draws · {tenure.losses} losses · {tenure.win_pct}% win rate</p></div>))}</>;
}
