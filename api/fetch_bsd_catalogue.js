"use strict";

const { randomUUID } = require("crypto");
const bsd = require("./bsd_client");
const { BSD_LEAGUE_ALLOWLIST } = require("./bsd_config");
const { createReferenceStore } = require("./reference_store");
const { DAY_MS, identity, id, numeric, normalizePlayer, normalizeTeam, normalizeCompetition, createColourResolver } = require("./reference_model");

function isDetailedPlayer(player) {
  return player && ["rating", "attributes", "current_team_id", "market_value_eur"].every((key) => Object.hasOwn(player, key));
}

function createCatalogueRefresher({ client = bsd, store = createReferenceStore(), competitionIds = BSD_LEAGUE_ALLOWLIST, now = Date.now, colourResolver = createColourResolver } = {}) {
  let inFlight = null;
  function refresh({ signal, force = false } = {}) {
    if (inFlight) return inFlight;
    inFlight = run(signal, force).finally(() => { inFlight = null; });
    return inFlight;
  }
  async function run(signal, force) {
    const owner = randomUUID();
    if (!await store.acquireLease(owner)) return { skipped: true, succeeded: 0, failed: 0 };
    let leaseLost = false;
    let renewing = false;
    const heartbeat = setInterval(async () => {
      if (renewing) return;
      renewing = true;
      try { if (!await store.renewLease(owner)) leaseLost = true; }
      catch (_error) { leaseLost = true; }
      finally { renewing = false; }
    }, 60_000);
    heartbeat.unref();
    const check = () => {
      if (signal?.aborted || leaseLost) throw new Error("Reference refresh cancelled or lease lost");
    };
    // bsd_client adds limit=200 to paginated lists. BSD rejects list-only
    // parameters on detail endpoints (including /leagues/:id).
    const options = { initiator: "bsd_reference_catalogue", strict: true };
    // One background request at a time shares bsd_client's limiter with live
    // polling; deduplicate teams/players across all competition memberships.
    const request = async (fn) => { check(); const result = await fn(); check(); return result; };
    const players = new Map();
    const teams = new Map();
    const summary = { skipped: false, succeeded: 0, failed: 0 };
    try {
      await store.ensureIndexes();
      const previous = await store.load(competitionIds.map(String), { includeRows: false });
      const published = new Map(previous.manifests.map((manifest) => [manifest.competition.id, manifest]));
      const resolveColours = colourResolver();
      async function fetchPlayer(playerId, listedPlayer) {
        if (players.has(playerId)) return players.get(playerId);
        const raw = isDetailedPlayer(listedPlayer) ? listedPlayer : await request(() => client.getPlayer(playerId, options));
        identity(raw, playerId);
        if (!isDetailedPlayer(raw)) throw new Error(`BSD player ${playerId} profile is incomplete`);
        const normalized = normalizePlayer(raw, new Date(now()).toISOString());
        await store.saveSources("bsd_players", [{ id: playerId, payload: raw }]);
        players.set(playerId, normalized);
        return normalized;
      }
      async function fetchTeam(teamId) {
        if (teams.has(teamId)) return teams.get(teamId);
        const raw = await request(() => client.getTeam(teamId, options));
        identity(raw, teamId);
        const updatedAt = new Date(now()).toISOString();
        const team = normalizeTeam(raw, updatedAt, resolveColours);
        let entries = [];
        let status = "placeholder";
        if (!team.is_placeholder) {
          const rawSquad = await request(() => client.getTeamSquad(teamId, options));
          if (!rawSquad || String(rawSquad.team_id) !== teamId || !Array.isArray(rawSquad.players) ||
              rawSquad.count !== rawSquad.players.length || rawSquad.players.some((player) => !id(player.id)) ||
              new Set(rawSquad.players.map((player) => String(player.id))).size !== rawSquad.players.length) {
            throw new Error(`BSD team ${teamId} squad is incomplete or malformed`);
          }
          let detailed = [];
          if (rawSquad.players.some((player) => !players.has(String(player.id)))) {
            try { detailed = await request(() => client.getPlayers({ teamId }, options)); }
            catch (error) {
              check();
              // National squads are not equivalent to current-club membership.
              // A failed bulk optimisation never makes a squad look empty.
              console.warn(`[reference] team ${teamId} player list unavailable; fetching individual profiles`);
            }
          }
          const details = new Map(detailed.map((player) => [String(player.id), player]));
          for (const member of rawSquad.players) {
            const playerId = String(member.id);
            const player = await fetchPlayer(playerId, details.get(playerId));
            entries.push({ player_id: playerId, jersey_number: numeric(member.jersey_number), player });
          }
          entries.sort((a, b) => a.player_id.localeCompare(b.player_id));
          status = entries.length ? "available" : "empty";
          await store.saveSources("bsd_team_squads", [{ id: teamId, payload: rawSquad }]);
        }
        await store.saveSources("bsd_teams", [{ id: teamId, payload: raw }]);
        const result = { team, squad: { team_id: teamId, status, count: entries.length, players: entries, updated_at: new Date(now()).toISOString() } };
        teams.set(teamId, result);
        return result;
      }
      for (const competitionId of competitionIds.map(String)) {
        check();
        const prior = published.get(competitionId);
        if (!force && prior && now() - Date.parse(prior.published_at) < DAY_MS) continue;
        const attemptedAt = new Date(now()).toISOString();
        try {
          const raw = await request(() => client.getLeague(competitionId, options));
          identity(raw, competitionId);
          const competition = normalizeCompetition(raw, new Date(now()).toISOString());
          const membership = await request(() => client.getTeams({ leagueId: competitionId, seasonId: competition.current_season.id }, options));
          if (!Array.isArray(membership) || !membership.length || membership.some((team) => !id(team.id)) ||
              new Set(membership.map((team) => String(team.id))).size !== membership.length) {
            throw new Error(`BSD competition ${competitionId} membership is empty or malformed`);
          }
          const records = [];
          for (const team of membership) records.push(await fetchTeam(String(team.id)));
          records.sort((a, b) => a.team.id.localeCompare(b.team.id));
          await store.saveSources("bsd_leagues", [{ id: competitionId, payload: raw }]);
          check();
          if (!await store.renewLease(owner)) throw new Error("Reference refresh lease lost before publication");
          const manifest = {
            competition, snapshot_id: randomUUID(), published_at: new Date(now()).toISOString(), team_count: records.length,
            player_count: new Set(records.flatMap((record) => record.squad.players.map((entry) => entry.player_id))).size,
          };
          await store.publish(manifest, records);
          summary.succeeded += 1;
          await store.recordAttempt(competitionId, { attempted_at: attemptedAt, status: "succeeded" });
        } catch (error) {
          check();
          summary.failed += 1;
          await store.recordAttempt(competitionId, { attempted_at: attemptedAt, status: "failed" });
          console.warn(`[reference] competition ${competitionId} refresh failed: ${error.message}`);
        }
      }
      await store.prune();
      return summary;
    } finally {
      clearInterval(heartbeat);
      await store.releaseLease(owner);
    }
  }
  return { refresh };
}

const catalogue = createCatalogueRefresher();
if (require.main === module) {
  catalogue.refresh({ force: process.argv.includes("--force") }).then((result) => {
    console.log(JSON.stringify(result));
    if (result.failed) process.exitCode = 1;
  }).catch((error) => {
    console.error(`[reference] ${error.message}`);
    process.exitCode = 1;
  }).finally(() => require("./mongo_client").closeMongoConnection());
}
module.exports = { createCatalogueRefresher, refreshCatalogue: catalogue.refresh, isDetailedPlayer };
