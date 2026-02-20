#!/usr/bin/env node
const data = require('./bbc_scores_fixtures_matches.json');

const match = data.find(m =>
  m.details_url &&
  m.home_score !== undefined &&
  (!m.home_goal_scorers || m.home_goal_scorers.length === 0)
);

if (match) {
  const url = new URL(match.details_url);
  const parts = url.pathname.split('/');
  const matchId = parts[parts.length - 1];
  console.log(JSON.stringify({
    matchId,
    details_url: match.details_url,
    home_team: match.home_team,
    away_team: match.away_team,
    score: `${match.home_score}-${match.away_score}`,
    date: match.date,
    has_scorers: !!match.home_goal_scorers?.length
  }, null, 2));
} else {
  console.log('No match found that needs enrichment');
}
