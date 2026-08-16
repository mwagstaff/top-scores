#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// Ingest BSD events (matches) into Mongo for the allowlisted leagues:
//   - notstarted + finished events         -> bsd_events
//   - incidents/lineups for played     -> bsd_incidents, bsd_lineups
//   - referenced teams                 -> bsd_teams
//   - referenced venues                -> bsd_venues
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

// `started` is historical in BSD (it includes events that started long ago),
// not a synonym for currently live. Live matches come from /events/live, so
// bulk ingestion only needs upcoming and finished lists.
const EVENT_STATUSES = ["notstarted", "finished"];

function positiveNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

const INCREMENTAL_UPCOMING_MAX_PAGES = Math.floor(
  positiveNumber(process.env.BSD_EVENTS_INCREMENTAL_UPCOMING_MAX_PAGES, 5)
);
const INCREMENTAL_FINISHED_MAX_PAGES = Math.floor(
  positiveNumber(process.env.BSD_EVENTS_INCREMENTAL_FINISHED_MAX_PAGES, 1)
);
const INCREMENTAL_FINISHED_DAYS = positiveNumber(
  process.env.BSD_EVENTS_INCREMENTAL_FINISHED_DAYS,
  7
);
const RECENT_FINISHED_DETAIL_WINDOW_MS = positiveNumber(
  process.env.BSD_RECENT_FINISHED_DETAIL_WINDOW_MS,
  4 * 60 * 60 * 1000
);
const RECENT_FINISHED_DETAIL_REFRESH_MS = positiveNumber(
  process.env.BSD_RECENT_FINISHED_DETAIL_REFRESH_MS,
  15 * 60 * 1000
);

function eventToRecord(event) {
  return {
    id: event.id,
    payload: event,
    extra: {
      league_id: event.league_id != null ? event.league_id : null,
      status: event.status || null,
      season_id: event.season_id != null ? event.season_id : null,
      event_date: event.event_date || null,
      home_team: event.home_team || null,
      away_team: event.away_team || null,
      home_team_id: event.home_team_id != null ? event.home_team_id : null,
      away_team_id: event.away_team_id != null ? event.away_team_id : null,
      venue_id: event.venue_id != null ? event.venue_id : null,
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

function isRecentFinishedEvent(event, nowMs = Date.now()) {
  if (!event || String(event.status || "").toLowerCase() !== "finished") return false;
  const eventDateMs = Date.parse(event.event_date || "");
  if (!Number.isFinite(eventDateMs)) return false;
  const windowMs = Math.max(0, INCREMENTAL_FINISHED_DAYS) * 24 * 60 * 60 * 1000;
  return eventDateMs >= nowMs - windowMs;
}

function needsRecentFinishedDetailRefresh(event, incidentDoc, nowMs = Date.now()) {
  if (!event || String(event.status || "").toLowerCase() !== "finished") return false;
  const eventDateMs = Date.parse(event.event_date || "");
  if (
    !Number.isFinite(eventDateMs) ||
    eventDateMs > nowMs ||
    nowMs - eventDateMs > RECENT_FINISHED_DETAIL_WINDOW_MS
  ) {
    return false;
  }
  const lastRefreshMs = Date.parse((incidentDoc && incidentDoc.updated_at) || "");
  return (
    !Number.isFinite(lastRefreshMs) ||
    nowMs - lastRefreshMs >= RECENT_FINISHED_DETAIL_REFRESH_MS
  );
}

function selectIncrementalEvents(events, nowMs = Date.now()) {
  const source = Array.isArray(events) ? events : [];
  const retained = source.filter((event) => {
    const status = String(event && event.status ? event.status : "").toLowerCase();
    return status === "notstarted" || isRecentFinishedEvent(event, nowMs);
  });
  const newestFinished = source
    .filter((event) => {
      const status = String(event && event.status ? event.status : "").toLowerCase();
      return status === "finished" && Number.isFinite(Date.parse(event.event_date || ""));
    })
    .sort((a, b) => Date.parse(b.event_date) - Date.parse(a.event_date))[0];
  if (newestFinished && !retained.includes(newestFinished)) retained.push(newestFinished);
  return retained;
}

async function ingestLeagueEvents(leagueId, options = {}) {
  const statuses = Array.isArray(options.statuses) ? options.statuses : EVENT_STATUSES;
  const maxPagesByStatus = options.maxPagesByStatus || {};
  const filterEvents = typeof options.filterEvents === "function" ? options.filterEvents : null;
  const collected = [];
  for (const status of statuses) {
    const maxPages = Number(maxPagesByStatus[status]);
    // eslint-disable-next-line no-await-in-loop
    const events = await bsd.getEvents(
      { leagueId, status },
      {
        initiator: "fetch_bsd_events",
        ...(Number.isFinite(maxPages) && maxPages > 0 ? { maxPages } : {}),
      }
    );
    const retained = filterEvents ? filterEvents(events, status) : events;
    collected.push(...retained);
    console.log(
      `[bsd] league ${leagueId} status=${status}: ${events.length} fetched, ${retained.length} retained`
    );
  }
  const records = collected
    .filter((event) => event && event.id != null)
    .map(eventToRecord);
  await upsertBsdRecords("bsd_events", records);
  return collected;
}

async function ingestLeagueIncrementalEvents(leagueId, nowMs = Date.now()) {
  return ingestLeagueEvents(leagueId, {
    maxPagesByStatus: {
      notstarted: INCREMENTAL_UPCOMING_MAX_PAGES,
      finished: INCREMENTAL_FINISHED_MAX_PAGES,
    },
    filterEvents: (events) => selectIncrementalEvents(events, nowMs),
  });
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

async function hydrateVenues(venueIds) {
  const records = [];
  for (const venueId of venueIds) {
    try {
      // eslint-disable-next-line no-await-in-loop
      const venue = await bsd.getVenue(venueId, { initiator: "fetch_bsd_events" });
      records.push({
        id: venueId,
        payload: venue,
        extra: {
          name: (venue && venue.name) || null,
          city: (venue && venue.city) || null,
          country_code: (venue && venue.country_code) || null,
          latitude: venue && venue.latitude != null ? venue.latitude : null,
          longitude: venue && venue.longitude != null ? venue.longitude : null,
        },
      });
    } catch (error) {
      console.error(`[bsd] venue ${venueId} failed: ${error.message || error}`);
    }
  }
  if (records.length > 0) await upsertBsdRecords("bsd_venues", records);
  console.log(`[bsd] venues hydrated: ${records.length}/${venueIds.length}`);
}

async function hydrateMissingDetails(allEvents, nowMs = Date.now()) {
  // Incidents/lineups for a played match rarely change once captured, so skip
  // events already hydrated rather than re-fetching the entire history every
  // run. Recently finished matches are deliberately revisited so a restart
  // cannot lose the post-match settlement passes. Early BSD payloads with an
  // "Unknown" manager card are also refreshed.
  const incidentDocs = await getBsdRecords("bsd_incidents");
  const hydratedIds = new Set(incidentDocs.map((doc) => String(doc._id)));
  const incidentDocsById = new Map(incidentDocs.map((doc) => [String(doc._id), doc]));
  const staleIncidentIds = new Set(
    incidentDocs
      .filter(hasUnknownOutsideTimelineCardIncident)
      .map((doc) => String(doc._id))
  );
  const toHydrate = allEvents
    .filter(isPlayed)
    .filter((event) => {
      const id = String(event.id);
      return (
        !hydratedIds.has(id) ||
        staleIncidentIds.has(id) ||
        needsRecentFinishedDetailRefresh(event, incidentDocsById.get(id), nowMs)
      );
    })
    .sort((a, b) => Date.parse(b.event_date || 0) - Date.parse(a.event_date || 0));
  console.log(`[bsd] hydrating incidents/lineups for ${toHydrate.length} played events (skipping ${allEvents.filter(isPlayed).length - toHydrate.length} already hydrated, stale=${staleIncidentIds.size})`);
  for (const event of toHydrate) {
    // eslint-disable-next-line no-await-in-loop
    await hydrateDetail(event);
  }
}

async function hydrateMissingTeams(allEvents) {
  const hydratedTeamIds = new Set((await getBsdRecordIds("bsd_teams")).map(String));
  const teamIds = new Set();
  allEvents.forEach((event) => {
    if (event.home_team_id != null && !hydratedTeamIds.has(String(event.home_team_id))) {
      teamIds.add(event.home_team_id);
    }
    if (event.away_team_id != null && !hydratedTeamIds.has(String(event.away_team_id))) {
      teamIds.add(event.away_team_id);
    }
  });
  await hydrateTeams([...teamIds]);
}

async function hydrateMissingVenues(allEvents) {
  const hydratedVenueIds = new Set((await getBsdRecordIds("bsd_venues")).map(String));
  const venueIds = new Set();
  allEvents.forEach((event) => {
    if (event.venue_id != null && !hydratedVenueIds.has(String(event.venue_id))) {
      venueIds.add(event.venue_id);
    }
  });
  await hydrateVenues([...venueIds]);
}

// Explicit full-history backfill. The long-running poller intentionally uses
// refreshIncrementalEvents instead.
async function refreshAllEvents() {
  console.log(`[bsd] events ingest, allowlist: ${BSD_LEAGUE_ALLOWLIST.join(", ")}`);
  const allEvents = [];
  for (const leagueId of BSD_LEAGUE_ALLOWLIST) {
    // eslint-disable-next-line no-await-in-loop
    const events = await ingestLeagueEvents(leagueId);
    allEvents.push(...events);
  }

  await hydrateMissingDetails(allEvents);
  await hydrateMissingTeams(allEvents);
  await hydrateMissingVenues(allEvents);

  console.log("[bsd] events ingest complete");
  return allEvents;
}

// Automatic runtime refresh: bounded to upcoming fixtures and the newest page
// of recently finished matches. Full history is intentionally reserved for
// the explicit CLI backfill above.
async function refreshIncrementalEvents() {
  console.log(`[bsd] incremental events ingest, allowlist: ${BSD_LEAGUE_ALLOWLIST.join(", ")}`);
  const allEvents = [];
  for (const leagueId of BSD_LEAGUE_ALLOWLIST) {
    // eslint-disable-next-line no-await-in-loop
    const events = await ingestLeagueIncrementalEvents(leagueId);
    allEvents.push(...events);
  }
  await hydrateMissingDetails(allEvents);
  await hydrateMissingTeams(allEvents);
  await hydrateMissingVenues(allEvents);
  console.log(`[bsd] incremental events ingest complete: ${allEvents.length} events`);
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
  ingestLeagueIncrementalEvents,
  hydrateDetail,
  hydrateTeams,
  hydrateVenues,
  hydrateMissingDetails,
  hydrateMissingTeams,
  hydrateMissingVenues,
  isPlayed,
  hasUnknownOutsideTimelineCardIncident,
  eventToRecord,
  refreshAllEvents,
  refreshIncrementalEvents,
  EVENT_STATUSES,
  INCREMENTAL_UPCOMING_MAX_PAGES,
  INCREMENTAL_FINISHED_MAX_PAGES,
  INCREMENTAL_FINISHED_DAYS,
  RECENT_FINISHED_DETAIL_WINDOW_MS,
  RECENT_FINISHED_DETAIL_REFRESH_MS,
  isRecentFinishedEvent,
  needsRecentFinishedDetailRefresh,
  selectIncrementalEvents,
};
