#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// Ingest BSD events (matches) into Mongo for the allowlisted leagues:
//   - notstarted + started + finished events -> bsd_events
//   - incidents/lineups for played     -> bsd_incidents, bsd_lineups
//   - referenced teams                 -> bsd_teams
//
// Run: BSD_API_KEY=... MONGODB_URI_TOP_SCORES=... node api/fetch_bsd_events.js
// ---------------------------------------------------------------------------

const bsd = require("./bsd_client");
const { BSD_LEAGUE_ALLOWLIST } = require("./bsd_config");
const {
  upsertBsdRecords,
  upsertBsdRecord,
  getBsdRecordIds,
  getBsdRecords,
  closeMongoConnection,
} = require("./mongo_client");

const EVENT_STATUSES = ["notstarted", "started", "finished"];

function eventToRecord(event) {
  return {
    id: event.id,
    payload: event,
    extra: {
      league_id: event.league_id != null ? event.league_id : null,
      status: event.status || null,
      event_date: event.event_date || null,
      home_team: event.home_team || null,
      away_team: event.away_team || null,
      home_team_id: event.home_team_id != null ? event.home_team_id : null,
      away_team_id: event.away_team_id != null ? event.away_team_id : null,
    },
  };
}

// An event has playable detail (incidents/lineups) once it is no longer a
// not-yet-started fixture.
function isPlayed(event) {
  const status = String(event && event.status ? event.status : "").toLowerCase();
  return status !== "notstarted" && status !== "";
}

function hasUnknownOutsideTimelineCardIncident(doc) {
  const incidents =
    doc && doc.payload && Array.isArray(doc.payload.incidents)
      ? doc.payload.incidents
      : [];
  return incidents.some((incident) => {
    if (!incident || incident.type !== "card") return false;
    const minute = Number(incident.minute);
    if (!Number.isFinite(minute) || minute >= 0) return false;
    const player = String(incident.player || "").trim().toLowerCase();
    return !player || player === "unknown";
  });
}

async function ingestLeagueEvents(leagueId) {
  const collected = [];
  for (const status of EVENT_STATUSES) {
    // eslint-disable-next-line no-await-in-loop
    const events = await bsd.getEvents(
      { leagueId, status },
      { initiator: "fetch_bsd_events" }
    );
    collected.push(...events);
    console.log(`[bsd] league ${leagueId} status=${status}: ${events.length} events`);
  }
  const records = collected
    .filter((event) => event && event.id != null)
    .map(eventToRecord);
  await upsertBsdRecords("bsd_events", records);
  return collected;
}

async function hydrateDetail(event) {
  const id = event.id;
  try {
    const incidents = await bsd.getIncidents(id, { initiator: "fetch_bsd_events" });
    await upsertBsdRecord("bsd_incidents", id, incidents, {
      event_id: incidents && incidents.event_id != null ? incidents.event_id : id,
    });
  } catch (error) {
    console.error(`[bsd] incidents event ${id} failed: ${error.message || error}`);
  }
  try {
    const lineups = await bsd.getLineups(id, { initiator: "fetch_bsd_events" });
    await upsertBsdRecord("bsd_lineups", id, lineups, {
      event_id: lineups && lineups.event_id != null ? lineups.event_id : id,
      lineup_status: (lineups && lineups.lineup_status) || null,
    });
  } catch (error) {
    console.error(`[bsd] lineups event ${id} failed: ${error.message || error}`);
  }
}

async function hydrateTeams(teamIds) {
  const records = [];
  for (const teamId of teamIds) {
    try {
      // eslint-disable-next-line no-await-in-loop
      const team = await bsd.getTeam(teamId, { initiator: "fetch_bsd_events" });
      records.push({
        id: teamId,
        payload: team,
        extra: { name: (team && team.name) || null, country: (team && team.country) || null },
      });
    } catch (error) {
      console.error(`[bsd] team ${teamId} failed: ${error.message || error}`);
    }
  }
  if (records.length > 0) await upsertBsdRecords("bsd_teams", records);
  console.log(`[bsd] teams hydrated: ${records.length}/${teamIds.length}`);
}

// Full events refresh: notstarted/started/finished lists + incidents/lineups for
// played matches + referenced teams, across every allowlisted league. Shared
// by the CLI entry point and the bsd runtime's periodic refresh.
async function refreshAllEvents() {
  console.log(`[bsd] events ingest, allowlist: ${BSD_LEAGUE_ALLOWLIST.join(", ")}`);
  const allEvents = [];
  for (const leagueId of BSD_LEAGUE_ALLOWLIST) {
    // eslint-disable-next-line no-await-in-loop
    const events = await ingestLeagueEvents(leagueId);
    allEvents.push(...events);
  }

  // Incidents/lineups for a played match rarely change once captured, so skip
  // events already hydrated rather than re-fetching the entire history every
  // run. Exception: early BSD payloads used "Unknown" for some manager cards
  // outside the normal timeline; rehydrate those so the now-populated player
  // name can surface in Match Events.
  const hydratedIds = new Set((await getBsdRecordIds("bsd_incidents")).map(String));
  const staleIncidentIds = new Set(
    (await getBsdRecords("bsd_incidents"))
      .filter(hasUnknownOutsideTimelineCardIncident)
      .map((doc) => String(doc._id))
  );
  const toHydrate = allEvents
    .filter(isPlayed)
    .filter((event) => !hydratedIds.has(String(event.id)) || staleIncidentIds.has(String(event.id)))
    .sort((a, b) => Date.parse(b.event_date || 0) - Date.parse(a.event_date || 0));
  console.log(`[bsd] hydrating incidents/lineups for ${toHydrate.length} played events (skipping ${allEvents.filter(isPlayed).length - toHydrate.length} already hydrated, stale=${staleIncidentIds.size})`);
  for (const event of toHydrate) {
    // eslint-disable-next-line no-await-in-loop
    await hydrateDetail(event);
  }

  const teamIds = new Set();
  allEvents.forEach((event) => {
    if (event.home_team_id != null) teamIds.add(event.home_team_id);
    if (event.away_team_id != null) teamIds.add(event.away_team_id);
  });
  await hydrateTeams([...teamIds]);

  console.log("[bsd] events ingest complete");
  return allEvents;
}

async function runCli() {
  await refreshAllEvents();
  await closeMongoConnection();
}

if (require.main === module) {
  runCli().catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

module.exports = {
  ingestLeagueEvents,
  hydrateDetail,
  hydrateTeams,
  isPlayed,
  hasUnknownOutsideTimelineCardIncident,
  eventToRecord,
  refreshAllEvents,
  EVENT_STATUSES,
};
