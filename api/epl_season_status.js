"use strict";

// Tracks whether Fantasy Premier League should be shown. BSD's league metadata
// is not reliable for this, so the gate compares the latest finished Premier
// League event with the next not-started Premier League event. Different
// season_id values mean we are between seasons, so FPL chrome should be hidden.

const bsd = require("./bsd_client");
const { getBsdRecords } = require("./mongo_client");

const PREMIER_LEAGUE_BSD_ID = "1";
const SEASON_STATUS_CACHE_TTL_MS = 24 * 60 * 60 * 1000;

// Safe default until the first refresh completes: FPL chrome should only be
// shown once the Premier League season window has been positively confirmed.
let cachedActive = false;
let cachedCheckedAtMs = 0;
let refreshInFlight = false;

function parseEventDateMs(value) {
  if (!value) return null;
  const trimmed = String(value).trim();
  const ms = Date.parse(trimmed);
  return Number.isFinite(ms) ? ms : null;
}

async function computeEplSeasonActive(nowMs) {
  return eventSeasonStatus(await fetchPremierLeagueSeasonEvents(), nowMs).active;
}

async function fetchPremierLeagueSeasonEvents() {
  try {
    const [finished, notStarted] = await Promise.all([
      bsd.getEvents(
        { leagueId: PREMIER_LEAGUE_BSD_ID, status: "finished" },
        { initiator: "epl_season_status" }
      ),
      bsd.getEvents(
        { leagueId: PREMIER_LEAGUE_BSD_ID, status: "notstarted" },
        { initiator: "epl_season_status" }
      ),
    ]);
    return [...finished, ...notStarted];
  } catch (error) {
    console.warn(`[EplSeasonStatus] BSD events API failed; falling back to Mongo: ${error.message || error}`);
    return getBsdRecords("bsd_events", {
      league_id: { $in: [Number(PREMIER_LEAGUE_BSD_ID), PREMIER_LEAGUE_BSD_ID] },
      status: { $in: ["finished", "notstarted"] },
    });
  }
}

function eventPayload(doc) {
  if (doc && doc.payload && typeof doc.payload === "object") return doc.payload;
  return doc && typeof doc === "object" ? doc : null;
}

function eventSeasonId(event) {
  const value = event && event.season_id;
  if (value === null || value === undefined || value === "") return null;
  return String(value);
}

function eventSeasonStatus(eventDocs, nowMs) {
  let lastFinished = null;
  let nextNotStarted = null;

  for (const doc of Array.isArray(eventDocs) ? eventDocs : []) {
    const event = eventPayload(doc);
    if (!event) continue;
    const ms = parseEventDateMs(event.event_date);
    if (!Number.isFinite(ms)) continue;

    const status = String(event.status || "").trim().toLowerCase();
    if (status === "finished" && ms <= nowMs) {
      if (!lastFinished || ms > lastFinished.eventDateMs) {
        lastFinished = { event, eventDateMs: ms };
      }
    } else if (status === "notstarted" && ms > nowMs) {
      if (!nextNotStarted || ms < nextNotStarted.eventDateMs) {
        nextNotStarted = { event, eventDateMs: ms };
      }
    }
  }

  const lastFinishedSeasonId = eventSeasonId(lastFinished && lastFinished.event);
  const nextNotStartedSeasonId = eventSeasonId(nextNotStarted && nextNotStarted.event);
  const active =
    lastFinishedSeasonId !== null &&
    nextNotStartedSeasonId !== null &&
    lastFinishedSeasonId === nextNotStartedSeasonId;

  return {
    active,
    lastFinished: lastFinished
      ? {
        id: lastFinished.event.id ?? null,
        eventDate: lastFinished.event.event_date || null,
        seasonId: lastFinishedSeasonId,
      }
      : null,
    nextNotStarted: nextNotStarted
      ? {
        id: nextNotStarted.event.id ?? null,
        eventDate: nextNotStarted.event.event_date || null,
        seasonId: nextNotStartedSeasonId,
      }
      : null,
  };
}

async function refreshEplSeasonActive(nowMs = Date.now()) {
  if (cachedCheckedAtMs && nowMs - cachedCheckedAtMs < SEASON_STATUS_CACHE_TTL_MS) {
    return cachedActive;
  }
  if (refreshInFlight) return cachedActive;
  refreshInFlight = true;
  try {
    const status = eventSeasonStatus(await fetchPremierLeagueSeasonEvents(), nowMs);
    cachedActive = status.active;
    cachedCheckedAtMs = nowMs;
  } catch (error) {
    console.error(`[EplSeasonStatus] refresh failed: ${error.message || error}`);
  } finally {
    refreshInFlight = false;
  }
  return cachedActive;
}

function isEplSeasonActiveCached() {
  return cachedActive;
}

function eplSeasonStatusSnapshot() {
  return {
    active: isEplSeasonActiveCached(),
    checkedAt: cachedCheckedAtMs ? new Date(cachedCheckedAtMs).toISOString() : null,
  };
}

module.exports = {
  PREMIER_LEAGUE_BSD_ID,
  refreshEplSeasonActive,
  isEplSeasonActiveCached,
  eplSeasonStatusSnapshot,
  __private: {
    parseEventDateMs,
    eventSeasonStatus,
    computeEplSeasonActive,
  },
};
