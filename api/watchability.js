"use strict";

const MODEL_VERSION = "v3";

const FACTORS = Object.freeze({
  competition: { label: "Competition", weight: 0.5 },
  team_quality: { label: "Team quality", weight: 0.18 },
  competitive_balance: { label: "Competitive balance", weight: 0.12 },
  table_stakes: { label: "Table stakes", weight: 0.08 },
  form_and_attack: { label: "Form & attack", weight: 0.04 },
  stage: { label: "Match stage", weight: 0.08 },
});

function clamp(value, min = 0, max = 100) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return min;
  return Math.min(max, Math.max(min, parsed));
}

function rounded(value) {
  return Math.round(clamp(value));
}

function tierForScore(score) {
  const value = rounded(score);
  if (value >= 85) return "must_watch";
  if (value >= 70) return "highly_watchable";
  if (value >= 55) return "good_watch";
  return "moderate";
}

function qualityScore(homeElo, awayElo) {
  const ratings = [homeElo, awayElo].map(Number).filter(Number.isFinite);
  if (ratings.length === 0) return 45;
  const average = ratings.reduce((total, rating) => total + rating, 0) / ratings.length;
  return clamp((average - 1400) / 6);
}

function balanceScore(homeElo, awayElo) {
  const home = Number(homeElo);
  const away = Number(awayElo);
  if (!Number.isFinite(home) || !Number.isFinite(away)) return 55;
  return clamp(100 - Math.abs(home - away) / 4);
}

function tableStakesScore(homeStanding, awayStanding) {
  if (!homeStanding || !awayStanding) return 45;

  const homePosition = Number(homeStanding.position);
  const awayPosition = Number(awayStanding.position);
  const homePoints = Number(homeStanding.points);
  const awayPoints = Number(awayStanding.points);
  const teamCount = Math.max(
    Number(homeStanding.team_count) || 0,
    Number(awayStanding.team_count) || 0,
    homePosition,
    awayPosition
  );
  if (![homePosition, awayPosition, homePoints, awayPoints].every(Number.isFinite)) return 45;

  const pointsCloseness = clamp(100 - Math.abs(homePoints - awayPoints) * 8);
  const positionCloseness = clamp(100 - Math.abs(homePosition - awayPosition) * 12);
  let significance = 35;
  if (homePosition <= 2 && awayPosition <= 2) significance = 100;
  else if (homePosition <= 4 && awayPosition <= 4) significance = 88;
  else if (homePosition <= 6 && awayPosition <= 6) significance = 72;
  else if (
    teamCount >= 8 &&
    homePosition > teamCount - 3 &&
    awayPosition > teamCount - 3
  ) significance = 82;
  else if (homePosition <= 4 || awayPosition <= 4) significance = 62;
  else if (
    teamCount >= 8 &&
    (homePosition > teamCount - 3 || awayPosition > teamCount - 3)
  ) significance = 58;

  return clamp(significance * 0.55 + pointsCloseness * 0.25 + positionCloseness * 0.2);
}

function formAndAttackScore(homeStanding, awayStanding) {
  const rows = [homeStanding, awayStanding].filter(Boolean);
  if (rows.length === 0) return 50;

  const scores = rows.map((row) => {
    const form = Array.isArray(row.form) ? row.form.slice(-5) : [];
    const formScore = form.length > 0
      ? form.reduce((total, result) => total + (result === "W" ? 3 : result === "D" ? 1 : 0), 0) /
        (form.length * 3) * 100
      : 50;
    const played = Number(row.played);
    const goalsFor = Number(row.goals_for);
    const attackScore = Number.isFinite(played) && played > 0 && Number.isFinite(goalsFor)
      ? clamp((goalsFor / played) * 40)
      : 50;
    return formScore * 0.7 + attackScore * 0.3;
  });

  return clamp(scores.reduce((total, score) => total + score, 0) / scores.length);
}

function stageScore(stage) {
  const value = String(stage || "").toLowerCase();
  if (/\bfinal\b/.test(value) && !/semi|quarter|round/.test(value)) return 100;
  if (/semi[- ]?final/.test(value)) return 90;
  if (/quarter[- ]?final/.test(value)) return 78;
  if (/round of 16|last 16|knockout/.test(value)) return 66;
  if (/play[- ]?off|group/.test(value)) return 42;
  return 30;
}

function eplClubDrawAdjustment(input) {
  const competition = String(input.competitionName || "").trim().toLowerCase();
  if (competition !== "premier league" && competition !== "english premier league") {
    return null;
  }

  const ratings = [input.homeElo, input.awayElo].map(Number).filter(Number.isFinite);
  const drawScore = ratings.length > 0
    ? clamp((Math.max(...ratings) - 1822) * 2)
    : 50;
  return {
    score: rounded(drawScore),
    contribution: Math.round((-9 * (1 - drawScore / 100)) * 10) / 10,
  };
}

function championshipClubStatureAdjustment(input) {
  const competition = String(input.competitionName || "").trim().toLowerCase();
  if (competition !== "championship" && competition !== "english championship") {
    return null;
  }

  const homeElo = Number(input.homeElo);
  const awayElo = Number(input.awayElo);
  if (!Number.isFinite(homeElo) || !Number.isFinite(awayElo)) return null;

  const statureScore = clamp((Math.min(homeElo, awayElo) - 1550) / 1.5);
  return {
    score: rounded(statureScore),
    contribution: Math.round((14 * statureScore / 100) * 10) / 10,
  };
}

function factorDetail(key, score, input) {
  switch (key) {
    case "competition":
      return `${input.competitionName || "Competition"} carries a ${rounded(score)}/100 competition weighting.`;
    case "team_quality":
      return input.homeElo != null && input.awayElo != null
        ? "Based on both clubs’ pre-match Elo ratings."
        : "Uses a neutral baseline where a team rating is unavailable.";
    case "competitive_balance":
      return input.homeElo != null && input.awayElo != null
        ? "Closer Elo ratings indicate a more evenly matched contest."
        : "Uses a neutral baseline where both ratings are not available.";
    case "table_stakes":
      return input.homeStanding && input.awayStanding
        ? "Reflects league position, points proximity and title or relegation pressure."
        : "Uses a neutral baseline where a current table is unavailable.";
    case "form_and_attack":
      return input.homeStanding && input.awayStanding
        ? "Uses recent form and goals scored per match."
        : "Uses a neutral baseline where recent form is unavailable.";
    case "stage":
      return "Later knockout rounds and finals receive a larger boost.";
    default:
      return "";
  }
}

function calculateWatchability(input = {}) {
  const factorScores = {
    competition: clamp(input.competitionWeight),
    team_quality: qualityScore(input.homeElo, input.awayElo),
    competitive_balance: balanceScore(input.homeElo, input.awayElo),
    table_stakes: tableStakesScore(input.homeStanding, input.awayStanding),
    form_and_attack: formAndAttackScore(input.homeStanding, input.awayStanding),
    stage: stageScore(input.stage),
  };

  const components = Object.entries(FACTORS).map(([key, definition]) => {
    const score = rounded(factorScores[key]);
    const contribution = Math.round(score * definition.weight * 10) / 10;
    return {
      key,
      label: definition.label,
      score,
      weight: Math.round(definition.weight * 100),
      contribution,
      detail: factorDetail(key, score, input),
    };
  });

  const clubDrawAdjustment = eplClubDrawAdjustment(input);
  if (clubDrawAdjustment) {
    components.push({
      key: "club_draw",
      label: "Club draw",
      score: clubDrawAdjustment.score,
      weight: 0,
      contribution: clubDrawAdjustment.contribution,
      detail: "Adjusts the Premier League baseline using the highest pre-match club Elo in the fixture.",
    });
  }

  const clubStatureAdjustment = championshipClubStatureAdjustment(input);
  if (clubStatureAdjustment) {
    components.push({
      key: "club_stature",
      label: "Club stature",
      score: clubStatureAdjustment.score,
      weight: 0,
      contribution: clubStatureAdjustment.contribution,
      detail: "Recognises high-profile Championship fixtures where both clubs have strong pre-match Elo ratings.",
    });
  }

  const weightedScore = components.reduce((total, component) => total + component.contribution, 0);
  const tableStakes = factorScores.table_stakes;
  const baseRivalryBonus = 15 + clamp(tableStakes) * 0.07;
  const rivalryBonus = input.rivalryName
    ? Math.round(Math.max(baseRivalryBonus, 85 - weightedScore) * 10) / 10
    : 0;
  if (input.rivalryName) {
    components.push({
      key: "rivalry",
      label: "Rivalry",
      score: 100,
      weight: 0,
      contribution: rivalryBonus,
      detail: `${input.rivalryName} adds a marquee-rivalry boost; high table stakes increase it further.`,
    });
  }

  const score = rounded(weightedScore + rivalryBonus);
  const availableSignals = [
    input.homeElo != null && input.awayElo != null,
    input.homeStanding != null && input.awayStanding != null,
    Boolean(String(input.stage || "").trim()),
  ].filter(Boolean).length;
  const confidence = Math.round((0.64 + availableSignals * 0.1) * 100) / 100;

  return {
    score,
    tier: tierForScore(score),
    stars: Math.max(0, Math.min(5, Math.round(score / 20))),
    confidence: Math.min(0.94, confidence),
    model_version: MODEL_VERSION,
    components,
  };
}

module.exports = {
  MODEL_VERSION,
  calculateWatchability,
  tierForScore,
  qualityScore,
  balanceScore,
  tableStakesScore,
  formAndAttackScore,
  stageScore,
  eplClubDrawAdjustment,
  championshipClubStatureAdjustment,
};
