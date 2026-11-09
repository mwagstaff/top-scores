// Public picks adapter. Pure, request-scoped scoring for web and API consumers.
// Final gameweeks use FPL's settled multipliers; live weeks project substitutions.
const PUBLIC_PLAYER_FIELDS = ['id', 'web_name', 'first_name', 'second_name', 'team', 'element_type', 'code', 'now_cost', 'form', 'selected_by_percent', 'points_per_game', 'total_points', 'minutes', 'starts', 'ep_next', 'news', 'status', 'ict_index', 'goals_scored', 'assists', 'clean_sheets', 'bonus', 'expected_goals', 'expected_assists'];
function publicPlayer(player) {
  return Object.fromEntries(PUBLIC_PLAYER_FIELDS.map(key => [key, player[key]]));
}
function scorePublicSquad({ bootstrap, picks, live, fixtures, event }) {
  const elements = new Map(bootstrap.elements.map(player => [player.id, player]));
  const stats = new Map(live.elements.map(player => [player.id, player.stats]));
  const finalized = event.data_checked === true;
  const benchBoost = picks.active_chip === 'bboost';
  const captainMultiplier = picks.active_chip === '3xc' ? 3 : 2;
  const players = picks.picks.map(pick => {
    const player = elements.get(pick.element);
    if (!player) throw new Error('A squad player is missing from the FPL catalogue.');
    const playerFixtures = fixtures.filter(f => f.team_h === player.team || f.team_a === player.team);
    const playerStats = stats.get(player.id) || {};
    const participated = playerStats.minutes > 0 || playerStats.yellow_cards > 0 || playerStats.red_cards > 0;
    return {
      ...publicPlayer(player), participated, pickPosition: pick.position, isCaptain: pick.is_captain,
      isViceCaptain: pick.is_vice_captain, stats: playerStats,
      rawPoints: playerStats.total_points || 0,
      multiplier: finalized ? pick.multiplier : pick.position <= 11 ? (pick.is_captain ? captainMultiplier : 1) : benchBoost ? 1 : 0,
      fixtures: playerFixtures,
      started: playerFixtures.some(f => f.started),
      inPlay: playerFixtures.some(f => f.started && !f.finished && !f.finished_provisional),
      // In a double gameweek, retain the player until every fixture is settled.
      absent: stats.has(player.id) && !participated && playerFixtures.every(f => f.finished || f.finished_provisional),
    };
  }).sort((a, b) => a.pickPosition - b.pickPosition);
  const substitutions = [];
  const notes = [];
  if (finalized) {
    for (const substitution of picks.automatic_subs || []) {
      substitutions.push({ incoming: substitution.element_in, outgoing: substitution.element_out, confirmed: true });
    }
  } else if (!benchBoost) {
    const starters = players.filter(p => p.pickPosition <= 11);
    const missing = starters.filter(p => p.absent);
    const counts = Object.fromEntries([1, 2, 3, 4].map(type => [type, starters.filter(p => p.element_type === type).length]));
    for (const substitute of players.filter(p => p.pickPosition > 11 && p.participated)) {
      const index = missing.findIndex(out => {
        if (substitute.element_type === 1 || out.element_type === 1) return substitute.element_type === out.element_type;
        const next = { ...counts };
        next[out.element_type]--; next[substitute.element_type]++;
        return next[2] >= 3 && next[3] >= 2 && next[4] >= 1;
      });
      if (index < 0) continue;
      const [out] = missing.splice(index, 1);
      counts[out.element_type]--; counts[substitute.element_type]++;
      out.multiplier = 0; substitute.multiplier = 1;
      substitutions.push({ incoming: substitute.id, outgoing: out.id, confirmed: false });
    }
  }
  if (!finalized) {
    const captain = players.find(p => p.isCaptain);
    const vice = players.find(p => p.isViceCaptain);
    if (captain?.absent && vice && vice.multiplier > 0 && vice.participated) {
      captain.multiplier = 0; vice.multiplier = captainMultiplier;
      notes.push(`${vice.web_name} takes the captain multiplier (×${captainMultiplier}).`);
    }
  }
  if (benchBoost) notes.push('Bench Boost: all bench points count.');
  for (const sub of substitutions) {
    const incoming = players.find(p => p.id === sub.incoming), outgoing = players.find(p => p.id === sub.outgoing);
    notes.push(`${incoming?.web_name || sub.incoming} replaces ${outgoing?.web_name || sub.outgoing}${sub.confirmed ? '' : ' (provisional)'}.`);
  }
  const grossPoints = players.reduce((sum, p) => sum + p.rawPoints * p.multiplier, 0);
  const transferCost = picks.entry_history?.event_transfers_cost || 0;
  return { players, substitutions, notes, grossPoints, transferCost, points: grossPoints - transferCost, finalized, chip: picks.active_chip || null };
}

module.exports = { scorePublicSquad, publicPlayer };
