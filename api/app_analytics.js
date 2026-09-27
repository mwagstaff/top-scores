"use strict";

const crypto = require("node:crypto");
const { getDb } = require("./mongo_client");
const { zonedDateTimeToUtcMs } = require("./match_time");

const DAY = 86400000;
const RETENTION_DAYS = 45;
const SCREENS = new Set(["fixtures", "results", "scores", "match_detail", "tables", "fantasy", "predictions", "profile", "preferences", "about", "tv_listings"]);
const EVENTS = new Set([
  "app_open", "screen_view", "match_details_loaded", "manual_refresh", "prediction_submitted", "live_activity_started",
  "fixture_teams_changed", "fixture_competition_changed", "fixture_competition_favourites", "fixture_competition_all",
  "fixture_competition_favourites_saved", "fixture_premier_league_matches_preset", "fixture_top_teams_preset",
  "pref_epl_only_toggle", "pref_home_nations_toggle", "pref_major_uefa_toggle", "pref_major_tournaments_toggle",
  "pref_competition_filter_toggle", "pref_fixtures_all_major_matches_toggle", "pref_notifications_all_major_matches_toggle",
  "pref_notifications_same_as_fixtures_toggle", "pref_channel_filter_toggle",
]);
const SURFACES = new Set(["ios_app", "widget", "watch", "web"]);
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const BUCKETS = [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 2, 5, 10, 30];
const londonDay = (date) => new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/London", year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
const version = (value) => /^\d{1,3}(\.\d{1,3}){0,2}$/.test(String(value)) ? String(value) : "unknown";
const choice = (value, allowed, fallback = "unknown") => allowed.has(value) ? value : fallback;
function invalid(message) { return Object.assign(new Error(message), { status: 400 }); }

function normalizeEvent(payload, token, now = Date.now()) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw invalid("Invalid event.");
  if (!EVENTS.has(payload.event)) throw invalid("Unknown event.");
  const modern = payload.schemaVersion === 2;
  if (modern && (!UUID.test(token || "") || !UUID.test(payload.eventId || ""))) throw invalid("Invalid installation or event ID.");
  if (payload.screen != null && !SCREENS.has(payload.screen)) throw invalid("Unknown screen.");
  if (payload.event === "screen_view" && !SCREENS.has(payload.screen)) throw invalid("Screen is required.");
  const recorded = Date.parse(payload.recordedAt);
  if (modern && (!Number.isFinite(recorded) || recorded < now - 2 * DAY || recorded > now + 300000)) throw invalid("Event timestamp outside delivery window.");
  const at = modern ? Math.min(recorded, now) : now;
  const duration = payload.durationMs;
  return {
    event_id: modern ? payload.eventId.toLowerCase() : crypto.randomUUID(),
    schema: modern ? 2 : 1,
    event: payload.event, screen: payload.screen || "unknown",
    surface: modern ? choice(payload.surface, SURFACES) : "unknown",
    state: modern ? choice(payload.state, new Set(["foreground", "background"])) : "unknown",
    build_type: choice(payload.buildType, new Set(["production", "debug"])),
    app_version: version(payload.appVersion),
    os_major: /^\d{1,2}(\.\d+)*$/.test(String(payload.osVersion)) ? String(payload.osVersion).split(".")[0] : "unknown",
    device_type: choice(payload.deviceType, new Set(["phone", "pad", "mac", "vision"])),
    duration_seconds: typeof duration === "number" && Number.isFinite(duration) && duration >= 0 && duration <= 300000 ? duration / 1000 : null,
    recorded_at: new Date(at), day: londonDay(new Date(at)), updated_at: new Date(now),
    expires_at: new Date(at + RETENTION_DAYS * DAY),
  };
}

function windows(now) {
  const today = londonDay(new Date(now));
  const yesterday = londonDay(new Date(Date.parse(today + "T12:00:00Z") - DAY));
  const previous = londonDay(new Date(Date.parse(today + "T12:00:00Z") - 2 * DAY));
  const earlier = londonDay(new Date(Date.parse(today + "T12:00:00Z") - 3 * DAY));
  return {
    today: [zonedDateTimeToUtcMs(today, "00:00", "Europe/London"), now],
    yesterday: [zonedDateTimeToUtcMs(yesterday, "00:00", "Europe/London"), zonedDateTimeToUtcMs(today, "00:00", "Europe/London")],
    previous_day: [zonedDateTimeToUtcMs(previous, "00:00", "Europe/London"), zonedDateTimeToUtcMs(yesterday, "00:00", "Europe/London")],
    earlier_day: [zonedDateTimeToUtcMs(earlier, "00:00", "Europe/London"), zonedDateTimeToUtcMs(previous, "00:00", "Europe/London")],
    "7d": [now - 7 * DAY, now], "30d": [now - 30 * DAY, now],
  };
}

function summaryPipeline(now, buildType = "production") {
  const facets = {};
  for (const [window, [start, end]] of Object.entries(windows(now))) {
    const match = { $match: { recorded_at: { $gte: new Date(start), $lt: new Date(end) } } };
    facets[`${window}_total`] = [match, { $group: { _id: "$installation" } }, { $count: "count" }];
    for (const dimension of ["app_version", "os_major", "device_type"]) {
      facets[`${window}_${dimension}`] = [match,
        { $sort: { recorded_at: 1 } },
        { $group: { _id: "$installation", value: { $last: `$${dimension}` } } },
        { $group: { _id: "$value", count: { $sum: 1 } } },
      ];
    }
    facets[`${window}_features`] = [match,
      { $match: { event: "screen_view" } },
      { $group: { _id: { installation: "$installation", screen: "$screen" }, visits: { $sum: 1 } } },
      { $group: { _id: "$_id.screen", installations: { $sum: 1 }, visits: { $sum: "$visits" } } },
    ];
    facets[`${window}_events`] = [match, { $group: { _id: "$event", count: { $sum: 1 } } }];
    facets[`${window}_hours`] = [match,
      { $match: { event: "app_open" } },
      { $group: { _id: { hour: { $hour: { date: "$recorded_at", timezone: "Europe/London" } }, weekday: { $isoDayOfWeek: { date: "$recorded_at", timezone: "Europe/London" } } }, count: { $sum: 1 } } },
    ];
  }
  return [
    { $match: { schema: 2, build_type: buildType, surface: "ios_app", state: "foreground", recorded_at: { $gte: new Date(now - 30 * DAY) } } },
    { $facet: facets },
  ];
}

function routeFamily(path) {
  const part = String(path).replace(/^\/api\/v1\/?/, "").split("/")[0];
  return new Set(["matches", "tables", "teams", "players", "competitions", "channels", "fantasy", "prediction-game", "goal-guesser", "preferences", "live-activity", "live-activities", "app-metrics", "reference", "notifications", "device-token", "stadium-artwork"]).has(part) ? part : "other";
}

function createAppAnalytics({ database = getDb, clock = Date.now } = {}) {
  let ready, key, events, timer, refreshing;
  let snapshot = null, updated = 0, failures = 0;
  const deliveries = { accepted: 0, duplicate: 0, rejected: 0, unavailable: 0, limited: 0 };
  const requests = new Map(), durations = new Map(), eventCounts = new Map(), limits = new Map();
  async function initialize() {
    if (!ready) ready = (async () => {
      const db = await database();
      if (!db) throw new Error("Analytics database unavailable");
      events = db.collection("app_analytics_events");
      await events.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 });
      await events.createIndex({ schema: 1, build_type: 1, surface: 1, state: 1, recorded_at: 1 });
      const config = db.collection("app_analytics_config");
      try {
        await config.updateOne({ _id: "identity-key" }, { $setOnInsert: { key: crypto.randomBytes(32).toString("hex"), updated_at: new Date(clock()) } }, { upsert: true });
      } catch (error) { if (error.code !== 11000) throw error; }
      key = (await config.findOne({ _id: "identity-key" })).key;
      if (!/^[a-f0-9]{64}$/.test(key)) throw new Error("Analytics identity key invalid");
      return db;
    })().catch((error) => { ready = null; throw error; });
    return ready;
  }
  function hash(value) { return crypto.createHmac("sha256", key).update(value).digest("hex"); }
  async function accept(payload, token) {
    let event;
    try { event = normalizeEvent(payload, token, clock()); }
    catch (error) { deliveries.rejected++; throw error; }
    try {
      await initialize();
      const installation = hash(String(token || "unidentified").toLowerCase());
      const minute = Math.floor(clock() / 60000);
      if (limits.size >= 10000 || limits.get(installation)?.minute !== minute) {
        for (const [id, value] of limits) if (value.minute !== minute) limits.delete(id);
      }
      const bucket = limits.get(installation) || { minute, count: 0 };
      if (bucket.count >= 120 || (!limits.has(installation) && limits.size >= 10000)) {
        deliveries.limited++;
        throw Object.assign(new Error("Too many analytics events"), { status: 429 });
      }
      bucket.count++; limits.set(installation, bucket);
      const id = hash(`${installation}:${event.event_id}`);
      delete event.event_id;
      const result = await events.updateOne({ _id: id }, { $setOnInsert: { ...event, installation } }, { upsert: true });
      const duplicate = result.upsertedCount === 0;
      deliveries[duplicate ? "duplicate" : "accepted"]++;
      return { event, duplicate };
    } catch (error) {
      if (error.code === 11000) { deliveries.duplicate++; return { event, duplicate: true }; }
      if (error.status === 429) throw error;
      deliveries.unavailable++;
      throw Object.assign(new Error("Analytics temporarily unavailable"), { status: 503 });
    }
  }
  async function refresh() {
    if (refreshing) return refreshing;
    refreshing = (async () => {
      const db = await initialize();
      const now = clock();
      const next = {};
      for (const buildType of ["production", "debug"]) {
        const result = await events.aggregate(summaryPipeline(now, buildType), { maxTimeMS: 10000 }).toArray();
        const rows = result[0] || {}, summaries = {};
        for (const window of Object.keys(windows(now))) {
          const audience = {};
          for (const dimension of ["total", "app_version", "os_major", "device_type"]) audience[dimension] = rows[`${window}_${dimension}`] || [];
          summaries[window] = [{ audience: [audience], features: rows[`${window}_features`] || [], events: rows[`${window}_events`] || [], hours: rows[`${window}_hours`] || [] }];
        }
        // Preserve the production document IDs; debug summaries have a separate namespace.
        for (const window of ["today", "yesterday", "previous_day", "earlier_day"]) {
          const day = londonDay(new Date(windows(now)[window][0]));
          const id = buildType === "production" ? day : `${day}:debug`;
          await db.collection("app_analytics_daily").replaceOne({ _id: id }, { _id: id, build_type: buildType, summary: summaries[window]?.[0] || {}, updated_at: new Date(now) }, { upsert: true });
        }
        next[buildType] = summaries;
      }
      snapshot = next; updated = now;
    })().catch(() => { failures++; }).finally(() => { refreshing = null; });
    return refreshing;
  }
  function requestMiddleware(req, res, next) {
    if (!req.path.startsWith("/api/v1/")) return next();
    const start = performance.now();
    const labels = {
      surface: choice(req.get("X-Client-Surface"), SURFACES),
      state: choice(req.get("X-Client-State"), new Set(["foreground", "background"])),
      build_type: choice(req.get("X-Build-Type"), new Set(["production", "debug"])),
      route: routeFamily(req.path),
      identified: UUID.test(req.get("X-Device-Token") || "") ? "yes" : "no",
    };
    res.on("finish", () => {
      const fields = { ...labels, status: `${Math.floor(res.statusCode / 100)}xx` };
      const id = JSON.stringify(fields), seconds = (performance.now() - start) / 1000;
      const row = requests.get(id) || { labels: fields, count: 0, sum: 0, buckets: BUCKETS.map(() => 0) };
      row.count++; row.sum += seconds;
      BUCKETS.forEach((limit, i) => { if (seconds <= limit) row.buckets[i]++; });
      requests.set(id, row);
    });
    next();
  }
  function recordDuration(event) {
    if (event.schema !== 2 || !["production", "debug"].includes(event.build_type) || event.surface !== "ios_app" || event.state !== "foreground") return;
    const id = `${event.build_type}:${event.event}:${event.screen}`;
    const count = eventCounts.get(id) || { labels: { event: event.event, screen: event.screen, build_type: event.build_type }, count: 0 };
    count.count++; eventCounts.set(id, count);
    if (event.duration_seconds == null) return;
    const row = durations.get(id) || { labels: { event: event.event, screen: event.screen, build_type: event.build_type }, count: 0, sum: 0, buckets: BUCKETS.map(() => 0) };
    row.count++; row.sum += event.duration_seconds;
    BUCKETS.forEach((limit, i) => { if (event.duration_seconds <= limit) row.buckets[i]++; });
    durations.set(id, row);
  }
  function metrics() {
    const lines = [], declared = new Set();
    function emit(name, value, labels = {}, type = "gauge") {
      name = `top_scores_audience_${name}`;
      if (!declared.has(name)) { lines.push(`# HELP ${name} Top Scores audience analytics.`, `# TYPE ${name} ${type}`); declared.add(name); }
      const fields = Object.entries(labels).map(([k, v]) => `${k}=${JSON.stringify(String(v))}`).join(",");
      lines.push(`${name}${fields ? `{${fields}}` : ""} ${value}`);
    }
    emit("ready", snapshot && clock() - updated < 180000 ? 1 : 0);
    emit("snapshot_timestamp_seconds", updated / 1000);
    emit("refresh_failures_total", failures, {}, "counter");
    for (const [result, count] of Object.entries(deliveries)) emit("deliveries_total", count, { result }, "counter");
    for (const row of eventCounts.values()) emit("events_total", row.count, row.labels, "counter");
    if (snapshot) for (const build_type of ["production", "debug"]) for (const window of Object.keys(windows(clock()))) {
      if (window === "previous_day" || window === "earlier_day") continue;
      const data = snapshot[build_type][window]?.[0] || {};
      const audience = data.audience?.[0] || {};
      emit("active_installations", audience.total?.[0]?.count || 0, { window, build_type });
      for (const dimension of ["app_version", "os_major", "device_type"]) {
        for (const row of audience[dimension] || []) emit("installations_by_dimension", row.count, { window, dimension, value: row._id, build_type });
      }
      for (const screen of SCREENS) {
        const row = data.features?.find((item) => item._id === screen);
        emit("feature_installations", row?.installations || 0, { window, screen, build_type });
        emit("feature_visits", row?.visits || 0, { window, screen, build_type });
      }
      for (const event of EVENTS) emit("events", data.events?.find((item) => item._id === event)?.count || 0, { window, event, build_type });
      if (window === "30d") for (let weekday = 1; weekday <= 7; weekday++) for (let hour = 0; hour < 24; hour++) {
        const row = data.hours?.find((item) => item._id.hour === hour && item._id.weekday === weekday);
        emit("sessions_by_hour", row?.count || 0, { weekday, hour: String(hour).padStart(2, "0"), build_type });
      }
    }
    function histogram(name, rows) {
      const full = `top_scores_audience_${name}`;
      lines.push(`# HELP ${full} Observed duration in seconds.`, `# TYPE ${full} histogram`);
      declared.add(full + "_bucket"); declared.add(full + "_count"); declared.add(full + "_sum");
      for (const row of rows.values()) {
        BUCKETS.forEach((limit, i) => emit(name + "_bucket", row.buckets[i], { ...row.labels, le: limit }));
        emit(name + "_bucket", row.count, { ...row.labels, le: "+Inf" });
        emit(name + "_count", row.count, row.labels); emit(name + "_sum", row.sum, row.labels);
      }
    }
    histogram("request_duration_seconds", requests);
    histogram("event_duration_seconds", durations);
    return lines.join("\n");
  }
  return { accept, refresh, metrics, requestMiddleware, recordDuration,
    start() { if (!timer) { void refresh(); timer = setInterval(() => { void refresh(); }, 60000); timer.unref?.(); } },
    stop() { clearInterval(timer); timer = null; },
  };
}

module.exports = { createAppAnalytics, normalizeEvent, summaryPipeline, windows, routeFamily, SCREENS, EVENTS };
