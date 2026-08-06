"use strict";

const crypto = require("crypto");
const { getDb } = require("./mongo_client");
const { zonedDateTimeToUtcMs } = require("./match_time");

const PREFIX = "/api/v1/goal-guesser";
const PREMIER_LEAGUE = "Premier League";
const GAME_TYPE = "score-picks";
const SCORING_VERSION = 1;
const MAX_MEMBERS = 50;
const MAX_SCORE = 20;
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const TERMINAL_STATUSES = new Set(["ft", "full time", "finished", "aet", "pens"]);
const EMAIL_CODE_TTL_MS = 10 * 60 * 1000;
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
};

const rateBuckets = new Map();
let lastFixtureSyncAtMs = 0;
let fixtureSyncPromise = null;
let goalGuesserTestNowMs = null;
const jwksCache = new Map();

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

function normalizeEmail(value) {
  const email = normalizeText(value).toLowerCase();
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  return email;
}

function csvEnvironment(name) {
  const fallback = name === "GOAL_GUESSER_GOOGLE_CLIENT_IDS" ? process.env.GOOGLE_CLIENT_ID_WEBSITE_GOAL_GUESSER : "";
  return String(process.env[name] || fallback || "").split(",").map(normalizeText).filter(Boolean);
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

function fixtureResponse(fixture, pick = null, nowMs = currentTimeMs(), pickWeekLocked = null) {
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
    pick: pick
      ? {
          home_score: pick.home_score,
          away_score: pick.away_score,
          power_pick: pick.power_pick === true,
          points: Number.isInteger(pick.points) ? pick.points : null,
          score_tier: pick.score_tier || null,
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

function publicPlayer(player) {
  return {
    id: player._id,
    name: player.name,
    email: player.email || null,
    email_verified: player.email_verified === true,
    email_notifications_enabled: player.email_notifications_enabled === true,
    auth_providers: Array.isArray(player.auth_providers) ? player.auth_providers : [],
    created_at: player.created_at,
    updated_at: player.updated_at,
  };
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
    if (pick.scored_result_revision && pick.scored_result_revision !== fixture.result_revision) metrics.results_rescored += 1;
    return {
      updateOne: {
        filter: { _id: pick._id },
        update: {
          $set: {
            points: score.points,
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
    const finalFixtures = await db.collection("gg_fixtures").find({ competition: PREMIER_LEAGUE, result_revision: { $ne: null } }).toArray();
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

async function nextOpenScoringStart(db, nowMs = currentTimeMs()) {
  const fixtures = await db.collection("gg_fixtures").find({ competition: PREMIER_LEAGUE }).sort({ kickoff_at: 1 }).toArray();
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

function registerGoalGuesserRoutes(app, options = {}) {
  const enabled = options.enabled === true;
  const rateLimitsEnabled = options.disableRateLimits !== true;
  const getCanonicalMatches = options.getCanonicalMatches;
  if (typeof getCanonicalMatches !== "function") throw new Error("getCanonicalMatches is required");

  app.use(PREFIX, (req, res, next) => {
    if (!enabled) return res.status(404).json({ error: "Goal Guesser is not enabled" });
    res.set("Cache-Control", "no-store");
    return next();
  });

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
    const hasNotifications = Object.prototype.hasOwnProperty.call(req.body || {}, "email_notifications_enabled");
    const name = hasName ? normalizeName(req.body?.name) : req.goalGuesser.player.name;
    if (hasName && !name) return res.status(400).json({ error: "Name must be between 1 and 32 characters" });
    if (!hasName && !hasNotifications) return res.status(400).json({ error: "No profile changes were provided" });
    if (hasNotifications && req.body?.email_notifications_enabled === true && !req.goalGuesser.player.email_verified) {
      return res.status(409).json({ error: "Verify an email address before enabling reminders" });
    }
    const now = new Date().toISOString();
    const update = { ...(hasName ? { name } : {}), ...(hasNotifications ? { email_notifications_enabled: req.body.email_notifications_enabled === true } : {}), updated_at: now };
    await req.goalGuesser.db.collection("gg_players").updateOne({ _id: req.goalGuesser.player._id }, { $set: update });
    return res.json({ player: publicPlayer({ ...req.goalGuesser.player, ...update }) });
  });

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
    const owned = await db.collection("gg_leagues").find({ owner_player_id: player._id }).toArray();
    for (const league of owned) {
      const successor = await db.collection("gg_memberships").find({ league_id: league._id, player_id: { $ne: player._id } }).sort({ joined_at: 1 }).limit(1).next();
      if (successor) {
        await db.collection("gg_leagues").updateOne({ _id: league._id }, { $set: { owner_player_id: successor.player_id, updated_at: new Date().toISOString() } });
        await db.collection("gg_memberships").updateOne({ _id: successor._id }, { $set: { role: "owner" } });
      } else {
        await db.collection("gg_leagues").deleteOne({ _id: league._id });
      }
    }
    await Promise.all([
      db.collection("gg_sessions").deleteMany({ player_id: player._id }),
      db.collection("gg_memberships").deleteMany({ player_id: player._id }),
      db.collection("gg_picks").deleteMany({ player_id: player._id }),
      db.collection("gg_identities").deleteMany({ player_id: player._id }),
      db.collection("gg_players").deleteOne({ _id: player._id }),
    ]);
    return res.status(204).end();
  });

  app.get(`${PREFIX}/fixtures`, authenticate, async (req, res) => {
    await syncFixtures(getCanonicalMatches);
    const { db, player } = req.goalGuesser;
    const query = { competition: PREMIER_LEAGUE };
    if (req.query.pick_week_id) query.pick_week_id = String(req.query.pick_week_id);
    const fixtures = await db.collection("gg_fixtures").find(query).sort({ kickoff_at: 1 }).toArray();
    const lockTimes = pickWeekLockTimes(fixtures);
    const nowMs = currentTimeMs();
    const picks = await db.collection("gg_picks").find({ player_id: player._id, fixture_id: { $in: fixtures.map((item) => item._id) } }).toArray();
    const picksByFixture = new Map(picks.map((pick) => [pick.fixture_id, pick]));
    return res.json({ server_time: new Date(nowMs).toISOString(), competition: PREMIER_LEAGUE, fixtures: fixtures.map((fixture) => fixtureResponse(fixture, picksByFixture.get(fixture._id), nowMs, (lockTimes.get(fixture.pick_week_id) || Infinity) <= nowMs)) });
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
    const requestedWeeks = [...new Set(fixtures.map((fixture) => fixture.pick_week_id).filter(Boolean))];
    const weekFixtures = requestedWeeks.length
      ? await db.collection("gg_fixtures").find({ competition: PREMIER_LEAGUE, pick_week_id: { $in: requestedWeeks } }, { projection: { pick_week_id: 1, kickoff_at: 1 } }).toArray()
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
      if ((pickWeekLocks.get(fixture.pick_week_id) || Date.parse(fixture.kickoff_at)) <= currentTimeMs()) {
        metrics.picks_locked += 1;
        rejected.push({ fixture_id: fixtureId, reason: "locked" });
        continue;
      }
      if (item.power_pick === true && duplicatePowerWeeks.has(fixture.pick_week_id)) {
        rejected.push({ fixture_id: fixtureId, reason: "multiple_power_picks" });
        continue;
      }
      if (item.power_pick === true) {
        const existingPower = await db.collection("gg_picks").findOne({ player_id: req.goalGuesser.player._id, pick_week_id: fixture.pick_week_id, power_pick: true, fixture_id: { $ne: fixtureId } });
        if (existingPower) {
          const powerFixture = await db.collection("gg_fixtures").findOne({ _id: existingPower.fixture_id });
          if (powerFixture && Date.parse(powerFixture.kickoff_at) <= currentTimeMs()) {
            rejected.push({ fixture_id: fixtureId, reason: "power_pick_spent" });
            continue;
          }
          await db.collection("gg_picks").updateMany({ player_id: req.goalGuesser.player._id, pick_week_id: fixture.pick_week_id }, { $set: { power_pick: false } });
        }
      }
      const now = new Date().toISOString();
      try {
        await db.collection("gg_picks").updateOne(
          { player_id: req.goalGuesser.player._id, fixture_id: fixtureId },
          {
            $set: { home_score: homeScore, away_score: awayScore, power_pick: item.power_pick === true, pick_week_id: fixture.pick_week_id, contest_id: fixture.contest_id, updated_at: now },
            $setOnInsert: { _id: crypto.randomUUID(), player_id: req.goalGuesser.player._id, fixture_id: fixtureId, created_at: now },
            $unset: { points: "", score_tier: "", scored_result_revision: "", scored_at: "" },
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
    return res.status(rejected.length > 0 && saved.length === 0 ? 409 : 200).json({ saved, rejected, server_time: new Date(currentTimeMs()).toISOString() });
  });

  app.get(`${PREFIX}/leagues`, authenticate, async (req, res) => {
    const memberships = await req.goalGuesser.db.collection("gg_memberships").find({ player_id: req.goalGuesser.player._id }).sort({ joined_at: 1 }).toArray();
    const leagues = await req.goalGuesser.db.collection("gg_leagues").find({ _id: { $in: memberships.map((item) => item.league_id) } }).toArray();
    const membershipByLeague = new Map(memberships.map((item) => [item.league_id, item]));
    return res.json({ leagues: leagues.map((league) => ({ id: league._id, name: league.name, join_code: league.join_code, archived: league.archived === true, owner_player_id: league.owner_player_id, role: membershipByLeague.get(league._id)?.role || "member", scoring_from: membershipByLeague.get(league._id)?.scoring_from || null })) });
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
    const league = { _id: crypto.randomUUID(), name, join_code: joinCode, owner_player_id: req.goalGuesser.player._id, archived: false, created_at: now, updated_at: now };
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
    const scoring = await nextOpenScoringStart(db);
    const now = new Date().toISOString();
    await db.collection("gg_memberships").insertOne({ _id: crypto.randomUUID(), league_id: league._id, player_id: req.goalGuesser.player._id, role: "member", joined_at: now, scoring_from: scoring.kickoff_at, scoring_from_pick_week_id: scoring.week });
    return res.status(201).json({ league: { id: league._id, name: league.name, join_code: league.join_code, role: "member", scoring_from: scoring.kickoff_at } });
  });

  app.get(`${PREFIX}/leagues/:leagueId`, authenticate, async (req, res) => {
    const db = req.goalGuesser.db;
    const membership = await requireMembership(db, req.params.leagueId, req.goalGuesser.player._id);
    if (!membership) return res.status(404).json({ error: "League not found" });
    const league = await db.collection("gg_leagues").findOne({ _id: req.params.leagueId });
    const members = await db.collection("gg_memberships").find({ league_id: req.params.leagueId }).sort({ joined_at: 1 }).toArray();
    const players = await db.collection("gg_players").find({ _id: { $in: members.map((item) => item.player_id) } }).toArray();
    const names = new Map(players.map((player) => [player._id, player.name]));
    return res.json({ league: { id: league._id, name: league.name, join_code: league.join_code, archived: league.archived === true, owner_player_id: league.owner_player_id, role: membership.role }, members: members.map((item) => ({ player_id: item.player_id, name: names.get(item.player_id) || "Former player", role: item.role, joined_at: item.joined_at, scoring_from: item.scoring_from })) });
  });

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
    await db.collection("gg_memberships").deleteOne({ league_id: league._id, player_id: req.params.playerId });
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
    await db.collection("gg_memberships").deleteOne({ league_id: league._id, player_id: req.goalGuesser.player._id });
    return res.status(204).end();
  });

  app.get(`${PREFIX}/leagues/:leagueId/leaderboard`, authenticate, async (req, res) => {
    await syncFixtures(getCanonicalMatches);
    const db = req.goalGuesser.db;
    const viewerMembership = await requireMembership(db, req.params.leagueId, req.goalGuesser.player._id);
    if (!viewerMembership) return res.status(404).json({ error: "League not found" });
    const memberships = await db.collection("gg_memberships").find({ league_id: req.params.leagueId }).toArray();
    const players = await db.collection("gg_players").find({ _id: { $in: memberships.map((item) => item.player_id) } }).toArray();
    const names = new Map(players.map((player) => [player._id, player.name]));
    const playerIds = memberships.map((item) => item.player_id);
    const picks = await db.collection("gg_picks").find({ player_id: { $in: playerIds }, points: { $type: "number" } }).toArray();
    const fixtures = await db.collection("gg_fixtures").find({ _id: { $in: picks.map((pick) => pick.fixture_id) } }).toArray();
    const fixtureById = new Map(fixtures.map((fixture) => [fixture._id, fixture]));
    const rows = rankLeaderboard(memberships.map((membership) => {
      const eligible = picks.filter((pick) => pick.player_id === membership.player_id && Date.parse(fixtureById.get(pick.fixture_id)?.kickoff_at || 0) >= Date.parse(membership.scoring_from || 0));
      return {
        player_id: membership.player_id,
        name: names.get(membership.player_id) || "Former player",
        points: eligible.reduce((sum, pick) => sum + Number(pick.points || 0), 0),
        exact_scores: eligible.filter((pick) => pick.score_tier === "exact").length,
        correct_results: eligible.filter((pick) => ["exact", "result_and_team_score", "result"].includes(pick.score_tier)).length,
      };
    }));
    return res.json({ leaderboard: rows });
  });

  app.get(`${PREFIX}/leagues/:leagueId/picks`, authenticate, async (req, res) => {
    await syncFixtures(getCanonicalMatches);
    const db = req.goalGuesser.db;
    const viewerMembership = await requireMembership(db, req.params.leagueId, req.goalGuesser.player._id);
    if (!viewerMembership) return res.status(404).json({ error: "League not found" });
    const pickWeekId = normalizeText(req.query.pick_week_id);
    if (!pickWeekId) return res.status(400).json({ error: "pick_week_id is required" });
    const fixtures = await db.collection("gg_fixtures").find({ pick_week_id: pickWeekId, competition: PREMIER_LEAGUE }).sort({ kickoff_at: 1 }).toArray();
    const members = await db.collection("gg_memberships").find({ league_id: req.params.leagueId }).toArray();
    const players = await db.collection("gg_players").find({ _id: { $in: members.map((item) => item.player_id) } }).toArray();
    const names = new Map(players.map((player) => [player._id, player.name]));
    const picks = await db.collection("gg_picks").find({ player_id: { $in: members.map((item) => item.player_id) }, fixture_id: { $in: fixtures.map((item) => item._id) } }).toArray();
    const now = currentTimeMs();
    return res.json({
      fixtures: fixtures.map((fixture) => fixtureResponse(fixture, null, now)),
      members: members.map((member) => ({
        player_id: member.player_id,
        name: names.get(member.player_id) || "Former player",
        picks: fixtures.map((fixture) => {
          const pick = picks.find((item) => item.player_id === member.player_id && item.fixture_id === fixture._id);
          const reveal = member.player_id === req.goalGuesser.player._id || Date.parse(fixture.kickoff_at) <= now;
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
    normalizeEmail,
    sendPlunkEmail,
    normalizeLeagueName,
    integerScore,
    isPremierLeagueMatch,
    rankLeaderboard,
    currentTimeMs,
    setGoalGuesserTestNow,
    secretDigest,
    secretMatches,
    parseCredential,
    fixtureResponse,
    pickWeekLockTimes,
  },
};
