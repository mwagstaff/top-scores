"use strict";

const crypto = require("node:crypto");
const { isIP } = require("node:net");
const PREFIX = "/api/v1/prediction-game";
const DAY = 86400000;
const iso = (time) => new Date(time).toISOString();
const hash = (value) => crypto.createHash("sha256").update(value).digest("hex");
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const invitationBase = () => (process.env.PREDICTION_GAME_INVITE_BASE_URL || "https://top-scores.skynolimit.dev/invite").replace(/\/$/, "");
function invitationCode() { return Array.from({ length: 12 }, () => CODE_ALPHABET[crypto.randomInt(CODE_ALPHABET.length)]).join(""); }
function normalizeCode(value) {
  let code = String(value || "").trim();
  if (code.includes(":")) {
    try {
      const url = new URL(code); const base = new URL(invitationBase());
      if (url.username || url.password || url.search || url.hash || url.port) return "";
      if (url.protocol === "https:" && url.hostname === base.hostname && url.pathname.startsWith(`${base.pathname}/`)) code = url.pathname.slice(base.pathname.length + 1);
      else if (url.protocol === "topscores:" && url.hostname === "invite") code = url.pathname.slice(1);
      else return "";
    } catch (_) { return ""; }
  }
  return code.toUpperCase().replace(/[\s-]/g, "");
}
function hasLocked(fixture, now) { return Boolean(fixture && (fixture.started || fixture.result || Date.parse(fixture.kickoffAt) <= now)); }
function memberFor(league, playerId) { return league.members.find((member) => member.playerId === playerId); }
function invitationClientIP(req) {
  const remote = String(req.socket?.remoteAddress || req.ip || "").toLowerCase();
  // Production's local Caddy is the only trusted forwarding hop. Use the last
  // address it appended; an Internet client cannot select its own limiter key.
  if (["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(remote)) {
    const forwarded = req.headers?.["x-forwarded-for"];
    if (typeof forwarded === "string" && forwarded.length <= 2048) {
      const nearest = forwarded.split(",").at(-1).trim().toLowerCase();
      if (isIP(nearest)) return nearest;
    }
  }
  return isIP(remote) ? remote : "unknown";
}
function activeMembers(league) { return league.members.filter((member) => member.status === "active"); }
function eligible(member, round, fixtureId) {
  return Boolean(member) && member.periods.some((period) => Date.parse(round.startsAt) > Date.parse(period.from)
    && !(period.excludedRoundIds || []).includes(round._id)
    && (!period.endedAt || period.retainedFixtureIds.includes(fixtureId)));
}
function rankRows(rows) {
  rows.sort((a, b) => b.points - a.points || b.exactScores - a.exactScores || a.displayName.localeCompare(b.displayName) || a.memberId.localeCompare(b.memberId));
  rows.forEach((row, index) => { row.rank = index && rows[index - 1].points === row.points && rows[index - 1].exactScores === row.exactScores ? rows[index - 1].rank : index + 1; });
  return rows;
}

function createPrivatePredictionLeagues(options) {
  const { game, helpers: h } = options;
  const now = game.now;
  const fail = (status, code, message) => { throw new h.GameError(status, code, message); };
  const invalidInvite = () => fail(404, "invitation_unavailable", "This invitation has expired or is no longer available. Ask the league owner for a new one.");
  const isOwner = (league, player) => league.ownerPlayerId === player._id;
  const publicationCache = new Map();

  async function leagueFor(db, id, player, owner = false) {
    const league = typeof id === "string" && /^[a-f0-9-]{36}$/.test(id) ? await db.collection("pg_mini_leagues").findOne({ _id: id }) : null;
    if (!league || memberFor(league, player._id)?.status !== "active") fail(404, "league_not_found", "This league is no longer available to you.");
    if (owner && !isOwner(league, player)) fail(403, "owner_required", "Only the league owner can do that.");
    return league;
  }

  // Every authorization decision and membership/owner/invitation change uses
  // one versioned document. A crash cannot leave an orphaned owner or a revoked
  // invitation still authorized by a second collection. The lease reduces
  // contention; the compare-and-swap is the final fencing authority.
  async function mutate(db, id, player, owner, action, allowClosed = false) {
    return h.withFixtureLock(db, `private-league:${id}`, async (renew) => {
      const league = await leagueFor(db, id, player, owner);
      if (league.status !== "active" && !allowClosed) fail(409, "league_closed", "This league has closed. Its final table is still available.");
      const version = league.version;
      await action(league);
      league.updatedAt = iso(now()); league.version += 1;
      league.activePlayerIds = activeMembers(league).map((member) => member.playerId);
      league.memberPlayerIds = league.members.map((member) => member.playerId);
      await renew();
      const result = await db.collection("pg_mini_leagues").updateOne({ _id: id, version }, { $set: league });
      if (result.matchedCount !== 1) fail(409, "league_changed", "Your league changed. Refresh and try again.");
      return league;
    });
  }

  async function sourceRounds(db, competitionId) {
    // BSD's official round is the shared opportunity set, including fixtures
    // outside the public weekly challenge. Never truncate it to ten matches.
    const docs = await db.collection("bsd_events").find({ league_id: { $in: [competitionId, Number(competitionId)] } }).toArray();
    const predictions = await h.predictionMap(db, [competitionId]);
    const previous = await db.collection("pg_fixtures").find({ competitionId: competitionId === "1" ? { $in: ["1", null] } : competitionId }).toArray();
    const previousMap = new Map(previous.map((fixture) => [fixture._id, fixture]));
    const groups = new Map();
    for (const doc of docs) {
      const fixture = h.fixtureFromEvent(doc, previousMap.get(String(doc._id)), predictions.get(String(doc._id)));
      if (!fixture?.roundNumber || !fixture.seasonId) continue;
      const id = `${competitionId}:${fixture.seasonId}:round:${fixture.roundNumber}`;
      if (!groups.has(id)) groups.set(id, { _id: id, competitionId, label: `Round ${fixture.roundNumber}`, seasonId: fixture.seasonId, seasonLabel: fixture.seasonLabel, fixtures: [] });
      groups.get(id).fixtures.push(fixture);
    }
    return [...groups.values()].map((round) => {
      round.fixtures.sort((a, b) => a.kickoffAt.localeCompare(b.kickoffAt) || a._id.localeCompare(b._id));
      round.startsAt = round.fixtures[0].kickoffAt;
      round.opensAt = iso(Date.parse(round.startsAt) - 2 * DAY);
      return round;
    }).sort((a, b) => a.startsAt.localeCompare(b.startsAt));
  }

  async function publish(db, competitionId, force = false) {
    const cached = publicationCache.get(competitionId);
    if (!force && cached && now() - cached.checkedAt < 15000) return cached.candidates;
    const candidates = await sourceRounds(db, competitionId);
    const published = await db.collection("pg_mini_league_rounds").find({ competitionId }).toArray();
    const knownRounds = new Set(published.map((round) => round._id));
    const assignedFixtures = new Set(published.flatMap((round) => round.fixtureIds));
    for (const round of candidates) {
      if (knownRounds.has(round._id)) continue;
      if (Date.parse(round.opensAt) > now() || Date.parse(round.startsAt) <= now() || round.fixtures.some((fixture) => h.isLocked(fixture, now()) && !fixture.void)) continue;
      const fixtures = round.fixtures.filter((fixture) => fixture.ai && !fixture.void && !assignedFixtures.has(fixture._id));
      if (!fixtures.length) continue;
      // Insert-only snapshot. Restart, duplicate worker and market changes can
      // never move the benchmark or add scoring opportunities mid-round.
      const snapshot = { ...round, fixtures: undefined, fixtureIds: fixtures.map((fixture) => fixture._id),
        fixtureSnapshots: fixtures.map((fixture) => ({ ...fixture, ai: { ...fixture.ai, frozenAt: iso(now()) } })),
        scoringRulesVersion: 2, createdAt: iso(now()), updatedAt: iso(now()) };
      delete snapshot.fixtures;
      try {
        await db.collection("pg_mini_league_rounds").updateOne({ _id: round._id }, { $setOnInsert: snapshot }, { upsert: true });
        fixtures.forEach((fixture) => assignedFixtures.add(fixture._id));
      } catch (error) {
        // The unique fixture index also fences concurrent publications after a
        // provider round-number correction. Retry against the winner next run.
        if (error.code !== 11000) throw error;
      }
    }
    publicationCache.set(competitionId, { checkedAt: now(), candidates });
    return candidates;
  }

  async function roundsFor(db, league) {
    const rounds = await db.collection("pg_mini_league_rounds").find({ competitionId: league.competitionId, startsAt: { $gt: league.createdAt } }, { projection: { fixtureSnapshots: 0 } }).sort({ startsAt: 1 }).toArray();
    // Closing a league freezes participation at the already locked matches;
    // future rounds must not appear when source results subsequently arrive.
    return rounds.filter((round) => !(league.excludedRoundIds || []).includes(round._id) && (!league.closedAt || round.startsAt <= league.closedAt));
  }

  async function fixturesFor(db, rounds) {
    const ids = [...new Set(rounds.flatMap((round) => round.fixtureIds))];
    if (!ids.length) return new Map();
    const [source, cached] = await Promise.all([
      db.collection("bsd_events").find({ _id: { $in: ids } }).toArray(),
      db.collection("pg_fixtures").find({ _id: { $in: ids } }).toArray(),
    ]);
    const map = new Map(rounds.flatMap((round) => round.fixtureSnapshots.map((fixture) => [fixture._id, fixture])));
    for (const fixture of cached) map.set(fixture._id, fixture);
    for (const doc of await h.eventDocsWithResults(db, source)) {
      const fixture = h.fixtureFromEvent(doc, map.get(String(doc._id)), map.get(String(doc._id))?.ai);
      if (fixture) map.set(fixture._id, fixture);
    }
    return map;
  }

  function roundResponse(round, fixtures) {
    if (!round) return null;
    return { id: round._id, label: round.label, seasonId: round.seasonId, seasonLabel: round.seasonLabel, startsAt: round.startsAt, opensAt: round.opensAt,
      fixtureCount: round.fixtureIds.length, completed: round.fixtureIds.every((id) => fixtures.has(id))
        ? round.fixtureIds.every((id) => fixtures.get(id)?.void || fixtures.get(id)?.result) : round.completed === true };
  }
  function currentRound(rounds, fixtures) {
    // A postponed match keeps its original round and remains in history. It
    // must not keep the whole league stuck on that old round for weeks.
    return rounds.find((round) => Date.parse(round.startsAt) > now()) || rounds.at(-1) || null;
  }
  function startDescription(member, candidates) {
    const start = member.periods.at(-1)?.from;
    const next = candidates.find((round) => round.startsAt > start && round.fixtures.every((fixture) => !h.isLocked(fixture, now()) || fixture.void));
    return next ? `${next.label} · ${next.seasonLabel}` : "Next full round";
  }
  function memberResponse(member, league, player, candidates = []) {
    return { id: member.id, displayName: member.displayName, isYou: member.playerId === player._id, isOwner: member.playerId === league.ownerPlayerId,
      status: member.status, startsFrom: member.status === "active" ? startDescription(member, candidates) : null };
  }

  function calculate(league, rounds, fixtures, entries) {
    const entriesByPlayer = new Map(entries.map((entry) => [`${entry.playerId}:${entry.fixtureId}`, entry]));
    const rows = league.members.map((member) => ({ memberId: member.id, displayName: member.displayName, points: 0, exactScores: 0, correctResults: 0, predicted: 0, played: 0,
      isAI: false, status: member.status }));
    const ai = { memberId: "top-scores-ai", displayName: "Top Scores AI", points: 0, exactScores: 0, correctResults: 0, predicted: 0, played: 0, isAI: true, status: "benchmark" };
    for (const round of rounds) for (const snapshot of round.fixtureSnapshots) {
      const fixture = fixtures.get(snapshot._id);
      if (!fixture || fixture.void || (league.closedAt && !league.retainedFixtureIds.includes(fixture._id))) continue;
      const locked = hasLocked(fixture, now());
      if (locked) ai.predicted += 1;
      const aiPoints = h.pointsFor(snapshot.ai, fixture.result);
      if (aiPoints != null) { ai.points += aiPoints; ai.exactScores += Number(aiPoints === 3); ai.correctResults += Number(aiPoints > 0); ai.played += 1; }
      for (let index = 0; index < league.members.length; index += 1) {
        const member = league.members[index]; const row = rows[index];
        if (!eligible(member, round, fixture._id)) continue;
        const entry = entriesByPlayer.get(`${member.playerId}:${fixture._id}`);
        // Pre-lock participation counts would disclose that somebody has made
        // a pick. Private tables expose settled/locked activity only.
        const valid = entry && !entry.withdrawn && entry.ai && Date.parse(entry.updatedAt) < Date.parse(fixture.kickoffAt);
        if (locked && valid) row.predicted += 1;
        if (!fixture.result) continue;
        row.played += 1;
        const points = valid ? h.pointsFor(entry, fixture.result) || 0 : 0;
        row.points += points; row.exactScores += Number(points === 3); row.correctResults += Number(points > 0);
      }
    }
    rankRows(rows);
    // AI is a reference, never a human podium place or a tie-breaker.
    if (league.showAI) rows.push({ ...ai, rank: 0 });
    return rows;
  }

  async function data(db, league, query = null, suppliedRounds = null) {
    const allRounds = suppliedRounds || await roundsFor(db, league);
    const selected = query ? selectedRounds({ rounds: allRounds, fixtures: new Map() }, query).rounds : allRounds;
    const rounds = await db.collection("pg_mini_league_rounds").find({ _id: { $in: selected.map((round) => round._id) } }).sort({ startsAt: 1 }).toArray();
    const fixtures = await fixturesFor(db, rounds);
    const entries = await db.collection("pg_entries").find({ playerId: { $in: league.memberPlayerIds }, fixtureId: { $in: [...fixtures.keys()] } }).toArray();
    return { rounds, fixtures, entries };
  }
  function viewerRows(rows, league, player) { return rows.map((row) => ({ ...row, isYou: memberFor(league, player._id)?.id === row.memberId })); }
  function selectedRounds(state, query) {
    const current = currentRound(state.rounds, state.fixtures);
    if (query.scope === "season") {
      const seasonId = query.seasonId || current?.seasonId;
      if (query.seasonId && !state.rounds.some((round) => round.seasonId === seasonId)) fail(404, "season_not_found", "That season is not part of this league.");
      return { rounds: state.rounds.filter((round) => round.seasonId === seasonId), roundId: null, seasonId: seasonId || null };
    }
    const round = query.roundId ? state.rounds.find((round) => round._id === query.roundId) : current;
    if (query.roundId && !round) fail(404, "round_not_found", "That round is not part of this league.");
    return { rounds: round ? [round] : [], roundId: round?._id || null, seasonId: round?.seasonId || null };
  }

  async function standings(db, league, player, query = {}) {
    if (query.scope && !["round", "season"].includes(query.scope)) fail(400, "invalid_scope", "Choose this round or season.");
    // Acquire before reading results/entries: an older calculation must never
    // wait behind a newer rebuild and then overwrite its corrected totals.
    return h.withFixtureLock(db, `private-table:${league._id}`, async (renew) => {
      const authorized = await leagueFor(db, league._id, player);
      const state = await data(db, authorized, query); const selected = selectedRounds(state, query);
      const rows = calculate(authorized, selected.rounds, state.fixtures, state.entries);
      const scope = query.scope || "round";
      const id = `${league._id}:${scope}:${selected.roundId || selected.seasonId || "pending"}`;
      const sourceRevision = hash(JSON.stringify({ version: authorized.version, rounds: selected.rounds.map((round) => round._id),
        fixtures: [...state.fixtures.values()].map((fixture) => [fixture._id, fixture.resultRevision, fixture.kickoffAt, fixture.started, fixture.void]),
        entries: state.entries.map((entry) => [entry._id, entry.version, entry.updatedAt, entry.withdrawn]) }));
      const existing = await db.collection("pg_mini_league_standings").findOne({ _id: id });
      if (existing?.sourceRevision !== sourceRevision || existing.rebuildPending) {
        const latest = await leagueFor(db, league._id, player);
        if (latest.version !== authorized.version) fail(409, "league_changed", "Your league changed. Refresh and try again.");
        const revision = (existing?.revision || 0) + 1;
        // Persist recovery intent before replacing totals. A crash leaves the
        // scope retryable and the periodic worker also revisits every season.
        await renew();
        await db.collection("pg_mini_league_standings").updateOne({ _id: id }, { $setOnInsert: { revision: 0 }, $set: { leagueId: league._id, rebuildPending: true, updatedAt: iso(now()) } }, { upsert: true });
        await renew();
        const changed = await db.collection("pg_mini_league_standings").updateOne({ _id: id, revision: existing?.revision || 0 }, { $set: {
          scope, roundId: selected.roundId, seasonId: selected.seasonId, rows, sourceRevision, leagueVersion: authorized.version, revision, rebuildPending: false, updatedAt: iso(now()),
        } });
        if (changed.matchedCount !== 1) fail(409, "league_changed", "The table is updating. Please try again.");
      }
      return { leagueId: league._id, scope, roundId: selected.roundId, seasonId: selected.seasonId, rows: viewerRows(rows, authorized, player), serverTime: iso(now()) };
    });
  }

  async function leagueResponse(db, league, player, candidates = [], suppliedState = null) {
    const rounds = suppliedState?.rounds || await roundsFor(db, league);
    const round = currentRound(rounds, new Map());
    const cached = round ? await db.collection("pg_mini_league_standings").findOne({ _id: `${league._id}:season:${round.seasonId}`, leagueVersion: league.version, rebuildPending: false }) : null;
    const state = suppliedState || await data(db, league, cached ? { roundId: round._id } : { scope: "season", seasonId: round?.seasonId }, rounds);
    const seasonRounds = state.rounds.filter((item) => item.seasonId === round?.seasonId);
    const rows = cached?.rows || calculate(league, seasonRounds, state.fixtures, state.entries);
    const member = memberFor(league, player._id); const you = rows.find((row) => row.memberId === member?.id);
    return { id: league._id, name: league.name, competitionId: league.competitionId, competitionName: league.competitionName,
      ownerMemberId: memberFor(league, league.ownerPlayerId)?.id || "", myMemberId: member?.id || "", isOwner: isOwner(league, player), showAI: league.showAI,
      status: league.status, memberCount: league.members.length, position: round && you ? you.rank : null,
      points: you?.points || 0, gapToLeader: Math.max(0, (rows[0]?.points || 0) - (you?.points || 0)),
      currentRound: roundResponse(round, state.fixtures), startsFrom: member ? startDescription(member, candidates) : null, createdAt: league.createdAt };
  }

  function newMember(player) {
    return { id: crypto.randomUUID(), playerId: player._id, displayName: player.displayName, status: "active", joinedAt: iso(now()), periods: [{ from: iso(now()), endedAt: null, retainedFixtureIds: [] }] };
  }
  async function startedRoundIds(db, competitionId) {
    const rounds = await db.collection("pg_mini_league_rounds").find({ competitionId, startsAt: { $gt: iso(now()) } }).toArray();
    const fixtures = await fixturesFor(db, rounds);
    return rounds.filter((round) => round.fixtureIds.some((id) => hasLocked(fixtures.get(id), now()))).map((round) => round._id);
  }
  async function joiningBoundary(db, competitionId) {
    const rounds = await sourceRounds(db, competitionId);
    return rounds.find((round) => Date.parse(round.startsAt) > now() && round.fixtures.every((fixture) => !h.isLocked(fixture, now()) || fixture.void))?.startsAt || null;
  }
  function leagueName(value) {
    if (typeof value !== "string") fail(400, "invalid_name", "Give your league a name.");
    const name = value.trim().replace(/\s+/g, " ");
    if (name.length < 2 || name.length > 40 || /[\u0000-\u001f\u007f]/.test(name)) fail(400, "invalid_name", "Choose a league name between 2 and 40 characters.");
    return name;
  }
  async function createUnlocked(db, player, body, renew) {
    const name = leagueName(body?.name);
    const competitionId = String(body?.competitionId || "");
    const competitions = await h.availableCompetitions(db, player._id);
    const competition = competitions.find((item) => item.id === competitionId);
    if (!competition) fail(400, "invalid_competition", "Choose a competition with AI predictions.");
    if (body?.showAI != null && typeof body.showAI !== "boolean") fail(400, "invalid_setting", "Choose whether to show the AI benchmark.");
    if (await db.collection("pg_mini_leagues").countDocuments({ activePlayerIds: player._id, status: "active" }) >= 20) fail(409, "league_limit", "You can play in up to 20 active leagues.");
    const excludedRoundIds = await startedRoundIds(db, competitionId);
    const boundary = await joiningBoundary(db, competitionId);
    const league = { _id: crypto.randomUUID(), name, competitionId, competitionName: competition.name, ownerPlayerId: player._id, showAI: body.showAI !== false, excludedRoundIds,
      status: "active", members: [newMember(player)], memberPlayerIds: [player._id], activePlayerIds: [player._id], invitations: [], retainedFixtureIds: [], version: 1,
      createdAt: iso(now()), updatedAt: iso(now()) };
    await renew();
    // An inert draft permits a database-clock activation guard without Mongo
    // transactions. A join that straddles kickoff must retry into the next full
    // round, never inherit eligibility sampled before the delayed write.
    await db.collection("pg_mini_leagues").insertOne({ ...league, status: "creating", activePlayerIds: [], draftExpiresAt: new Date(now() + DAY) });
    await renew();
    const activated = await db.collection("pg_mini_leagues").updateOne({ _id: league._id, status: "creating", ...(boundary ? { $expr: { $lt: ["$$NOW", new Date(boundary)] } } : {}) }, { $set: { status: "active", activePlayerIds: league.activePlayerIds, draftExpiresAt: null } });
    if (activated.matchedCount !== 1) { await db.collection("pg_mini_leagues").deleteOne({ _id: league._id, status: "creating" }); fail(409, "round_started", "The round just kicked off. Try again to start with the next full round."); }
    const candidates = await publish(db, competitionId);
    return { league: await leagueResponse(db, league, player, candidates), serverTime: iso(now()) };
  }
  async function create(db, player, body) {
    return h.withFixtureLock(db, `private-player:${player._id}`, (renew) => createUnlocked(db, player, body, renew));
  }

  async function endMembership(db, league, member) {
    const state = await data(db, league);
    const period = member.periods.at(-1);
    period.endedAt = iso(now());
    period.retainedFixtureIds = state.rounds.filter((round) => round.startsAt > period.from)
      .flatMap((round) => round.fixtureIds.filter((id) => hasLocked(state.fixtures.get(id), now())));
  }

  async function limitInvitationAttempts(db, req, player) {
    if (options.disableRateLimits) return;
    // Persist both scopes: a new API process or changing player account cannot
    // reset attempts from an address. Hash addresses; never store invitation text.
    const window = Math.floor(now() / 600000);
    for (const [scope, value, limit] of [["player", player._id, 30], ["ip", invitationClientIP(req), 100]]) {
      const id = `${scope}:${hash(String(value))}:${window}`;
      await db.collection("pg_mini_league_attempts").updateOne({ _id: id }, { $inc: { count: 1 }, $setOnInsert: { expiresAt: new Date((window + 2) * 600000), updatedAt: iso(now()) } }, { upsert: true });
      if ((await db.collection("pg_mini_league_attempts").findOne({ _id: id })).count > limit) fail(429, "rate_limited", "Too many invitation attempts. Please try again in a few minutes.");
    }
  }
  async function limitRequests(db, req, player) {
    if (options.disableRateLimits) return;
    const kind = req.method === "GET" ? "read" : "write";
    const window = Math.floor(now() / 60000);
    const id = `request:${kind}:${hash(player._id)}:${window}`;
    await db.collection("pg_mini_league_attempts").updateOne({ _id: id }, { $inc: { count: 1 }, $setOnInsert: { expiresAt: new Date((window + 2) * 60000), updatedAt: iso(now()) } }, { upsert: true });
    if ((await db.collection("pg_mini_league_attempts").findOne({ _id: id })).count > (kind === "read" ? 120 : 40)) fail(429, "rate_limited", "Please wait a moment before trying again.");
  }

  async function inviteLeague(db, value) {
    const code = normalizeCode(value);
    if (!new RegExp(`^[${CODE_ALPHABET}]{12}$`).test(code)) return invalidInvite();
    const digest = hash(code); const lookup = await db.collection("pg_mini_league_invite_lookup").findOne({ _id: digest });
    const league = lookup ? await db.collection("pg_mini_leagues").findOne({ _id: lookup.leagueId }) : null;
    const invitation = league?.invitations.find((item) => item.hash === digest && !item.revokedAt && Date.parse(item.expiresAt) > now());
    if (!invitation || league.status !== "active") return invalidInvite();
    return { league, invitation };
  }

  async function invitation(db, leagueId, player) {
    const code = invitationCode(); const digest = hash(code);
    const record = { id: crypto.randomUUID(), hash: digest, createdAt: iso(now()), expiresAt: iso(now() + 7 * DAY), revokedAt: null };
    let previousHashes = [];
    const league = await mutate(db, leagueId, player, true, async (value) => {
      previousHashes = value.invitations.map((item) => item.hash);
      // Replacement revokes the previous reusable invitation in the same CAS.
      value.invitations = value.invitations.filter((item) => Date.parse(item.expiresAt) > now()).slice(-19);
      for (const item of value.invitations) if (!item.revokedAt) item.revokedAt = iso(now());
      value.invitations.push(record);
    });
    // A crash before lookup insertion leaves an unusable invitation, never an
    // unauthorized one. Generating its replacement safely repairs the flow.
    await db.collection("pg_mini_league_invite_lookup").insertOne({ _id: digest, leagueId: league._id, expiresAt: new Date(record.expiresAt), updatedAt: iso(now()) });
    for (const previous of previousHashes) await db.collection("pg_mini_league_invite_lookup").deleteOne({ _id: previous });
    const base = invitationBase();
    return { invitation: { id: record.id, code, url: `${base}/${code}`, expiresAt: record.expiresAt }, serverTime: iso(now()) };
  }

  async function redeemUnlocked(db, player, code, renewPlayer) {
    const found = await inviteLeague(db, code);
    return h.withFixtureLock(db, `private-league:${found.league._id}`, async (renew) => {
      const { league, invitation } = await inviteLeague(db, code); // Recheck revoke/expiry inside the lease.
      const previous = memberFor(league, player._id);
      if (previous?.status === "removed") fail(403, "membership_removed", "The owner removed you from this league. Ask them to restore your membership.");
      if (previous?.status !== "active") {
        if (activeMembers(league).length >= 100 || (!previous && league.members.length >= 1000)) fail(409, "league_full", "This league has reached 100 members.");
        if (await db.collection("pg_mini_leagues").countDocuments({ activePlayerIds: player._id, status: "active" }) >= 20) fail(409, "league_limit", "You can play in up to 20 active leagues.");
        const version = league.version;
        const excludedRoundIds = await startedRoundIds(db, league.competitionId);
        const boundary = await joiningBoundary(db, league.competitionId);
        if (previous) { previous.status = "active"; previous.displayName = player.displayName; previous.periods.push({ from: iso(now()), endedAt: null, retainedFixtureIds: [], excludedRoundIds }); }
        else { const member = newMember(player); member.periods[0].excludedRoundIds = excludedRoundIds; league.members.push(member); }
        league.activePlayerIds = activeMembers(league).map((member) => member.playerId);
        league.memberPlayerIds = league.members.map((member) => member.playerId);
        league.version += 1; league.updatedAt = iso(now());
        await renew();
        await renewPlayer();
        const deadline = Math.min(Date.parse(invitation.expiresAt), boundary ? Date.parse(boundary) : Infinity);
        const result = await db.collection("pg_mini_leagues").updateOne({ _id: league._id, version, $expr: { $lt: ["$$NOW", new Date(deadline)] } }, { $set: league });
        if (result.matchedCount !== 1) fail(409, "league_changed", "Your league or invitation changed. Try joining again.");
      }
      const candidates = await publish(db, league.competitionId);
      return { league: await leagueResponse(db, league, player, candidates), serverTime: iso(now()) };
    });
  }
  async function redeem(db, player, code) {
    return h.withFixtureLock(db, `private-player:${player._id}`, (renew) => redeemUnlocked(db, player, code, renew));
  }

  async function sync() {
    const db = await game.database(); if (!db) return;
    const leagues = await db.collection("pg_mini_leagues").find({ status: { $in: ["active", "closed"] } }).toArray();
    for (const competitionId of new Set(leagues.filter((league) => league.status === "active").map((league) => league.competitionId))) await publish(db, competitionId, true);
    const published = await db.collection("pg_mini_league_rounds").find({}).toArray();
    const fixtures = await fixturesFor(db, published);
    for (const round of published) {
      const completed = round.fixtureIds.every((id) => fixtures.get(id)?.void || fixtures.get(id)?.result);
      if (round.completed !== completed) await db.collection("pg_mini_league_rounds").updateOne({ _id: round._id }, { $set: { completed, updatedAt: iso(now()) } });
    }
    for (const league of leagues) {
      const owner = { _id: activeMembers(league).find((member) => member.playerId === league.ownerPlayerId)?.playerId || activeMembers(league)[0]?.playerId };
      if (!owner._id) continue;
      try {
        await standings(db, league, owner, { scope: "round" });
        // Rebuild every retained season: old result corrections remain effective.
        const rounds = await roundsFor(db, league);
        for (const seasonId of new Set(rounds.map((round) => round.seasonId))) await standings(db, league, owner, { scope: "season", seasonId });
      } catch (error) { if (!["league_changed", "fixture_busy", "league_not_found"].includes(error.code)) throw error; }
    }
  }
  return { fail, leagueFor, mutate, publish, roundsFor, fixturesFor, roundResponse, currentRound, memberResponse, standings, leagueResponse, create, endMembership,
    limitInvitationAttempts, limitRequests, inviteLeague, invitation, redeem, sync, data, selectedRounds, calculate, viewerRows, startDescription };
}

function registerPrivatePredictionLeagueRoutes(app, options) {
  const service = createPrivatePredictionLeagues(options); const { game, helpers: h } = options;
  const route = (handler) => async (req, res) => {
    try {
      res.set("Cache-Control", "private, no-store"); res.set("Vary", "Authorization");
      if (options.enabled === false) service.fail(503, "unavailable", "Private leagues are not available yet.");
      const db = await game.database(); if (!db) service.fail(503, "unavailable", "Your leagues are temporarily unavailable.");
      const player = await options.authenticateCredential(db, req.headers.authorization, true, game.now());
      await service.limitRequests(db, req, player);
      return await handler(req, res, db, player);
    } catch (error) {
      if (!error.status) console.warn("[Private prediction leagues]", error.message);
      if (error.status === 429) res.set("Retry-After", "600");
      return res.status(error.status || 503).json({ code: typeof error.code === "string" ? error.code : "unavailable", error: error.status ? error.message : "Your leagues are temporarily unavailable. Please try again." });
    }
  };
  const ok = (res) => res.json({ ok: true, serverTime: iso(game.now()) });
  app.get(`${PREFIX}/my-leagues`, route(async (_req, res, db, player) => {
    const leagues = await db.collection("pg_mini_leagues").find({ activePlayerIds: player._id }).sort({ createdAt: -1 }).toArray();
    const candidates = new Map();
    for (const id of new Set(leagues.filter((league) => league.status === "active").map((league) => league.competitionId))) candidates.set(id, await service.publish(db, id));
    const cards = await Promise.all(leagues.map((league) => service.leagueResponse(db, league, player, candidates.get(league.competitionId))));
    // A removal racing the read must not return a now-private league card.
    for (const league of leagues) await service.leagueFor(db, league._id, player);
    res.json({ leagues: cards, serverTime: iso(game.now()) });
  }));
  app.post(`${PREFIX}/mini-leagues`, route(async (req, res, db, player) => res.status(201).json(await service.create(db, player, req.body || {}))));
  app.get(`${PREFIX}/mini-leagues/:id`, route(async (req, res, db, player) => {
    const league = await service.leagueFor(db, req.params.id, player);
    const candidates = league.status === "active" ? await service.publish(db, league.competitionId) : [];
    const rounds = await service.roundsFor(db, league);
    const state = await service.data(db, league, { scope: "season" }, rounds);
    const response = { league: await service.leagueResponse(db, league, player, candidates, state), rounds: rounds.map((round) => service.roundResponse(round, state.fixtures)),
      members: league.members.map((member) => service.memberResponse(member, league, player, candidates)), serverTime: iso(game.now()) };
    await service.leagueFor(db, league._id, player); res.json(response);
  }));
  app.patch(`${PREFIX}/mini-leagues/:id`, route(async (req, res, db, player) => {
    const league = await service.mutate(db, req.params.id, player, true, async (value) => {
      if (req.body?.name != null) {
        const name = typeof req.body.name === "string" ? req.body.name.trim().replace(/\s+/g, " ") : "";
        if (name.length < 2 || name.length > 40 || /[\u0000-\u001f\u007f]/.test(name)) service.fail(400, "invalid_name", "Choose a league name between 2 and 40 characters.");
        value.name = name;
      }
      if (req.body?.showAI != null) { if (typeof req.body.showAI !== "boolean") service.fail(400, "invalid_setting", "Choose whether to show the AI benchmark."); value.showAI = req.body.showAI; }
    });
    res.json({ league: await service.leagueResponse(db, league, player), serverTime: iso(game.now()) });
  }));
  app.get(`${PREFIX}/mini-leagues/:id/standings`, route(async (req, res, db, player) => {
    const league = await service.leagueFor(db, req.params.id, player);
    const response = await service.standings(db, league, player, req.query);
    await service.leagueFor(db, league._id, player); res.json(response);
  }));
  app.get(`${PREFIX}/mini-leagues/:id/fixtures`, route(async (req, res, db, player) => {
    const league = await service.leagueFor(db, req.params.id, player); const state = await service.data(db, league, { roundId: req.query.roundId });
    const round = service.selectedRounds(state, { roundId: req.query.roundId }).rounds[0];
    const fixtures = round ? await h.gameFixtureBatch(db, player._id, round.fixtureIds, game.now) : [];
    const byId = new Map(fixtures.map((fixture) => [fixture.id, fixture]));
    // Retained snapshots keep postponed/deleted source fixtures visible. This
    // endpoint includes only the caller's canonical picks, never a peer's.
    const response = { fixtures: round ? round.fixtureIds.map((id) => byId.get(id) || h.fixtureResponse(state.fixtures.get(id), null, game.now())) : [],
      sharedAI: round ? round.fixtureSnapshots.map((fixture) => ({ fixtureId: fixture._id, ai: fixture.ai })) : [], scoringEligible: Boolean(league.status === "active" && round && round.fixtureIds.some((id) => eligible(memberFor(league, player._id), round, id))), round: service.roundResponse(round, state.fixtures), serverTime: iso(game.now()) };
    await service.leagueFor(db, league._id, player); res.json(response);
  }));
  app.get(`${PREFIX}/mini-leagues/:id/predictions`, route(async (req, res, db, player) => {
    const league = await service.leagueFor(db, req.params.id, player); const state = await service.data(db, league, { roundId: req.query.roundId });
    const round = service.selectedRounds(state, { roundId: req.query.roundId }).rounds[0];
    const matches = (round?.fixtureIds || []).map((id) => {
      const locked = hasLocked(state.fixtures.get(id), game.now());
      return { fixtureId: id, locked, predictions: !locked ? [] : state.entries.filter((entry) => entry.fixtureId === id && !entry.withdrawn && entry.ai && eligible(memberFor(league, entry.playerId), round, id))
        .map((entry) => ({ memberId: memberFor(league, entry.playerId).id, homeScore: entry.homeScore, awayScore: entry.awayScore, ...(entry.penaltyWinner ? { penaltyWinner: entry.penaltyWinner } : {}) })) };
    });
    await service.leagueFor(db, league._id, player); res.json({ matches, serverTime: iso(game.now()) });
  }));
  app.post(`${PREFIX}/mini-leagues/:id/invitations`, route(async (req, res, db, player) => res.status(201).json(await service.invitation(db, req.params.id, player))));
  app.get(`${PREFIX}/mini-leagues/:id/invitations`, route(async (req, res, db, player) => {
    const league = await service.leagueFor(db, req.params.id, player, true);
    res.json({ invitations: league.invitations.map(({ id, expiresAt, revokedAt, createdAt }) => ({ id, expiresAt, revokedAt, createdAt })), serverTime: iso(game.now()) });
  }));
  app.delete(`${PREFIX}/mini-leagues/:id/invitations/:invitationId`, route(async (req, res, db, player) => {
    await service.mutate(db, req.params.id, player, true, async (league) => {
      const invitation = league.invitations.find((item) => item.id === req.params.invitationId);
      if (!invitation) service.fail(404, "invitation_unavailable", "That invitation is no longer available.");
      invitation.revokedAt = iso(game.now());
    }); ok(res);
  }));
  app.post(`${PREFIX}/mini-league-invitations/preview`, route(async (req, res, db, player) => {
    await service.limitInvitationAttempts(db, req, player);
    const { league, invitation } = await service.inviteLeague(db, req.body?.code);
    if (memberFor(league, player._id)?.status === "removed") service.fail(403, "membership_removed", "The owner removed you from this league. Ask them to restore your membership.");
    res.json({ invitation: { leagueId: league._id, leagueName: league.name, competitionName: league.competitionName, memberCount: activeMembers(league).length,
      expiresAt: invitation.expiresAt, alreadyMember: memberFor(league, player._id)?.status === "active", startsFrom: "Next full round" }, serverTime: iso(game.now()) });
  }));
  app.post(`${PREFIX}/mini-league-invitations/redeem`, route(async (req, res, db, player) => {
    await service.limitInvitationAttempts(db, req, player); res.json(await service.redeem(db, player, req.body?.code));
  }));
  app.delete(`${PREFIX}/mini-leagues/:id/membership`, route(async (req, res, db, player) => {
    await service.mutate(db, req.params.id, player, false, async (league) => {
      if (league.ownerPlayerId === player._id && league.status === "active") service.fail(409, "owner_transfer_required", "Transfer ownership to another member or close the league before leaving.");
      const member = memberFor(league, player._id); if (league.status === "active") await service.endMembership(db, league, member); member.status = "left";
    }, true); ok(res);
  }));
  app.delete(`${PREFIX}/mini-leagues/:id/members/:memberId`, route(async (req, res, db, player) => {
    await service.mutate(db, req.params.id, player, true, async (league) => {
      const member = league.members.find((item) => item.id === req.params.memberId);
      if (!member || member.status !== "active") service.fail(404, "member_not_found", "That member is no longer in this league.");
      if (member.playerId === player._id) service.fail(409, "owner_transfer_required", "Transfer ownership or close the league first.");
      await service.endMembership(db, league, member); member.status = "removed";
    }); ok(res);
  }));
  app.post(`${PREFIX}/mini-leagues/:id/members/:memberId/reinstate`, route(async (req, res, db, player) => {
    await service.mutate(db, req.params.id, player, true, async (league) => {
      const member = league.members.find((item) => item.id === req.params.memberId);
      if (!member || member.status !== "removed") service.fail(404, "member_not_found", "That member has not been removed.");
      // Reinstatement permits a new invitation join; it does not silently add
      // somebody back or import points they missed while removed.
      member.status = "left";
    }); ok(res);
  }));
  app.post(`${PREFIX}/mini-leagues/:id/transfer`, route(async (req, res, db, player) => {
    await service.mutate(db, req.params.id, player, true, async (league) => {
      const member = league.members.find((item) => item.id === req.body?.memberId && item.status === "active");
      if (!member || member.playerId === player._id) service.fail(400, "invalid_owner", "Choose another active league member.");
      league.ownerPlayerId = member.playerId;
      for (const invitation of league.invitations) if (!invitation.revokedAt) invitation.revokedAt = iso(game.now());
    }); ok(res);
  }));
  app.post(`${PREFIX}/mini-leagues/:id/close`, route(async (req, res, db, player) => {
    await service.mutate(db, req.params.id, player, true, async (league) => {
      const state = await service.data(db, league);
      league.status = "closed"; league.closedAt = iso(game.now());
      league.retainedFixtureIds = [...state.fixtures.values()].filter((fixture) => hasLocked(fixture, game.now())).map((fixture) => fixture._id);
      for (const member of activeMembers(league)) await service.endMembership(db, league, member);
      for (const invitation of league.invitations) if (!invitation.revokedAt) invitation.revokedAt = iso(game.now());
    }); ok(res);
  }));
  return service;
}

module.exports = { registerPrivatePredictionLeagueRoutes, createPrivatePredictionLeagues, __private: { invitationCode, normalizeCode, eligible, rankRows, hasLocked, invitationClientIP } };
