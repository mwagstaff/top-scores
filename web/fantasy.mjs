import scoring from './server-shared/fantasy_public_score.cjs';

export function createFantasyService(fetcher = fetch) {
  const cache = new Map(), pending = new Map();
  // Bounded public cache. Never forward browser cookies or accept arbitrary URLs.
  async function get(path, ttl = 30_000) {
    const cached = cache.get(path);
    if (cached && Date.now() - cached.time < ttl) return cached.value;
    if (pending.has(path)) return pending.get(path);
    const work = (async () => {
      let response;
      for (let attempt = 0; attempt < 3; attempt++) {
        response = await fetcher(`https://fantasy.premierleague.com/api/${path}`, { signal: AbortSignal.timeout(10_000), headers: { Accept: 'application/json' } });
        if (response.status !== 429 && response.status < 500) break;
        if (attempt < 2) {
          await response.body?.cancel();
          await new Promise(resolve => setTimeout(resolve, 500 * 2 ** attempt));
        }
      }
      if (!response.ok) {
        const error = new Error(response.status === 404 ? 'No published FPL data was found for this selection.' : 'FPL is temporarily unavailable. Please retry shortly.');
        error.status = response.status === 404 ? 404 : 503;
        throw error;
      }
      let value;
      try { value = await response.json(); } catch { throw new Error('FPL is updating. Please retry shortly.'); }
      if (!value || typeof value !== 'object') throw new Error('FPL is updating. Please retry shortly.');
      cache.delete(path); cache.set(path, { value, time: Date.now() });
      while (cache.size > 160) cache.delete(cache.keys().next().value);
      return value;
    })().finally(() => pending.delete(path));
    pending.set(path, work);
    return work;
  }
  return {
    get,
    async squad(entry, requestedEvent) {
      const [bootstrap, profile] = await Promise.all([get('bootstrap-static/', 300_000), get(`entry/${entry}/`, 60_000)]);
      const published = bootstrap.events.filter(e => Date.parse(e.deadline_time) <= Date.now());
      const event = requestedEvent ? published.find(e => e.id === requestedEvent) : published.at(-1);
      if (!event) { const error = new Error('Picks are not published for this gameweek yet.'); error.status = 404; throw error; }
      const [picks, live, fixtures] = await Promise.all([
        get(`entry/${entry}/event/${event.id}/picks/`), get(`event/${event.id}/live/`), get(`fixtures/?event=${event.id}`),
      ]);
      // A failed component never publishes a partial score/status snapshot.
      const compactEvent = ({ id, name, deadline_time, data_checked, average_entry_score, highest_score }) => ({ id, name, deadline_time, data_checked, average_entry_score, highest_score });
      const { id, name, player_first_name, player_last_name, summary_overall_points, summary_overall_rank, club_badge_src } = profile;
      return { profile: { id, name, player_first_name, player_last_name, summary_overall_points, summary_overall_rank, club_badge_src,
          leagues: { classic: (profile.leagues?.classic || []).map(({ id, name, entry_rank, entry_last_rank, league_type }) => ({ id, name, entry_rank, entry_last_rank, league_type })) } },
        nextDeadline: bootstrap.events.find(e => Date.parse(e.deadline_time) > Date.now())?.deadline_time || null,
        event: compactEvent(event), events: published.map(compactEvent), teams: bootstrap.teams.map(({ id, name, short_name }) => ({ id, name, short_name })), totalPlayers: bootstrap.total_players,
        ...scoring.scorePublicSquad({ bootstrap, picks, live, fixtures, event }),
        nextExpectedPoints: event.id === published.at(-1)?.id ? picks.picks.filter(p => p.position <= 11).reduce((sum, pick) => {
          const player = bootstrap.elements.find(p => p.id === pick.element);
          return sum + Number(player?.ep_next || 0) * (pick.is_captain ? 2 : 1);
        }, 0) : null,
        history: picks.entry_history, updatedAt: new Date().toISOString() };
    },
    async player(id) {
      const [bootstrap, summary] = await Promise.all([get('bootstrap-static/', 300_000), get(`element-summary/${id}/`, 60_000)]);
      const player = bootstrap.elements.find(p => p.id === id);
      if (!player) { const error = new Error('Player not found.'); error.status = 404; throw error; }
      const alternatives = bootstrap.elements.filter(p => p.element_type === player.element_type && p.id !== id).map(scoring.publicPlayer);
      return { player: scoring.publicPlayer(player), ...summary, teams: bootstrap.teams.map(({ id, name, short_name }) => ({ id, name, short_name })), alternatives };
    },
  };
}

export function registerFantasy(app) {
  const service = createFantasyService();
  const positive = value => /^\d{1,9}$/.test(String(value || '')) && Number(value) > 0;
  const route = (pattern, work) => app.get(pattern, async (req, res) => {
    if (Object.values(req.params).some(value => !positive(value)) ||
        ['event', 'page'].some(key => req.query[key] !== undefined && !positive(req.query[key]))) {
      res.status(400).json({ error: 'Enter a valid FPL ID or gameweek.' }); return;
    }
    try { res.set('Cache-Control', 'no-store').json(await work(req)); }
    catch (error) { res.status(error.status || 503).json({ error: error.message || 'FPL is temporarily unavailable.' }); }
  });
  route('/api/fpl/entry/:id', req => service.squad(Number(req.params.id), Number(req.query.event) || undefined));
  route('/api/fpl/profile/:id', req => service.get(`entry/${req.params.id}/`, 60_000));
  route('/api/fpl/league/:id', req => service.get(`leagues-classic/${req.params.id}/standings/?page_standings=${Number(req.query.page) || 1}`, 60_000));
  route('/api/fpl/player/:id', req => service.player(Number(req.params.id)));
  return service;
}
