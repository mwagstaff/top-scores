"use strict";

const crypto = require("crypto");
const express = require("express");
const { getDb } = require("./mongo_client");
const { zonedDateTimeToUtcMs } = require("./match_time");
const { generateSimulationSeasonFromFixtures, realisticResults, resultRevision } = require("./goal_guesser_simulation");
const { MAX_UPLOAD_BYTES, TeamLogoStorageError, normalizeTeamLogo, createTeamLogoStorage } = require("./goal_guesser_images");

const PREFIX = "/api/v1/goal-guesser";
const PREMIER_LEAGUE = "Premier League";
const GAME_TYPE = "score-picks";
const SCORING_VERSION = 1;
const GAMEPLAY_RULES_VERSION = 3;
const CARD_TYPES = new Set(["exacta", "triple_threat", "wildcard", "all_or_nothing"]);
const MAX_MEMBERS = 50;
const MAX_SCORE = 20;
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const TERMINAL_STATUSES = new Set(["ft", "full time", "finished", "aet", "pens"]);
const EMAIL_CODE_TTL_MS = 10 * 60 * 1000;
const DEFAULT_ADMIN_EMAIL = "mike.wagstaff@gmail.com";
const OIDC_PROVIDERS = {
  google: {
    issuers: new Set(["accounts.google.com", "https://accounts.google.com"]),
    jwks: "https://www.googleapis.com/oauth2/v3/certs",
    audiencesEnv: "GOAL_GUESSER_GOOGLE_CLIENT_IDS",
  },
  apple: {
    issuers: new Set(["https://appleid.apple.com"]),
    jwks: "https://appleid.apple.com/auth/keys",
    audiencesEnv: "GOAL_GUESSER_APPLE_CLIENT_IDS",
  },
};

const metrics = {
  fixture_sync_runs: 0,
  fixture_sync_failures: 0,
  non_premier_league_rejected: 0,
  picks_saved: 0,
  picks_locked: 0,
  picks_invalid: 0,
  recovery_failures: 0,
  email_login_failures: 0,
  oauth_login_failures: 0,
  join_failures: 0,
  results_settled: 0,
  results_rescored: 0,
  team_logo_uploads: 0,
  team_logo_rejections: 0,
  team_logo_storage_failures: 0,
  team_logo_moderation_emails: 0,
  team_logo_moderation_email_failures: 0,
};

const rateBuckets = new Map();
let lastFixtureSyncAtMs = 0;
let fixtureSyncPromise = null;
let goalGuesserTestNowMs = null;
const jwksCache = new Map();
let configuredAdminEmails = new Set([DEFAULT_ADMIN_EMAIL]);
let teamLogoNotificationTimer = null;

function currentTimeMs() {
  return Number.isFinite(goalGuesserTestNowMs) ? goalGuesserTestNowMs : Date.now();
}

function setGoalGuesserTestNow(value) {
  if (process.env.NODE_ENV !== "test") throw new Error("Goal Guesser virtual time is available only in NODE_ENV=test");
  if (value == null) {
    goalGuesserTestNowMs = null;
    return;
  }
  const parsed = typeof value === "number" ? value : Date.parse(String(value));
  if (!Number.isFinite(parsed)) throw new Error("Invalid Goal Guesser test time");
  goalGuesserTestNowMs = parsed;
}

function normalizeText(value) {
  return String(value || "").trim().replace(/\s+/g, " ");
}

function normalizeName(value) {
  const name = normalizeText(value);
  if (name.length < 1 || name.length > 32) return null;
  return name;
}

function normalizeTeamName(value) {
  const name = normalizeText(value);
  if (name.length < 1 || name.length > 40) return null;
  return name;
}

function normalizeEmail(value) {
  const email = normalizeText(value).toLowerCase();
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  return email;
}

function csvEnvironment(name) {
  const fallback = name === "GOAL_GUESSER_GOOGLE_CLIENT_IDS" ? process.env.GOOGLE_CLIENT_ID_WEBSITE_GOAL_GUESSER : "";
  return String(process.env[name] || fallback || "").split(",").map(normalizeText).filter(Boolean);
}

function configureAdminEmails(value) {
  const emails = String(value == null ? DEFAULT_ADMIN_EMAIL : value)
    .split(",")
    .map(normalizeEmail)
    .filter(Boolean);
  configuredAdminEmails = new Set(emails);
}

function isAdminPlayer(player) {
  return player?.email_verified === true && configuredAdminEmails.has(normalizeEmail(player.email));
}

function liveFixtureQuery(extra = {}) {
  return { competition: PREMIER_LEAGUE, simulation_id: { $exists: false }, ...extra };
}

function fixtureScopeQuery(simulationId, extra = {}) {
  return simulationId
    ? { competition: PREMIER_LEAGUE, simulation_id: simulationId, ...extra }
    : liveFixtureQuery(extra);
}

function decodeJwtPart(value) {
  return JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
}

async function providerClaims(provider, idToken) {
  const config = OIDC_PROVIDERS[provider];
  const audiences = config ? csvEnvironment(config.audiencesEnv) : [];
  if (!config || !audiences.length) throw new Error(`${provider} sign-in is not configured`);
  const parts = String(idToken || "").split(".");
  if (parts.length !== 3) throw new Error("Identity token is invalid");
  const header = decodeJwtPart(parts[0]);
  const payload = decodeJwtPart(parts[1]);
  const tokenAudiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (header.alg !== "RS256" || !header.kid || !config.issuers.has(payload.iss) || !tokenAudiences.some((value) => audiences.includes(value))) {
    throw new Error("Identity token is invalid");
  }
  const nowSeconds = Math.floor(currentTimeMs() / 1000);
  if (!payload.sub || !Number.isFinite(Number(payload.exp)) || Number(payload.exp) <= nowSeconds || Number(payload.iat || 0) > nowSeconds + 60) {
    throw new Error("Identity token has expired");
  }
  let cached = jwksCache.get(config.jwks);
  if (!cached || cached.expiresAt <= currentTimeMs()) {
    const response = await fetch(config.jwks, { signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw new Error("Identity provider is unavailable");
    cached = { keys: (await response.json()).keys || [], expiresAt: currentTimeMs() + 6 * 60 * 60 * 1000 };
    jwksCache.set(config.jwks, cached);
  }
  const jwk = cached.keys.find((value) => value.kid === header.kid && value.kty === "RSA");
  if (!jwk) throw new Error("Identity signing key was not found");
  const valid = crypto.verify("RSA-SHA256", Buffer.from(`${parts[0]}.${parts[1]}`), crypto.createPublicKey({ key: jwk, format: "jwk" }), Buffer.from(parts[2], "base64url"));
  if (!valid) throw new Error("Identity token signature is invalid");
  return payload;
}

function normalizeLeagueName(value) {
  const name = normalizeText(value);
  if (name.length < 1 || name.length > 40) return null;
  return name;
}

function randomCrockford(length) {
  const bytes = crypto.randomBytes(length);
  let value = "";
  for (let index = 0; index < length; index += 1) {
    value += CROCKFORD[bytes[index] % CROCKFORD.length];
  }
  return value;
}

function randomSecret() {
  return crypto.randomBytes(32).toString("base64url");
}

function secretDigest(secret, salt = crypto.randomBytes(16).toString("base64url")) {
  return {
    salt,
    digest: crypto.scryptSync(String(secret), salt, 32).toString("base64url"),
  };
}

function secretMatches(secret, stored) {
  if (!stored || !stored.salt || !stored.digest) return false;
  const candidate = secretDigest(secret, stored.salt).digest;
  const left = Buffer.from(candidate, "base64url");
  const right = Buffer.from(stored.digest, "base64url");
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function scoreOutcome(home, away) {
  if (home === away) return "draw";
  return home > away ? "home" : "away";
}

function scorePrediction(predictedHome, predictedAway, actualHome, actualAway, powerPick = false) {
  const values = [predictedHome, predictedAway, actualHome, actualAway].map(Number);
  if (!values.every(Number.isInteger)) return { points: 0, tier: "unsettled" };
  const [ph, pa, ah, aa] = values;
  let points = 0;
  let tier = "none";
  if (ph === ah && pa === aa) {
    points = 12;
    tier = "exact";
  } else if (scoreOutcome(ph, pa) === scoreOutcome(ah, aa) && (ph === ah || pa === aa)) {
    points = 5;
    tier = "result_and_team_score";
  } else if (scoreOutcome(ph, pa) === scoreOutcome(ah, aa)) {
    points = 3;
    tier = "result";
  } else if (ph === ah || pa === aa) {
    points = 1;
    tier = "team_score";
  }
  return { points: powerPick ? points * 2 : points, tier };
}

function integerScore(value) {
  if (value == null || normalizeText(value) === "") return null;
  const score = Number(value);
  return Number.isInteger(score) && score >= 0 ? score : null;
}

function isPremierLeagueMatch(match) {
  return normalizeText(match?.league) === PREMIER_LEAGUE;
}

function rankLeaderboard(rows) {
  const ranked = [...rows].sort((left, right) => right.points - left.points || right.exact_scores - left.exact_scores || right.correct_results - left.correct_results || left.name.localeCompare(right.name));
  let previous = null;
  ranked.forEach((row, index) => {
    const signature = `${row.points}|${row.exact_scores}|${row.correct_results}`;
    row.position = previous && previous.signature === signature ? previous.position : index + 1;
    previous = { signature, position: row.position };
  });
  return ranked;
}

function median(values) {
  const sorted = values.filter(Number.isFinite).sort((left, right) => left - right);
  if (!sorted.length) return 0;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function basePointsForPick(pick) {
  if (Number.isInteger(pick?.base_points)) return pick.base_points;
  if (!Number.isInteger(pick?.points)) return 0;
  return pick.power_pick === true ? Math.floor(pick.points / 2) : pick.points;
}

function cardPointsForPick(pick, card) {
  const base = basePointsForPick(pick);
  if (!card || !CARD_TYPES.has(card.type)) return Number(pick?.points || 0);
  if (card.type === "triple_threat") return base * 3;
  if (card.type === "wildcard") return base * 2;
  if (card.type === "exacta") return pick.score_tier === "exact" ? base + 10 : base;
  if (card.type === "all_or_nothing") return pick.score_tier === "exact" ? 24 : 0;
  return Number(pick?.points || 0);
}

function monthlyChampionships(fixtures) {
  const months = new Map();
  for (const fixture of fixtures || []) {
    const date = new Date(fixture.kickoff_at);
    if (!Number.isFinite(date.getTime())) continue;
    const id = date.toISOString().slice(0, 7);
    const value = months.get(id) || { id, fixtures: [], weeks: new Set() };
    value.fixtures.push(fixture);
    if (fixture.pick_week_id) value.weeks.add(fixture.pick_week_id);
    months.set(id, value);
  }
  return [...months.values()].sort((left, right) => left.id.localeCompare(right.id)).map((month, index) => {
    const starts = month.fixtures.map((fixture) => Date.parse(fixture.kickoff_at)).filter(Number.isFinite);
    const first = Math.min(...starts);
    const end = new Date(first);
    end.setUTCMonth(end.getUTCMonth() + 1, 1);
    end.setUTCHours(0, 0, 0, 0);
    const weeks = [...month.weeks].sort();
    return {
      id: `month-${month.id}`,
      index: index + 1,
      label: new Intl.DateTimeFormat("en-GB", { month: "long", year: "numeric", timeZone: "UTC" }).format(new Date(`${month.id}-01T12:00:00Z`)),
      start_week_id: weeks[0] || null,
      end_week_id: weeks.at(-1) || null,
      weeks,
      expires_at: end.toISOString(),
    };
  });
}

function completedWeeks(fixtures) {
  const values = new Map();
  for (const fixture of fixtures || []) {
    const week = normalizeText(fixture.pick_week_id);
    if (!week) continue;
    const entry = values.get(week) || { week, fixtures: [] };
    entry.fixtures.push(fixture);
    values.set(week, entry);
  }
  return [...values.values()].filter((entry) => entry.fixtures.length > 0 && entry.fixtures.every((fixture) => fixture.result_revision)).map((entry) => entry.week).sort();
}

function weeklyScores(membership, picks, fixtureById) {
  const scores = new Map();
  for (const pick of picks) {
    if (pick.player_id !== membership.player_id) continue;
    const fixture = fixtureById.get(pick.fixture_id);
    if (!fixture || Date.parse(fixture.kickoff_at) < Date.parse(membership.scoring_from || 0)) continue;
    scores.set(fixture.pick_week_id, (scores.get(fixture.pick_week_id) || 0) + Number(pick.points || 0));
  }
  return scores;
}

function momentumForMembership(membership, picks, fixtureById, settledWeeks) {
  const scores = weeklyScores(membership, picks, fixtureById);
  const values = settledWeeks.map((week) => ({ week, points: scores.get(week) || 0 }));
  if (values.length < 6) return { player_id: membership.player_id, baseline: null, latest: values.at(-1)?.points ?? null, streak: 0, eligible: false };
  const recent = values.slice(-2);
  const baseline = values.slice(-6, -2).reduce((sum, item) => sum + item.points, 0) / 4;
  const streak = recent.filter((item) => item.points > baseline).length;
  return { player_id: membership.player_id, baseline: Number(baseline.toFixed(1)), latest: recent.at(-1)?.points ?? null, streak, eligible: streak === 2 };
}

function gameplayRows({ memberships, names, teamNames = new Map(), logos = new Map(), picks, fixtureById, cards = [] }) {
  const cardsByPick = new Map(cards.filter((card) => card.status === "played" && card.target_fixture_id).map((card) => [`${card.player_id}:${card.target_fixture_id}`, card]));
  return rankLeaderboard(memberships.map((membership) => {
    const eligible = picks.filter((pick) => {
      const fixture = fixtureById.get(pick.fixture_id);
      return pick.player_id === membership.player_id && fixture && Date.parse(fixture.kickoff_at) >= Date.parse(membership.scoring_from || 0);
    });
    return {
      player_id: membership.player_id,
      name: names.get(membership.player_id) || "Former player",
      team_name: teamNames.get(membership.player_id) || null,
      team_logo: logos.get(membership.player_id) || null,
      points: eligible.reduce((sum, pick) => sum + cardPointsForPick(pick, cardsByPick.get(`${membership.player_id}:${pick.fixture_id}`)), 0),
      exact_scores: eligible.filter((pick) => pick.score_tier === "exact").length,
      correct_results: eligible.filter((pick) => ["exact", "result_and_team_score", "result"].includes(pick.score_tier)).length,
    };
  }));
}

function monthlyRows({ month, memberships, names, teamNames, logos, picks, fixtureById, cards }) {
  const monthFixtures = new Set([...fixtureById.values()].filter((fixture) => month.weeks.includes(fixture.pick_week_id)).map((fixture) => fixture._id));
  return gameplayRows({ memberships, names, teamNames, logos, fixtureById, cards, picks: picks.filter((pick) => monthFixtures.has(pick.fixture_id)) });
}

function rivalDuels(rows, weeklyPointMap, pickWeekId) {
  const duels = [];
  for (let index = 0; index + 1 < rows.length; index += 2) {
    const left = rows[index]; const right = rows[index + 1];
    const leftPoints = weeklyPointMap.get(left.player_id) || 0;
    const rightPoints = weeklyPointMap.get(right.player_id) || 0;
    duels.push({ pick_week_id: pickWeekId, left: { player_id: left.player_id, name: left.name, team_logo: left.team_logo || null, points: leftPoints }, right: { player_id: right.player_id, name: right.name, team_logo: right.team_logo || null, points: rightPoints }, winner_player_id: leftPoints === rightPoints ? null : leftPoints > rightPoints ? left.player_id : right.player_id });
  }
  return duels;
}

function pickWeekIdForDate(dateString) {
  const match = String(dateString || "").match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) return null;
  const date = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]), 12));
  const daysSinceFriday = (date.getUTCDay() + 2) % 7;
  date.setUTCDate(date.getUTCDate() - daysSinceFriday);
  return date.toISOString().slice(0, 10);
}

function seasonKeyForDate(dateString) {
  const match = String(dateString || "").match(/^(\d{4})-(\d{2})-/);
  if (!match) return "unknown";
  const year = Number(match[1]);
  const month = Number(match[2]);
  const start = month >= 7 ? year : year - 1;
  return `${start}-${String(start + 1).slice(-2)}`;
}

function isFinalStatus(value) {
  const normalized = normalizeText(value).toLowerCase();
  return TERMINAL_STATUSES.has(normalized) || normalized.startsWith("ft ");
}

function canonicalTeamKey(value) {
  return normalizeText(value)
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "");
}

function fixtureResponse(fixture, pick = null, nowMs = currentTimeMs(), pickWeekLocked = null, card = null) {
  return {
    id: fixture._id,
    contest_id: fixture.contest_id,
    competition: fixture.competition,
    season_key: fixture.season_key,
    pick_week_id: fixture.pick_week_id,
    kickoff_at: fixture.kickoff_at,
    // A scorecard is submitted as one weekly entry: once its first fixture
    // begins, every pick in that Friday–Thursday week is locked together.
    locked: pickWeekLocked == null ? Date.parse(fixture.kickoff_at) <= nowMs : pickWeekLocked,
    home_team: fixture.home_team,
    away_team: fixture.away_team,
    home_team_id: fixture.home_team_id || null,
    away_team_id: fixture.away_team_id || null,
    status: fixture.status || null,
    home_score: Number.isInteger(fixture.home_score) ? fixture.home_score : null,
    away_score: Number.isInteger(fixture.away_score) ? fixture.away_score : null,
    settled: Boolean(fixture.result_revision),
    simulation_id: fixture.simulation_id || null,
    pick: pick
      ? {
          home_score: pick.home_score,
          away_score: pick.away_score,
          power_pick: pick.power_pick === true,
          points: Number.isInteger(pick.points) ? pick.points : null,
          awarded_points: Number.isInteger(pick.points) ? cardPointsForPick(pick, card) : null,
          base_points: Number.isInteger(pick.base_points) ? pick.base_points : null,
          score_tier: pick.score_tier || null,
          applied_card_type: card?.type || (pick.power_pick === true ? "double_down" : null),
          saved_at: pick.updated_at,
        }
      : null,
  };
}

function pickWeekLockTimes(fixtures) {
  const lockTimes = new Map();
  for (const fixture of fixtures || []) {
    const week = normalizeText(fixture && fixture.pick_week_id);
    const kickoffMs = Date.parse(fixture && fixture.kickoff_at);
    if (!week || !Number.isFinite(kickoffMs)) continue;
    const existing = lockTimes.get(week);
    if (!Number.isFinite(existing) || kickoffMs < existing) lockTimes.set(week, kickoffMs);
  }
  return lockTimes;
}

async function upcomingCanonicalSeasonFixtures(db, nowMs = currentTimeMs()) {
  const fixtures = await db.collection("gg_fixtures").find(liveFixtureQuery()).sort({ kickoff_at: 1 }).toArray();
  const lockTimes = pickWeekLockTimes(fixtures);
  const firstUpcoming = fixtures.find((fixture) => (lockTimes.get(fixture.pick_week_id) || Date.parse(fixture.kickoff_at)) > nowMs);
  if (!firstUpcoming) return [];
  const seasonFixtures = fixtures.filter((fixture) => fixture.season_key === firstUpcoming.season_key);
  const weekIds = [...new Set(seasonFixtures.map((fixture) => fixture.pick_week_id))];
  const firstWeekIndex = weekIds.indexOf(firstUpcoming.pick_week_id);
  const includedWeeks = new Set(weekIds.slice(Math.max(0, firstWeekIndex)));
  return seasonFixtures.filter((fixture) => includedWeeks.has(fixture.pick_week_id));
}

function publicPlayer(player) {
  return {
    id: player._id,
    name: player.name,
    team_name: player.team_name || null,
    team_logo: teamLogoReference(player.team_logo_asset_id),
    team_setup_completed: Boolean(player.team_setup_completed_at && player.team_name),
    email: player.email || null,
    email_verified: player.email_verified === true,
    email_notifications_enabled: player.email_notifications_enabled === true,
    auth_providers: Array.isArray(player.auth_providers) ? player.auth_providers : [],
    capabilities: { admin: isAdminPlayer(player) },
    created_at: player.created_at,
    updated_at: player.updated_at,
  };
}

function teamLogoReference(assetId) {
  const id = normalizeText(assetId);
  if (!id) return null;
  const encoded = encodeURIComponent(id);
  return {
    asset_id: id,
    thumbnail_url: `${PREFIX}/team-logos/${encoded}/content?variant=thumbnail`,
    full_url: `${PREFIX}/team-logos/${encoded}/content?variant=full`,
  };
}

function resolvedTeamLogoReference(player, membership = null) {
  return teamLogoReference(membership?.team_logo_asset_id || player?.team_logo_asset_id);
}

function publicLeagueMember(player, membership) {
  return {
    player_id: membership.player_id,
    name: player?.name || "Former player",
    team_name: player?.team_name || null,
    role: membership.role,
    joined_at: membership.joined_at,
    scoring_from: membership.scoring_from,
    team_logo: resolvedTeamLogoReference(player, membership),
    team_logo_override: Boolean(membership.team_logo_asset_id),
  };
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function retireTeamLogoAssetIfUnreferenced(db, storage, assetId) {
  if (!assetId) return;
  const [playerReference, membershipReference] = await Promise.all([
    db.collection("gg_players").findOne({ team_logo_asset_id: assetId }),
    db.collection("gg_memberships").findOne({ team_logo_asset_id: assetId }),
  ]);
  if (playerReference || membershipReference) return;
  const asset = await db.collection("gg_image_assets").findOne({ _id: assetId });
  if (!asset || asset.storage_status === "deleted") return;
  await storage.remove(asset.variants).catch((error) => {
    console.warn(JSON.stringify({ event: "goal_guesser_team_logo_cleanup_failed", asset_id: assetId, message: error.message }));
  });
  await db.collection("gg_image_assets").updateOne({ _id: assetId }, { $set: { storage_status: "deleted", retired_at: new Date().toISOString(), updated_at: new Date().toISOString() } });
}

async function deliverTeamLogoModerationEmail(db, asset) {
  const sent = new Set(asset.moderation_email_sent_to || []);
  const recipients = [...configuredAdminEmails].filter(Boolean);
  if (!recipients.length) return;
  const publicOrigin = String(process.env.GOAL_GUESSER_PUBLIC_ORIGIN || "https://goal-guesser.skynolimit.dev").replace(/\/+$/, "");
  const reviewUrl = `${publicOrigin}/admin/team-logos/${encodeURIComponent(asset._id)}`;
  for (const recipient of recipients) {
    if (sent.has(recipient)) continue;
    try {
      const delivered = await sendPlunkEmail({
        to: recipient,
        subject: `Team logo review: ${asset.target_team_name || asset.target_player_name || "Goal Guesser player"}`,
        body: `<p>A new Goal Guesser team logo is ready for review.</p><dl><dt>Team</dt><dd>${escapeHtml(asset.target_team_name || "Not named")}</dd><dt>Player</dt><dd>${escapeHtml(asset.target_player_name || asset.target_player_id)}</dd><dt>Uploaded by</dt><dd>${escapeHtml(asset.uploaded_by_name || asset.uploaded_by_player_id)}</dd>${asset.league_name ? `<dt>League</dt><dd>${escapeHtml(asset.league_name)}</dd>` : ""}<dt>Uploaded</dt><dd>${escapeHtml(asset.created_at)}</dd></dl><p><a href="${escapeHtml(reviewUrl)}">Review this team logo</a></p>`,
        idempotencyKey: `goal-guesser-team-logo-${asset._id}-${crypto.createHash("sha256").update(recipient).digest("hex").slice(0, 12)}`,
      });
      if (!delivered) throw new Error("Plunk is not configured");
      await db.collection("gg_image_assets").updateOne({ _id: asset._id }, { $addToSet: { moderation_email_sent_to: recipient }, $set: { updated_at: new Date().toISOString() } });
      sent.add(recipient);
      metrics.team_logo_moderation_emails += 1;
    } catch (error) {
      metrics.team_logo_moderation_email_failures += 1;
      await db.collection("gg_image_assets").updateOne({ _id: asset._id }, { $inc: { moderation_email_attempts: 1 }, $set: { moderation_email_last_error: String(error.message || error), updated_at: new Date().toISOString() } });
    }
  }
  if (recipients.every((recipient) => sent.has(recipient))) {
    await db.collection("gg_image_assets").updateOne({ _id: asset._id }, { $set: { moderation_email_status: "sent", moderation_email_sent_at: new Date().toISOString(), updated_at: new Date().toISOString() }, $unset: { moderation_email_last_error: "" } });
  }
}

async function deliverPendingTeamLogoModerationEmails() {
  const db = await getDb();
  if (!db) return;
  const pending = await db.collection("gg_image_assets").find({ moderation_email_status: { $ne: "sent" }, moderation_status: "pending" }).sort({ created_at: 1 }).limit(10).toArray();
  for (const asset of pending) await deliverTeamLogoModerationEmail(db, asset);
}

function startTeamLogoNotificationPump() {
  if (teamLogoNotificationTimer || process.env.NODE_ENV === "test") return;
  teamLogoNotificationTimer = setInterval(() => {
    void deliverPendingTeamLogoModerationEmails().catch((error) => console.warn(JSON.stringify({ event: "goal_guesser_team_logo_email_pump_failed", message: error.message })));
  }, 60_000);
  teamLogoNotificationTimer.unref?.();
}

function fallbackName(email, supplied) {
  const requested = normalizeName(supplied);
  if (requested) return requested;
  const local = String(email || "Player").split("@")[0].replace(/[._+-]+/g, " ");
  return normalizeName(local.replace(/\b\w/g, (letter) => letter.toUpperCase())) || "Player";
}

async function issueIdentitySession(db, { provider, subject, email, name, notifications = false }) {
  const identityId = `${provider}:${subject}`;
  const normalizedEmail = normalizeEmail(email);
  let identity = await db.collection("gg_identities").findOne({ _id: identityId });
  let player = identity ? await db.collection("gg_players").findOne({ _id: identity.player_id }) : null;
  let recoveryCode = null;
  if (!player && normalizedEmail) {
    const existingEmail = await db.collection("gg_identities").findOne({ email_normalized: normalizedEmail, email_verified: true });
    if (existingEmail) player = await db.collection("gg_players").findOne({ _id: existingEmail.player_id });
  }
  const now = new Date().toISOString();
  if (!player) {
    const id = crypto.randomUUID();
    const recovery = makeRecoveryCode(id);
    recoveryCode = recovery.code;
    player = {
      _id: id,
      name: fallbackName(normalizedEmail, name),
      email: normalizedEmail,
      email_verified: Boolean(normalizedEmail),
      email_notifications_enabled: Boolean(normalizedEmail && notifications),
      auth_providers: [provider],
      recovery: recovery.digest,
      created_at: now,
      updated_at: now,
    };
    await db.collection("gg_players").insertOne(player);
  } else {
    const update = { updated_at: now };
    if (normalizedEmail) {
      update.email = normalizedEmail;
      update.email_verified = true;
      if (notifications === true) update.email_notifications_enabled = true;
    }
    await db.collection("gg_players").updateOne({ _id: player._id }, { $set: update, $addToSet: { auth_providers: provider } });
    player = { ...player, ...update, auth_providers: [...new Set([...(player.auth_providers || []), provider])] };
  }
  if (!identity) {
    const candidate = {
      _id: identityId,
      provider,
      subject,
      player_id: player._id,
      email_normalized: normalizedEmail,
      email_verified: Boolean(normalizedEmail),
      created_at: now,
      updated_at: now,
    };
    identity = await db.collection("gg_identities").findOneAndUpdate(
      { _id: identityId },
      { $setOnInsert: candidate },
      { upsert: true, returnDocument: "after" }
    );
    if (identity.player_id !== player._id) {
      if (recoveryCode) await db.collection("gg_players").deleteOne({ _id: player._id });
      recoveryCode = null;
      player = await db.collection("gg_players").findOne({ _id: identity.player_id });
      if (!player) throw new Error("Identity is not linked to a player");
    }
  }
  const session = makeSession(player._id);
  await db.collection("gg_sessions").insertOne(session.record);
  return { player: publicPlayer(player), access_token: session.token, ...(recoveryCode ? { recovery_code: recoveryCode } : {}) };
}

async function sendPlunkEmail({ to, subject, body, idempotencyKey }) {
  const secretKey = String(process.env.PLUNK_SECRET_KEY || "").trim();
  const from = normalizeText(process.env.GOAL_GUESSER_EMAIL_FROM);
  if (!secretKey || !from) return false;
  const response = await fetch("https://next-api.useplunk.com/v1/send", {
    method: "POST",
    headers: {
      authorization: `Bearer ${secretKey}`,
      "content-type": "application/json",
      "idempotency-key": idempotencyKey,
    },
    body: JSON.stringify({ to, from: { name: "Goal Guesser", email: from }, subject, body }),
    signal: AbortSignal.timeout(10000),
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok || payload?.success !== true) throw new Error("Plunk rejected the email request");
  return true;
}

function makeSession(playerId) {
  const id = crypto.randomUUID();
  const secret = randomSecret();
  return {
    token: `${id}.${secret}`,
    record: {
      _id: id,
      player_id: playerId,
      secret: secretDigest(secret),
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
  };
}

function makeRecoveryCode(playerId) {
  const secret = randomCrockford(24);
  return {
    code: `GG-${playerId}.${secret}`,
    digest: secretDigest(secret),
  };
}

function parseCredential(value, prefix = "") {
  const raw = normalizeText(value);
  const withoutPrefix = prefix && raw.startsWith(prefix) ? raw.slice(prefix.length) : raw;
  const dot = withoutPrefix.indexOf(".");
  if (dot <= 0 || dot === withoutPrefix.length - 1) return null;
  return { id: withoutPrefix.slice(0, dot), secret: withoutPrefix.slice(dot + 1) };
}

function allowRate(key, limit, windowMs) {
  const now = Date.now();
  const bucket = rateBuckets.get(key);
  if (!bucket || bucket.resetAt <= now) {
    rateBuckets.set(key, { count: 1, resetAt: now + windowMs });
    return true;
  }
  if (bucket.count >= limit) return false;
  bucket.count += 1;
  return true;
}

function requestAddress(req) {
  return String(req.ip || req.socket?.remoteAddress || "unknown");
}

async function authenticate(req, res, next) {
  try {
    const authorization = String(req.get("authorization") || "");
    const token = authorization.toLowerCase().startsWith("bearer ") ? authorization.slice(7).trim() : "";
    const parsed = parseCredential(token);
    if (!parsed) return res.status(401).json({ error: "Authentication required" });
    const db = await getDb();
    if (!db) return res.status(503).json({ error: "Goal Guesser storage is unavailable" });
    const session = await db.collection("gg_sessions").findOne({ _id: parsed.id });
    if (!session || session.revoked_at || !secretMatches(parsed.secret, session.secret)) {
      return res.status(401).json({ error: "Session is invalid" });
    }
    const player = await db.collection("gg_players").findOne({ _id: session.player_id });
    if (!player) return res.status(401).json({ error: "Player no longer exists" });
    req.goalGuesser = { db, player, session };
    void db.collection("gg_sessions").updateOne({ _id: session._id }, { $set: { updated_at: new Date().toISOString() } });
    return next();
  } catch (error) {
    return res.status(500).json({ error: "Authentication failed" });
  }
}

async function ensureContest(db, seasonKey) {
  const id = `premier-league:${seasonKey}:${GAME_TYPE}`;
  const now = new Date().toISOString();
  await db.collection("gg_contests").updateOne(
    { _id: id },
    {
      $set: {
        competition_key: "premier-league",
        competition_name: PREMIER_LEAGUE,
        season_key: seasonKey,
        game_type: GAME_TYPE,
        scoring_version: SCORING_VERSION,
        result_basis: "normal_time",
        updated_at: now,
      },
      $setOnInsert: { created_at: now },
    },
    { upsert: true }
  );
  return id;
}

async function upsertFixture(db, match, source = "bsd") {
  const date = normalizeText(match.date);
  const time = normalizeText(match.time);
  const kickoffMs = zonedDateTimeToUtcMs(date, time, "Europe/London");
  if (!Number.isFinite(kickoffMs)) return null;
  const seasonKey = seasonKeyForDate(date);
  const contestId = await ensureContest(db, seasonKey);
  const providerId = normalizeText(match.match_details_id || match.id);
  const sourceKey = `${source}:${providerId || crypto.createHash("sha256").update(`${date}|${time}|${match.home_team}|${match.away_team}`).digest("hex")}`;
  let existing = await db.collection("gg_fixtures").findOne({ source_key: sourceKey });
  if (!existing) {
    existing = await db.collection("gg_fixtures").findOne({
      contest_id: contestId,
      home_team_key: canonicalTeamKey(match.home_team),
      away_team_key: canonicalTeamKey(match.away_team),
      kickoff_at: {
        $gte: new Date(kickoffMs - 48 * 60 * 60 * 1000).toISOString(),
        $lte: new Date(kickoffMs + 48 * 60 * 60 * 1000).toISOString(),
      },
    });
  }
  const id = existing?._id || crypto.randomUUID();
  const now = new Date().toISOString();
  const homeScore = integerScore(match.home_score);
  const awayScore = integerScore(match.away_score);
  const resultRevision = isFinalStatus(match.score_status) && Number.isInteger(homeScore) && Number.isInteger(awayScore)
    ? crypto.createHash("sha256").update(`${homeScore}:${awayScore}:${normalizeText(match.score_status)}`).digest("hex")
    : null;
  await db.collection("gg_fixtures").updateOne(
    { _id: id },
    {
      $set: {
        source_key: sourceKey,
        [`source_ids.${source}`]: providerId || null,
        contest_id: contestId,
        competition: PREMIER_LEAGUE,
        season_key: seasonKey,
        kickoff_at: new Date(kickoffMs).toISOString(),
        home_team: normalizeText(match.home_team),
        away_team: normalizeText(match.away_team),
        home_team_key: canonicalTeamKey(match.home_team),
        away_team_key: canonicalTeamKey(match.away_team),
        home_team_id: match.home_team_id != null ? String(match.home_team_id) : null,
        away_team_id: match.away_team_id != null ? String(match.away_team_id) : null,
        status: normalizeText(match.score_status) || null,
        home_score: Number.isInteger(homeScore) ? homeScore : null,
        away_score: Number.isInteger(awayScore) ? awayScore : null,
        result_revision: resultRevision,
        updated_at: now,
      },
      $setOnInsert: {
        original_kickoff_at: new Date(kickoffMs).toISOString(),
        pick_week_id: pickWeekIdForDate(date),
        created_at: now,
      },
    },
    { upsert: true }
  );
  return id;
}

async function settleFixture(db, fixture) {
  if (!fixture.result_revision || !Number.isInteger(fixture.home_score) || !Number.isInteger(fixture.away_score)) return;
  const picks = await db.collection("gg_picks").find({ fixture_id: fixture._id, scored_result_revision: { $ne: fixture.result_revision } }).toArray();
  if (picks.length === 0) return;
  const operations = picks.map((pick) => {
    const score = scorePrediction(
      pick.home_score,
      pick.away_score,
      fixture.home_score,
      fixture.away_score,
      pick.power_pick
    );
    const baseScore = scorePrediction(
      pick.home_score,
      pick.away_score,
      fixture.home_score,
      fixture.away_score,
      false
    );
    if (pick.scored_result_revision && pick.scored_result_revision !== fixture.result_revision) metrics.results_rescored += 1;
    return {
      updateOne: {
        filter: { _id: pick._id },
        update: {
          $set: {
            points: score.points,
            base_points: baseScore.points,
            score_tier: score.tier,
            scored_result_revision: fixture.result_revision,
            scored_at: new Date().toISOString(),
          },
        },
      },
    };
  });
  await db.collection("gg_picks").bulkWrite(operations, { ordered: false });
  metrics.results_settled += operations.length;
}

async function syncFixtures(getCanonicalMatches, { force = false } = {}) {
  if (!force && Date.now() - lastFixtureSyncAtMs < 60_000) return;
  if (fixtureSyncPromise) return fixtureSyncPromise;
  fixtureSyncPromise = (async () => {
    const db = await getDb();
    if (!db) throw new Error("MongoDB is unavailable");
    const matches = await getCanonicalMatches();
    const premierLeagueMatches = [];
    for (const match of Array.isArray(matches) ? matches : []) {
      if (!isPremierLeagueMatch(match)) {
        metrics.non_premier_league_rejected += 1;
        continue;
      }
      premierLeagueMatches.push(match);
    }
    for (const match of premierLeagueMatches) await upsertFixture(db, match, "bsd");
    const finalFixtures = await db.collection("gg_fixtures").find(liveFixtureQuery({ result_revision: { $ne: null } })).toArray();
    for (const fixture of finalFixtures) await settleFixture(db, fixture);
    lastFixtureSyncAtMs = Date.now();
    metrics.fixture_sync_runs += 1;
    console.log(JSON.stringify({ event: "goal_guesser_fixture_sync", matches: premierLeagueMatches.length, at: new Date().toISOString() }));
  })().catch((error) => {
    metrics.fixture_sync_failures += 1;
    console.warn(JSON.stringify({ event: "goal_guesser_fixture_sync_failed", message: error.message }));
    throw error;
  }).finally(() => {
    fixtureSyncPromise = null;
  });
  return fixtureSyncPromise;
}

async function requireMembership(db, leagueId, playerId) {
  return db.collection("gg_memberships").findOne({ league_id: leagueId, player_id: playerId });
}

function requireAdmin(req, res, next) {
  if (!isAdminPlayer(req.goalGuesser?.player)) return res.status(403).json({ error: "Goal Guesser administrator access required" });
  return next();
}

async function simulationForLeague(db, league) {
  if (!league?.simulation_id) return null;
  return db.collection("gg_simulation_runs").findOne({ _id: league.simulation_id, league_id: league._id });
}

async function nextOpenScoringStart(db, nowMs = currentTimeMs(), simulationId = null) {
  const fixtures = await db.collection("gg_fixtures").find(fixtureScopeQuery(simulationId)).sort({ kickoff_at: 1 }).toArray();
  const byWeek = new Map();
  fixtures.forEach((fixture) => {
    const values = byWeek.get(fixture.pick_week_id) || [];
    values.push(Date.parse(fixture.kickoff_at));
    byWeek.set(fixture.pick_week_id, values);
  });
  for (const [week, kickoffTimes] of byWeek) {
    if (kickoffTimes.every((value) => value > nowMs)) return { week, kickoff_at: new Date(Math.min(...kickoffTimes)).toISOString() };
  }
  return { week: null, kickoff_at: new Date(nowMs).toISOString() };
}

function publicCard(card) {
  return {
    id: card._id,
    type: card.type,
    month_id: card.month_id,
    label: card.label,
    status: card.status,
    expires_at: card.expires_at || null,
    target_fixture_id: card.target_fixture_id || null,
    reason: card.reason,
  };
}

async function ensureGameplayCards(db, { league, memberships, names, picks, fixtures, cards, nowMs = currentTimeMs() }) {
  const now = new Date(nowMs).toISOString();
  const months = monthlyChampionships(fixtures);
  const activeMonth = months.find((month) => month.weeks.some((week) => fixtures.some((fixture) => fixture.pick_week_id === week && Date.parse(fixture.kickoff_at) > nowMs))) || months.at(-1);
  if (!activeMonth) return cards;

  await db.collection("gg_leagues").updateOne({ _id: league._id }, { $set: { gameplay_rules_version: GAMEPLAY_RULES_VERSION, updated_at: now } });
  await db.collection("gg_wildcards").updateMany({ league_id: league._id, status: "available", expires_at: { $lte: now } }, { $set: { status: "expired", updated_at: now } });

  const fixtureById = new Map(fixtures.map((fixture) => [fixture._id, fixture]));
  const championship = gameplayRows({ memberships, names, picks, fixtureById, cards: [] });
  const leader = championship[0];
  const settledWeeks = completedWeeks(fixtures);
  const recentWeeks = settledWeeks.slice(-4);
  const recentScores = memberships.flatMap((membership) => {
    const scores = weeklyScores(membership, picks, fixtureById);
    return recentWeeks.map((week) => scores.get(week) || 0);
  });
  const typicalGameweek = median(recentScores);
  const expiry = activeMonth.expires_at;
  const finalMonth = activeMonth.index === months.length;
  const upserts = [];
  const createCard = (playerId, type, reason, label) => {
    const key = `${league._id}:${playerId}:${activeMonth.id}:${type}`;
    upserts.push({ updateOne: {
      filter: { card_key: key },
      update: { $setOnInsert: { _id: crypto.randomUUID(), card_key: key, league_id: league._id, simulation_id: league.simulation_id || null, player_id: playerId, type, label, reason, month_id: activeMonth.id, status: "available", expires_at: expiry, created_at: now }, $set: { updated_at: now } },
      upsert: true,
    }});
  };
  for (const membership of memberships) {
    createCard(membership.player_id, "exacta", "monthly", "Exacta");
    if (finalMonth) createCard(membership.player_id, "all_or_nothing", "final_month", "All or Nothing");
    const row = championship.find((item) => item.player_id === membership.player_id);
    if (leader && row && typicalGameweek > 0 && row.player_id !== leader.player_id && leader.points - row.points >= typicalGameweek) {
      createCard(membership.player_id, "triple_threat", "chase", "Triple Threat");
    }
    const momentum = momentumForMembership(membership, picks, fixtureById, settledWeeks);
    if (momentum.eligible) createCard(membership.player_id, "wildcard", "momentum", "Momentum");
  }
  if (upserts.length) await db.collection("gg_wildcards").bulkWrite(upserts, { ordered: false });
  return db.collection("gg_wildcards").find({ league_id: league._id, player_id: { $in: memberships.map((membership) => membership.player_id) } }).toArray();
}

async function loadLeagueGameplay(db, leagueId, viewerId) {
  const league = await db.collection("gg_leagues").findOne({ _id: leagueId });
  if (!league) return null;
  const memberships = await db.collection("gg_memberships").find({ league_id: leagueId }).toArray();
  const playerIds = memberships.map((item) => item.player_id);
  const players = await db.collection("gg_players").find({ _id: { $in: playerIds } }).toArray();
  const names = new Map(players.map((player) => [player._id, player.name]));
  const teamNames = new Map(players.map((player) => [player._id, player.team_name || null]));
  const playerById = new Map(players.map((player) => [player._id, player]));
  const logos = new Map(memberships.map((membership) => [membership.player_id, resolvedTeamLogoReference(playerById.get(membership.player_id), membership)]));
  const simulation = await simulationForLeague(db, league);
  const fixtures = await db.collection("gg_fixtures").find(fixtureScopeQuery(simulation?._id)).sort({ kickoff_at: 1 }).toArray();
  const fixtureIds = fixtures.map((fixture) => fixture._id);
  const picks = await db.collection("gg_picks").find({ player_id: { $in: playerIds }, fixture_id: { $in: fixtureIds }, points: { $type: "number" } }).toArray();
  const cards = await db.collection("gg_wildcards").find({ league_id: league._id, player_id: { $in: playerIds } }).toArray();
  const nowMs = simulation ? Date.parse(simulation.current_time) : currentTimeMs();
  const ensuredCards = await ensureGameplayCards(db, { league, memberships, names, picks, fixtures, cards, nowMs });
  return { league, memberships, names, teamNames, logos, picks, fixtures, cards: ensuredCards, summary: gameplaySummary({ memberships, names, teamNames, logos, picks, fixtures, cards: ensuredCards, viewerId }) };
}

function gameplaySummary({ memberships, names, teamNames = new Map(), logos = new Map(), picks, fixtures, cards, viewerId }) {
  const fixtureById = new Map(fixtures.map((fixture) => [fixture._id, fixture]));
  const months = monthlyChampionships(fixtures);
  const settledWeeks = completedWeeks(fixtures);
  const leaderboard = gameplayRows({ memberships, names, teamNames, logos, picks, fixtureById, cards });
  const lastWeek = settledWeeks.at(-1) || null;
  const weeklyPoints = new Map(memberships.map((membership) => [membership.player_id, 0]));
  if (lastWeek) {
    const cardByPick = new Map(cards.filter((card) => card.status === "played" && card.target_fixture_id).map((card) => [`${card.player_id}:${card.target_fixture_id}`, card]));
    for (const pick of picks) {
      if (fixtureById.get(pick.fixture_id)?.pick_week_id !== lastWeek) continue;
      weeklyPoints.set(pick.player_id, (weeklyPoints.get(pick.player_id) || 0) + cardPointsForPick(pick, cardByPick.get(`${pick.player_id}:${pick.fixture_id}`)));
    }
  }
  const formRows = rankLeaderboard(memberships.map((membership) => {
    const scores = weeklyScores(membership, picks, fixtureById);
    const points = settledWeeks.slice(-4).reduce((sum, week) => sum + (scores.get(week) || 0), 0);
    return { player_id: membership.player_id, name: names.get(membership.player_id) || "Former player", team_name: teamNames.get(membership.player_id) || null, team_logo: logos.get(membership.player_id) || null, points, exact_scores: 0, correct_results: 0 };
  }));
  const previousWeekPicks = lastWeek ? picks.filter((pick) => fixtureById.get(pick.fixture_id)?.pick_week_id !== lastWeek) : picks;
  const previousLeaderboard = lastWeek ? gameplayRows({ memberships, names, teamNames, logos, picks: previousWeekPicks, fixtureById, cards }) : leaderboard;
  const previousPositions = new Map(previousLeaderboard.map((row) => [row.player_id, row.position]));
  const snapshotRows = leaderboard.map((row) => {
    const previousPosition = settledWeeks.length > 1 ? previousPositions.get(row.player_id) || row.position : null;
    return { ...row, previous_position: previousPosition, movement: previousPosition == null ? null : previousPosition - row.position };
  });
  const viewerIndex = snapshotRows.findIndex((row) => row.player_id === viewerId);
  const snapshotStart = Math.max(0, Math.min(viewerIndex - 2, snapshotRows.length - 5));
  const tableSnapshot = viewerIndex < 0 ? snapshotRows.slice(0, 5) : snapshotRows.slice(snapshotStart, snapshotStart + 5);
  const weeklyPerformance = settledWeeks.map((pickWeekId) => {
    const weekPicks = picks.filter((pick) => fixtureById.get(pick.fixture_id)?.pick_week_id === pickWeekId);
    const rows = gameplayRows({ memberships, names, teamNames, logos, picks: weekPicks, fixtureById, cards });
    const viewer = rows.find((row) => row.player_id === viewerId) || { position: rows.length, points: 0, exact_scores: 0, correct_results: 0 };
    return {
      pick_week_id: pickWeekId,
      points: viewer.points,
      position: viewer.position,
      player_count: rows.length,
      exact_scores: viewer.exact_scores,
      correct_results: viewer.correct_results,
      badges: weeklyPerformanceBadges(viewer, rows.length),
    };
  });
  const viewerRow = snapshotRows.find((row) => row.player_id === viewerId) || null;
  const latestPerformance = weeklyPerformance.at(-1) || null;
  return {
    rules_version: GAMEPLAY_RULES_VERSION,
    leaderboard,
    viewer: viewerRow ? {
      player_id: viewerRow.player_id,
      total_points: viewerRow.points,
      exact_scores: viewerRow.exact_scores,
      position: viewerRow.position,
      previous_position: viewerRow.previous_position,
      movement: viewerRow.movement,
      player_count: leaderboard.length,
      last_week_id: latestPerformance?.pick_week_id || null,
      last_week_points: latestPerformance?.points || 0,
    } : null,
    table_snapshot: tableSnapshot,
    weekly_performance: weeklyPerformance,
    monthly_championships: months.map((month) => ({ ...month, leaderboard: monthlyRows({ month, memberships, names, teamNames, logos, picks, fixtureById, cards }) })),
    form_table: formRows,
    rival_duels: lastWeek ? rivalDuels(leaderboard, weeklyPoints, lastWeek) : [],
    momentum: memberships.map((membership) => ({ ...momentumForMembership(membership, picks, fixtureById, settledWeeks), name: names.get(membership.player_id) || "Former player" })),
    wildcards: cards.filter((card) => card.player_id === viewerId).map(publicCard),
  };
}

function weeklyPerformanceBadges(row, playerCount) {
  const badges = [];
  if (row.points > 0 && row.position === 1) badges.push({ id: "best_in_class", label: "Best in class!", tone: "gold" });
  if (playerCount >= 10 && row.position <= 10) badges.push({ id: "top_ten", label: "Top 10!", tone: "green" });
  else if (playerCount >= 3 && row.position <= 3) badges.push({ id: "top_three", label: "Top 3!", tone: "green" });
  else if (playerCount > 1 && row.position <= Math.ceil(playerCount / 2)) badges.push({ id: "top_half", label: "Top half", tone: "green" });
  if (row.exact_scores > 0) badges.push({ id: "bullseye", label: row.exact_scores === 1 ? "Exact score" : `${row.exact_scores} exact scores`, tone: "ink" });
  return badges;
}

async function loadPlayerWildcards(db, playerId, leagueId = null) {
  const league = leagueId ? await db.collection("gg_leagues").findOne({ _id: leagueId }) : null;
  const simulation = await simulationForLeague(db, league);
  const fixtures = await db.collection("gg_fixtures").find(fixtureScopeQuery(simulation?._id)).sort({ kickoff_at: 1 }).toArray();
  const months = monthlyChampionships(fixtures);
  const nowMs = simulation ? Date.parse(simulation.current_time) : currentTimeMs();
  const activeMonth = months.find((month) => month.weeks.some((week) => fixtures.some((fixture) => fixture.pick_week_id === week && Date.parse(fixture.kickoff_at) > nowMs))) || months.at(-1);
  const now = new Date(nowMs).toISOString();
  const cardScope = league ? { league_id: league._id } : { simulation_id: null };
  await db.collection("gg_wildcards").updateMany({ player_id: playerId, ...cardScope, status: "available", expires_at: { $lte: now } }, { $set: { status: "expired", updated_at: now } });
  if (activeMonth) {
    const cardKey = league ? `${league._id}:${playerId}:${activeMonth.id}:exacta` : `${playerId}:${activeMonth.id}:exacta`;
    await db.collection("gg_wildcards").updateOne(
      { card_key: cardKey },
      { $setOnInsert: { _id: crypto.randomUUID(), card_key: cardKey, league_id: league?._id || null, simulation_id: simulation?._id || null, player_id: playerId, type: "exacta", label: "Exacta", reason: "monthly", month_id: activeMonth.id, status: "available", expires_at: activeMonth.expires_at, created_at: now }, $set: { updated_at: now } },
      { upsert: true }
    );
  }
  return { fixtures, cards: await db.collection("gg_wildcards").find({ player_id: playerId, ...cardScope }).toArray() };
}

async function recordAdminEvent(db, player, leagueId, simulationId, action, details = {}) {
  const event = {
    _id: crypto.randomUUID(),
    actor_player_id: player._id,
    actor_email: player.email || null,
    league_id: leagueId,
    simulation_id: simulationId || null,
    action,
    details,
    created_at: new Date().toISOString(),
  };
  await db.collection("gg_admin_audit_events").insertOne(event);
  return event;
}

async function adminLeagueState(db, leagueId) {
  const league = await db.collection("gg_leagues").findOne({ _id: leagueId });
  if (!league) return null;
  const simulation = await simulationForLeague(db, league);
  const members = await db.collection("gg_memberships").find({ league_id: leagueId }).sort({ joined_at: 1 }).toArray();
  const players = await db.collection("gg_players").find({ _id: { $in: members.map((member) => member.player_id) } }).toArray();
  const names = new Map(players.map((player) => [player._id, player.name]));
  if (!simulation) return { league: { id: league._id, name: league.name, simulation_id: null }, simulation: null, members: members.map((member) => ({ player_id: member.player_id, name: names.get(member.player_id) || "Former player" })) };
  const currentWeek = simulation.weeks?.[simulation.current_week_index - 1] || null;
  const fixtures = currentWeek ? await db.collection("gg_fixtures").find(fixtureScopeQuery(simulation._id, { pick_week_id: currentWeek.pick_week_id })).sort({ kickoff_at: 1 }).toArray() : [];
  const picks = await db.collection("gg_picks").find({ player_id: { $in: members.map((member) => member.player_id) }, fixture_id: { $in: fixtures.map((fixture) => fixture._id) } }).toArray();
  const cards = await db.collection("gg_wildcards").find({ league_id: leagueId, status: "played", target_fixture_id: { $in: fixtures.map((fixture) => fixture._id) } }).toArray();
  const cardByPick = new Map(cards.map((card) => [`${card.player_id}:${card.target_fixture_id}`, card]));
  const resultsReady = fixtures.length > 0 && fixtures.every((fixture) => Number.isInteger(fixture.proposed_home_score) && Number.isInteger(fixture.proposed_away_score));
  const memberRows = members.map((member) => {
    const memberPicks = picks.filter((pick) => pick.player_id === member.player_id);
    const previewPoints = memberPicks.reduce((total, pick) => {
      const fixture = fixtures.find((item) => item._id === pick.fixture_id);
      if (!fixture || !Number.isInteger(fixture.proposed_home_score) || !Number.isInteger(fixture.proposed_away_score)) return total;
      const scored = scorePrediction(pick.home_score, pick.away_score, fixture.proposed_home_score, fixture.proposed_away_score, pick.power_pick);
      const base = scorePrediction(pick.home_score, pick.away_score, fixture.proposed_home_score, fixture.proposed_away_score, false);
      return total + cardPointsForPick({ ...pick, points: scored.points, base_points: base.points, score_tier: scored.tier }, cardByPick.get(`${member.player_id}:${fixture._id}`));
    }, 0);
    return { player_id: member.player_id, name: names.get(member.player_id) || "Former player", submitted: memberPicks.length, fixture_count: fixtures.length, preview_points: previewPoints };
  });
  const audit = await db.collection("gg_admin_audit_events").find({ simulation_id: simulation._id }).sort({ created_at: -1 }).limit(12).toArray();
  return {
    league: { id: league._id, name: league.name, simulation_id: simulation._id },
    simulation: { id: simulation._id, status: simulation.status, phase: simulation.phase, current_week_index: simulation.current_week_index, total_weeks: simulation.weeks.length, current_time: simulation.current_time, seed: simulation.seed, version: simulation.version, current_week: currentWeek, results_ready: resultsReady },
    fixtures: fixtures.map((fixture) => ({ ...fixtureResponse(fixture, null, Date.parse(simulation.current_time)), proposed_home_score: Number.isInteger(fixture.proposed_home_score) ? fixture.proposed_home_score : null, proposed_away_score: Number.isInteger(fixture.proposed_away_score) ? fixture.proposed_away_score : null })),
    members: memberRows,
    audit: audit.map((event) => ({ id: event._id, action: event.action, details: event.details || {}, created_at: event.created_at })),
  };
}

function parseAdminResults(input, fixtures) {
  const values = Array.isArray(input) ? input : [];
  if (values.length !== fixtures.length) return null;
  const fixtureIds = new Set(fixtures.map((fixture) => fixture._id));
  const seen = new Set();
  const parsed = [];
  for (const item of values) {
    const fixtureId = normalizeText(item?.fixture_id);
    const homeScore = Number(item?.home_score);
    const awayScore = Number(item?.away_score);
    if (!fixtureIds.has(fixtureId) || seen.has(fixtureId) || !Number.isInteger(homeScore) || !Number.isInteger(awayScore) || homeScore < 0 || awayScore < 0 || homeScore > MAX_SCORE || awayScore > MAX_SCORE) return null;
    seen.add(fixtureId);
    parsed.push({ fixture_id: fixtureId, home_score: homeScore, away_score: awayScore });
  }
  return parsed;
}

function registerGoalGuesserRoutes(app, options = {}) {
  const enabled = options.enabled === true;
  const rateLimitsEnabled = options.disableRateLimits !== true;
  const getCanonicalMatches = options.getCanonicalMatches;
  const teamLogoStorage = options.teamLogoStorage || createTeamLogoStorage();
  const rawTeamLogo = express.raw({ type: () => true, limit: MAX_UPLOAD_BYTES });
  configureAdminEmails(options.adminEmails ?? process.env.GOAL_GUESSER_ADMIN_EMAILS);
  if (typeof getCanonicalMatches !== "function") throw new Error("getCanonicalMatches is required");
  startTeamLogoNotificationPump();

  app.use(PREFIX, (req, res, next) => {
    if (!enabled) return res.status(404).json({ error: "Goal Guesser is not enabled" });
    res.set("Cache-Control", "no-store");
    return next();
  });

  const logoRoute = (handler) => async (req, res) => {
    try {
      return await handler(req, res);
    } catch (error) {
      if (error?.type === "entity.too.large") return res.status(413).json({ error: "The cropped image must be smaller than 5 MB" });
      if (error instanceof TeamLogoStorageError) {
        if (error.status >= 500) metrics.team_logo_storage_failures += 1;
        else metrics.team_logo_rejections += 1;
        return res.status(error.status).json({ error: error.message });
      }
      console.error("goal_guesser_team_logo_failed", { message: error.message });
      return res.status(500).json({ error: "The team logo could not be saved" });
    }
  };

  const storeLogoForTarget = async ({ req, targetType, targetPlayer, membership = null, league = null }) => {
    if (rateLimitsEnabled && !allowRate(`team-logo:${req.goalGuesser.player._id}`, 10, 60 * 60 * 1000)) throw new TeamLogoStorageError("Wait before uploading another team logo", 429);
    if (!teamLogoStorage.configured) throw new TeamLogoStorageError("Team logo storage is not configured", 503);
    const normalized = await normalizeTeamLogo(req.body);
    const db = req.goalGuesser.db;
    const assetId = crypto.randomUUID();
    const variants = await teamLogoStorage.store(assetId, normalized);
    const now = new Date().toISOString();
    const previousAssetId = membership?.team_logo_asset_id || (targetType === "player_default" ? targetPlayer.team_logo_asset_id : null);
    const asset = {
      _id: assetId,
      kind: "team_logo",
      target_type: targetType,
      target_player_id: targetPlayer._id,
      target_player_name: targetPlayer.name,
      target_team_name: targetPlayer.team_name || null,
      league_id: league?._id || null,
      league_name: league?.name || null,
      uploaded_by_player_id: req.goalGuesser.player._id,
      uploaded_by_name: req.goalGuesser.player.name,
      variants,
      source: normalized.source,
      sha256: normalized.sha256,
      storage_status: "stored",
      moderation_status: "pending",
      moderation_email_status: "pending",
      moderation_email_attempts: 0,
      moderation_email_sent_to: [],
      replaced_asset_id: previousAssetId || null,
      created_at: now,
      updated_at: now,
    };
    try {
      await db.collection("gg_image_assets").insertOne(asset);
      if (targetType === "player_default") {
        await db.collection("gg_players").updateOne({ _id: targetPlayer._id }, { $set: { team_logo_asset_id: assetId, updated_at: now } });
      } else {
        const result = await db.collection("gg_memberships").updateOne(
          { _id: membership._id, league_id: league._id, player_id: targetPlayer._id },
          { $set: { team_logo_asset_id: assetId, team_logo_set_by_player_id: req.goalGuesser.player._id, team_logo_set_at: now } }
        );
        if (result.matchedCount !== 1) throw new Error("League membership changed during upload");
      }
    } catch (error) {
      await teamLogoStorage.remove(variants).catch(() => {});
      await db.collection("gg_image_assets").deleteOne({ _id: assetId }).catch(() => {});
      throw error;
    }
    metrics.team_logo_uploads += 1;
    if (previousAssetId) await retireTeamLogoAssetIfUnreferenced(db, teamLogoStorage, previousAssetId);
    void deliverTeamLogoModerationEmail(db, asset).catch((error) => console.warn(JSON.stringify({ event: "goal_guesser_team_logo_email_failed", asset_id: assetId, message: error.message })));
    return asset;
  };

  app.post(`${PREFIX}/players`, async (req, res) => {
    if (rateLimitsEnabled && !allowRate(`create:${requestAddress(req)}`, 10, 60 * 60 * 1000)) return res.status(429).json({ error: "Try again later" });
    const name = normalizeName(req.body?.name);
    if (!name) return res.status(400).json({ error: "Name must be between 1 and 32 characters" });
    const db = await getDb();
    if (!db) return res.status(503).json({ error: "Goal Guesser storage is unavailable" });
    const id = crypto.randomUUID();
    const recovery = makeRecoveryCode(id);
    const session = makeSession(id);
    const now = new Date().toISOString();
    const player = { _id: id, name, recovery: recovery.digest, created_at: now, updated_at: now };
    await db.collection("gg_players").insertOne(player);
    await db.collection("gg_sessions").insertOne(session.record);
    return res.status(201).json({ player: publicPlayer(player), access_token: session.token, recovery_code: recovery.code });
  });

  app.post(`${PREFIX}/auth/email/start`, async (req, res) => {
    const email = normalizeEmail(req.body?.email);
    if (!email) return res.status(400).json({ error: "Enter a valid email address" });
    if (rateLimitsEnabled && (!allowRate(`email-ip:${requestAddress(req)}`, 10, 15 * 60 * 1000) || !allowRate(`email:${crypto.createHash("sha256").update(email).digest("hex")}`, 5, 15 * 60 * 1000))) {
      return res.status(429).json({ error: "Wait a few minutes before requesting another code" });
    }
    const db = await getDb();
    if (!db) return res.status(503).json({ error: "Goal Guesser storage is unavailable" });
    const challengeId = crypto.randomUUID();
    const code = String(crypto.randomInt(0, 1000000)).padStart(6, "0");
    const now = new Date();
    await db.collection("gg_login_challenges").insertOne({
      _id: challengeId,
      email_normalized: email,
      code: secretDigest(code),
      requested_name: normalizeName(req.body?.name),
      email_notifications_enabled: req.body?.email_notifications_enabled === true,
      attempt_count: 0,
      expires_at: new Date(now.getTime() + EMAIL_CODE_TTL_MS),
      created_at: now.toISOString(),
    });
    let emailSent = false;
    try {
      emailSent = await sendPlunkEmail({
        to: email,
        subject: `${code} is your Goal Guesser code`,
        body: `<p>Your Goal Guesser sign-in code is:</p><p style="font-size:28px;font-weight:700;letter-spacing:6px">${code}</p><p>It expires in 10 minutes. If you did not request it, you can ignore this email.</p>`,
        idempotencyKey: `goal-guesser-login-${challengeId}`,
      });
    } catch (_error) {
      await db.collection("gg_login_challenges").deleteOne({ _id: challengeId });
      return res.status(503).json({ error: "We could not send the sign-in email. Try again shortly." });
    }
    if (!emailSent && process.env.NODE_ENV === "production") {
      await db.collection("gg_login_challenges").deleteOne({ _id: challengeId });
      return res.status(503).json({ error: "Email sign-in is not configured" });
    }
    return res.status(201).json({ challenge_id: challengeId, expires_in: EMAIL_CODE_TTL_MS / 1000, ...(emailSent ? {} : { development_code: code }) });
  });

  app.post(`${PREFIX}/auth/email/verify`, async (req, res) => {
    if (rateLimitsEnabled && !allowRate(`email-verify:${requestAddress(req)}`, 20, 15 * 60 * 1000)) return res.status(429).json({ error: "Try again later" });
    const challengeId = normalizeText(req.body?.challenge_id);
    const code = normalizeText(req.body?.code);
    const db = await getDb();
    const challenge = db && challengeId ? await db.collection("gg_login_challenges").findOne({ _id: challengeId }) : null;
    if (!challenge || challenge.consumed_at || challenge.attempt_count >= 5 || challenge.expires_at.getTime() <= currentTimeMs() || !/^\d{6}$/.test(code) || !secretMatches(code, challenge.code)) {
      metrics.email_login_failures += 1;
      if (challenge && !challenge.consumed_at) await db.collection("gg_login_challenges").updateOne({ _id: challengeId }, { $inc: { attempt_count: 1 } });
      return res.status(401).json({ error: "That code is invalid or has expired" });
    }
    const consumed = await db.collection("gg_login_challenges").updateOne({ _id: challengeId, consumed_at: { $exists: false } }, { $set: { consumed_at: new Date().toISOString() } });
    if (consumed.modifiedCount !== 1) return res.status(401).json({ error: "That code has already been used" });
    const result = await issueIdentitySession(db, {
      provider: "email",
      subject: challenge.email_normalized,
      email: challenge.email_normalized,
      name: challenge.requested_name,
      notifications: challenge.email_notifications_enabled,
    });
    return res.json(result);
  });

  app.post(`${PREFIX}/auth/oauth`, async (req, res) => {
    const provider = normalizeText(req.body?.provider).toLowerCase();
    if (!OIDC_PROVIDERS[provider]) return res.status(400).json({ error: "Unsupported identity provider" });
    if (rateLimitsEnabled && !allowRate(`oauth:${requestAddress(req)}`, 20, 15 * 60 * 1000)) return res.status(429).json({ error: "Try again later" });
    const db = await getDb();
    if (!db) return res.status(503).json({ error: "Goal Guesser storage is unavailable" });
    try {
      const idToken = String(req.body?.id_token || "");
      const claims = await providerClaims(provider, idToken);
      const assertionId = crypto.createHash("sha256").update(idToken).digest("hex");
      try {
        await db.collection("gg_auth_assertions").insertOne({ _id: assertionId, provider, expires_at: new Date(Number(claims.exp) * 1000) });
      } catch (error) {
        if (error?.code === 11000) return res.status(401).json({ error: "This sign-in response has already been used" });
        throw error;
      }
      const verified = claims.email_verified === true || claims.email_verified === "true";
      const result = await issueIdentitySession(db, {
        provider,
        subject: claims.sub,
        email: verified ? claims.email : null,
        name: req.body?.name || claims.name,
        notifications: req.body?.email_notifications_enabled === true,
      });
      return res.json(result);
    } catch (error) {
      metrics.oauth_login_failures += 1;
      const configurationError = String(error.message || "").includes("not configured");
      return res.status(configurationError ? 503 : 401).json({ error: configurationError ? error.message : "Sign-in could not be verified" });
    }
  });

  app.post(`${PREFIX}/sessions/recover`, async (req, res) => {
    if (rateLimitsEnabled && !allowRate(`recover:${requestAddress(req)}`, 8, 15 * 60 * 1000)) return res.status(429).json({ error: "Try again later" });
    const parsed = parseCredential(req.body?.recovery_code, "GG-");
    const db = await getDb();
    const player = parsed && db ? await db.collection("gg_players").findOne({ _id: parsed.id }) : null;
    if (!player || !secretMatches(parsed.secret, player.recovery)) {
      metrics.recovery_failures += 1;
      return res.status(401).json({ error: "Recovery code is invalid" });
    }
    const session = makeSession(player._id);
    await db.collection("gg_sessions").insertOne(session.record);
    return res.json({ player: publicPlayer(player), access_token: session.token });
  });

  app.delete(`${PREFIX}/sessions/current`, authenticate, async (req, res) => {
    await req.goalGuesser.db.collection("gg_sessions").updateOne({ _id: req.goalGuesser.session._id }, { $set: { revoked_at: new Date().toISOString() } });
    return res.status(204).end();
  });

  app.get(`${PREFIX}/me`, authenticate, (req, res) => res.json({ player: publicPlayer(req.goalGuesser.player) }));

  app.patch(`${PREFIX}/me`, authenticate, async (req, res) => {
    const hasName = Object.prototype.hasOwnProperty.call(req.body || {}, "name");
    const hasTeamName = Object.prototype.hasOwnProperty.call(req.body || {}, "team_name");
    const hasNotifications = Object.prototype.hasOwnProperty.call(req.body || {}, "email_notifications_enabled");
    const name = hasName ? normalizeName(req.body?.name) : req.goalGuesser.player.name;
    const teamName = hasTeamName ? normalizeTeamName(req.body?.team_name) : req.goalGuesser.player.team_name;
    if (hasName && !name) return res.status(400).json({ error: "Name must be between 1 and 32 characters" });
    if (hasTeamName && !teamName) return res.status(400).json({ error: "Team name must be between 1 and 40 characters" });
    if (!hasName && !hasTeamName && !hasNotifications) return res.status(400).json({ error: "No profile changes were provided" });
    if (hasNotifications && req.body?.email_notifications_enabled === true && !req.goalGuesser.player.email_verified) {
      return res.status(409).json({ error: "Verify an email address before enabling reminders" });
    }
    const now = new Date().toISOString();
    const update = { ...(hasName ? { name } : {}), ...(hasTeamName ? { team_name: teamName } : {}), ...(hasNotifications ? { email_notifications_enabled: req.body.email_notifications_enabled === true } : {}), updated_at: now };
    await req.goalGuesser.db.collection("gg_players").updateOne({ _id: req.goalGuesser.player._id }, { $set: update });
    return res.json({ player: publicPlayer({ ...req.goalGuesser.player, ...update }) });
  });

  app.post(`${PREFIX}/me/team-setup/complete`, authenticate, async (req, res) => {
    const teamName = normalizeTeamName(req.body?.team_name || req.goalGuesser.player.team_name);
    if (!teamName) return res.status(400).json({ error: "Choose a team name between 1 and 40 characters" });
    const completedAt = req.goalGuesser.player.team_setup_completed_at || new Date().toISOString();
    await req.goalGuesser.db.collection("gg_players").updateOne(
      { _id: req.goalGuesser.player._id },
      { $set: { team_name: teamName, team_setup_completed_at: completedAt, updated_at: new Date().toISOString() } }
    );
    return res.json({ player: publicPlayer({ ...req.goalGuesser.player, team_name: teamName, team_setup_completed_at: completedAt }) });
  });

  app.put(`${PREFIX}/me/team-logo`, authenticate, rawTeamLogo, logoRoute(async (req, res) => {
    const asset = await storeLogoForTarget({ req, targetType: "player_default", targetPlayer: req.goalGuesser.player });
    return res.status(201).json({ team_logo: teamLogoReference(asset._id), moderation_status: asset.moderation_status });
  }));

  app.delete(`${PREFIX}/me/team-logo`, authenticate, logoRoute(async (req, res) => {
    const previousAssetId = req.goalGuesser.player.team_logo_asset_id;
    await req.goalGuesser.db.collection("gg_players").updateOne(
      { _id: req.goalGuesser.player._id },
      { $unset: { team_logo_asset_id: "" }, $set: { updated_at: new Date().toISOString() } }
    );
    if (previousAssetId) await retireTeamLogoAssetIfUnreferenced(req.goalGuesser.db, teamLogoStorage, previousAssetId);
    return res.status(204).end();
  }));

  app.get(`${PREFIX}/team-logos/:assetId/content`, authenticate, logoRoute(async (req, res) => {
    const asset = await req.goalGuesser.db.collection("gg_image_assets").findOne({ _id: req.params.assetId, storage_status: "stored", moderation_status: { $ne: "rejected" } });
    if (!asset) throw new TeamLogoStorageError("Team logo was not found", 404);
    const variant = req.query.variant === "full" ? "full" : "thumbnail";
    const object = await teamLogoStorage.read(asset, variant);
    res.set("Content-Type", object.contentType);
    res.set("Cache-Control", "private, max-age=300");
    if (object.contentLength) res.set("Content-Length", String(object.contentLength));
    if (object.etag) res.set("ETag", object.etag);
    if (typeof object.body?.pipe === "function") return object.body.pipe(res);
    if (typeof object.body?.transformToByteArray === "function") return res.send(Buffer.from(await object.body.transformToByteArray()));
    throw new TeamLogoStorageError("Team logo storage returned an invalid response", 503);
  }));

  app.post(`${PREFIX}/me/recovery-code`, authenticate, async (req, res) => {
    const recovery = makeRecoveryCode(req.goalGuesser.player._id);
    await req.goalGuesser.db.collection("gg_players").updateOne(
      { _id: req.goalGuesser.player._id },
      { $set: { recovery: recovery.digest, updated_at: new Date().toISOString() } }
    );
    return res.json({ recovery_code: recovery.code });
  });

  app.delete(`${PREFIX}/me`, authenticate, async (req, res) => {
    const { db, player } = req.goalGuesser;
    const playerMemberships = await db.collection("gg_memberships").find({ player_id: player._id }).toArray();
    const logoAssetIds = [...new Set([player.team_logo_asset_id, ...playerMemberships.map((membership) => membership.team_logo_asset_id)].filter(Boolean))];
    const owned = await db.collection("gg_leagues").find({ owner_player_id: player._id }).toArray();
    for (const league of owned) {
      const successor = await db.collection("gg_memberships").find({ league_id: league._id, player_id: { $ne: player._id } }).sort({ joined_at: 1 }).limit(1).next();
      if (successor) {
        await db.collection("gg_leagues").updateOne({ _id: league._id }, { $set: { owner_player_id: successor.player_id, updated_at: new Date().toISOString() } });
        await db.collection("gg_memberships").updateOne({ _id: successor._id }, { $set: { role: "owner" } });
      } else {
        if (league.simulation_id) {
          await Promise.all([
            db.collection("gg_simulation_runs").deleteOne({ _id: league.simulation_id }),
            db.collection("gg_fixtures").deleteMany({ simulation_id: league.simulation_id }),
            db.collection("gg_contests").deleteOne({ _id: `simulation:${league.simulation_id}` }),
            db.collection("gg_admin_audit_events").deleteMany({ simulation_id: league.simulation_id }),
            db.collection("gg_wildcards").deleteMany({ league_id: league._id }),
          ]);
        }
        await db.collection("gg_leagues").deleteOne({ _id: league._id });
      }
    }
    await Promise.all([
      db.collection("gg_sessions").deleteMany({ player_id: player._id }),
      db.collection("gg_memberships").deleteMany({ player_id: player._id }),
      db.collection("gg_picks").deleteMany({ player_id: player._id }),
      db.collection("gg_league_cards").deleteMany({ player_id: player._id }),
      db.collection("gg_wildcards").deleteMany({ player_id: player._id }),
      db.collection("gg_identities").deleteMany({ player_id: player._id }),
      db.collection("gg_players").deleteOne({ _id: player._id }),
    ]);
    for (const assetId of logoAssetIds) await retireTeamLogoAssetIfUnreferenced(db, teamLogoStorage, assetId);
    return res.status(204).end();
  });

  app.get(`${PREFIX}/fixtures`, authenticate, async (req, res) => {
    await syncFixtures(getCanonicalMatches);
    const { db, player } = req.goalGuesser;
    const leagueId = normalizeText(req.query.league_id);
    const league = leagueId ? await db.collection("gg_leagues").findOne({ _id: leagueId }) : null;
    if (leagueId && (!league || !await requireMembership(db, leagueId, player._id))) return res.status(404).json({ error: "League not found" });
    const simulation = await simulationForLeague(db, league);
    const query = fixtureScopeQuery(simulation?._id);
    if (simulation && !req.query.pick_week_id) query.simulation_week = { $lte: simulation.current_week_index };
    if (req.query.pick_week_id) query.pick_week_id = String(req.query.pick_week_id);
    const fixtures = await db.collection("gg_fixtures").find(query).sort({ kickoff_at: 1 }).toArray();
    const lockTimes = pickWeekLockTimes(fixtures);
    const nowMs = simulation ? Date.parse(simulation.current_time) : currentTimeMs();
    const picks = await db.collection("gg_picks").find({ player_id: player._id, fixture_id: { $in: fixtures.map((item) => item._id) } }).toArray();
    const picksByFixture = new Map(picks.map((pick) => [pick.fixture_id, pick]));
    const playedCards = leagueId ? await db.collection("gg_wildcards").find({ league_id: leagueId, player_id: player._id, status: "played", target_fixture_id: { $in: fixtures.map((item) => item._id) } }).toArray() : [];
    const cardByFixture = new Map(playedCards.map((card) => [card.target_fixture_id, card]));
    return res.json({ server_time: new Date(nowMs).toISOString(), competition: PREMIER_LEAGUE, simulation: simulation ? { id: simulation._id, league_id: simulation.league_id, phase: simulation.phase, current_week_index: simulation.current_week_index } : null, fixtures: fixtures.map((fixture) => fixtureResponse(fixture, picksByFixture.get(fixture._id), nowMs, (lockTimes.get(fixture.pick_week_id) || Infinity) <= nowMs, cardByFixture.get(fixture._id))) });
  });

  app.get(`${PREFIX}/me/picks`, authenticate, async (req, res) => {
    const query = { player_id: req.goalGuesser.player._id };
    if (req.query.pick_week_id) query.pick_week_id = String(req.query.pick_week_id);
    const picks = await req.goalGuesser.db.collection("gg_picks").find(query).sort({ updated_at: -1 }).toArray();
    return res.json({ picks });
  });

  app.put(`${PREFIX}/picks`, authenticate, async (req, res) => {
    await syncFixtures(getCanonicalMatches);
    const input = Array.isArray(req.body?.picks) ? req.body.picks : [];
    if (input.length < 1 || input.length > 50) return res.status(400).json({ error: "Provide between 1 and 50 picks" });
    const duplicatePowerWeeks = new Set();
    const requestedPowerWeeks = new Set();
    const db = req.goalGuesser.db;
    const fixtureIds = [...new Set(input.map((item) => String(item?.fixture_id || "")).filter(Boolean))];
    const fixtures = await db.collection("gg_fixtures").find({ _id: { $in: fixtureIds } }).toArray();
    const fixtureById = new Map(fixtures.map((fixture) => [fixture._id, fixture]));
    const simulationIds = [...new Set(fixtures.map((fixture) => fixture.simulation_id || "live"))];
    if (simulationIds.length > 1) return res.status(400).json({ error: "Save picks from one league context at a time" });
    const simulation = simulationIds[0] !== "live" ? await db.collection("gg_simulation_runs").findOne({ _id: simulationIds[0] }) : null;
    if (simulation && !await requireMembership(db, simulation.league_id, req.goalGuesser.player._id)) return res.status(403).json({ error: "Join that test league before saving predictions" });
    const requestNowMs = simulation ? Date.parse(simulation.current_time) : currentTimeMs();
    const requestedWeeks = [...new Set(fixtures.map((fixture) => fixture.pick_week_id).filter(Boolean))];
    const weekFixtures = requestedWeeks.length
      ? await db.collection("gg_fixtures").find(fixtureScopeQuery(simulation?._id, { pick_week_id: { $in: requestedWeeks } }), { projection: { pick_week_id: 1, kickoff_at: 1 } }).toArray()
      : [];
    const pickWeekLocks = pickWeekLockTimes(weekFixtures);
    for (const item of input) {
      const fixture = fixtureById.get(String(item?.fixture_id || ""));
      if (fixture && item?.power_pick === true) {
        if (requestedPowerWeeks.has(fixture.pick_week_id)) duplicatePowerWeeks.add(fixture.pick_week_id);
        requestedPowerWeeks.add(fixture.pick_week_id);
      }
    }
    const saved = [];
    const rejected = [];
    for (const item of input) {
      const fixtureId = String(item?.fixture_id || "");
      const fixture = fixtureById.get(fixtureId);
      const homeScore = Number(item?.home_score);
      const awayScore = Number(item?.away_score);
      if (!fixture || !Number.isInteger(homeScore) || !Number.isInteger(awayScore) || homeScore < 0 || awayScore < 0 || homeScore > MAX_SCORE || awayScore > MAX_SCORE) {
        metrics.picks_invalid += 1;
        rejected.push({ fixture_id: fixtureId, reason: "invalid" });
        continue;
      }
      if (simulation && (simulation.phase !== "open" || fixture.simulation_week !== simulation.current_week_index)) {
        metrics.picks_locked += 1;
        rejected.push({ fixture_id: fixtureId, reason: "locked" });
        continue;
      }
      if ((pickWeekLocks.get(fixture.pick_week_id) || Date.parse(fixture.kickoff_at)) <= requestNowMs) {
        metrics.picks_locked += 1;
        rejected.push({ fixture_id: fixtureId, reason: "locked" });
        continue;
      }
      if (item.power_pick === true && duplicatePowerWeeks.has(fixture.pick_week_id)) {
        rejected.push({ fixture_id: fixtureId, reason: "multiple_power_picks" });
        continue;
      }
      if (item.power_pick === true) {
        const existingPower = await db.collection("gg_picks").findOne({ player_id: req.goalGuesser.player._id, contest_id: fixture.contest_id, pick_week_id: fixture.pick_week_id, power_pick: true, fixture_id: { $ne: fixtureId } });
        if (existingPower) {
          const powerFixture = await db.collection("gg_fixtures").findOne({ _id: existingPower.fixture_id });
          if (powerFixture && Date.parse(powerFixture.kickoff_at) <= requestNowMs) {
            rejected.push({ fixture_id: fixtureId, reason: "power_pick_spent" });
            continue;
          }
          await db.collection("gg_picks").updateMany({ player_id: req.goalGuesser.player._id, contest_id: fixture.contest_id, pick_week_id: fixture.pick_week_id }, { $set: { power_pick: false } });
        }
      }
      const now = new Date().toISOString();
      try {
        await db.collection("gg_picks").updateOne(
          { player_id: req.goalGuesser.player._id, fixture_id: fixtureId },
          {
            $set: { home_score: homeScore, away_score: awayScore, power_pick: item.power_pick === true, pick_week_id: fixture.pick_week_id, contest_id: fixture.contest_id, updated_at: now },
            $setOnInsert: { _id: crypto.randomUUID(), player_id: req.goalGuesser.player._id, fixture_id: fixtureId, created_at: now },
            $unset: { points: "", base_points: "", score_tier: "", scored_result_revision: "", scored_at: "" },
          },
          { upsert: true }
        );
      } catch (error) {
        if (error?.code === 11000 && item.power_pick === true) {
          rejected.push({ fixture_id: fixtureId, reason: "multiple_power_picks" });
          continue;
        }
        throw error;
      }
      metrics.picks_saved += 1;
      saved.push({ fixture_id: fixtureId, saved_at: now });
    }
    return res.status(rejected.length > 0 && saved.length === 0 ? 409 : 200).json({ saved, rejected, server_time: new Date(requestNowMs).toISOString() });
  });

  app.get(`${PREFIX}/leagues`, authenticate, async (req, res) => {
    const memberships = await req.goalGuesser.db.collection("gg_memberships").find({ player_id: req.goalGuesser.player._id }).sort({ joined_at: 1 }).toArray();
    const leagues = await req.goalGuesser.db.collection("gg_leagues").find({ _id: { $in: memberships.map((item) => item.league_id) } }).toArray();
    const membershipByLeague = new Map(memberships.map((item) => [item.league_id, item]));
    return res.json({ leagues: leagues.map((league) => ({ id: league._id, name: league.name, join_code: league.join_code, archived: league.archived === true, owner_player_id: league.owner_player_id, role: membershipByLeague.get(league._id)?.role || "member", scoring_from: membershipByLeague.get(league._id)?.scoring_from || null, simulation_id: league.simulation_id || null })) });
  });

  app.post(`${PREFIX}/leagues`, authenticate, async (req, res) => {
    await syncFixtures(getCanonicalMatches);
    const name = normalizeLeagueName(req.body?.name);
    if (!name) return res.status(400).json({ error: "League name must be between 1 and 40 characters" });
    const db = req.goalGuesser.db;
    let joinCode = randomCrockford(6);
    while (await db.collection("gg_leagues").findOne({ join_code: joinCode })) joinCode = randomCrockford(6);
    const scoring = await nextOpenScoringStart(db);
    const now = new Date().toISOString();
    const league = { _id: crypto.randomUUID(), name, join_code: joinCode, owner_player_id: req.goalGuesser.player._id, archived: false, gameplay_rules_version: GAMEPLAY_RULES_VERSION, created_at: now, updated_at: now };
    await db.collection("gg_leagues").insertOne(league);
    await db.collection("gg_memberships").insertOne({ _id: crypto.randomUUID(), league_id: league._id, player_id: req.goalGuesser.player._id, role: "owner", joined_at: now, scoring_from: scoring.kickoff_at, scoring_from_pick_week_id: scoring.week });
    return res.status(201).json({ league: { id: league._id, name, join_code: joinCode, role: "owner", scoring_from: scoring.kickoff_at } });
  });

  app.post(`${PREFIX}/leagues/join`, authenticate, async (req, res) => {
    if (rateLimitsEnabled && !allowRate(`join:${requestAddress(req)}`, 30, 15 * 60 * 1000)) return res.status(429).json({ error: "Try again later" });
    await syncFixtures(getCanonicalMatches);
    const joinCode = normalizeText(req.body?.join_code).toUpperCase();
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ join_code: joinCode, archived: { $ne: true } });
    if (!league) {
      metrics.join_failures += 1;
      return res.status(404).json({ error: "League code was not found" });
    }
    const existing = await requireMembership(db, league._id, req.goalGuesser.player._id);
    if (existing) return res.json({ league: { id: league._id, name: league.name, join_code: league.join_code, role: existing.role } });
    const memberCount = await db.collection("gg_memberships").countDocuments({ league_id: league._id });
    if (memberCount >= MAX_MEMBERS) return res.status(409).json({ error: "League is full" });
    const simulation = await simulationForLeague(db, league);
    const scoring = await nextOpenScoringStart(db, simulation ? Date.parse(simulation.current_time) : currentTimeMs(), simulation?._id || null);
    const now = new Date().toISOString();
    await db.collection("gg_memberships").insertOne({ _id: crypto.randomUUID(), league_id: league._id, player_id: req.goalGuesser.player._id, role: "member", joined_at: now, scoring_from: scoring.kickoff_at, scoring_from_pick_week_id: scoring.week });
    return res.status(201).json({ league: { id: league._id, name: league.name, join_code: league.join_code, role: "member", scoring_from: scoring.kickoff_at, simulation_id: league.simulation_id || null } });
  });

  app.get(`${PREFIX}/leagues/:leagueId`, authenticate, async (req, res) => {
    const db = req.goalGuesser.db;
    const membership = await requireMembership(db, req.params.leagueId, req.goalGuesser.player._id);
    if (!membership) return res.status(404).json({ error: "League not found" });
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
    const members = await db.collection("gg_memberships").find({ league_id: req.params.leagueId }).sort({ joined_at: 1 }).toArray();
    const players = await db.collection("gg_players").find({ _id: { $in: members.map((item) => item.player_id) } }).toArray();
    const playerById = new Map(players.map((player) => [player._id, player]));
    return res.json({ league: { id: league._id, name: league.name, join_code: league.join_code, archived: league.archived === true, owner_player_id: league.owner_player_id, role: membership.role, simulation_id: league.simulation_id || null }, members: members.map((item) => publicLeagueMember(playerById.get(item.player_id), item)) });
  });

  app.put(`${PREFIX}/leagues/:leagueId/members/:playerId/team-logo`, authenticate, rawTeamLogo, logoRoute(async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId, owner_player_id: req.goalGuesser.player._id });
    if (!league) throw new TeamLogoStorageError("League owner access required", 403);
    const membership = await db.collection("gg_memberships").findOne({ league_id: league._id, player_id: req.params.playerId });
    const targetPlayer = membership ? await db.collection("gg_players").findOne({ _id: membership.player_id }) : null;
    if (!membership || !targetPlayer) throw new TeamLogoStorageError("League member was not found", 404);
    const asset = await storeLogoForTarget({ req, targetType: "league_membership", targetPlayer, membership, league });
    return res.status(201).json({ team_logo: teamLogoReference(asset._id), moderation_status: asset.moderation_status });
  }));

  app.delete(`${PREFIX}/leagues/:leagueId/members/:playerId/team-logo`, authenticate, logoRoute(async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId, owner_player_id: req.goalGuesser.player._id });
    if (!league) throw new TeamLogoStorageError("League owner access required", 403);
    const membership = await db.collection("gg_memberships").findOne({ league_id: league._id, player_id: req.params.playerId });
    if (!membership) throw new TeamLogoStorageError("League member was not found", 404);
    await db.collection("gg_memberships").updateOne(
      { _id: membership._id },
      { $unset: { team_logo_asset_id: "", team_logo_set_by_player_id: "", team_logo_set_at: "" } }
    );
    if (membership.team_logo_asset_id) await retireTeamLogoAssetIfUnreferenced(db, teamLogoStorage, membership.team_logo_asset_id);
    return res.status(204).end();
  }));

  app.patch(`${PREFIX}/leagues/:leagueId`, authenticate, async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId, owner_player_id: req.goalGuesser.player._id });
    if (!league) return res.status(403).json({ error: "League owner access required" });
    const update = { updated_at: new Date().toISOString() };
    if (Object.prototype.hasOwnProperty.call(req.body || {}, "name")) {
      const name = normalizeLeagueName(req.body.name);
      if (!name) return res.status(400).json({ error: "League name must be between 1 and 40 characters" });
      update.name = name;
    }
    if (typeof req.body?.archived === "boolean") update.archived = req.body.archived;
    await db.collection("gg_leagues").updateOne({ _id: league._id }, { $set: update });
    return res.json({ league: { id: league._id, name: update.name || league.name, join_code: league.join_code, archived: update.archived ?? league.archived } });
  });

  app.post(`${PREFIX}/leagues/:leagueId/join-code`, authenticate, async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId, owner_player_id: req.goalGuesser.player._id });
    if (!league) return res.status(403).json({ error: "League owner access required" });
    let joinCode = randomCrockford(6);
    while (await db.collection("gg_leagues").findOne({ join_code: joinCode })) joinCode = randomCrockford(6);
    await db.collection("gg_leagues").updateOne({ _id: league._id }, { $set: { join_code: joinCode, updated_at: new Date().toISOString() } });
    return res.json({ join_code: joinCode });
  });

  app.delete(`${PREFIX}/leagues/:leagueId/members/:playerId`, authenticate, async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId, owner_player_id: req.goalGuesser.player._id });
    if (!league) return res.status(403).json({ error: "League owner access required" });
    if (req.params.playerId === league.owner_player_id) return res.status(409).json({ error: "Transfer ownership before leaving" });
    const membership = await db.collection("gg_memberships").findOne({ league_id: league._id, player_id: req.params.playerId });
    await db.collection("gg_memberships").deleteOne({ league_id: league._id, player_id: req.params.playerId });
    if (membership?.team_logo_asset_id) await retireTeamLogoAssetIfUnreferenced(db, teamLogoStorage, membership.team_logo_asset_id);
    return res.status(204).end();
  });

  app.post(`${PREFIX}/leagues/:leagueId/transfer-owner`, authenticate, async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId, owner_player_id: req.goalGuesser.player._id });
    const nextOwner = normalizeText(req.body?.player_id);
    const membership = league && nextOwner ? await requireMembership(db, league._id, nextOwner) : null;
    if (!league) return res.status(403).json({ error: "League owner access required" });
    if (!membership) return res.status(400).json({ error: "New owner must be a league member" });
    await db.collection("gg_leagues").updateOne({ _id: league._id }, { $set: { owner_player_id: nextOwner, updated_at: new Date().toISOString() } });
    await db.collection("gg_memberships").updateMany({ league_id: league._id }, [{ $set: { role: { $cond: [{ $eq: ["$player_id", nextOwner] }, "owner", "member"] } } }]);
    return res.json({ owner_player_id: nextOwner });
  });

  app.post(`${PREFIX}/leagues/:leagueId/leave`, authenticate, async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
    if (!league) return res.status(404).json({ error: "League not found" });
    if (league.owner_player_id === req.goalGuesser.player._id) return res.status(409).json({ error: "Transfer ownership before leaving" });
    const membership = await db.collection("gg_memberships").findOne({ league_id: league._id, player_id: req.goalGuesser.player._id });
    await db.collection("gg_memberships").deleteOne({ league_id: league._id, player_id: req.goalGuesser.player._id });
    if (membership?.team_logo_asset_id) await retireTeamLogoAssetIfUnreferenced(db, teamLogoStorage, membership.team_logo_asset_id);
    return res.status(204).end();
  });

  app.get(`${PREFIX}/leagues/:leagueId/leaderboard`, authenticate, async (req, res) => {
    await syncFixtures(getCanonicalMatches);
    const db = req.goalGuesser.db;
    const viewerMembership = await requireMembership(db, req.params.leagueId, req.goalGuesser.player._id);
    if (!viewerMembership) return res.status(404).json({ error: "League not found" });
    const gameplay = await loadLeagueGameplay(db, req.params.leagueId, req.goalGuesser.player._id);
    return res.json({ leaderboard: gameplay.summary.leaderboard });
  });

  app.get(`${PREFIX}/leagues/:leagueId/gameplay`, authenticate, async (req, res) => {
    await syncFixtures(getCanonicalMatches);
    const db = req.goalGuesser.db;
    const viewerMembership = await requireMembership(db, req.params.leagueId, req.goalGuesser.player._id);
    if (!viewerMembership) return res.status(404).json({ error: "League not found" });
    const gameplay = await loadLeagueGameplay(db, req.params.leagueId, req.goalGuesser.player._id);
    return res.json(gameplay.summary);
  });

  app.get(`${PREFIX}/wildcards`, authenticate, async (req, res) => {
    await syncFixtures(getCanonicalMatches);
    const leagueId = normalizeText(req.query.league_id);
    if (leagueId && !await requireMembership(req.goalGuesser.db, leagueId, req.goalGuesser.player._id)) return res.status(404).json({ error: "League not found" });
    const wildcardState = await loadPlayerWildcards(req.goalGuesser.db, req.goalGuesser.player._id, leagueId || null);
    return res.json({ wildcards: wildcardState.cards.map(publicCard) });
  });

  app.post(`${PREFIX}/wildcards/:cardId/play`, authenticate, async (req, res) => {
    await syncFixtures(getCanonicalMatches);
    const db = req.goalGuesser.db;
    const card = await db.collection("gg_wildcards").findOne({ _id: req.params.cardId, player_id: req.goalGuesser.player._id });
    const fixtureId = normalizeText(req.body?.fixture_id);
    const fixture = fixtureId ? await db.collection("gg_fixtures").findOne({ _id: fixtureId, ...fixtureScopeQuery(card?.simulation_id || null) }) : null;
    const simulation = card?.simulation_id ? await db.collection("gg_simulation_runs").findOne({ _id: card.simulation_id }) : null;
    const nowMs = simulation ? Date.parse(simulation.current_time) : currentTimeMs();
    if (!card || !CARD_TYPES.has(card.type)) return res.status(404).json({ error: "Card not found" });
    if (card.status !== "available" && card.status !== "played") return res.status(409).json({ error: "That card is no longer available" });
    if (simulation && (simulation.phase !== "open" || fixture?.simulation_week !== simulation.current_week_index)) return res.status(409).json({ error: "Choose a fixture from the open test scorecard" });
    if (!fixture || !monthlyChampionships(await db.collection("gg_fixtures").find(fixtureScopeQuery(card.simulation_id || null)).toArray()).find((month) => month.id === card.month_id)?.weeks.includes(fixture.pick_week_id)) return res.status(400).json({ error: "Choose a fixture this month" });
    const weekFixtures = await db.collection("gg_fixtures").find(fixtureScopeQuery(card.simulation_id || null, { pick_week_id: fixture.pick_week_id })).toArray();
    if ((pickWeekLockTimes(weekFixtures).get(fixture.pick_week_id) || Date.parse(fixture.kickoff_at)) <= nowMs) return res.status(409).json({ error: "That scorecard is locked" });
    if (card.expires_at && Date.parse(card.expires_at) <= nowMs) return res.status(409).json({ error: "That card has expired" });
    const pick = await db.collection("gg_picks").findOne({ player_id: req.goalGuesser.player._id, fixture_id: fixture._id });
    if (!pick) return res.status(409).json({ error: "Save a prediction for that fixture first" });
    if (pick.power_pick === true) return res.status(409).json({ error: "Power Cards cannot stack with Double Down" });
    const occupied = await db.collection("gg_wildcards").findOne({ player_id: req.goalGuesser.player._id, league_id: card.league_id ?? null, status: "played", target_fixture_id: fixture._id, _id: { $ne: card._id } });
    if (occupied) return res.status(409).json({ error: "Another card already targets that fixture" });
    const now = new Date().toISOString();
    await db.collection("gg_wildcards").updateOne({ _id: card._id }, { $set: { status: "played", target_fixture_id: fixture._id, played_at: now, updated_at: now } });
    return res.json({ card: publicCard({ ...card, status: "played", target_fixture_id: fixture._id }) });
  });

  app.delete(`${PREFIX}/wildcards/:cardId/play`, authenticate, async (req, res) => {
    const db = req.goalGuesser.db;
    const card = await db.collection("gg_wildcards").findOne({ _id: req.params.cardId, player_id: req.goalGuesser.player._id, status: "played" });
    if (!card) return res.status(404).json({ error: "Played card not found" });
    const fixture = await db.collection("gg_fixtures").findOne({ _id: card.target_fixture_id });
    const simulation = card.simulation_id ? await db.collection("gg_simulation_runs").findOne({ _id: card.simulation_id }) : null;
    const nowMs = simulation ? Date.parse(simulation.current_time) : currentTimeMs();
    const weekFixtures = fixture ? await db.collection("gg_fixtures").find(fixtureScopeQuery(card.simulation_id || null, { pick_week_id: fixture.pick_week_id })).toArray() : [];
    if (!fixture || (pickWeekLockTimes(weekFixtures).get(fixture.pick_week_id) || Date.parse(fixture.kickoff_at)) <= nowMs) return res.status(409).json({ error: "That scorecard is locked" });
    await db.collection("gg_wildcards").updateOne({ _id: card._id }, { $set: { status: "available", updated_at: new Date().toISOString() }, $unset: { target_fixture_id: "", played_at: "" } });
    return res.status(204).end();
  });

  app.get(`${PREFIX}/leagues/:leagueId/picks`, authenticate, async (req, res) => {
    await syncFixtures(getCanonicalMatches);
    const db = req.goalGuesser.db;
    const viewerMembership = await requireMembership(db, req.params.leagueId, req.goalGuesser.player._id);
    if (!viewerMembership) return res.status(404).json({ error: "League not found" });
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
    const simulation = await simulationForLeague(db, league);
    const pickWeekId = normalizeText(req.query.pick_week_id);
    if (!pickWeekId) return res.status(400).json({ error: "pick_week_id is required" });
    const fixtures = await db.collection("gg_fixtures").find(fixtureScopeQuery(simulation?._id, { pick_week_id: pickWeekId })).sort({ kickoff_at: 1 }).toArray();
    const members = await db.collection("gg_memberships").find({ league_id: req.params.leagueId }).toArray();
    const players = await db.collection("gg_players").find({ _id: { $in: members.map((item) => item.player_id) } }).toArray();
    const names = new Map(players.map((player) => [player._id, player.name]));
    const playerById = new Map(players.map((player) => [player._id, player]));
    const picks = await db.collection("gg_picks").find({ player_id: { $in: members.map((item) => item.player_id) }, fixture_id: { $in: fixtures.map((item) => item._id) } }).toArray();
    const now = simulation ? Date.parse(simulation.current_time) : currentTimeMs();
    const weekLocked = (pickWeekLockTimes(fixtures).get(pickWeekId) || Infinity) <= now;
    return res.json({
      fixtures: fixtures.map((fixture) => fixtureResponse(fixture, null, now, weekLocked)),
      members: members.map((member) => ({
        player_id: member.player_id,
        name: names.get(member.player_id) || "Former player",
        team_name: playerById.get(member.player_id)?.team_name || null,
        team_logo: resolvedTeamLogoReference(playerById.get(member.player_id), member),
        picks: fixtures.map((fixture) => {
          const pick = picks.find((item) => item.player_id === member.player_id && item.fixture_id === fixture._id);
          const reveal = member.player_id === req.goalGuesser.player._id || weekLocked;
          return {
            fixture_id: fixture._id,
            submitted: Boolean(pick),
            home_score: reveal && pick ? pick.home_score : null,
            away_score: reveal && pick ? pick.away_score : null,
            power_pick: reveal && pick ? pick.power_pick === true : false,
            points: reveal && pick && Number.isInteger(pick.points) ? pick.points : null,
          };
        }),
      })),
    });
  });

  app.get(`${PREFIX}/admin/team-logos/:assetId`, authenticate, requireAdmin, logoRoute(async (req, res) => {
    const asset = await req.goalGuesser.db.collection("gg_image_assets").findOne({ _id: req.params.assetId, kind: "team_logo" });
    if (!asset) throw new TeamLogoStorageError("Team logo review was not found", 404);
    return res.json({
      asset: {
        id: asset._id,
        target_type: asset.target_type,
        target_player_id: asset.target_player_id,
        target_player_name: asset.target_player_name,
        target_team_name: asset.target_team_name || null,
        league_id: asset.league_id,
        league_name: asset.league_name,
        uploaded_by_player_id: asset.uploaded_by_player_id,
        uploaded_by_name: asset.uploaded_by_name,
        moderation_status: asset.moderation_status,
        storage_status: asset.storage_status,
        created_at: asset.created_at,
        reviewed_at: asset.reviewed_at || null,
        team_logo: asset.storage_status === "stored" && asset.moderation_status !== "rejected" ? teamLogoReference(asset._id) : null,
      },
    });
  }));

  app.post(`${PREFIX}/admin/team-logos/:assetId/approve`, authenticate, requireAdmin, logoRoute(async (req, res) => {
    const now = new Date().toISOString();
    const result = await req.goalGuesser.db.collection("gg_image_assets").updateOne(
      { _id: req.params.assetId, kind: "team_logo", moderation_status: { $ne: "rejected" } },
      { $set: { moderation_status: "approved", reviewed_at: now, reviewed_by_player_id: req.goalGuesser.player._id, updated_at: now } }
    );
    if (result.matchedCount !== 1) throw new TeamLogoStorageError("Team logo review was not found", 404);
    return res.json({ moderation_status: "approved", reviewed_at: now });
  }));

  app.post(`${PREFIX}/admin/team-logos/:assetId/reject`, authenticate, requireAdmin, logoRoute(async (req, res) => {
    const db = req.goalGuesser.db;
    const asset = await db.collection("gg_image_assets").findOne({ _id: req.params.assetId, kind: "team_logo" });
    if (!asset) throw new TeamLogoStorageError("Team logo review was not found", 404);
    if (asset.moderation_status !== "rejected") {
      await Promise.all([
        db.collection("gg_players").updateMany({ team_logo_asset_id: asset._id }, { $unset: { team_logo_asset_id: "" }, $set: { updated_at: new Date().toISOString() } }),
        db.collection("gg_memberships").updateMany({ team_logo_asset_id: asset._id }, { $unset: { team_logo_asset_id: "", team_logo_set_by_player_id: "", team_logo_set_at: "" } }),
      ]);
      await teamLogoStorage.remove(asset.variants);
      const now = new Date().toISOString();
      await db.collection("gg_image_assets").updateOne({ _id: asset._id }, { $set: { moderation_status: "rejected", storage_status: "deleted", reviewed_at: now, reviewed_by_player_id: req.goalGuesser.player._id, rejection_reason: "unsuitable", updated_at: now } });
    }
    return res.json({ moderation_status: "rejected" });
  }));

  app.get(`${PREFIX}/admin/leagues`, authenticate, requireAdmin, async (req, res) => {
    const db = req.goalGuesser.db;
    const leagues = await db.collection("gg_leagues").find({}).sort({ created_at: -1 }).toArray();
    const counts = await Promise.all(leagues.map((league) => db.collection("gg_memberships").countDocuments({ league_id: league._id })));
    const runs = await db.collection("gg_simulation_runs").find({ league_id: { $in: leagues.map((league) => league._id) } }).toArray();
    const runByLeague = new Map(runs.map((run) => [run.league_id, run]));
    return res.json({ leagues: leagues.map((league, index) => {
      const run = runByLeague.get(league._id);
      return { id: league._id, name: league.name, archived: league.archived === true, member_count: counts[index], simulation: run ? { id: run._id, phase: run.phase, status: run.status, current_week_index: run.current_week_index, total_weeks: run.weeks.length } : null };
    }) });
  });

  app.post(`${PREFIX}/admin/leagues/:leagueId/simulation`, authenticate, requireAdmin, async (req, res) => {
    await syncFixtures(getCanonicalMatches);
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
    if (!league) return res.status(404).json({ error: "League not found" });
    if (league.simulation_id) return res.status(409).json({ error: "This league already has a test season" });
    const seed = Number.isInteger(Number(req.body?.seed)) ? Number(req.body.seed) : 20260801;
    let generated;
    try {
      const canonicalFixtures = await upcomingCanonicalSeasonFixtures(db);
      generated = generateSimulationSeasonFromFixtures({ fixtures: canonicalFixtures, seed });
    } catch (error) {
      return res.status(400).json({ error: error.message || "The test season could not be created" });
    }
    const firstKickoff = Math.min(...generated.fixtures.map((fixture) => Date.parse(fixture.kickoff_at)));
    const currentTime = new Date(firstKickoff - 12 * 60 * 60 * 1000).toISOString();
    const now = new Date().toISOString();
    const run = { _id: generated.runId, league_id: league._id, contest_id: generated.contestId, season_key: generated.seasonKey, seed, status: "active", phase: "open", current_week_index: 1, current_time: currentTime, weeks: generated.weeks, version: 1, created_by: req.goalGuesser.player._id, created_at: now, updated_at: now };
    const claimed = await db.collection("gg_leagues").updateOne({ _id: league._id, simulation_id: { $exists: false } }, { $set: { simulation_id: run._id, updated_at: now } });
    if (claimed.modifiedCount !== 1) return res.status(409).json({ error: "This league already has a test season" });
    try {
      await db.collection("gg_contests").insertOne({ _id: generated.contestId, competition_key: `premier-league-simulation:${generated.runId}`, competition_name: PREMIER_LEAGUE, season_key: generated.seasonKey, game_type: GAME_TYPE, scoring_version: SCORING_VERSION, result_basis: "normal_time", simulation_id: generated.runId, created_at: now, updated_at: now });
      await db.collection("gg_fixtures").insertMany(generated.fixtures);
      await db.collection("gg_simulation_runs").insertOne(run);
      await recordAdminEvent(db, req.goalGuesser.player, league._id, run._id, "simulation_created", { seed, source: "canonical_fixtures", first_pick_week_id: generated.startDate, fixture_count: generated.fixtures.length });
      await db.collection("gg_memberships").updateMany({ league_id: league._id }, { $set: { scoring_from: new Date(firstKickoff).toISOString(), scoring_from_pick_week_id: generated.weeks[0].pick_week_id } });
    } catch (error) {
      await Promise.all([
        db.collection("gg_leagues").updateOne({ _id: league._id, simulation_id: run._id }, { $unset: { simulation_id: "" }, $set: { updated_at: new Date().toISOString() } }),
        db.collection("gg_simulation_runs").deleteOne({ _id: run._id }),
        db.collection("gg_fixtures").deleteMany({ simulation_id: run._id }),
        db.collection("gg_contests").deleteOne({ _id: generated.contestId }),
        db.collection("gg_admin_audit_events").deleteMany({ simulation_id: run._id }),
      ]);
      throw error;
    }
    return res.status(201).json(await adminLeagueState(db, league._id));
  });

  app.post(`${PREFIX}/admin/leagues/:leagueId/simulation/restart`, authenticate, requireAdmin, async (req, res) => {
    try {
      await syncFixtures(getCanonicalMatches);
      const db = req.goalGuesser.db;
      const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
      const previousRun = await simulationForLeague(db, league);
      if (!league) return res.status(404).json({ error: "League not found" });
      if (!previousRun) return res.status(404).json({ error: "Test season not found" });
      const seed = Number.isInteger(Number(req.body?.seed)) ? Number(req.body.seed) : previousRun.seed;
      const canonicalFixtures = await upcomingCanonicalSeasonFixtures(db);
      const generated = generateSimulationSeasonFromFixtures({ fixtures: canonicalFixtures, seed, runId: previousRun._id });
      const firstKickoff = Math.min(...generated.fixtures.map((fixture) => Date.parse(fixture.kickoff_at)));
      const currentTime = new Date(firstKickoff - 12 * 60 * 60 * 1000).toISOString();
      const now = new Date().toISOString();
      const previousFixtures = await db.collection("gg_fixtures").find({ simulation_id: previousRun._id }).toArray();

      await db.collection("gg_fixtures").deleteMany({ simulation_id: previousRun._id });
      try {
        await db.collection("gg_fixtures").insertMany(generated.fixtures);
      } catch (error) {
        await db.collection("gg_fixtures").deleteMany({ simulation_id: previousRun._id });
        if (previousFixtures.length) await db.collection("gg_fixtures").insertMany(previousFixtures);
        throw error;
      }

      await db.collection("gg_contests").updateOne(
        { _id: generated.contestId },
        {
          $set: { competition_key: `premier-league-simulation:${previousRun._id}`, competition_name: PREMIER_LEAGUE, season_key: generated.seasonKey, game_type: GAME_TYPE, scoring_version: SCORING_VERSION, result_basis: "normal_time", simulation_id: previousRun._id, updated_at: now },
          $setOnInsert: { created_at: now },
        },
        { upsert: true }
      );
      await db.collection("gg_simulation_runs").updateOne(
        { _id: previousRun._id, league_id: league._id },
        { $set: { contest_id: generated.contestId, season_key: generated.seasonKey, seed, status: "active", phase: "open", current_week_index: 1, current_time: currentTime, weeks: generated.weeks, created_by: req.goalGuesser.player._id, updated_at: now }, $inc: { version: 1 } }
      );
      await Promise.all([
        db.collection("gg_picks").deleteMany({ fixture_id: { $in: previousFixtures.map((fixture) => fixture._id) } }),
        db.collection("gg_wildcards").deleteMany({ league_id: league._id }),
        db.collection("gg_memberships").updateMany({ league_id: league._id }, { $set: { scoring_from: new Date(firstKickoff).toISOString(), scoring_from_pick_week_id: generated.weeks[0].pick_week_id } }),
      ]);
      await recordAdminEvent(db, req.goalGuesser.player, league._id, previousRun._id, "simulation_restarted", { seed, source: "canonical_fixtures", first_pick_week_id: generated.startDate, fixture_count: generated.fixtures.length });
      return res.json(await adminLeagueState(db, league._id));
    } catch (error) {
      console.error("goal_guesser_simulation_rebuild_failed", { league_id: req.params.leagueId, message: error.message });
      return res.status(500).json({ error: "The fixture schedule could not be rebuilt. The existing test season is unchanged." });
    }
  });

  app.get(`${PREFIX}/admin/leagues/:leagueId/simulation`, authenticate, requireAdmin, async (req, res) => {
    const state = await adminLeagueState(req.goalGuesser.db, req.params.leagueId);
    return state ? res.json(state) : res.status(404).json({ error: "League not found" });
  });

  app.post(`${PREFIX}/admin/leagues/:leagueId/simulation/lock`, authenticate, requireAdmin, async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
    const run = await simulationForLeague(db, league);
    if (!run) return res.status(404).json({ error: "Test season not found" });
    if (run.phase !== "open") return res.status(409).json({ error: "Only an open scorecard can be locked" });
    const week = run.weeks[run.current_week_index - 1];
    const fixtures = await db.collection("gg_fixtures").find(fixtureScopeQuery(run._id, { pick_week_id: week.pick_week_id })).toArray();
    const lockTime = new Date(Math.min(...fixtures.map((fixture) => Date.parse(fixture.kickoff_at))) + 60 * 1000).toISOString();
    const updated = await db.collection("gg_simulation_runs").updateOne({ _id: run._id, phase: "open", version: run.version }, { $set: { phase: "locked", current_time: lockTime, updated_at: new Date().toISOString() }, $inc: { version: 1 } });
    if (updated.modifiedCount !== 1) return res.status(409).json({ error: "The scorecard changed. Refresh and try again." });
    await recordAdminEvent(db, req.goalGuesser.player, league._id, run._id, "scorecard_locked", { week: run.current_week_index, pick_week_id: week.pick_week_id });
    return res.json(await adminLeagueState(db, league._id));
  });

  app.post(`${PREFIX}/admin/leagues/:leagueId/simulation/results/randomise`, authenticate, requireAdmin, async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
    const run = await simulationForLeague(db, league);
    if (!run) return res.status(404).json({ error: "Test season not found" });
    if (!new Set(["locked", "results_ready"]).has(run.phase)) return res.status(409).json({ error: "Lock the scorecard before generating results" });
    const week = run.weeks[run.current_week_index - 1];
    const fixtures = await db.collection("gg_fixtures").find(fixtureScopeQuery(run._id, { pick_week_id: week.pick_week_id })).sort({ kickoff_at: 1 }).toArray();
    const seed = Number.isInteger(Number(req.body?.seed)) ? Number(req.body.seed) : run.seed ^ (run.current_week_index * 0x9e3779b1);
    return res.json({ seed, results: realisticResults(fixtures, seed) });
  });

  app.put(`${PREFIX}/admin/leagues/:leagueId/simulation/results`, authenticate, requireAdmin, async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
    const run = await simulationForLeague(db, league);
    if (!run) return res.status(404).json({ error: "Test season not found" });
    if (!new Set(["locked", "results_ready"]).has(run.phase)) return res.status(409).json({ error: "Lock the scorecard before entering results" });
    const week = run.weeks[run.current_week_index - 1];
    const fixtures = await db.collection("gg_fixtures").find(fixtureScopeQuery(run._id, { pick_week_id: week.pick_week_id })).toArray();
    const results = parseAdminResults(req.body?.results, fixtures);
    if (!results) return res.status(400).json({ error: `Enter a valid score for all ${fixtures.length} fixtures` });
    const now = new Date().toISOString();
    await db.collection("gg_fixtures").bulkWrite(results.map((result) => ({ updateOne: { filter: { _id: result.fixture_id, simulation_id: run._id }, update: { $set: { proposed_home_score: result.home_score, proposed_away_score: result.away_score, updated_at: now } } } })), { ordered: false });
    await db.collection("gg_simulation_runs").updateOne({ _id: run._id }, { $set: { phase: "results_ready", updated_at: now }, $inc: { version: 1 } });
    await recordAdminEvent(db, req.goalGuesser.player, league._id, run._id, "results_saved", { week: run.current_week_index });
    return res.json(await adminLeagueState(db, league._id));
  });

  app.post(`${PREFIX}/admin/leagues/:leagueId/simulation/settle`, authenticate, requireAdmin, async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
    const run = await simulationForLeague(db, league);
    if (!run) return res.status(404).json({ error: "Test season not found" });
    if (run.phase !== "results_ready") return res.status(409).json({ error: "Save every result before scoring the gameweek" });
    const claimed = await db.collection("gg_simulation_runs").updateOne({ _id: run._id, phase: "results_ready", version: run.version }, { $set: { phase: "settling", updated_at: new Date().toISOString() }, $inc: { version: 1 } });
    if (claimed.modifiedCount !== 1) return res.status(409).json({ error: "The gameweek is already being scored" });
    const week = run.weeks[run.current_week_index - 1];
    const fixtures = await db.collection("gg_fixtures").find(fixtureScopeQuery(run._id, { pick_week_id: week.pick_week_id })).toArray();
    const settledAt = new Date(Math.max(...fixtures.map((fixture) => Date.parse(fixture.kickoff_at))) + 3 * 60 * 60 * 1000).toISOString();
    try {
      for (const fixture of fixtures) {
        const revisionNumber = Number(fixture.admin_result_revision || 0) + 1;
        const revision = resultRevision(fixture._id, fixture.proposed_home_score, fixture.proposed_away_score, revisionNumber);
        const settled = { ...fixture, status: "FT", home_score: fixture.proposed_home_score, away_score: fixture.proposed_away_score, result_revision: revision, admin_result_revision: revisionNumber };
        await db.collection("gg_fixtures").updateOne({ _id: fixture._id }, { $set: { status: "FT", home_score: settled.home_score, away_score: settled.away_score, result_revision: revision, admin_result_revision: revisionNumber, updated_at: new Date().toISOString() } });
        await settleFixture(db, settled);
      }
    } catch (error) {
      await db.collection("gg_simulation_runs").updateOne({ _id: run._id, phase: "settling" }, { $set: { phase: "results_ready", updated_at: new Date().toISOString() }, $inc: { version: 1 } });
      throw error;
    }
    await db.collection("gg_simulation_runs").updateOne({ _id: run._id, phase: "settling" }, { $set: { phase: "settled", current_time: settledAt, updated_at: new Date().toISOString() }, $inc: { version: 1 } });
    await recordAdminEvent(db, req.goalGuesser.player, league._id, run._id, "gameweek_scored", { week: run.current_week_index, fixture_count: fixtures.length });
    return res.json(await adminLeagueState(db, league._id));
  });

  app.post(`${PREFIX}/admin/leagues/:leagueId/simulation/advance`, authenticate, requireAdmin, async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
    const run = await simulationForLeague(db, league);
    if (!run) return res.status(404).json({ error: "Test season not found" });
    if (run.phase !== "settled") return res.status(409).json({ error: "Score this gameweek before opening the next one" });
    const complete = run.current_week_index >= run.weeks.length;
    const nextIndex = complete ? run.current_week_index : run.current_week_index + 1;
    let nextTime = run.current_time;
    if (!complete) {
      const nextWeek = run.weeks[nextIndex - 1];
      const fixtures = await db.collection("gg_fixtures").find(fixtureScopeQuery(run._id, { pick_week_id: nextWeek.pick_week_id })).toArray();
      nextTime = new Date(Math.min(...fixtures.map((fixture) => Date.parse(fixture.kickoff_at))) - 12 * 60 * 60 * 1000).toISOString();
    }
    const nextPhase = complete ? "completed" : "open";
    const updated = await db.collection("gg_simulation_runs").updateOne({ _id: run._id, phase: "settled", version: run.version }, { $set: { phase: nextPhase, status: complete ? "completed" : "active", current_week_index: nextIndex, current_time: nextTime, updated_at: new Date().toISOString() }, $inc: { version: 1 } });
    if (updated.modifiedCount !== 1) return res.status(409).json({ error: "The gameweek changed. Refresh and try again." });
    await recordAdminEvent(db, req.goalGuesser.player, league._id, run._id, complete ? "season_completed" : "gameweek_opened", { week: nextIndex });
    return res.json(await adminLeagueState(db, league._id));
  });

  app.put(`${PREFIX}/admin/leagues/:leagueId/simulation/fixtures/:fixtureId/result`, authenticate, requireAdmin, async (req, res) => {
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
    const run = await simulationForLeague(db, league);
    const fixture = run ? await db.collection("gg_fixtures").findOne({ _id: req.params.fixtureId, simulation_id: run._id, result_revision: { $ne: null } }) : null;
    const homeScore = Number(req.body?.home_score);
    const awayScore = Number(req.body?.away_score);
    if (!fixture) return res.status(404).json({ error: "Settled test fixture not found" });
    if (![homeScore, awayScore].every((score) => Number.isInteger(score) && score >= 0 && score <= MAX_SCORE)) return res.status(400).json({ error: "Scores must be whole numbers between 0 and 20" });
    const revisionNumber = Number(fixture.admin_result_revision || 0) + 1;
    const revision = resultRevision(fixture._id, homeScore, awayScore, revisionNumber);
    const settled = { ...fixture, home_score: homeScore, away_score: awayScore, proposed_home_score: homeScore, proposed_away_score: awayScore, result_revision: revision, admin_result_revision: revisionNumber };
    await db.collection("gg_fixtures").updateOne({ _id: fixture._id }, { $set: { home_score: homeScore, away_score: awayScore, proposed_home_score: homeScore, proposed_away_score: awayScore, result_revision: revision, admin_result_revision: revisionNumber, updated_at: new Date().toISOString() } });
    await settleFixture(db, settled);
    await recordAdminEvent(db, req.goalGuesser.player, league._id, run._id, "result_corrected", { fixture_id: fixture._id, home_score: homeScore, away_score: awayScore });
    return res.json(await adminLeagueState(db, league._id));
  });

  app.post(`${PREFIX}/admin/leagues/:leagueId/simulation/events/:eventType`, authenticate, requireAdmin, async (req, res) => {
    const allowed = new Set(["prediction_reminder_requested", "weekly_summary_requested"]);
    if (!allowed.has(req.params.eventType)) return res.status(400).json({ error: "That test event is not supported" });
    const db = req.goalGuesser.db;
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
    const run = await simulationForLeague(db, league);
    if (!run) return res.status(404).json({ error: "Test season not found" });
    const event = await recordAdminEvent(db, req.goalGuesser.player, league._id, run._id, req.params.eventType, { week: run.current_week_index, delivery: "recorded_only" });
    return res.status(202).json({ event: { id: event._id, type: event.action, delivery: "recorded_only" }, message: "Trigger recorded. No email handler is configured yet." });
  });

  app.get(`${PREFIX}/metrics`, authenticate, (_req, res) => res.json({ ...metrics, last_fixture_sync_at: lastFixtureSyncAtMs ? new Date(lastFixtureSyncAtMs).toISOString() : null }));
}

module.exports = {
  registerGoalGuesserRoutes,
  scorePrediction,
  pickWeekIdForDate,
  seasonKeyForDate,
  isFinalStatus,
  __private: {
    normalizeName,
    normalizeTeamName,
    normalizeEmail,
    configureAdminEmails,
    isAdminPlayer,
    requireAdmin,
    liveFixtureQuery,
    fixtureScopeQuery,
    sendPlunkEmail,
    teamLogoReference,
    resolvedTeamLogoReference,
    publicLeagueMember,
    deliverTeamLogoModerationEmail,
    normalizeLeagueName,
    integerScore,
    isPremierLeagueMatch,
    rankLeaderboard,
    basePointsForPick,
    cardPointsForPick,
    monthlyChampionships,
    completedWeeks,
    momentumForMembership,
    gameplayRows,
    gameplaySummary,
    weeklyPerformanceBadges,
    rivalDuels,
    currentTimeMs,
    setGoalGuesserTestNow,
    secretDigest,
    secretMatches,
    parseCredential,
    fixtureResponse,
    pickWeekLockTimes,
  },
};
