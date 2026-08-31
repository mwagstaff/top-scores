"use strict";

const crypto = require("crypto");
const { fetchLiveFootballTvListings } = require("./fetch_live_footballontv");
const { BSD_LEAGUE_ALLOWLIST } = require("./bsd_config");
const { zonedDateTimeToUtcMs } = require("./match_time");
const {
  normalizeTeamIdentityName,
  teamNamesEquivalent,
} = require("./team_identity");
const {
  acquireLiveFootballTvLease,
  releaseLiveFootballTvLease,
  saveLiveFootballTvSnapshot,
  getLiveFootballTvSnapshot,
  getActiveLiveFootballTvListings,
  updateLiveFootballTvListingMatches,
  pruneLiveFootballTvSnapshots,
  getBsdRecords,
  getOperationalDataset,
  saveOperationalDataset,
} = require("./mongo_client");

const METADATA_DATASET = "live_football_tv_listings_meta";
const LONDON_TIME_ZONE = "Europe/London";
const LEASE_TTL_MS = 5 * 60 * 1000;
const MIN_SNAPSHOT_LISTINGS = 25;
const MIN_FUZZY_TEAM_SCORE = 0.72;
const MIN_FUZZY_AVERAGE_SCORE = 0.82;
const MIN_MATCH_CONFIDENCE = 0.82;
const MIN_MATCH_MARGIN = 0.08;
const MAX_EXACT_TIME_DELTA_MINUTES = 6 * 60;
const MAX_FUZZY_TIME_DELTA_MINUTES = 3 * 60;

const londonFormatter = new Intl.DateTimeFormat("en-GB", {
  timeZone: LONDON_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

function londonDateTime(value) {
  const timestamp = Date.parse(String(value || ""));
  if (!Number.isFinite(timestamp)) return null;
  const parts = {};
  londonFormatter.formatToParts(new Date(timestamp)).forEach((part) => {
    if (part.type !== "literal") parts[part.type] = part.value;
  });
  if (!parts.year || !parts.month || !parts.day || !parts.hour || !parts.minute) return null;
  return {
    date: `${parts.year}-${parts.month}-${parts.day}`,
    time: `${parts.hour}:${parts.minute}`,
    timestamp,
  };
}

function normalizedName(value) {
  return normalizeTeamIdentityName(value).replace(/[^a-z0-9]+/g, " ").trim();
}

function levenshtein(leftValue, rightValue) {
  const left = Array.from(leftValue);
  const right = Array.from(rightValue);
  const previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  const current = new Array(right.length + 1).fill(0);
  for (let leftIndex = 0; leftIndex < left.length; leftIndex += 1) {
    current[0] = leftIndex + 1;
    for (let rightIndex = 0; rightIndex < right.length; rightIndex += 1) {
      const cost = left[leftIndex] === right[rightIndex] ? 0 : 1;
      current[rightIndex + 1] = Math.min(
        previous[rightIndex + 1] + 1,
        current[rightIndex] + 1,
        previous[rightIndex] + cost
      );
    }
    for (let index = 0; index < current.length; index += 1) previous[index] = current[index];
  }
  return previous[right.length];
}

function tokenDice(leftValue, rightValue) {
  const left = new Set(normalizedName(leftValue).split(" ").filter(Boolean));
  const right = new Set(normalizedName(rightValue).split(" ").filter(Boolean));
  if (left.size === 0 || right.size === 0) return 0;
  let intersection = 0;
  left.forEach((token) => {
    if (right.has(token)) intersection += 1;
  });
  return (2 * intersection) / (left.size + right.size);
}

function teamSimilarity(leftValue, rightValue) {
  if (teamNamesEquivalent(leftValue, rightValue)) return 1;
  const left = normalizedName(leftValue).replace(/\s+/g, "");
  const right = normalizedName(rightValue).replace(/\s+/g, "");
  if (!left || !right) return 0;
  const characterScore = 1 - levenshtein(left, right) / Math.max(left.length, right.length);
  return Math.max(characterScore, tokenDice(leftValue, rightValue));
}

function minutesFromTime(value) {
  const match = String(value || "").match(/^(\d{2}):(\d{2})$/);
  return match ? Number(match[1]) * 60 + Number(match[2]) : null;
}

function timeDeltaMinutes(left, right) {
  const leftMinutes = minutesFromTime(left);
  const rightMinutes = minutesFromTime(right);
  if (!Number.isFinite(leftMinutes) || !Number.isFinite(rightMinutes)) return Infinity;
  return Math.abs(leftMinutes - rightMinutes);
}

function timeConfidence(deltaMinutes) {
  if (deltaMinutes === 0) return 1;
  if (deltaMinutes <= 15) return 0.95;
  if (deltaMinutes <= 60) return 0.8;
  if (deltaMinutes <= 180) return 0.55;
  if (deltaMinutes <= 360) return 0.25;
  return 0;
}

function competitionConfidence(listingCompetition, eventCompetition) {
  if (!listingCompetition || !eventCompetition) return 0.5;
  const score = teamSimilarity(listingCompetition, eventCompetition);
  return Math.max(0.25, score);
}

function sourceKeyForListing(listing) {
  const identity = [
    listing.date_local,
    listing.time_local,
    normalizedName(listing.competition),
    normalizedName(listing.home_team),
    normalizedName(listing.away_team),
  ].join("|");
  return crypto.createHash("sha1").update(identity).digest("hex");
}

function prepareListings(listings) {
  const bySourceKey = new Map();
  (Array.isArray(listings) ? listings : []).forEach((listing) => {
    if (!listing || !listing.date_local || !listing.time_local) return;
    const homeTeam = String(listing.home_team || "").trim();
    const awayTeam = String(listing.away_team || "").trim();
    const competition = String(listing.competition || "").trim();
    if (!homeTeam || !awayTeam || !competition || !Array.isArray(listing.channels)) return;
    const sourceKey = sourceKeyForListing(listing);
    const kickoffMs = zonedDateTimeToUtcMs(
      listing.date_local,
      listing.time_local,
      LONDON_TIME_ZONE
    );
    if (!Number.isFinite(kickoffMs)) return;
    const existing = bySourceKey.get(sourceKey);
    const channels = [];
    const seen = new Set();
    [...(existing && existing.channels || []), ...(listing.channels || [])].forEach((channel) => {
      const name = String(channel && channel.name || "").trim();
      const key = name.toLowerCase();
      if (!name || seen.has(key)) return;
      seen.add(key);
      channels.push({ name, country: "United Kingdom", countryCode: "GB", logo: null });
    });
    if (channels.length === 0) return;
    bySourceKey.set(sourceKey, {
      source_key: sourceKey,
      date_local: listing.date_local,
      time_local: listing.time_local,
      time_zone: LONDON_TIME_ZONE,
      kickoff_at: new Date(kickoffMs).toISOString(),
      home_team: homeTeam,
      away_team: awayTeam,
      competition,
      channels,
      matched_event_id: null,
      match_status: "unmatched",
    });
  });
  return Array.from(bySourceKey.values());
}

function buildEventCandidates(eventDocs, leagueDocs = []) {
  const leagueNames = new Map();
  leagueDocs.forEach((doc) => {
    const payload = doc && doc.payload || {};
    const id = payload.id != null ? String(payload.id) : String(doc && doc._id || "");
    if (id && payload.name) leagueNames.set(id, String(payload.name));
  });
  const byDate = new Map();
  eventDocs.forEach((doc) => {
    const event = doc && doc.payload || doc;
    if (!event || event.id == null) return;
    const local = londonDateTime(event.event_date);
    if (!local) return;
    const candidate = {
      event_id: String(event.id),
      date_local: local.date,
      time_local: local.time,
      home_team: String(event.home_team || "").trim(),
      away_team: String(event.away_team || "").trim(),
      competition: leagueNames.get(String(event.league_id)) || String(event.league_name || ""),
    };
    if (!candidate.home_team || !candidate.away_team) return;
    if (!byDate.has(local.date)) byDate.set(local.date, []);
    byDate.get(local.date).push(candidate);
  });
  return byDate;
}

function scoreCandidate(listing, candidate) {
  const homeScore = teamSimilarity(listing.home_team, candidate.home_team);
  const awayScore = teamSimilarity(listing.away_team, candidate.away_team);
  const exactTeams = homeScore === 1 && awayScore === 1;
  const deltaMinutes = timeDeltaMinutes(listing.time_local, candidate.time_local);
  const nameAverage = (homeScore + awayScore) / 2;
  const confidence = (
    homeScore * 0.41 +
    awayScore * 0.41 +
    timeConfidence(deltaMinutes) * 0.14 +
    competitionConfidence(listing.competition, candidate.competition) * 0.04
  );
  const eligible = exactTeams
    ? deltaMinutes <= MAX_EXACT_TIME_DELTA_MINUTES
    : deltaMinutes <= MAX_FUZZY_TIME_DELTA_MINUTES &&
      Math.min(homeScore, awayScore) >= MIN_FUZZY_TEAM_SCORE &&
      nameAverage >= MIN_FUZZY_AVERAGE_SCORE &&
      confidence >= MIN_MATCH_CONFIDENCE;
  return {
    ...candidate,
    confidence,
    delta_minutes: deltaMinutes,
    exact_teams: exactTeams,
    eligible,
    method: exactTeams ? "canonical_teams_and_kickoff" : "fuzzy_teams_and_kickoff",
  };
}

function matchListingsToEvents(listings, eventDocs, leagueDocs = []) {
  const candidatesByDate = buildEventCandidates(eventDocs, leagueDocs);
  const proposals = listings.map((listing) => {
    const candidates = (candidatesByDate.get(listing.date_local) || [])
      .map((candidate) => scoreCandidate(listing, candidate))
      .sort((left, right) => right.confidence - left.confidence || left.delta_minutes - right.delta_minutes);
    const best = candidates[0] || null;
    const second = candidates[1] || null;
    const margin = best ? best.confidence - (second ? second.confidence : 0) : 0;
    return { listing, best, second, margin };
  }).sort((left, right) => (right.best && right.best.confidence || 0) - (left.best && left.best.confidence || 0));

  const usedEventIds = new Set();
  const assignmentsByKey = new Map();
  proposals.forEach(({ listing, best, margin }) => {
    let assignment = {
      source_key: listing.source_key,
      matched_event_id: null,
      match_status: "unmatched",
      match_method: null,
      match_confidence: best ? best.confidence : null,
      match_margin: best ? margin : null,
      match_reason: best ? "no_candidate_met_threshold" : "no_same_date_candidate",
    };
    if (best && best.eligible && margin < MIN_MATCH_MARGIN) {
      assignment = {
        ...assignment,
        match_status: "ambiguous",
        match_method: best.method,
        match_reason: "candidate_margin_too_small",
      };
    } else if (best && best.eligible && usedEventIds.has(best.event_id)) {
      assignment = {
        ...assignment,
        match_status: "ambiguous",
        match_method: best.method,
        match_reason: "event_already_matched",
      };
    } else if (best && best.eligible) {
      usedEventIds.add(best.event_id);
      assignment = {
        ...assignment,
        matched_event_id: best.event_id,
        match_status: "matched",
        match_method: best.method,
        match_reason: null,
      };
    }
    assignmentsByKey.set(listing.source_key, assignment);
  });

  const assignments = listings.map((listing) => assignmentsByKey.get(listing.source_key));
  return {
    assignments,
    matched: assignments.filter((item) => item.match_status === "matched").length,
    ambiguous: assignments.filter((item) => item.match_status === "ambiguous").length,
    unmatched: assignments.filter((item) => item.match_status === "unmatched").length,
  };
}

async function reconcileLiveFootballTvSnapshot(snapshotId) {
  const allowedLeagueIds = Array.from(new Set(
    BSD_LEAGUE_ALLOWLIST.flatMap((id) => {
      const numeric = Number(id);
      return Number.isFinite(numeric) ? [String(id), numeric] : [String(id)];
    })
  ));
  const [listings, eventDocs, leagueDocs] = await Promise.all([
    getLiveFootballTvSnapshot(snapshotId),
    getBsdRecords("bsd_events", {
      $or: [
        { league_id: { $in: allowedLeagueIds } },
        { "payload.league_id": { $in: allowedLeagueIds } },
      ],
    }),
    getBsdRecords("bsd_leagues"),
  ]);
  const result = matchListingsToEvents(listings, eventDocs, leagueDocs);
  const listingBySourceKey = new Map(listings.map((listing) => [listing.source_key, listing]));
  const changedAssignments = result.assignments.filter((assignment) => {
    const current = listingBySourceKey.get(assignment.source_key) || {};
    return [
      "matched_event_id",
      "match_status",
      "match_method",
      "match_confidence",
      "match_margin",
      "match_reason",
    ].some((field) => current[field] !== assignment[field]);
  });
  await updateLiveFootballTvListingMatches(snapshotId, changedAssignments);
  return {
    snapshot_id: snapshotId,
    total: listings.length,
    updated: changedAssignments.length,
    ...result,
  };
}

async function reconcileActiveLiveFootballTvListings() {
  const active = await getActiveLiveFootballTvListings();
  if (!active.snapshot_id) {
    return { snapshot_id: null, total: 0, matched: 0, ambiguous: 0, unmatched: 0 };
  }
  const result = await reconcileLiveFootballTvSnapshot(active.snapshot_id);
  const payload = {
    ...(active.metadata && active.metadata.payload || {}),
    matched_count: result.matched,
    ambiguous_count: result.ambiguous,
    unmatched_count: result.unmatched,
    last_reconciled_at: new Date().toISOString(),
  };
  await saveOperationalDataset({
    name: METADATA_DATASET,
    source: "live-footballontv.com",
    updated_at: new Date().toISOString(),
    payload,
  });
  return result;
}

function validateSnapshot(records, previousMetadata) {
  if (!Array.isArray(records) || records.length < MIN_SNAPSHOT_LISTINGS) {
    throw new Error(
      `TV listings scrape produced too few valid listings (${Array.isArray(records) ? records.length : 0})`
    );
  }
  const previousCount = Number(
    previousMetadata && previousMetadata.payload && previousMetadata.payload.parsed_count
  );
  if (previousCount >= 100 && records.length < Math.floor(previousCount * 0.5)) {
    throw new Error(
      `TV listings scrape count dropped unexpectedly (${records.length} from ${previousCount})`
    );
  }
}

async function refreshLiveFootballTvListings(options = {}) {
  const owner = `${process.pid}:${crypto.randomUUID()}`;
  const acquired = await acquireLiveFootballTvLease(owner, options.leaseTtlMs || LEASE_TTL_MS);
  if (acquired === null) {
    throw new Error("MongoDB is required to refresh supplementary TV listings");
  }
  if (!acquired) {
    const error = new Error("TV listings refresh already in progress");
    error.code = "TV_LISTINGS_REFRESH_IN_PROGRESS";
    throw error;
  }
  const startedAtMs = Date.now();
  try {
    const previousMetadata = await getOperationalDataset(METADATA_DATASET);
    const fetched = await (options.fetchListings || fetchLiveFootballTvListings)(options);
    const records = prepareListings(fetched.listings);
    validateSnapshot(records, previousMetadata);
    const snapshotId = `${Date.now()}-${crypto.randomUUID()}`;
    const saved = await saveLiveFootballTvSnapshot(snapshotId, records, {
      source_url: fetched.url,
      scraped_at: fetched.fetched_at,
    });
    if (!saved || saved.written !== records.length) {
      throw new Error("MongoDB did not persist the complete TV listings snapshot");
    }
    const reconciliation = await reconcileLiveFootballTvSnapshot(snapshotId);
    const previousSnapshotId = previousMetadata && previousMetadata.payload
      ? previousMetadata.payload.active_snapshot_id || null
      : null;
    const dates = records.map((record) => record.date_local).sort();
    const payload = {
      active_snapshot_id: snapshotId,
      previous_snapshot_id: previousSnapshotId,
      source_url: fetched.url,
      scraped_at: fetched.fetched_at,
      parsed_count: records.length,
      matched_count: reconciliation.matched,
      ambiguous_count: reconciliation.ambiguous,
      unmatched_count: reconciliation.unmatched,
      first_listing_date: dates[0] || null,
      last_listing_date: dates[dates.length - 1] || null,
      html_bytes: fetched.html_bytes || null,
      duration_ms: Date.now() - startedAtMs,
      trigger: options.trigger || "manual",
    };
    await saveOperationalDataset({
      name: METADATA_DATASET,
      source: "live-footballontv.com",
      updated_at: new Date().toISOString(),
      payload,
      payload_count: records.length,
    });
    const pruned = await pruneLiveFootballTvSnapshots([snapshotId, previousSnapshotId]);
    return { success: true, snapshot_id: snapshotId, pruned, ...payload };
  } finally {
    await releaseLiveFootballTvLease(owner).catch(() => {});
  }
}

module.exports = {
  METADATA_DATASET,
  refreshLiveFootballTvListings,
  reconcileActiveLiveFootballTvListings,
  reconcileLiveFootballTvSnapshot,
  matchListingsToEvents,
  prepareListings,
  sourceKeyForListing,
  teamSimilarity,
  __private: {
    buildEventCandidates,
    londonDateTime,
    scoreCandidate,
    timeDeltaMinutes,
    validateSnapshot,
  },
};
