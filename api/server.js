#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const path = require("path");
const http = require("http");
const https = require("https");
const crypto = require("crypto");
const v8 = require("v8");
const zlib = require("zlib");
const { monitorEventLoopDelay, performance } = require("perf_hooks");
const express = require("express");
const liveActivityMetrics = require("./live_activity_metrics");
const {
  SERVER_CONFIG,
  TEAM_RANKING_SOURCE_MERGED,
  TEAM_RANKING_SOURCE_CLUBELO,
  TEAM_RANKING_SOURCE_FOOTBALLDATABASE,
  TEAM_RANKING_SOURCE_NATIONAL_ELO,
  normalizeTeamRankingSource,
} = require("./config");
const {
  DEFAULT_URL,
  DEFAULT_OUTPUT,
  fetchMatches,
  writeMatches,
} = require("./fetch_live_footballontv");
const {
  DEFAULT_BBC_URL,
  DEFAULT_BBC_OUTPUT,
  DEFAULT_BBC_MATCH_TIMEZONE,
  DEFAULT_BBC_RANGE_PAST_DAYS,
  DEFAULT_BBC_RANGE_FUTURE_DAYS,
  DEFAULT_BBC_RANGE_CONCURRENCY,
  fetchBbcFixtures,
  fetchBbcScoresFixturesByDateRange,
  fetchBbcMatchByDetailsUrl,
  writeBbcFixtures,
} = require("./fetch_bbc_scores");
const {
  DEFAULT_BBC_TABLES_URL,
  DEFAULT_BBC_PREMIER_LEAGUE_OUTPUT,
  fetchPremierLeagueTeams,
  writePremierLeagueTeams,
} = require("./fetch_bbc_premier_league_table");
const {
  LEAGUE_TABLE_SOURCES,
  DEFAULT_BBC_LEAGUE_TABLES_OUTPUT,
  fetchLeagueTables,
  writeLeagueTables,
} = require("./fetch_bbc_league_tables");
const {
  DEFAULT_CLUB_ELO_BASE_URL,
  DEFAULT_CLUB_ELO_TIMEZONE,
  DEFAULT_CLUB_ELO_OUTPUT,
  DEFAULT_CLUB_ELO_MIN_ROWS,
  DEFAULT_CLUB_ELO_MIN_BYTES,
  fetchClubEloRankings,
  writeClubEloRankings,
} = require("./fetch_club_elo_rankings");
const {
  DEFAULT_CLUB_ELO_FIXTURES_URL,
  DEFAULT_CLUB_ELO_FIXTURES_OUTPUT,
  DEFAULT_CLUB_ELO_FIXTURES_MIN_ROWS,
  DEFAULT_CLUB_ELO_FIXTURES_MIN_BYTES,
  fetchClubEloFixtures,
  writeClubEloFixtures,
} = require("./fetch_club_elo_fixtures");
const {
  DEFAULT_FOOTBALL_DATABASE_BASE_URL,
  DEFAULT_FOOTBALL_DATABASE_OUTPUT,
  DEFAULT_FOOTBALL_DATABASE_MIN_ROWS,
  DEFAULT_FOOTBALL_DATABASE_RETRY_ATTEMPTS,
  DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS,
  DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_MAX_MS,
  DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_FACTOR,
  DEFAULT_FOOTBALL_DATABASE_RETRY_JITTER_MS,
  fetchFootballDatabaseRankings,
  writeFootballDatabaseRankings,
} = require("./fetch_football_database_rankings");
const {
  DEFAULT_NATIONAL_ELO_BASE_URL,
  DEFAULT_NATIONAL_ELO_PAGE,
  DEFAULT_NATIONAL_ELO_OUTPUT,
  DEFAULT_NATIONAL_ELO_MIN_ROWS,
  DEFAULT_NATIONAL_ELO_MIN_BYTES,
  DEFAULT_NATIONAL_ELO_RETRY_ATTEMPTS,
  DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_BASE_MS,
  DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_MAX_MS,
  DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_FACTOR,
  DEFAULT_NATIONAL_ELO_RETRY_JITTER_MS,
  DEFAULT_NATIONAL_ELO_PREFER_IPV4,
  DEFAULT_NATIONAL_ELO_USER_AGENT,
  fetchNationalEloRankings,
  writeNationalEloRankings,
} = require("./fetch_national_elo_rankings");
const testMatchState = require("./test_match_state");
const {
  loadTeamIdentityConfig,
  normalizeTeamIdentityName,
  canonicalTeamName,
  buildFantasyShortNameMappings,
} = require("./team_identity");
const fantasyScore = require("./fantasy_score");

function parseEnvBoolean(value, fallback = false) {
  if (value === undefined || value === null) return fallback;
  if (typeof value === "boolean") return value;
  const normalized = String(value).trim().toLowerCase();
  if (!normalized) return fallback;
  if (["1", "true", "yes", "y", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "n", "off"].includes(normalized)) return false;
  return fallback;
}

const PORT = Number(process.env.PORT || 3011);
const SOURCE_URL = process.env.SOURCE_URL || DEFAULT_URL;
const OUTPUT_PATH = process.env.OUTPUT_PATH || DEFAULT_OUTPUT;
const INTERVAL_MINUTES = Number(process.env.UPDATE_INTERVAL_MINUTES || 30);
const INTERVAL_MS = Number(process.env.UPDATE_INTERVAL_MS || INTERVAL_MINUTES * 60 * 1000);

const BBC_SOURCE_URL = process.env.BBC_SOURCE_URL || DEFAULT_BBC_URL;
const BBC_OUTPUT_PATH = process.env.BBC_OUTPUT_PATH || DEFAULT_BBC_OUTPUT;
const BBC_INTERVAL_MS = Number(process.env.BBC_UPDATE_INTERVAL_MS || 30 * 1000);
const BBC_RANGE_BASE_URL = process.env.BBC_RANGE_BASE_URL || DEFAULT_BBC_URL;
const BBC_RANGE_OUTPUT_PATH =
  process.env.BBC_RANGE_OUTPUT_PATH || path.join(__dirname, "bbc_scores_fixtures_matches.json");
const parsedBbcRangePastDays = Number(process.env.BBC_RANGE_PAST_DAYS || DEFAULT_BBC_RANGE_PAST_DAYS);
const BBC_RANGE_PAST_DAYS = Number.isFinite(parsedBbcRangePastDays)
  ? Math.max(0, Math.floor(parsedBbcRangePastDays))
  : DEFAULT_BBC_RANGE_PAST_DAYS;
const parsedBbcRangeFutureDays = Number(
  process.env.BBC_RANGE_FUTURE_DAYS || DEFAULT_BBC_RANGE_FUTURE_DAYS
);
const BBC_RANGE_FUTURE_DAYS = Number.isFinite(parsedBbcRangeFutureDays)
  ? Math.max(0, Math.floor(parsedBbcRangeFutureDays))
  : DEFAULT_BBC_RANGE_FUTURE_DAYS;
const parsedBbcRangeConcurrency = Number(
  process.env.BBC_RANGE_CONCURRENCY || DEFAULT_BBC_RANGE_CONCURRENCY
);
const BBC_RANGE_CONCURRENCY = Number.isFinite(parsedBbcRangeConcurrency)
  ? Math.max(1, Math.floor(parsedBbcRangeConcurrency))
  : DEFAULT_BBC_RANGE_CONCURRENCY;
const BBC_RANGE_MATCH_TIMEZONE = process.env.BBC_RANGE_MATCH_TIMEZONE || DEFAULT_BBC_MATCH_TIMEZONE;
const BBC_RANGE_INTERVAL_HOURS = Number(process.env.BBC_RANGE_INTERVAL_HOURS || 1);
const BBC_RANGE_INTERVAL_MS = Number(
  process.env.BBC_RANGE_INTERVAL_MS || BBC_RANGE_INTERVAL_HOURS * 60 * 60 * 1000
);

const EPL_SOURCE_URL = process.env.EPL_SOURCE_URL || DEFAULT_BBC_TABLES_URL;
const EPL_OUTPUT_PATH = process.env.EPL_OUTPUT_PATH || DEFAULT_BBC_PREMIER_LEAGUE_OUTPUT;
const EPL_INTERVAL_HOURS = Number(process.env.EPL_UPDATE_INTERVAL_HOURS || 24);
const EPL_INTERVAL_MS = Number(
  process.env.EPL_UPDATE_INTERVAL_MS || EPL_INTERVAL_HOURS * 60 * 60 * 1000
);
const parsedEplTeamMinConfidence = Number(process.env.EPL_TEAM_MIN_CONFIDENCE || 0.82);
const EPL_TEAM_MIN_CONFIDENCE = Number.isFinite(parsedEplTeamMinConfidence)
  ? Math.min(1, Math.max(0, parsedEplTeamMinConfidence))
  : 0.82;
const LEAGUE_TABLES_OUTPUT_PATH =
  process.env.LEAGUE_TABLES_OUTPUT_PATH || DEFAULT_BBC_LEAGUE_TABLES_OUTPUT;
const parsedLeagueTablesIntervalMs = Number(
  process.env.LEAGUE_TABLES_UPDATE_INTERVAL_MS || 2 * 60 * 1000
);
const LEAGUE_TABLES_INTERVAL_MS = Number.isFinite(parsedLeagueTablesIntervalMs)
  ? Math.max(15 * 1000, Math.floor(parsedLeagueTablesIntervalMs))
  : 2 * 60 * 1000;
const CLUB_ELO_BASE_URL = process.env.CLUB_ELO_BASE_URL || DEFAULT_CLUB_ELO_BASE_URL;
const CLUB_ELO_OUTPUT_PATH = process.env.CLUB_ELO_OUTPUT_PATH || DEFAULT_CLUB_ELO_OUTPUT;
const CLUB_ELO_TIMEZONE = process.env.CLUB_ELO_TIMEZONE || DEFAULT_CLUB_ELO_TIMEZONE;
const parsedClubEloMinRows = Number(process.env.CLUB_ELO_MIN_ROWS || DEFAULT_CLUB_ELO_MIN_ROWS);
const CLUB_ELO_MIN_ROWS = Number.isFinite(parsedClubEloMinRows)
  ? Math.max(1, Math.floor(parsedClubEloMinRows))
  : DEFAULT_CLUB_ELO_MIN_ROWS;
const parsedClubEloMinBytes = Number(process.env.CLUB_ELO_MIN_BYTES || DEFAULT_CLUB_ELO_MIN_BYTES);
const CLUB_ELO_MIN_BYTES = Number.isFinite(parsedClubEloMinBytes)
  ? Math.max(1, Math.floor(parsedClubEloMinBytes))
  : DEFAULT_CLUB_ELO_MIN_BYTES;
const CLUB_ELO_INTERVAL_HOURS = Number(process.env.CLUB_ELO_UPDATE_INTERVAL_HOURS || 12);
const CLUB_ELO_INTERVAL_MS = Number(
  process.env.CLUB_ELO_UPDATE_INTERVAL_MS || CLUB_ELO_INTERVAL_HOURS * 60 * 60 * 1000
);
const parsedClubEloRedisTtlSeconds = Number(
  process.env.CLUB_ELO_REDIS_TTL_SECONDS || 7 * 24 * 60 * 60
);
const CLUB_ELO_REDIS_TTL_SECONDS = Number.isFinite(parsedClubEloRedisTtlSeconds)
  ? Math.max(1, Math.floor(parsedClubEloRedisTtlSeconds))
  : 7 * 24 * 60 * 60;
const CLUB_ELO_MANUAL_MAPPINGS_PATH =
  process.env.CLUB_ELO_MANUAL_MAPPINGS_PATH ||
  path.join(__dirname, "club_elo_manual_mappings.json");
const CLUB_ELO_FIXTURES_URL =
  process.env.CLUB_ELO_FIXTURES_URL || DEFAULT_CLUB_ELO_FIXTURES_URL;
const CLUB_ELO_FIXTURES_OUTPUT_PATH =
  process.env.CLUB_ELO_FIXTURES_OUTPUT_PATH || DEFAULT_CLUB_ELO_FIXTURES_OUTPUT;
const parsedClubEloFixturesMinRows = Number(
  process.env.CLUB_ELO_FIXTURES_MIN_ROWS || DEFAULT_CLUB_ELO_FIXTURES_MIN_ROWS
);
const CLUB_ELO_FIXTURES_MIN_ROWS = Number.isFinite(parsedClubEloFixturesMinRows)
  ? Math.max(1, Math.floor(parsedClubEloFixturesMinRows))
  : DEFAULT_CLUB_ELO_FIXTURES_MIN_ROWS;
const parsedClubEloFixturesMinBytes = Number(
  process.env.CLUB_ELO_FIXTURES_MIN_BYTES || DEFAULT_CLUB_ELO_FIXTURES_MIN_BYTES
);
const CLUB_ELO_FIXTURES_MIN_BYTES = Number.isFinite(parsedClubEloFixturesMinBytes)
  ? Math.max(1, Math.floor(parsedClubEloFixturesMinBytes))
  : DEFAULT_CLUB_ELO_FIXTURES_MIN_BYTES;
const CLUB_ELO_FIXTURES_INTERVAL_HOURS = Number(
  process.env.CLUB_ELO_FIXTURES_UPDATE_INTERVAL_HOURS || 12
);
const CLUB_ELO_FIXTURES_INTERVAL_MS = Number(
  process.env.CLUB_ELO_FIXTURES_UPDATE_INTERVAL_MS ||
    CLUB_ELO_FIXTURES_INTERVAL_HOURS * 60 * 60 * 1000
);
const FOOTBALL_DATABASE_BASE_URL =
  process.env.FOOTBALL_DATABASE_BASE_URL || DEFAULT_FOOTBALL_DATABASE_BASE_URL;
const FOOTBALL_DATABASE_OUTPUT_PATH =
  process.env.FOOTBALL_DATABASE_OUTPUT_PATH || DEFAULT_FOOTBALL_DATABASE_OUTPUT;
const RECOMMENDED_FOOTBALL_DATABASE_CONCURRENCY = 8;
const parsedFootballDatabaseConcurrency = Number(
  process.env.FOOTBALL_DATABASE_CONCURRENCY || RECOMMENDED_FOOTBALL_DATABASE_CONCURRENCY
);
const FOOTBALL_DATABASE_CONCURRENCY = Number.isFinite(parsedFootballDatabaseConcurrency)
  ? Math.max(1, Math.floor(parsedFootballDatabaseConcurrency))
  : RECOMMENDED_FOOTBALL_DATABASE_CONCURRENCY;
const parsedFootballDatabaseMinRows = Number(
  process.env.FOOTBALL_DATABASE_MIN_ROWS || DEFAULT_FOOTBALL_DATABASE_MIN_ROWS
);
const FOOTBALL_DATABASE_MIN_ROWS = Number.isFinite(parsedFootballDatabaseMinRows)
  ? Math.max(1, Math.floor(parsedFootballDatabaseMinRows))
  : DEFAULT_FOOTBALL_DATABASE_MIN_ROWS;
const rawFootballDatabaseMaxPages = process.env.FOOTBALL_DATABASE_MAX_PAGES;
const parsedFootballDatabaseMaxPages =
  rawFootballDatabaseMaxPages === undefined ||
  rawFootballDatabaseMaxPages === null ||
  String(rawFootballDatabaseMaxPages).trim() === ""
    ? null
    : Number(rawFootballDatabaseMaxPages);
const FOOTBALL_DATABASE_MAX_PAGES =
  Number.isFinite(parsedFootballDatabaseMaxPages) &&
  parsedFootballDatabaseMaxPages > 0
    ? Math.floor(parsedFootballDatabaseMaxPages)
  : null;
const FOOTBALL_DATABASE_INTERVAL_HOURS = Number(
  process.env.FOOTBALL_DATABASE_UPDATE_INTERVAL_HOURS || 12
);
const FOOTBALL_DATABASE_INTERVAL_MS = Number(
  process.env.FOOTBALL_DATABASE_UPDATE_INTERVAL_MS ||
    FOOTBALL_DATABASE_INTERVAL_HOURS * 60 * 60 * 1000
);
const parsedFootballDatabaseRedisTtlSeconds = Number(
  process.env.FOOTBALL_DATABASE_REDIS_TTL_SECONDS || 7 * 24 * 60 * 60
);
const FOOTBALL_DATABASE_REDIS_TTL_SECONDS = Number.isFinite(parsedFootballDatabaseRedisTtlSeconds)
  ? Math.max(1, Math.floor(parsedFootballDatabaseRedisTtlSeconds))
  : 7 * 24 * 60 * 60;
const parsedFootballDatabaseRetryAttempts = Number(
  process.env.FOOTBALL_DATABASE_RETRY_ATTEMPTS || DEFAULT_FOOTBALL_DATABASE_RETRY_ATTEMPTS
);
const FOOTBALL_DATABASE_RETRY_ATTEMPTS = Number.isFinite(parsedFootballDatabaseRetryAttempts)
  ? Math.max(1, Math.floor(parsedFootballDatabaseRetryAttempts))
  : DEFAULT_FOOTBALL_DATABASE_RETRY_ATTEMPTS;
const parsedFootballDatabaseRetryBackoffBaseMs = Number(
  process.env.FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS ||
    DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS
);
const FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS = Number.isFinite(
  parsedFootballDatabaseRetryBackoffBaseMs
)
  ? Math.max(1, Math.floor(parsedFootballDatabaseRetryBackoffBaseMs))
  : DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS;
const parsedFootballDatabaseRetryBackoffMaxMs = Number(
  process.env.FOOTBALL_DATABASE_RETRY_BACKOFF_MAX_MS ||
    DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_MAX_MS
);
const FOOTBALL_DATABASE_RETRY_BACKOFF_MAX_MS = Number.isFinite(
  parsedFootballDatabaseRetryBackoffMaxMs
)
  ? Math.max(
    FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS,
    Math.floor(parsedFootballDatabaseRetryBackoffMaxMs)
  )
  : Math.max(
    FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS,
    DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_MAX_MS
  );
const parsedFootballDatabaseRetryBackoffFactor = Number(
  process.env.FOOTBALL_DATABASE_RETRY_BACKOFF_FACTOR ||
    DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_FACTOR
);
const FOOTBALL_DATABASE_RETRY_BACKOFF_FACTOR = Number.isFinite(
  parsedFootballDatabaseRetryBackoffFactor
)
  ? Math.max(1, parsedFootballDatabaseRetryBackoffFactor)
  : DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_FACTOR;
const parsedFootballDatabaseRetryJitterMs = Number(
  process.env.FOOTBALL_DATABASE_RETRY_JITTER_MS || DEFAULT_FOOTBALL_DATABASE_RETRY_JITTER_MS
);
const FOOTBALL_DATABASE_RETRY_JITTER_MS = Number.isFinite(parsedFootballDatabaseRetryJitterMs)
  ? Math.max(0, Math.floor(parsedFootballDatabaseRetryJitterMs))
  : DEFAULT_FOOTBALL_DATABASE_RETRY_JITTER_MS;
const FOOTBALL_DATABASE_ADAPTIVE_CONCURRENCY_ENABLED = parseEnvBoolean(
  process.env.FOOTBALL_DATABASE_ADAPTIVE_CONCURRENCY_ENABLED,
  true
);
const parsedFootballDatabaseAdaptiveMinConcurrency = Number(
  process.env.FOOTBALL_DATABASE_ADAPTIVE_MIN_CONCURRENCY || 4
);
const FOOTBALL_DATABASE_ADAPTIVE_MIN_CONCURRENCY = Number.isFinite(
  parsedFootballDatabaseAdaptiveMinConcurrency
)
  ? Math.max(
    1,
    Math.min(FOOTBALL_DATABASE_CONCURRENCY, Math.floor(parsedFootballDatabaseAdaptiveMinConcurrency))
  )
  : Math.min(4, FOOTBALL_DATABASE_CONCURRENCY);
const NATIONAL_ELO_BASE_URL = process.env.NATIONAL_ELO_BASE_URL || DEFAULT_NATIONAL_ELO_BASE_URL;
const NATIONAL_ELO_PAGE = process.env.NATIONAL_ELO_PAGE || DEFAULT_NATIONAL_ELO_PAGE;
const NATIONAL_ELO_OUTPUT_PATH = process.env.NATIONAL_ELO_OUTPUT_PATH || DEFAULT_NATIONAL_ELO_OUTPUT;
const parsedNationalEloMinRows = Number(
  process.env.NATIONAL_ELO_MIN_ROWS || DEFAULT_NATIONAL_ELO_MIN_ROWS
);
const NATIONAL_ELO_MIN_ROWS = Number.isFinite(parsedNationalEloMinRows)
  ? Math.max(1, Math.floor(parsedNationalEloMinRows))
  : DEFAULT_NATIONAL_ELO_MIN_ROWS;
const parsedNationalEloMinBytes = Number(
  process.env.NATIONAL_ELO_MIN_BYTES || DEFAULT_NATIONAL_ELO_MIN_BYTES
);
const NATIONAL_ELO_MIN_BYTES = Number.isFinite(parsedNationalEloMinBytes)
  ? Math.max(1, Math.floor(parsedNationalEloMinBytes))
  : DEFAULT_NATIONAL_ELO_MIN_BYTES;
const NATIONAL_ELO_INTERVAL_HOURS = Number(process.env.NATIONAL_ELO_UPDATE_INTERVAL_HOURS || 12);
const NATIONAL_ELO_INTERVAL_MS = Number(
  process.env.NATIONAL_ELO_UPDATE_INTERVAL_MS || NATIONAL_ELO_INTERVAL_HOURS * 60 * 60 * 1000
);
const parsedNationalEloRedisTtlSeconds = Number(
  process.env.NATIONAL_ELO_REDIS_TTL_SECONDS || 7 * 24 * 60 * 60
);
const NATIONAL_ELO_REDIS_TTL_SECONDS = Number.isFinite(parsedNationalEloRedisTtlSeconds)
  ? Math.max(1, Math.floor(parsedNationalEloRedisTtlSeconds))
  : 7 * 24 * 60 * 60;
const parsedNationalEloRetryAttempts = Number(
  process.env.NATIONAL_ELO_RETRY_ATTEMPTS || DEFAULT_NATIONAL_ELO_RETRY_ATTEMPTS
);
const NATIONAL_ELO_RETRY_ATTEMPTS = Number.isFinite(parsedNationalEloRetryAttempts)
  ? Math.max(1, Math.floor(parsedNationalEloRetryAttempts))
  : DEFAULT_NATIONAL_ELO_RETRY_ATTEMPTS;
const parsedNationalEloRetryBackoffBaseMs = Number(
  process.env.NATIONAL_ELO_RETRY_BACKOFF_BASE_MS ||
    DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_BASE_MS
);
const NATIONAL_ELO_RETRY_BACKOFF_BASE_MS = Number.isFinite(parsedNationalEloRetryBackoffBaseMs)
  ? Math.max(1, Math.floor(parsedNationalEloRetryBackoffBaseMs))
  : DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_BASE_MS;
const parsedNationalEloRetryBackoffMaxMs = Number(
  process.env.NATIONAL_ELO_RETRY_BACKOFF_MAX_MS ||
    DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_MAX_MS
);
const NATIONAL_ELO_RETRY_BACKOFF_MAX_MS = Number.isFinite(parsedNationalEloRetryBackoffMaxMs)
  ? Math.max(NATIONAL_ELO_RETRY_BACKOFF_BASE_MS, Math.floor(parsedNationalEloRetryBackoffMaxMs))
  : Math.max(
    NATIONAL_ELO_RETRY_BACKOFF_BASE_MS,
    DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_MAX_MS
  );
const parsedNationalEloRetryBackoffFactor = Number(
  process.env.NATIONAL_ELO_RETRY_BACKOFF_FACTOR ||
    DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_FACTOR
);
const NATIONAL_ELO_RETRY_BACKOFF_FACTOR = Number.isFinite(parsedNationalEloRetryBackoffFactor)
  ? Math.max(1, parsedNationalEloRetryBackoffFactor)
  : DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_FACTOR;
const parsedNationalEloRetryJitterMs = Number(
  process.env.NATIONAL_ELO_RETRY_JITTER_MS || DEFAULT_NATIONAL_ELO_RETRY_JITTER_MS
);
const NATIONAL_ELO_RETRY_JITTER_MS = Number.isFinite(parsedNationalEloRetryJitterMs)
  ? Math.max(0, Math.floor(parsedNationalEloRetryJitterMs))
  : DEFAULT_NATIONAL_ELO_RETRY_JITTER_MS;
const NATIONAL_ELO_PREFER_IPV4 = parseEnvBoolean(
  process.env.NATIONAL_ELO_PREFER_IPV4,
  DEFAULT_NATIONAL_ELO_PREFER_IPV4
);
const NATIONAL_ELO_USER_AGENT_RAW = String(
  process.env.NATIONAL_ELO_USER_AGENT || DEFAULT_NATIONAL_ELO_USER_AGENT
).trim();
const NATIONAL_ELO_USER_AGENT = NATIONAL_ELO_USER_AGENT_RAW || DEFAULT_NATIONAL_ELO_USER_AGENT;
const DEFAULT_FPL_BOOTSTRAP_SOURCE_URL = "https://fantasy.premierleague.com/api/bootstrap-static/";
const FPL_BOOTSTRAP_SOURCE_URL =
  process.env.FPL_BOOTSTRAP_SOURCE_URL || DEFAULT_FPL_BOOTSTRAP_SOURCE_URL;
const FPL_BOOTSTRAP_INTERVAL_HOURS = Number(
  process.env.FPL_BOOTSTRAP_UPDATE_INTERVAL_HOURS || 12
);
const FPL_BOOTSTRAP_INTERVAL_MS = Number(
  process.env.FPL_BOOTSTRAP_UPDATE_INTERVAL_MS ||
    FPL_BOOTSTRAP_INTERVAL_HOURS * 60 * 60 * 1000
);
const FPL_BOOTSTRAP_DAILY_REFRESH_HOUR_UK = Number(
  process.env.FPL_BOOTSTRAP_DAILY_REFRESH_HOUR_UK || 3
);
const FPL_BOOTSTRAP_DAILY_REFRESH_MINUTE_UK = Number(
  process.env.FPL_BOOTSTRAP_DAILY_REFRESH_MINUTE_UK || 0
);
const parsedFplBootstrapMaxAgeMs = Number(
  process.env.FPL_BOOTSTRAP_MAX_AGE_MS || 24 * 60 * 60 * 1000
);
const FPL_BOOTSTRAP_MAX_AGE_MS = Number.isFinite(parsedFplBootstrapMaxAgeMs)
  ? Math.max(60 * 60 * 1000, Math.floor(parsedFplBootstrapMaxAgeMs))
  : 24 * 60 * 60 * 1000;
const parsedFplBootstrapTimeoutMs = Number(
  process.env.FPL_BOOTSTRAP_TIMEOUT_MS || 10 * 60 * 1000
);
const FPL_BOOTSTRAP_TIMEOUT_MS = Number.isFinite(parsedFplBootstrapTimeoutMs)
  ? Math.max(10 * 1000, Math.floor(parsedFplBootstrapTimeoutMs))
  : 10 * 60 * 1000;
const parsedFplBootstrapMaxBytes = Number(
  process.env.FPL_BOOTSTRAP_MAX_BYTES || 1900 * 1024 * 1024
);
const FPL_BOOTSTRAP_MAX_BYTES = Number.isFinite(parsedFplBootstrapMaxBytes)
  ? Math.max(10 * 1024 * 1024, Math.floor(parsedFplBootstrapMaxBytes))
  : 1900 * 1024 * 1024;
const FPL_GAME_UPDATING_NEEDLE = "the game is being updated";
const FPL_GAME_UPDATING_USER_MESSAGE =
  "Fantasy Premier League data is temporarily unavailable while the official game is being updated. Please try again in a few minutes.";
const FPL_TRANSFER_DEFAULT_VALUE_WINDOW_MILLIONS = 1.5;
const FPL_TRANSFER_DEFAULT_BUDGET_DISCOUNT_FRACTION = 0.30;
const FPL_TRANSFER_DEFAULT_LIMIT = 10;
const FPL_TRANSFER_MAX_LIMIT = 25;
const FANTASY_TEAM_SHORT_NAME_MAPPINGS_PATH =
  process.env.FANTASY_TEAM_SHORT_NAME_MAPPINGS_PATH ||
  path.join(__dirname, "fantasy_team_short_name_mappings.json");
const FANTASY_LOADING_MESSAGES_PATH =
  process.env.FANTASY_LOADING_MESSAGES_PATH ||
  path.join(__dirname, "fantasy_loading_messages.json");
const FANTASY_ASSISTANT_MANAGER_PHRASES_PATH =
  process.env.FANTASY_ASSISTANT_MANAGER_PHRASES_PATH ||
  path.join(__dirname, "fantasy_assistant_manager_phrases.json");
const TEAM_COLORS_CONFIG_PATH =
  process.env.TEAM_COLORS_CONFIG_PATH ||
  path.join(__dirname, "team_colors.json");
const DEFAULT_FPL_FIXTURES_SOURCE_URL = "https://fantasy.premierleague.com/api/fixtures/";
const FPL_FIXTURES_SOURCE_URL =
  process.env.FPL_FIXTURES_SOURCE_URL || DEFAULT_FPL_FIXTURES_SOURCE_URL;
const parsedFplFixturesIntervalHours = Number(
  process.env.FPL_FIXTURES_UPDATE_INTERVAL_HOURS || 6
);
const FPL_FIXTURES_INTERVAL_MS = Number(
  process.env.FPL_FIXTURES_UPDATE_INTERVAL_MS ||
    parsedFplFixturesIntervalHours * 60 * 60 * 1000
);
const parsedFplFixturesTimeoutMs = Number(
  process.env.FPL_FIXTURES_TIMEOUT_MS || 5 * 60 * 1000
);
const FPL_FIXTURES_TIMEOUT_MS = Number.isFinite(parsedFplFixturesTimeoutMs)
  ? Math.max(10 * 1000, Math.floor(parsedFplFixturesTimeoutMs))
  : 5 * 60 * 1000;
const parsedFplFixturesMaxBytes = Number(
  process.env.FPL_FIXTURES_MAX_BYTES || 200 * 1024 * 1024
);
const FPL_FIXTURES_MAX_BYTES = Number.isFinite(parsedFplFixturesMaxBytes)
  ? Math.max(10 * 1024 * 1024, Math.floor(parsedFplFixturesMaxBytes))
  : 200 * 1024 * 1024;
const DEFAULT_FPL_EVENT_LIVE_SOURCE_URL_TEMPLATE =
  "https://fantasy.premierleague.com/api/event/{event}/live/";
const FPL_EVENT_LIVE_SOURCE_URL_TEMPLATE =
  process.env.FPL_EVENT_LIVE_SOURCE_URL_TEMPLATE || DEFAULT_FPL_EVENT_LIVE_SOURCE_URL_TEMPLATE;
const parsedFplEventLiveIntervalSeconds = Number(
  process.env.FPL_EVENT_LIVE_UPDATE_INTERVAL_SECONDS || 15
);
const FPL_EVENT_LIVE_INTERVAL_MS = Number.isFinite(parsedFplEventLiveIntervalSeconds)
  ? Math.max(10 * 1000, Math.floor(parsedFplEventLiveIntervalSeconds * 1000))
  : 15 * 1000;
const parsedFplEventLiveTimeoutMs = Number(
  process.env.FPL_EVENT_LIVE_TIMEOUT_MS || 30 * 1000
);
const FPL_EVENT_LIVE_TIMEOUT_MS = Number.isFinite(parsedFplEventLiveTimeoutMs)
  ? Math.max(5 * 1000, Math.floor(parsedFplEventLiveTimeoutMs))
  : 30 * 1000;
const parsedFplEventLiveMaxBytes = Number(
  process.env.FPL_EVENT_LIVE_MAX_BYTES || 40 * 1024 * 1024
);
const FPL_EVENT_LIVE_MAX_BYTES = Number.isFinite(parsedFplEventLiveMaxBytes)
  ? Math.max(1024 * 1024, Math.floor(parsedFplEventLiveMaxBytes))
  : 40 * 1024 * 1024;
const RECENT_OUTPUT_PATH =
  process.env.RECENT_OUTPUT_PATH || path.join(__dirname, "recent_matches.json");
const MISSING_TEAM_LOGOS_OUTPUT_PATH =
  process.env.MISSING_TEAM_LOGOS_OUTPUT_PATH || path.join(__dirname, "missing_team_logos.json");
const TEAM_LOGO_ASSETS_PATH =
  process.env.TEAM_LOGO_ASSETS_PATH ||
  path.join(__dirname, "..", "ios", "Top Scores", "Top Scores", "team_logo_assets.json");
const RECENT_CACHE_HOURS = Number(process.env.RECENT_CACHE_HOURS || 24);
const RECENT_CACHE_MS = Number.isFinite(RECENT_CACHE_HOURS)
  ? RECENT_CACHE_HOURS * 60 * 60 * 1000
  : 24 * 60 * 60 * 1000;
const parsedMatchDetailsPollIntervalMs = Number(
  process.env.MATCH_DETAILS_POLL_INTERVAL_MS || 10 * 1000
);
const MATCH_DETAILS_POLL_INTERVAL_MS = Number.isFinite(parsedMatchDetailsPollIntervalMs)
  ? Math.max(1000, Math.floor(parsedMatchDetailsPollIntervalMs))
  : 10 * 1000;
const parsedMatchDetailsPollConcurrency = Number(
  process.env.MATCH_DETAILS_POLL_CONCURRENCY || 20
);
const MATCH_DETAILS_POLL_CONCURRENCY = Number.isFinite(parsedMatchDetailsPollConcurrency)
  ? Math.max(1, Math.floor(parsedMatchDetailsPollConcurrency))
  : 20;
const parsedMatchDetailsBackfillBatchSize = Number(
  process.env.MATCH_DETAILS_BACKFILL_BATCH_SIZE || 50
);
const MATCH_DETAILS_BACKFILL_BATCH_SIZE = Number.isFinite(parsedMatchDetailsBackfillBatchSize)
  ? Math.max(1, Math.floor(parsedMatchDetailsBackfillBatchSize))
  : 50;
const parsedMatchDetailsStaleInProgressMs = Number(
  process.env.MATCH_DETAILS_STALE_IN_PROGRESS_MS || 20 * 60 * 1000
);
const MATCH_DETAILS_STALE_IN_PROGRESS_MS = Number.isFinite(parsedMatchDetailsStaleInProgressMs)
  ? Math.max(60 * 1000, Math.floor(parsedMatchDetailsStaleInProgressMs))
  : 20 * 60 * 1000;
const parsedMatchDetailsStaleMinuteThreshold = Number(
  process.env.MATCH_DETAILS_STALE_MINUTE_THRESHOLD || 90
);
const MATCH_DETAILS_STALE_MINUTE_THRESHOLD = Number.isFinite(parsedMatchDetailsStaleMinuteThreshold)
  ? Math.max(1, Math.floor(parsedMatchDetailsStaleMinuteThreshold))
  : 90;
const parsedMatchStatusMaximumLiveWindowMs = Number(
  process.env.MATCH_STATUS_MAXIMUM_LIVE_WINDOW_MS || 3.5 * 60 * 60 * 1000
);
const MATCH_STATUS_MAXIMUM_LIVE_WINDOW_MS = Number.isFinite(parsedMatchStatusMaximumLiveWindowMs)
  ? Math.max(30 * 60 * 1000, Math.floor(parsedMatchStatusMaximumLiveWindowMs))
  : 3.5 * 60 * 60 * 1000;
const parsedMatchDetailsBackfillCooldownMs = Number(
  process.env.MATCH_DETAILS_BACKFILL_COOLDOWN_MS || 60 * 1000
);
const MATCH_DETAILS_BACKFILL_COOLDOWN_MS = Number.isFinite(parsedMatchDetailsBackfillCooldownMs)
  ? Math.max(5 * 1000, Math.floor(parsedMatchDetailsBackfillCooldownMs))
  : 60 * 1000;
const parsedMatchDetailsBackfillIdleCooldownMs = Number(
  process.env.MATCH_DETAILS_BACKFILL_IDLE_COOLDOWN_MS || 10 * 60 * 1000
);
const MATCH_DETAILS_BACKFILL_IDLE_COOLDOWN_MS = Number.isFinite(parsedMatchDetailsBackfillIdleCooldownMs)
  ? Math.max(30 * 1000, Math.floor(parsedMatchDetailsBackfillIdleCooldownMs))
  : 10 * 60 * 1000;
const parsedMatchDetailsBackfillFailureCooldownMs = Number(
  process.env.MATCH_DETAILS_BACKFILL_FAILURE_COOLDOWN_MS || 2 * 60 * 1000
);
const MATCH_DETAILS_BACKFILL_FAILURE_COOLDOWN_MS = Number.isFinite(parsedMatchDetailsBackfillFailureCooldownMs)
  ? Math.max(10 * 1000, Math.floor(parsedMatchDetailsBackfillFailureCooldownMs))
  : 2 * 60 * 1000;
const parsedMatchDetailsBackfillInFlightCooldownMs = Number(
  process.env.MATCH_DETAILS_BACKFILL_IN_FLIGHT_COOLDOWN_MS || 15 * 1000
);
const MATCH_DETAILS_BACKFILL_IN_FLIGHT_COOLDOWN_MS = Number.isFinite(parsedMatchDetailsBackfillInFlightCooldownMs)
  ? Math.max(5 * 1000, Math.floor(parsedMatchDetailsBackfillInFlightCooldownMs))
  : 15 * 1000;
const parsedMatchDetailsActiveRefreshWindowMs = Number(
  process.env.MATCH_DETAILS_ACTIVE_REFRESH_WINDOW_MS || 15 * 60 * 1000
);
const MATCH_DETAILS_ACTIVE_REFRESH_WINDOW_MS = Number.isFinite(parsedMatchDetailsActiveRefreshWindowMs)
  ? Math.max(30 * 1000, Math.floor(parsedMatchDetailsActiveRefreshWindowMs))
  : 15 * 60 * 1000;
const TEAM_RANKING_DEFAULT_SOURCE =
  normalizeTeamRankingSource(SERVER_CONFIG.teamRankingDefaultSource) ||
  TEAM_RANKING_SOURCE_MERGED;
const TEAM_RANKING_DEFAULT_ELO = Number.isFinite(SERVER_CONFIG.teamRankingDefaultElo)
  ? SERVER_CONFIG.teamRankingDefaultElo
  : 1000;

const app = express();
const API_PREFIX = "/api/v1";
const APP_DATA_SOURCE = "redis-operational";
const DEVICE_TOKEN_HEADER = "x-device-token";
const parsedRedisReconciliationIntervalMs = Number(
  process.env.REDIS_RECONCILIATION_INTERVAL_MS || 5 * 60 * 1000
);
const REDIS_RECONCILIATION_INTERVAL_MS = Number.isFinite(parsedRedisReconciliationIntervalMs)
  ? Math.max(30 * 1000, Math.floor(parsedRedisReconciliationIntervalMs))
  : 5 * 60 * 1000;
const REDIS_RECONCILIATION_AUTO_REPAIR = parseEnvBoolean(
  process.env.REDIS_RECONCILIATION_AUTO_REPAIR,
  true
);
const parsedRedisReconciliationSampleLimit = Number(
  process.env.REDIS_RECONCILIATION_SAMPLE_LIMIT || 8
);
const REDIS_RECONCILIATION_SAMPLE_LIMIT = Number.isFinite(parsedRedisReconciliationSampleLimit)
  ? Math.max(1, Math.floor(parsedRedisReconciliationSampleLimit))
  : 8;
const parsedRedisReconciliationFreshnessWarnSeconds = Number(
  process.env.REDIS_RECONCILIATION_FRESHNESS_WARN_SECONDS || 5 * 60
);
const REDIS_RECONCILIATION_FRESHNESS_WARN_SECONDS =
  Number.isFinite(parsedRedisReconciliationFreshnessWarnSeconds)
    ? Math.max(30, Math.floor(parsedRedisReconciliationFreshnessWarnSeconds))
    : 5 * 60;
const parsedAppMetricsActiveWindowHours = Number(
  process.env.APP_METRICS_ACTIVE_DEVICE_WINDOW_HOURS || 24 * 30
);
const APP_METRICS_ACTIVE_DEVICE_WINDOW_MS = Number.isFinite(parsedAppMetricsActiveWindowHours)
  ? Math.max(1, Math.floor(parsedAppMetricsActiveWindowHours)) * 60 * 60 * 1000
  : 30 * 24 * 60 * 60 * 1000;
app.use(express.json({ limit: "64kb" }));

const appUsageMetrics = {
  apiRequestsTotal: 0,
  apiRequestsWithDeviceTokenTotal: 0,
  apiRequestsWithoutDeviceTokenTotal: 0,
  appMetricEventsTotal: 0,
  appMetricEventsRejectedTotal: 0,
};
const appMetricEventsByDimension = new Map();
const seenDeviceTokens = new Set();
const deviceLastSeenAtMs = new Map();
let appMetricEventsLastUpdated = null;
let redisReconciliationState = null;
let redisReconciliationTask = null;
const PROCESS_START_TIME_SECONDS = Math.floor(Date.now() / 1000);
const PROCESS_CPU_USAGE_START = process.cpuUsage();
let processCpuUsageSample = {
  capturedAtMs: Date.now(),
  usage: process.cpuUsage(),
};
let eventLoopUtilizationSample = performance.eventLoopUtilization();
const RUNTIME_SERVICE_NAME = "top-scores-api";
const RUNTIME_ENVIRONMENT = String(process.env.NODE_ENV || "development").trim() || "development";
const HTTP_REQUEST_DURATION_BUCKETS = [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5];
const SOURCE_FETCH_DURATION_BUCKETS = [0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10];
const FPL_TRANSFER_RECOMMENDATION_DURATION_BUCKETS = [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1];
const UNIQUE_USER_WINDOWS = [
  { period: "1m", windowMs: 60 * 1000 },
  { period: "5m", windowMs: 5 * 60 * 1000 },
  { period: "1h", windowMs: 60 * 60 * 1000 },
  { period: "1d", windowMs: 24 * 60 * 60 * 1000 },
  { period: "1w", windowMs: 7 * 24 * 60 * 60 * 1000 },
  { period: "30d", windowMs: 30 * 24 * 60 * 60 * 1000 },
];
const httpRequestMetrics = new Map();
const sourceFetchMetrics = new Map();
const fantasyTransferRecommendationMetrics = new Map();
const sourceRecordsFetchedTotalBySource = new Map();
const sourceCacheSizeBySource = new Map();
const sourceLastSuccessAtSeconds = new Map();
const SOURCE_LIVE_FOOTBALL = "live_football_on_tv";
const SOURCE_BBC_LIVE = "bbc_live_scores";
const SOURCE_BBC_RANGE = "bbc_scores_fixtures_range";
const SOURCE_BBC_PREMIER_LEAGUE = "bbc_premier_league_table";
const SOURCE_BBC_LEAGUE_TABLES = "bbc_league_tables";
const SOURCE_CLUB_ELO = "club_elo_rankings";
const SOURCE_CLUB_ELO_FIXTURES = "club_elo_fixtures";
const SOURCE_FOOTBALL_DATABASE = "football_database_rankings";
const SOURCE_NATIONAL_ELO = "national_elo_rankings";
const SOURCE_BBC_MATCH_DETAILS = "bbc_match_details";
const SOURCE_RECENT_CACHE = "recent_matches_cache";
const SOURCE_FPL_BOOTSTRAP = "fpl_bootstrap_static";
const SOURCE_FPL_FIXTURES = "fpl_fixtures";
const SOURCE_FPL_EVENT_LIVE = "fpl_event_live";
const COMPONENT_SOURCE_LIVE_FOOTBALL = "source_live_football";
const COMPONENT_SOURCE_BBC_LIVE = "source_bbc_live";
const COMPONENT_SOURCE_BBC_RANGE = "source_bbc_range";
const COMPONENT_SOURCE_BBC_MATCH_DETAILS = "source_bbc_match_details";
const COMPONENT_SOURCE_BBC_TABLES_PREMIER_TEAMS = "source_bbc_premier_teams";
const COMPONENT_SOURCE_BBC_TABLES_LEAGUE_TABLES = "source_bbc_league_tables";
const COMPONENT_SOURCE_CLUB_ELO = "source_club_elo_rankings";
const COMPONENT_SOURCE_CLUB_ELO_FIXTURES = "source_club_elo_fixtures";
const COMPONENT_SOURCE_FOOTBALL_DATABASE = "source_football_database";
const COMPONENT_SOURCE_NATIONAL_ELO = "source_national_elo";
const COMPONENT_SOURCE_FPL_BOOTSTRAP = "source_fpl_bootstrap";
const COMPONENT_SOURCE_FPL_FIXTURES = "source_fpl_fixtures";
const COMPONENT_SOURCE_FPL_EVENT_LIVE = "source_fpl_event_live";
const COMPONENT_OPERATIONAL_REDIS = "operational_redis";
const COMPONENT_REDIS_RECONCILIATION = "redis_reconciliation";
const COMPONENT_BOOTSTRAP = "operational_bootstrap";
const OP_DATASET_LIVE_MATCHES = "live_matches";
const OP_DATASET_BBC_LIVE_MATCHES = "bbc_live_matches";
const OP_DATASET_BBC_RANGE_MATCHES = "bbc_range_matches";
const OP_DATASET_RECENT_MATCHES = "recent_matches";
const OP_DATASET_MERGED_MATCHES = "merged_matches";
const OP_DATASET_PREMIER_LEAGUE_TEAMS = "premier_league_teams";
const OP_DATASET_LEAGUE_TABLES = "league_tables";
const OP_DATASET_CLUB_ELO_TEAMS = "club_elo_teams";
const OP_DATASET_FOOTBALL_DATABASE_TEAMS = "football_database_teams";
const OP_DATASET_NATIONAL_ELO_TEAMS = "national_elo_teams";
const OP_DATASET_MISSING_TEAM_LOGOS = "missing_team_logos";
const OP_DATASET_CACHE_STATE = "cache_state";
const CACHE_STATE_DOMAINS = Object.freeze(["matches", "match_details", "bbc_live"]);
const CACHE_STATE_DOMAIN_ALIASES = Object.freeze({
  matches: "matches",
  match: "matches",
  fixture: "matches",
  fixtures: "matches",
  result: "matches",
  results: "matches",
  match_details: "match_details",
  "match-details": "match_details",
  matchdetails: "match_details",
  details: "match_details",
  bbc_live: "bbc_live",
  "bbc-live": "bbc_live",
  bbclive: "bbc_live",
  bbc: "bbc_live",
});
const CACHE_STATE_HEADERS_BY_DOMAIN = Object.freeze({
  matches: "X-Cache-Generation-Matches",
  match_details: "X-Cache-Generation-Match-Details",
  bbc_live: "X-Cache-Generation-Bbc-Live",
});
const eventLoopDelayMonitor = monitorEventLoopDelay({ resolution: 20 });
eventLoopDelayMonitor.enable();

app.use((req, res, next) => {
  const isApiPath = req.path.startsWith(API_PREFIX);
  if (isApiPath) {
    const deviceToken = normalizeDeviceToken(req.get(DEVICE_TOKEN_HEADER));
    req.deviceToken = deviceToken || null;
    appUsageMetrics.apiRequestsTotal += 1;
    if (req.deviceToken) {
      appUsageMetrics.apiRequestsWithDeviceTokenTotal += 1;
      trackSeenDeviceToken(req.deviceToken);
    } else {
      appUsageMetrics.apiRequestsWithoutDeviceTokenTotal += 1;
    }
  } else {
    req.deviceToken = null;
  }

  const requestId = Math.random().toString(36).slice(2, 10);
  const startedAtMs = Date.now();
  res.set("X-Request-Id", requestId);
  res.on("finish", () => {
    const durationMs = Date.now() - startedAtMs;
    const route = normalizeHttpRouteLabel(req);
    if (route !== "/metrics") {
      recordHistogramSample(
        httpRequestMetrics,
        {
          method: req.method,
          route,
          status_code: String(res.statusCode || 0),
        },
        durationMs / 1000,
        HTTP_REQUEST_DURATION_BUCKETS
      );
    }

    if (isApiPath) {
      console.log(
        `[api] id=${requestId} method=${req.method} path=${req.originalUrl} status=${res.statusCode} duration_ms=${durationMs} device_token=${req.deviceToken ? "present" : "missing"}`
      );
    }
  });
  next();
});

let cachedMatches = [];
let lastUpdated = null;
let updating = false;
let cachedBbcMatches = [];
let bbcLastUpdated = null;
let bbcUpdating = false;
let cachedBbcRangeMatches = [];
let bbcRangeLastUpdated = null;
let bbcRangeUpdating = false;
let cachedMergedMatches = [];
let cachedRecentMatches = [];
let recentLastUpdated = null;
let cachedPremierLeagueTeams = [];
let eplLastUpdated = null;
let eplUpdating = false;
let cachedLeagueTables = [];
let leagueTablesLastUpdated = null;
let leagueTablesUpdating = false;
let cachedClubEloTeams = [];
let clubEloLastUpdated = null;
let clubEloUpdating = false;
let clubEloLastSuccessAt = null;
let clubEloLastFailureAt = null;
let clubEloOldestFromDate = null;
let clubEloNewestFromDate = null;
let clubEloLatestPullTeamCount = 0;
let clubEloUnmatchedTeamCount = 0;
let clubEloLastSuccessDurationSeconds = 0;
let clubEloLastFailureDurationSeconds = 0;
let cachedClubEloFixtures = [];
let clubEloFixturesLastUpdated = null;
let clubEloFixturesUpdating = false;
let clubEloFixturesLastMatchedCount = 0;
let clubEloFixturesLastUnmatchedCount = 0;
let cachedFootballDatabaseTeams = [];
let footballDatabaseLastUpdated = null;
let footballDatabaseUpdating = false;
let footballDatabaseLastSuccessAt = null;
let footballDatabaseLastFailureAt = null;
let footballDatabaseDataDate = null;
let footballDatabaseLatestPullTeamCount = 0;
let footballDatabaseUnmatchedTeamCount = 0;
let footballDatabaseLastSuccessDurationSeconds = 0;
let footballDatabaseLastFailureDurationSeconds = 0;
let cachedNationalEloTeams = [];
let nationalEloLastUpdated = null;
let nationalEloUpdating = false;
let nationalEloLastSuccessAt = null;
let nationalEloLastFailureAt = null;
let nationalEloDataDate = null;
let nationalEloLatestPullTeamCount = 0;
let nationalEloUnmatchedTeamCount = 0;
let nationalEloLastSuccessDurationSeconds = 0;
let nationalEloLastFailureDurationSeconds = 0;
let clubEloManualMappings = new Map();
let clubEloManualMappingsMtimeMs = null;
let matchDetailsById = new Map();
let matchDetailsLastUpdated = null;
let matchDetailsUpdating = false;
const matchDetailsBackfillTasks = new Map();
const matchDetailsWarmTasks = new Map();
let matchDetailsSnapshotWarmTask = null;
const matchDetailsActiveRefreshUntilById = new Map();
const matchDetailsBackfillNextAttemptAt = new Map();
let operationalCacheState = buildDefaultOperationalCacheState();
let missingTeamLogosByKey = new Map();
let missingTeamLogosLastUpdated = null;
let knownTeamLogoCatalogLoaded = false;
let knownTeamLogoNormalizedLookup = new Map();
let knownTeamLogoCoreLookup = new Map();
let knownTeamLogoOriginalLookup = new Map();
let cachedFantasyBootstrap = null;
let fantasyBootstrapLastUpdated = null;
let fantasyBootstrapUpdating = false;
let fantasyBootstrapPayloadBytes = 0;
let fantasyBootstrapEventsCount = 0;
let fantasyBootstrapCurrentEvent = null;
let fantasyBootstrapNextEvent = null;
let fantasyBootstrapLastSuccessAt = null;
let fantasyBootstrapLastFailureAt = null;
let fantasyBootstrapLastSuccessDurationSeconds = 0;
let fantasyBootstrapLastFailureDurationSeconds = 0;
let fantasyBootstrapGameUpdating = false;
let fantasyBootstrapGameUpdatingMessage = null;
let fantasyBootstrapGameUpdatingDetectedAt = null;
let cachedFantasyFixtures = [];
let fantasyFixturesLastUpdated = null;
let fantasyFixturesUpdating = false;
let fantasyFixturesPayloadBytes = 0;
let fantasyFixturesLastSuccessAt = null;
let fantasyFixturesLastFailureAt = null;
let fantasyFixturesLastSuccessDurationSeconds = 0;
let fantasyFixturesLastFailureDurationSeconds = 0;
let cachedFantasyEventLive = null;
let fantasyEventLiveLastUpdated = null;
let fantasyEventLiveUpdating = false;
let fantasyEventLivePayloadBytes = 0;
let fantasyEventLiveLastSuccessAt = null;
let fantasyEventLiveLastFailureAt = null;
let fantasyEventLiveLastSuccessDurationSeconds = 0;
let fantasyEventLiveLastFailureDurationSeconds = 0;
let fantasyBootstrapNextDailyRefreshAt = null;
let fantasyBootstrapDailyRefreshTimer = null;
let fantasyTransferRecommendationRequestsTotal = 0;
let fantasyTransferRecommendationFailuresTotal = 0;
const fantasyAssistantManagerEntries = new Map();
const fantasyAssistantManagerRefreshTasks = new Map();
const FANTASY_ASSISTANT_MANAGER_POLL_INTERVAL_MS = 90 * 1000;
const FANTASY_ASSISTANT_MANAGER_ACTIVE_WATCH_WINDOW_MS = 6 * 60 * 60 * 1000;
const FANTASY_ASSISTANT_MANAGER_STALE_AFTER_MS = 5 * 60 * 1000;
const FANTASY_ASSISTANT_MANAGER_FETCH_TIMEOUT_MS = 15 * 1000;
const FANTASY_ASSISTANT_MANAGER_MAX_BYTES = 2 * 1024 * 1024;
const FANTASY_ASSISTANT_MANAGER_CANDIDATE_LIMIT = 6;
const FANTASY_ASSISTANT_MANAGER_MONEY_NO_OBJECT_LIMIT = 6;
const FANTASY_ASSISTANT_MANAGER_NEAR_TERM_BLANK_PENALTY = 4.5;
const FANTASY_ASSISTANT_MANAGER_IMMINENT_BLANK_PENALTY = 2.0;
const FANTASY_ASSISTANT_MANAGER_EXTENDED_BLANK_PENALTY = 1.0;
const FANTASY_ASSISTANT_MANAGER_IDEAL_SQUAD_BUDGET_UNITS = 1000;
const FANTASY_ASSISTANT_MANAGER_IDEAL_POOL_LIMITS = Object.freeze({
  1: 16,
  2: 28,
  3: 28,
  4: 18,
});
let fantasyTeamShortNameMappings = Object.freeze({});
let fantasyTeamShortNameMappingsLoadedAt = null;
let fantasyTeamShortNameMappingsMtimeMs = null;
let fantasyLoadingMessages = Object.freeze([]);
let fantasyLoadingMessagesLoadedAt = null;
let fantasyLoadingMessagesMtimeMs = null;
let fantasyAssistantManagerPhrases = Object.freeze([]);
let fantasyAssistantManagerPhrasesLoadedAt = null;
let fantasyAssistantManagerPhrasesMtimeMs = null;
let teamColorsConfig = Object.freeze({
  updatedAt: null,
  default: Object.freeze({
    primary: "#111111",
    secondary: "#FFFFFF",
    scheme: "default-dark",
  }),
  teams: Object.freeze([]),
  identity_groups: Object.freeze([]),
});
let teamColorsLoadedAt = null;
let teamColorsMtimeMs = null;
const RUNTIME_COMPONENT_ERROR_LIMIT = 8;
const runtimeComponentDiagnostics = Object.create(null);

function safeCloneDiagnosticsValue(value) {
  if (value === undefined) return null;
  try {
    return JSON.parse(JSON.stringify(value));
  } catch (_error) {
    return null;
  }
}

function ensureRuntimeComponentDiagnostics(componentId) {
  const normalized = String(componentId || "").trim();
  if (!normalized) {
    return {
      running: false,
      last_started_at: null,
      last_success_at: null,
      last_success: null,
      last_failure_at: null,
      last_error: null,
      recent_errors: [],
    };
  }
  if (!runtimeComponentDiagnostics[normalized]) {
    runtimeComponentDiagnostics[normalized] = {
      running: false,
      last_started_at: null,
      last_success_at: null,
      last_success: null,
      last_failure_at: null,
      last_error: null,
      recent_errors: [],
    };
  }
  return runtimeComponentDiagnostics[normalized];
}

function trimRuntimeComponentErrors(entry) {
  if (!entry || !Array.isArray(entry.recent_errors)) return;
  if (entry.recent_errors.length > RUNTIME_COMPONENT_ERROR_LIMIT) {
    entry.recent_errors.splice(0, entry.recent_errors.length - RUNTIME_COMPONENT_ERROR_LIMIT);
  }
}

function recordRuntimeComponentStart(componentId, meta = {}) {
  const entry = ensureRuntimeComponentDiagnostics(componentId);
  entry.running = true;
  entry.last_started_at = new Date().toISOString();
  entry.last_context = safeCloneDiagnosticsValue(meta);
}

function recordRuntimeComponentSuccess(componentId, meta = {}) {
  const entry = ensureRuntimeComponentDiagnostics(componentId);
  entry.running = false;
  entry.last_success_at = new Date().toISOString();
  entry.last_success = safeCloneDiagnosticsValue(meta);
}

function recordRuntimeComponentFailure(componentId, error, meta = {}) {
  const entry = ensureRuntimeComponentDiagnostics(componentId);
  const message =
    error && error.message ? String(error.message) : String(error || "Unknown error");
  const nowIso = new Date().toISOString();
  entry.running = false;
  entry.last_failure_at = nowIso;
  entry.last_error = message;
  entry.recent_errors.push({
    at: nowIso,
    error: message,
    meta: safeCloneDiagnosticsValue(meta),
  });
  trimRuntimeComponentErrors(entry);
}

function currentRuntimeComponentDiagnostics(componentId) {
  const entry = ensureRuntimeComponentDiagnostics(componentId);
  return {
    running: Boolean(entry.running),
    last_started_at: entry.last_started_at || null,
    last_success_at: entry.last_success_at || null,
    last_success: safeCloneDiagnosticsValue(entry.last_success),
    last_failure_at: entry.last_failure_at || null,
    last_error: entry.last_error || null,
    recent_errors: Array.isArray(entry.recent_errors)
      ? entry.recent_errors.slice().reverse()
      : [],
  };
}

const STAGE_PATTERNS = [
  /\s*[-:–]\s*Round\s+\w+$/i,
  /\s+\w+\s+Round$/i,
  /\s+Round\s+\w+$/i,
  /\s+Round\s+\d+$/i,
  /\s+Round\s+of\s+\d+$/i,
  /\s+Last\s+\d+$/i,
  /\s+Group\s+Stage$/i,
  /\s+Group\s+[A-Z]$/i,
  /\s+Quarter[- ]Finals?$/i,
  /\s+Semi[- ]Finals?$/i,
  /\s+Finals?$/i,
  /\s+Third[- ]Place\s+Play-?Off$/i,
  /\s+Play-?Offs?$/i,
  /\s+Qualifying$/i,
  /\s+Qualification$/i,
  /\s+Preliminary\s+Round$/i,
  /\s+First\s+Leg$/i,
  /\s+Second\s+Leg$/i,
  /\s+1st\s+Leg$/i,
  /\s+2nd\s+Leg$/i,
  /\s+Leg\s+\d+$/i,
];

function normalizeLeagueName(name) {
  if (!name) return name;
  let normalized = String(name).replace(/\s+/g, " ").trim();
  let changed = true;
  while (changed) {
    changed = false;
    for (const pattern of STAGE_PATTERNS) {
      if (pattern.test(normalized)) {
        normalized = normalized.replace(pattern, "").trim();
        normalized = normalized.replace(/[-:–]\s*$/, "").trim();
        changed = true;
      }
    }
  }
  return normalized;
}

function normalizeCompetitionFilterName(name) {
  const normalized = normalizeLeagueName(name || "");
  if (!normalized) return "";

  const lowered = normalized.toLowerCase();
  if (/^fifa world cup(?:\s+2026)? qualifying\b/.test(lowered)) {
    return "fifa world cup 2026";
  }

  return lowered;
}

const LEAGUE_TABLE_ID_ALIASES = {
  "uefa-champions-league": "champions-league",
  "uefa-europa-league": "europa-league",
  "uefa-conference-league": "europa-conference-league",
  "uefa-europa-conference-league": "europa-conference-league",
  championsip: "championship",
};

function normalizeLeagueTableId(value) {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (!normalized) return "";
  return LEAGUE_TABLE_ID_ALIASES[normalized] || normalized;
}

function leagueTableRowsCount(tables) {
  if (!Array.isArray(tables)) return 0;
  return tables.reduce((total, league) => {
    const rows = Array.isArray(league && league.rows) ? league.rows.length : 0;
    return total + rows;
  }, 0);
}

function sortLeagueTablesForResponse(tables) {
  if (!Array.isArray(tables)) return [];
  const order = new Map(LEAGUE_TABLE_SOURCES.map((source, index) => [source.id, index]));
  return [...tables].sort((left, right) => {
    const leftId = normalizeLeagueTableId(left && left.league_id);
    const rightId = normalizeLeagueTableId(right && right.league_id);
    const leftOrder = order.has(leftId) ? order.get(leftId) : Number.MAX_SAFE_INTEGER;
    const rightOrder = order.has(rightId) ? order.get(rightId) : Number.MAX_SAFE_INTEGER;
    if (leftOrder !== rightOrder) return leftOrder - rightOrder;
    const leftName = String((left && left.league_name) || "");
    const rightName = String((right && right.league_name) || "");
    return leftName.localeCompare(rightName);
  });
}

function findLeagueTableById(tables, leagueId) {
  const normalizedId = normalizeLeagueTableId(leagueId);
  if (!normalizedId || !Array.isArray(tables)) return null;
  return (
    tables.find((table) => normalizeLeagueTableId(table && table.league_id) === normalizedId) ||
    null
  );
}

function extractPremierLeagueTeamsFromTables(tables) {
  const premier = findLeagueTableById(tables, "premier-league");
  if (!premier || !Array.isArray(premier.rows)) return [];
  return premier.rows
    .map((row) => String((row && row.team) || "").trim())
    .filter(Boolean);
}

const ALLOWED_COMPETITION_SET = new Set(
  (SERVER_CONFIG.competitionAllowlist || [])
    .map(normalizeCompetitionFilterName)
    .filter(Boolean)
);

function isAllowedCompetition(leagueName) {
  if (ALLOWED_COMPETITION_SET.size === 0) return true;
  const normalized = normalizeCompetitionFilterName(leagueName || "");
  return ALLOWED_COMPETITION_SET.has(normalized);
}

function filterMatchesByCompetition(matches) {
  return matches.filter((match) => isAllowedCompetition(match && match.league));
}

function compareInsensitive(a, b) {
  return a.localeCompare(b, undefined, { sensitivity: "base" });
}

const TEAM_LOGO_STOP_WORDS = new Set([
  "fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk",
  "club", "de", "the", "and", "atletico", "athletic", "sporting",
]);

const TEAM_LOGO_CLUB_AFFIX_WORDS = new Set([
  "city", "town", "united", "rovers", "county", "albion", "wanderers",
  "hotspur", "saint", "st", "calcio",
]);

const TEAM_LOGO_ALIAS_MAP = {
  "manchester united": "man united",
  "man utd": "man united",
  "manchester utd": "man united",
  "man u": "man united",
  "manchester city": "man city",
  "tottenham hotspur": "tottenham",
  "wolverhampton wanderers": "wolves",
  "sheffield united": "sheff utd",
  "sheffield wednesday": "sheff wed",
  "nottingham forest": "nottm forest",
  "borussia dortmund": "dortmund",
  "borussia m'gladbach": "m'gladbach",
  "athletic club": "athletic",
  "real betis": "betis",
  "real sociedad": "real sociedad",
  "fc copenhagen": "copenhagen",
  "fc porto": "porto",
  "paok thessaloniki": "paok",
  "paok thessaloniki fc": "paok",
  "inter milan": "inter",
  "ac milan": "ac milan",
};

function normalizeTeamLogoCatalogTokens(value, stripClubAffixes = false) {
  const normalized = String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/'/g, "")
    .replace(/\./g, " ")
    .replace(/-/g, " ")
    .replace(/_/g, " ");

  return normalized
    .split(/[^\p{L}\p{N}]+/u)
    .filter(Boolean)
    .filter((token) => {
      if (TEAM_LOGO_STOP_WORDS.has(token)) return false;
      if (stripClubAffixes && TEAM_LOGO_CLUB_AFFIX_WORDS.has(token)) return false;
      return true;
    });
}

function normalizeTeamLogoCatalogKey(value) {
  return normalizeTeamLogoCatalogTokens(value).join("");
}

function normalizeTeamLogoCatalogCoreKey(value) {
  return normalizeTeamLogoCatalogTokens(value, true).join("");
}

function resetKnownTeamLogoCatalog() {
  knownTeamLogoNormalizedLookup = new Map();
  knownTeamLogoCoreLookup = new Map();
  knownTeamLogoOriginalLookup = new Map();
}

function registerKnownTeamLogoName(name) {
  const normalizedName = String(name || "").trim();
  if (!normalizedName) return;

  const normalizedKey = normalizeTeamLogoCatalogKey(normalizedName);
  if (normalizedKey) {
    knownTeamLogoNormalizedLookup.set(normalizedKey, normalizedName);
  }

  const coreKey = normalizeTeamLogoCatalogCoreKey(normalizedName);
  if (coreKey) {
    const existing = knownTeamLogoCoreLookup.get(coreKey) || [];
    existing.push(normalizedName);
    knownTeamLogoCoreLookup.set(coreKey, existing);
  }

  knownTeamLogoOriginalLookup.set(normalizedName.toLowerCase(), normalizedName);
}

function loadKnownTeamLogoCatalog() {
  if (knownTeamLogoCatalogLoaded) return;
  knownTeamLogoCatalogLoaded = true;
  resetKnownTeamLogoCatalog();

  try {
    if (!fs.existsSync(TEAM_LOGO_ASSETS_PATH)) return;
    const raw = fs.readFileSync(TEAM_LOGO_ASSETS_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return;
    parsed.forEach((name) => registerKnownTeamLogoName(name));
  } catch (err) {
    console.warn("Failed to load team logo assets catalog:", err.message || err);
  }
}

function knownTeamLogoAliases(name) {
  const lowered = String(name || "").trim().toLowerCase();
  if (!lowered) return [];
  if (TEAM_LOGO_ALIAS_MAP[lowered]) {
    return [TEAM_LOGO_ALIAS_MAP[lowered], lowered];
  }
  return [lowered];
}

function uniqueKnownTeamLogoCoreMatch(coreKey) {
  if (!coreKey) return null;
  const candidates = knownTeamLogoCoreLookup.get(coreKey) || [];
  const unique = Array.from(new Set(candidates));
  return unique.length === 1 ? unique[0] : null;
}

function resolveKnownTeamLogoAsset(name) {
  loadKnownTeamLogoCatalog();

  const trimmed = normalizeMissingTeamLogoName(name);
  if (!trimmed || knownTeamLogoNormalizedLookup.size === 0) return null;

  const direct = knownTeamLogoOriginalLookup.get(trimmed.toLowerCase());
  if (direct) return direct;

  for (const alias of knownTeamLogoAliases(trimmed)) {
    const directAlias = knownTeamLogoOriginalLookup.get(alias);
    if (directAlias) return directAlias;

    const aliasKey = normalizeTeamLogoCatalogKey(alias);
    if (aliasKey && knownTeamLogoNormalizedLookup.has(aliasKey)) {
      return knownTeamLogoNormalizedLookup.get(aliasKey);
    }
  }

  const normalizedKey = normalizeTeamLogoCatalogKey(trimmed);
  if (normalizedKey && knownTeamLogoNormalizedLookup.has(normalizedKey)) {
    return knownTeamLogoNormalizedLookup.get(normalizedKey);
  }

  const coreKey = normalizeTeamLogoCatalogCoreKey(trimmed);
  const coreMatch = uniqueKnownTeamLogoCoreMatch(coreKey);
  if (coreMatch) return coreMatch;

  let bestMatch = null;
  let bestScore = 0;
  for (const [candidateKey, candidateName] of knownTeamLogoNormalizedLookup.entries()) {
    const score = similarity(normalizedKey, candidateKey);
    if (score > bestScore) {
      bestScore = score;
      bestMatch = candidateName;
    }
  }

  return bestScore >= 0.78 ? bestMatch : null;
}

function pruneResolvableMissingTeamLogos() {
  loadKnownTeamLogoCatalog();
  if (knownTeamLogoNormalizedLookup.size === 0 || missingTeamLogosByKey.size === 0) {
    return [];
  }

  const retained = new Map();
  const removed = [];
  for (const teamName of missingTeamLogosByKey.values()) {
    if (resolveKnownTeamLogoAsset(teamName)) {
      removed.push(teamName);
      continue;
    }
    retained.set(missingTeamLogoKey(teamName), teamName);
  }

  missingTeamLogosByKey = retained;
  return removed.sort(compareInsensitive);
}

function normalizeDeviceToken(value) {
  if (typeof value !== "string") return "";
  const normalized = value.trim();
  if (!normalized) return "";
  if (normalized.length > 200) return "";
  if (!/^[A-Za-z0-9._:-]+$/.test(normalized)) return "";
  return normalized;
}

function normalizeLiveActivityToken(value) {
  if (typeof value !== "string") return "";
  const normalized = value.trim();
  if (!normalized) return "";
  if (normalized.length > 1024) return "";
  if (!/^[A-Fa-f0-9]+$/.test(normalized)) return "";
  return normalized.toLowerCase();
}

function normalizeMetricLabel(value, fallback = "unknown") {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 64);
  return normalized || fallback;
}

function appMetricEventKey(labels) {
  return [
    labels.event,
    labels.screen,
    labels.build_type,
    labels.platform,
    labels.os_version,
    labels.device_type,
    labels.device_model,
    labels.app_version,
    labels.build_number,
  ].join("|");
}

function trackSeenDeviceToken(deviceToken) {
  if (!deviceToken) return;
  seenDeviceTokens.add(deviceToken);
  deviceLastSeenAtMs.set(deviceToken, Date.now());
}

function pruneInactiveDevices(nowMs = Date.now()) {
  deviceLastSeenAtMs.forEach((lastSeenAtMs, token) => {
    if (nowMs - lastSeenAtMs > APP_METRICS_ACTIVE_DEVICE_WINDOW_MS) {
      deviceLastSeenAtMs.delete(token);
    }
  });
}

function activeDeviceCount(nowMs = Date.now()) {
  pruneInactiveDevices(nowMs);
  return deviceLastSeenAtMs.size;
}

function escapePrometheusLabel(value) {
  return String(value || "")
    .replace(/\\/g, "\\\\")
    .replace(/\n/g, "\\n")
    .replace(/"/g, '\\"');
}

function normalizeHttpRouteLabel(req) {
  const routePath = req.route && req.route.path;
  let route = "";

  if (typeof routePath === "string") {
    route = `${req.baseUrl || ""}${routePath}`;
  } else if (Array.isArray(routePath)) {
    const matched = routePath.find((candidate) => candidate === req.path) ||
      routePath.find((candidate) => typeof candidate === "string");
    if (matched) {
      route = `${req.baseUrl || ""}${matched}`;
    }
  }

  if (!route) {
    route = req.path || (req.originalUrl ? String(req.originalUrl).split("?")[0] : "") || "unknown";
  }

  if (!route.startsWith("/")) {
    route = `/${route}`;
  }

  return route;
}

function metricLabelKey(labels) {
  return Object.keys(labels)
    .sort()
    .map((key) => `${key}:${labels[key]}`)
    .join("|");
}

function formatPrometheusLabels(labels) {
  return Object.keys(labels)
    .sort()
    .map((key) => `${key}="${escapePrometheusLabel(labels[key])}"`)
    .join(",");
}

function pushPrometheusSample(lines, metricName, value, labels = null) {
  const normalizedValue = Number.isFinite(value) ? value : 0;
  if (labels && Object.keys(labels).length > 0) {
    lines.push(`${metricName}{${formatPrometheusLabels(labels)}} ${normalizedValue}`);
    return;
  }
  lines.push(`${metricName} ${normalizedValue}`);
}

function recordHistogramSample(map, labels, value, bucketBoundaries) {
  const normalizedValue = Number.isFinite(value) && value >= 0 ? value : 0;
  const key = metricLabelKey(labels);
  if (!map.has(key)) {
    map.set(key, {
      labels: { ...labels },
      count: 0,
      sum: 0,
      bucketCounts: bucketBoundaries.map(() => 0),
    });
  }

  const entry = map.get(key);
  entry.count += 1;
  entry.sum += normalizedValue;
  bucketBoundaries.forEach((boundary, index) => {
    if (normalizedValue <= boundary) {
      entry.bucketCounts[index] += 1;
    }
  });
}

function appendHistogramMetrics(lines, metricName, helpText, bucketBoundaries, entries) {
  lines.push(`# HELP ${metricName} ${helpText}`);
  lines.push(`# TYPE ${metricName} histogram`);
  entries.forEach((entry) => {
    bucketBoundaries.forEach((boundary, index) => {
      pushPrometheusSample(lines, `${metricName}_bucket`, entry.bucketCounts[index], {
        ...entry.labels,
        le: String(boundary),
      });
    });
    pushPrometheusSample(lines, `${metricName}_bucket`, entry.count, {
      ...entry.labels,
      le: "+Inf",
    });
    pushPrometheusSample(lines, `${metricName}_sum`, entry.sum, entry.labels);
    pushPrometheusSample(lines, `${metricName}_count`, entry.count, entry.labels);
  });
}

function activeUsersWithinWindow(windowMs, nowMs = Date.now()) {
  let count = 0;
  deviceLastSeenAtMs.forEach((lastSeenAtMs) => {
    if (nowMs - lastSeenAtMs <= windowMs) {
      count += 1;
    }
  });
  return count;
}

function countByType(items, selector) {
  const counts = new Map();
  (Array.isArray(items) ? items : []).forEach((item) => {
    const raw = selector(item);
    const key = String(raw || "unknown").trim() || "unknown";
    counts.set(key, (counts.get(key) || 0) + 1);
  });
  return counts;
}

function setSourceCacheSize(source, size) {
  const normalizedSize = Number.isFinite(size) && size >= 0 ? size : 0;
  sourceCacheSizeBySource.set(source, normalizedSize);
}

function trackSourceUpdateMetrics({ source, startedAtMs, success, recordsFetched = null }) {
  const status = success ? "success" : "failure";
  const durationSeconds = Math.max(0, (Date.now() - startedAtMs) / 1000);
  recordHistogramSample(
    sourceFetchMetrics,
    { source, status },
    durationSeconds,
    SOURCE_FETCH_DURATION_BUCKETS
  );

  if (success) {
    sourceLastSuccessAtSeconds.set(source, Math.floor(Date.now() / 1000));
    if (Number.isFinite(recordsFetched) && recordsFetched >= 0) {
      sourceRecordsFetchedTotalBySource.set(
        source,
        (sourceRecordsFetchedTotalBySource.get(source) || 0) + recordsFetched
      );
    }
  }
}

function logPollSuccess(job, details = {}) {
  const fields = Object.entries(details)
    .filter(([, value]) => value !== undefined && value !== null && value !== "")
    .map(([key, value]) => `${key}=${String(value).replace(/\s+/g, " ").trim()}`);
  const suffix = fields.length > 0 ? ` ${fields.join(" ")}` : "";
  console.info(`[POLL][SUCCESS] job=${job}${suffix}`);
}

function isoTimestampToSeconds(value) {
  const parsed = Date.parse(String(value || ""));
  if (!Number.isFinite(parsed) || parsed <= 0) return 0;
  return Math.floor(parsed / 1000);
}

function decodeHttpResponseStream(res) {
  const contentEncoding = String(res.headers["content-encoding"] || "")
    .trim()
    .toLowerCase();
  if (!contentEncoding) return res;
  if (contentEncoding.includes("gzip")) return res.pipe(zlib.createGunzip());
  if (contentEncoding.includes("deflate")) return res.pipe(zlib.createInflate());
  if (contentEncoding.includes("br")) return res.pipe(zlib.createBrotliDecompress());
  return res;
}

function normalizeFplMessage(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function isFplGameUpdatingMessage(value) {
  const normalized = normalizeFplMessage(value).toLowerCase();
  if (!normalized) return false;
  return normalized.includes(FPL_GAME_UPDATING_NEEDLE);
}

function extractFplGameUpdatingMessage(payload) {
  if (typeof payload === "string") {
    const normalized = normalizeFplMessage(payload);
    return isFplGameUpdatingMessage(normalized) ? normalized : null;
  }

  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return null;
  }

  const keys = ["error", "message", "detail"];
  for (const key of keys) {
    if (typeof payload[key] !== "string") continue;
    const normalized = normalizeFplMessage(payload[key]);
    if (isFplGameUpdatingMessage(normalized)) {
      return normalized;
    }
  }
  return null;
}

function extractFplGameUpdatingMessageFromError(error) {
  if (!error) return null;
  if (typeof error === "string") {
    const normalized = normalizeFplMessage(error);
    return isFplGameUpdatingMessage(normalized) ? normalized : null;
  }

  if (typeof error === "object") {
    if (typeof error.upstreamMessage === "string") {
      const upstreamMessage = normalizeFplMessage(error.upstreamMessage);
      if (isFplGameUpdatingMessage(upstreamMessage)) return upstreamMessage;
    }
    if (typeof error.message === "string") {
      const message = normalizeFplMessage(error.message);
      if (isFplGameUpdatingMessage(message)) return message;
    }
  }

  return null;
}

function fetchFantasyBootstrapStaticPayload(url, options = {}, redirectDepth = 0) {
  const timeoutMs = Number.isFinite(options.timeoutMs) ? options.timeoutMs : FPL_BOOTSTRAP_TIMEOUT_MS;
  const maxBytes = Number.isFinite(options.maxBytes) ? options.maxBytes : FPL_BOOTSTRAP_MAX_BYTES;
  const maxRedirects = Number.isFinite(options.maxRedirects) ? options.maxRedirects : 3;

  return new Promise((resolve, reject) => {
    let target;
    try {
      target = new URL(url);
    } catch (_error) {
      reject(new Error(`Invalid FPL bootstrap URL: ${url}`));
      return;
    }

    const lib = target.protocol === "https:" ? https : http;
    const req = lib.get(
      target,
      {
        headers: {
          "User-Agent": "TopScoresAPI/1.0 (+https://fantasy.premierleague.com/)",
          Accept: "application/json",
          "Accept-Encoding": "gzip, deflate, br",
        },
      },
      (res) => {
        const statusCode = Number(res.statusCode || 0);
        if (statusCode >= 300 && statusCode < 400 && res.headers.location) {
          if (redirectDepth >= maxRedirects) {
            res.resume();
            reject(new Error("FPL bootstrap fetch failed: too many redirects"));
            return;
          }
          const redirectUrl = new URL(res.headers.location, target).toString();
          res.resume();
          fetchFantasyBootstrapStaticPayload(redirectUrl, options, redirectDepth + 1)
            .then(resolve)
            .catch(reject);
          return;
        }

        if (statusCode !== 200) {
          res.resume();
          reject(new Error(`FPL bootstrap fetch failed with status ${statusCode}`));
          return;
        }

        const decodedStream = decodeHttpResponseStream(res);
        const chunks = [];
        let totalBytes = 0;

        decodedStream.on("data", (chunk) => {
          const bufferChunk = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
          totalBytes += bufferChunk.length;
          if (totalBytes > maxBytes) {
            decodedStream.destroy(
              new Error(`FPL bootstrap payload exceeded max size limit (${maxBytes} bytes)`)
            );
            return;
          }
          chunks.push(bufferChunk);
        });

        decodedStream.on("error", (error) => {
          reject(error);
        });

        decodedStream.on("end", () => {
          try {
            const rawPayload = Buffer.concat(chunks, totalBytes).toString("utf8");
            const payload = JSON.parse(rawPayload);
            const gameUpdatingMessage = extractFplGameUpdatingMessage(payload);
            if (gameUpdatingMessage) {
              const updatingError = new Error(
                `FPL upstream update in progress: ${gameUpdatingMessage}`
              );
              updatingError.code = "FPL_GAME_UPDATING";
              updatingError.upstreamMessage = gameUpdatingMessage;
              reject(updatingError);
              return;
            }
            if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
              reject(new Error("FPL bootstrap parse failed: expected JSON object payload"));
              return;
            }
            resolve({
              payload,
              payloadBytes: totalBytes,
            });
          } catch (error) {
            reject(new Error(`FPL bootstrap parse failed: ${error.message || error}`));
          }
        });
      }
    );

    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`FPL bootstrap request timed out after ${timeoutMs}ms`));
    });
    req.on("error", (error) => {
      reject(error);
    });
  });
}

function fetchFantasyFixturesPayload(url, options = {}, redirectDepth = 0) {
  const timeoutMs = Number.isFinite(options.timeoutMs) ? options.timeoutMs : FPL_FIXTURES_TIMEOUT_MS;
  const maxBytes = Number.isFinite(options.maxBytes) ? options.maxBytes : FPL_FIXTURES_MAX_BYTES;
  const maxRedirects = Number.isFinite(options.maxRedirects) ? options.maxRedirects : 3;

  return new Promise((resolve, reject) => {
    let target;
    try {
      target = new URL(url);
    } catch (_error) {
      reject(new Error(`Invalid FPL fixtures URL: ${url}`));
      return;
    }

    const lib = target.protocol === "https:" ? https : http;
    const req = lib.get(
      target,
      {
        headers: {
          "User-Agent": "TopScoresAPI/1.0 (+https://fantasy.premierleague.com/)",
          Accept: "application/json",
          "Accept-Encoding": "gzip, deflate, br",
        },
      },
      (res) => {
        const statusCode = Number(res.statusCode || 0);
        if (statusCode >= 300 && statusCode < 400 && res.headers.location) {
          if (redirectDepth >= maxRedirects) {
            res.resume();
            reject(new Error("FPL fixtures fetch failed: too many redirects"));
            return;
          }
          const redirectUrl = new URL(res.headers.location, target).toString();
          res.resume();
          fetchFantasyFixturesPayload(redirectUrl, options, redirectDepth + 1)
            .then(resolve)
            .catch(reject);
          return;
        }

        if (statusCode !== 200) {
          res.resume();
          reject(new Error(`FPL fixtures fetch failed with status ${statusCode}`));
          return;
        }

        const decodedStream = decodeHttpResponseStream(res);
        const chunks = [];
        let totalBytes = 0;

        decodedStream.on("data", (chunk) => {
          const bufferChunk = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
          totalBytes += bufferChunk.length;
          if (totalBytes > maxBytes) {
            decodedStream.destroy(
              new Error(`FPL fixtures payload exceeded max size limit (${maxBytes} bytes)`)
            );
            return;
          }
          chunks.push(bufferChunk);
        });

        decodedStream.on("error", (error) => {
          reject(error);
        });

        decodedStream.on("end", () => {
          try {
            const rawPayload = Buffer.concat(chunks, totalBytes).toString("utf8");
            const payload = JSON.parse(rawPayload);
            const gameUpdatingMessage = extractFplGameUpdatingMessage(payload);
            if (gameUpdatingMessage) {
              const updatingError = new Error(
                `FPL upstream update in progress: ${gameUpdatingMessage}`
              );
              updatingError.code = "FPL_GAME_UPDATING";
              updatingError.upstreamMessage = gameUpdatingMessage;
              reject(updatingError);
              return;
            }
            if (!Array.isArray(payload)) {
              reject(new Error("FPL fixtures parse failed: expected JSON array payload"));
              return;
            }
            resolve({
              payload,
              payloadBytes: totalBytes,
            });
          } catch (error) {
            reject(new Error(`FPL fixtures parse failed: ${error.message || error}`));
          }
        });
      }
    );

    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`FPL fixtures request timed out after ${timeoutMs}ms`));
    });
    req.on("error", (error) => {
      reject(error);
    });
  });
}

function fetchFantasyEventLivePayload(url, options = {}, redirectDepth = 0) {
  const timeoutMs = Number.isFinite(options.timeoutMs) ? options.timeoutMs : FPL_EVENT_LIVE_TIMEOUT_MS;
  const maxBytes = Number.isFinite(options.maxBytes) ? options.maxBytes : FPL_EVENT_LIVE_MAX_BYTES;
  const maxRedirects = Number.isFinite(options.maxRedirects) ? options.maxRedirects : 3;

  return new Promise((resolve, reject) => {
    let target;
    try {
      target = new URL(url);
    } catch (_error) {
      reject(new Error(`Invalid FPL event live URL: ${url}`));
      return;
    }

    const lib = target.protocol === "https:" ? https : http;
    const req = lib.get(
      target,
      {
        headers: {
          "User-Agent": "TopScoresAPI/1.0 (+https://fantasy.premierleague.com/)",
          Accept: "application/json",
          "Accept-Encoding": "gzip, deflate, br",
        },
      },
      (res) => {
        const statusCode = Number(res.statusCode || 0);
        if (statusCode >= 300 && statusCode < 400 && res.headers.location) {
          if (redirectDepth >= maxRedirects) {
            res.resume();
            reject(new Error("FPL event live fetch failed: too many redirects"));
            return;
          }
          const redirectUrl = new URL(res.headers.location, target).toString();
          res.resume();
          fetchFantasyEventLivePayload(redirectUrl, options, redirectDepth + 1)
            .then(resolve)
            .catch(reject);
          return;
        }

        if (statusCode !== 200) {
          res.resume();
          reject(new Error(`FPL event live fetch failed with status ${statusCode}`));
          return;
        }

        const decodedStream = decodeHttpResponseStream(res);
        const chunks = [];
        let totalBytes = 0;

        decodedStream.on("data", (chunk) => {
          const bufferChunk = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
          totalBytes += bufferChunk.length;
          if (totalBytes > maxBytes) {
            decodedStream.destroy(
              new Error(`FPL event live payload exceeded max size limit (${maxBytes} bytes)`)
            );
            return;
          }
          chunks.push(bufferChunk);
        });

        decodedStream.on("error", (error) => {
          reject(error);
        });

        decodedStream.on("end", () => {
          try {
            const rawPayload = Buffer.concat(chunks, totalBytes).toString("utf8");
            const payload = JSON.parse(rawPayload);
            const gameUpdatingMessage = extractFplGameUpdatingMessage(payload);
            if (gameUpdatingMessage) {
              const updatingError = new Error(
                `FPL upstream update in progress: ${gameUpdatingMessage}`
              );
              updatingError.code = "FPL_GAME_UPDATING";
              updatingError.upstreamMessage = gameUpdatingMessage;
              reject(updatingError);
              return;
            }
            if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
              reject(new Error("FPL event live parse failed: expected JSON object payload"));
              return;
            }
            resolve({
              payload,
              payloadBytes: totalBytes,
            });
          } catch (error) {
            reject(new Error(`FPL event live parse failed: ${error.message || error}`));
          }
        });
      }
    );

    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`FPL event live request timed out after ${timeoutMs}ms`));
    });
    req.on("error", (error) => {
      reject(error);
    });
  });
}

function refreshFantasyScoreContextCache() {
  fantasyScore.setFantasyScoreContext({
    bootstrap: cachedFantasyBootstrap,
    fixtures: cachedFantasyFixtures,
    live: cachedFantasyEventLive,
    currentEventId: fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id,
    bootstrapUpdatedAt: fantasyBootstrapLastUpdated,
    fixturesUpdatedAt: fantasyFixturesLastUpdated,
    liveUpdatedAt: fantasyEventLiveLastUpdated,
  });
}

function refreshFantasyBootstrapDerivedState(payload) {
  const previousCurrentEventID = Number(fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id) || 0;
  const events = Array.isArray(payload && payload.events) ? payload.events : [];
  fantasyBootstrapEventsCount = events.length;
  fantasyBootstrapCurrentEvent =
    events.find((event) => event && event.is_current === true) || null;
  fantasyBootstrapNextEvent =
    events.find((event) => event && event.is_next === true) || null;
  const nextCurrentEventID = Number(fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id) || 0;
  if (previousCurrentEventID > 0 && previousCurrentEventID !== nextCurrentEventID) {
    cachedFantasyEventLive = null;
    fantasyEventLiveLastUpdated = null;
    fantasyEventLivePayloadBytes = 0;
  }
  setSourceCacheSize(SOURCE_FPL_BOOTSTRAP, fantasyBootstrapEventsCount);
  refreshFantasyScoreContextCache();
}

function currentEventHasMutableFantasyFixtures() {
  const currentEventID = Number(fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id) || 0;
  if (!currentEventID) return false;

  return cachedFantasyFixtures.some((fixture) => {
    const fixtureEventID = Number(fixture && fixture.event) || 0;
    if (fixtureEventID !== currentEventID) return false;
    if (fixture && fixture.started !== true) return false;
    const finished = fixture && fixture.finished === true;
    const finishedProvisional =
      fixture && (fixture.finished_provisional === true || fixture.finishedProvisional === true);
    return !(finished && finishedProvisional);
  });
}

function currentFantasyEventLiveSourceURL() {
  const currentEventID = Number(fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id) || 0;
  if (!currentEventID) return null;
  return FPL_EVENT_LIVE_SOURCE_URL_TEMPLATE.replace("{event}", String(currentEventID));
}

function currentFantasyEventLiveAvailability() {
  const currentEventID = Number(fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id) || 0;
  const sourceURL = currentFantasyEventLiveSourceURL();

  if (!currentEventID) {
    return {
      active: false,
      reason: "No current FPL event is marked in bootstrap data.",
      current_event_id: null,
      source_url: null,
    };
  }

  if (!Array.isArray(cachedFantasyFixtures) || cachedFantasyFixtures.length === 0) {
    return {
      active: false,
      reason: "FPL fixtures are not loaded yet, so event-live polling is idle.",
      current_event_id: currentEventID,
      source_url: sourceURL,
    };
  }

  if (!currentEventHasMutableFantasyFixtures()) {
    return {
      active: false,
      reason: "Current FPL event has no started mutable fixtures, so event-live polling is idle.",
      current_event_id: currentEventID,
      source_url: sourceURL,
    };
  }

  return {
    active: true,
    reason: null,
    current_event_id: currentEventID,
    source_url: sourceURL,
  };
}

function fantasyBootstrapAgeSeconds(nowMs = Date.now()) {
  if (!fantasyBootstrapLastUpdated) return Number.POSITIVE_INFINITY;
  const parsed = Date.parse(fantasyBootstrapLastUpdated);
  if (!Number.isFinite(parsed) || parsed <= 0) return Number.POSITIVE_INFINITY;
  return Math.max(0, (nowMs - parsed) / 1000);
}

function isFantasyBootstrapStale(nowMs = Date.now()) {
  const ageSeconds = fantasyBootstrapAgeSeconds(nowMs);
  if (!Number.isFinite(ageSeconds)) return true;
  return ageSeconds * 1000 > FPL_BOOTSTRAP_MAX_AGE_MS;
}

const londonDateTimeFormatter = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/London",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hour12: false,
});

function londonDateTimeParts(date) {
  const parts = londonDateTimeFormatter.formatToParts(date);
  const values = {};
  for (const part of parts) {
    if (part.type === "literal") continue;
    values[part.type] = Number(part.value);
  }
  return {
    year: Number.isFinite(values.year) ? values.year : 0,
    month: Number.isFinite(values.month) ? values.month : 0,
    day: Number.isFinite(values.day) ? values.day : 0,
    hour: Number.isFinite(values.hour) ? values.hour : 0,
    minute: Number.isFinite(values.minute) ? values.minute : 0,
    second: Number.isFinite(values.second) ? values.second : 0,
  };
}

function millisecondsUntilNextLondonTime(targetHour, targetMinute, now = new Date()) {
  const safeHour = Number.isFinite(targetHour)
    ? Math.max(0, Math.min(23, Math.floor(targetHour)))
    : 3;
  const safeMinute = Number.isFinite(targetMinute)
    ? Math.max(0, Math.min(59, Math.floor(targetMinute)))
    : 0;

  const maxMinutesToSearch = 60 * 48;
  let candidate = new Date(now.getTime() + 60 * 1000);
  for (let i = 0; i < maxMinutesToSearch; i += 1) {
    const parts = londonDateTimeParts(candidate);
    if (parts.hour === safeHour && parts.minute === safeMinute) {
      candidate = new Date(candidate.getTime());
      candidate.setSeconds(0, 0);
      return Math.max(1000, candidate.getTime() - now.getTime());
    }
    candidate = new Date(candidate.getTime() + 60 * 1000);
  }

  return 24 * 60 * 60 * 1000;
}

function scheduleFantasyBootstrapDailyRefresh() {
  if (fantasyBootstrapDailyRefreshTimer) {
    clearTimeout(fantasyBootstrapDailyRefreshTimer);
    fantasyBootstrapDailyRefreshTimer = null;
  }

  const delayMs = millisecondsUntilNextLondonTime(
    FPL_BOOTSTRAP_DAILY_REFRESH_HOUR_UK,
    FPL_BOOTSTRAP_DAILY_REFRESH_MINUTE_UK
  );
  const nextAt = new Date(Date.now() + delayMs);
  fantasyBootstrapNextDailyRefreshAt = nextAt.toISOString();
  const londonTarget = londonDateTimeFormatter.format(nextAt);
  console.info(
    `[FPLBootstrap] Daily refresh scheduled hour_uk=${FPL_BOOTSTRAP_DAILY_REFRESH_HOUR_UK} minute_uk=${FPL_BOOTSTRAP_DAILY_REFRESH_MINUTE_UK} next_london="${londonTarget}" next_iso=${fantasyBootstrapNextDailyRefreshAt}`
  );

  fantasyBootstrapDailyRefreshTimer = setTimeout(async () => {
    try {
      await updateFantasyBootstrapStatic({ trigger: "daily_uk_time" });
    } finally {
      scheduleFantasyBootstrapDailyRefresh();
    }
  }, delayMs);

  if (
    fantasyBootstrapDailyRefreshTimer &&
    typeof fantasyBootstrapDailyRefreshTimer.unref === "function"
  ) {
    fantasyBootstrapDailyRefreshTimer.unref();
  }
}

function parseFiniteNumber(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function clamp(value, min, max) {
  if (!Number.isFinite(value)) return min;
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

function normalizeByRange(value, min, max, fallback = 0) {
  if (!Number.isFinite(value)) return fallback;
  if (!Number.isFinite(min) || !Number.isFinite(max) || max <= min) return fallback;
  return clamp((value - min) / (max - min), 0, 1);
}

function roundTo(value, places = 2) {
  const factor = 10 ** places;
  const normalized = Number.isFinite(value) ? value : 0;
  return Math.round(normalized * factor) / factor;
}

function normalizedPlayerName(element) {
  const first = String((element && element.first_name) || "").trim();
  const second = String((element && element.second_name) || "").trim();
  const full = [first, second].filter(Boolean).join(" ").trim();
  if (full) return full;
  return String((element && element.web_name) || "").trim() || "Unknown";
}

function assistantPlayerName(source) {
  const webName = String((source && source.web_name) || "").trim();
  if (webName) return webName;
  const playerName = String((source && source.player_name) || "").trim();
  if (playerName) return playerName;
  return normalizedPlayerName(source);
}

function elementAvailabilityPenalty(element) {
  const status = String((element && element.status) || "")
    .trim()
    .toLowerCase();
  const chanceNext = parseFiniteNumber(element && element.chance_of_playing_next_round, 100);
  const chanceThis = parseFiniteNumber(element && element.chance_of_playing_this_round, chanceNext);
  const chance = Math.min(chanceNext, chanceThis);
  const news = String((element && element.news) || "")
    .trim()
    .toLowerCase();

  let penalty = 0;
  if (status === "i" || status === "s" || status === "u") {
    penalty += 1.0;
  } else if (status === "d") {
    if (chance <= 0) penalty += 0.85;
    else if (chance < 50) penalty += 0.55;
    else penalty += 0.25;
  } else if (status && status !== "a") {
    penalty += 0.15;
  }

  if (chance <= 0) penalty += 0.3;
  else if (chance < 50) penalty += 0.2;
  else if (chance < 75) penalty += 0.08;

  if (
    /(injur|knock|suspend|ill|virus|hamstring|ankle|knee|muscle|doubt|doubtful|calf)/.test(news)
  ) {
    penalty += 0.12;
  }

  return clamp(penalty, 0, 1.5);
}

function teamStrengthContext(teams) {
  const records = Array.isArray(teams)
    ? teams.map((team) => ({
      id: parseFiniteNumber(team && team.id, 0),
      name: String((team && team.name) || "").trim(),
      shortName: String((team && team.short_name) || "").trim(),
      attackAverage:
        (parseFiniteNumber(team && team.strength_attack_home, 0) +
          parseFiniteNumber(team && team.strength_attack_away, 0)) / 2,
      defenceAverage:
        (parseFiniteNumber(team && team.strength_defence_home, 0) +
          parseFiniteNumber(team && team.strength_defence_away, 0)) / 2,
    }))
      .filter((team) => team.id > 0)
    : [];

  const teamsByID = new Map(records.map((team) => [team.id, team]));
  const attackValues = records.map((team) => team.attackAverage).filter(Number.isFinite);
  const defenceValues = records.map((team) => team.defenceAverage).filter(Number.isFinite);

  return {
    teamsByID,
    attackMin: attackValues.length > 0 ? Math.min(...attackValues) : 0,
    attackMax: attackValues.length > 0 ? Math.max(...attackValues) : 1,
    defenceMin: defenceValues.length > 0 ? Math.min(...defenceValues) : 0,
    defenceMax: defenceValues.length > 0 ? Math.max(...defenceValues) : 1,
  };
}

function projectedFiveGameDifficulty(element, teamContext) {
  const elementType = parseFiniteNumber(element && element.element_type, 0);
  const teamID = parseFiniteNumber(element && element.team, 0);
  const team = teamContext.teamsByID.get(teamID) || null;
  const epNext = parseFiniteNumber(element && element.ep_next, parseFiniteNumber(element && element.form, 0));
  const epNextNorm = clamp(epNext / 8.0, 0, 1);

  let teamStrengthNorm = 0.5;
  if (team) {
    if (elementType === 1 || elementType === 2) {
      teamStrengthNorm = normalizeByRange(
        team.defenceAverage,
        teamContext.defenceMin,
        teamContext.defenceMax,
        0.5
      );
    } else {
      teamStrengthNorm = normalizeByRange(
        team.attackAverage,
        teamContext.attackMin,
        teamContext.attackMax,
        0.5
      );
    }
  }

  const ease = clamp(epNextNorm * 0.7 + teamStrengthNorm * 0.3, 0, 1);
  const projectedDifficulty = Math.round((1 - ease) * 4 + 1);

  return {
    projectedDifficulty: clamp(projectedDifficulty, 1, 5),
    projectedEase: ease,
  };
}

function teamShortLabel(team) {
  const shortName = String((team && team.shortName) || "").trim();
  if (shortName) return shortName.toUpperCase();
  const name = String((team && team.name) || "").trim();
  if (!name) return "TBD";
  const alnum = name.replace(/[^A-Za-z0-9 ]/g, " ").replace(/\s+/g, " ").trim();
  if (!alnum) return "TBD";
  const words = alnum.split(" ").filter(Boolean);
  if (words.length >= 2) {
    return (words[0].slice(0, 1) + words[1].slice(0, 2)).toUpperCase();
  }
  return words[0].slice(0, 3).toUpperCase();
}

function fixtureKickoffSortValue(value) {
  const trimmed = String(value || "").trim();
  if (!trimmed) return Number.MAX_SAFE_INTEGER;
  const parsed = Date.parse(trimmed);
  if (!Number.isFinite(parsed)) return Number.MAX_SAFE_INTEGER;
  return parsed;
}

function buildUpcomingFixturesByTeam(fixturesPayload, teamContext, baselineEvent) {
  const fixtures = Array.isArray(fixturesPayload) ? fixturesPayload : [];
  const byTeam = new Map();

  for (const fixture of fixtures) {
    const event = parseFiniteNumber(fixture && fixture.event, 0);
    const teamH = parseFiniteNumber(fixture && fixture.team_h, 0);
    const teamA = parseFiniteNumber(fixture && fixture.team_a, 0);
    if (event <= 0 || teamH <= 0 || teamA <= 0) continue;
    if (event < baselineEvent) continue;
    const finished = fixture && (fixture.finished === true || fixture.finished_provisional === true);
    if (finished) continue;

    const kickoffSort = fixtureKickoffSortValue(fixture && fixture.kickoff_time);
    const homeDifficulty = parseFiniteNumber(fixture && fixture.team_h_difficulty, 3);
    const awayDifficulty = parseFiniteNumber(fixture && fixture.team_a_difficulty, 3);
    const awayTeam = teamContext.teamsByID.get(teamA) || null;
    const homeTeam = teamContext.teamsByID.get(teamH) || null;

    const homePerspective = {
      gameweek: event,
      opponent_team_id: teamA,
      opponent_short_name: teamShortLabel(awayTeam),
      is_home: true,
      difficulty: clamp(Math.round(homeDifficulty), 1, 5),
      kickoff_sort: kickoffSort,
    };
    const awayPerspective = {
      gameweek: event,
      opponent_team_id: teamH,
      opponent_short_name: teamShortLabel(homeTeam),
      is_home: false,
      difficulty: clamp(Math.round(awayDifficulty), 1, 5),
      kickoff_sort: kickoffSort,
    };

    byTeam.set(teamH, [...(byTeam.get(teamH) || []), homePerspective]);
    byTeam.set(teamA, [...(byTeam.get(teamA) || []), awayPerspective]);
  }

  byTeam.forEach((records, teamID) => {
    const sorted = [...records].sort((left, right) => {
      if (left.gameweek !== right.gameweek) return left.gameweek - right.gameweek;
      return left.kickoff_sort - right.kickoff_sort;
    });
    byTeam.set(teamID, sorted);
  });

  return byTeam;
}

function buildTransferRecommendation(
  element,
  targetElement,
  teamContext,
  positionNameByID,
  upcomingFixturesByTeam,
  baselineEvent
) {
  const nowCost = parseFiniteNumber(element && element.now_cost, 0);
  const targetCost = parseFiniteNumber(targetElement && targetElement.now_cost, 0);
  const costMillions = nowCost / 10;
  const targetCostMillions = targetCost / 10;
  const form = parseFiniteNumber(element && element.form, 0);
  const pointsPerGame = parseFiniteNumber(element && element.points_per_game, form);
  const totalPoints = parseFiniteNumber(element && element.total_points, 0);
  const eventPoints = parseFiniteNumber(element && element.event_points, 0);
  const teamID = parseFiniteNumber(element && element.team, 0);
  const availabilityPenalty = elementAvailabilityPenalty(element);
  const next5 = projectedFiveGameDifficulty(element, teamContext);
  const fixturesByGameweek = new Map();
  for (const fixture of upcomingFixturesByTeam.get(teamID) || []) {
    const fixtureGameweek = parseFiniteNumber(fixture && fixture.gameweek, 0);
    if (fixtureGameweek <= 0) continue;
    if (!fixturesByGameweek.has(fixtureGameweek)) {
      fixturesByGameweek.set(fixtureGameweek, fixture);
    }
  }

  const normalizedBaselineEvent = Math.max(1, parseFiniteNumber(baselineEvent, 1));
  const upcomingFixtures = Array.from({ length: 5 }, (_, index) => {
    const gameweek = normalizedBaselineEvent + index;
    const fixture = fixturesByGameweek.get(gameweek);
    if (fixture) {
      return {
        ...fixture,
        is_blank: false,
      };
    }
    return {
      gameweek,
      opponent_team_id: 0,
      opponent_short_name: "No game",
      is_home: false,
      difficulty: null,
      kickoff_sort: Number.MAX_SAFE_INTEGER,
      is_blank: true,
    };
  });
  const nextFixture = upcomingFixtures.length > 0 ? upcomingFixtures[0] : null;
  const blankGameweeks = upcomingFixtures.reduce(
    (count, fixture) => count + (fixture && fixture.is_blank ? 1 : 0),
    0
  );
  const scheduleEaseValues = upcomingFixtures.map((fixture) => {
    if (fixture && fixture.is_blank) return 0;
    const difficulty = clamp(
      Math.round(parseFiniteNumber(fixture && fixture.difficulty, 3)),
      1,
      5
    );
    return clamp((6 - difficulty) / 5, 0, 1);
  });
  const scheduleEase = scheduleEaseValues.length > 0
    ? scheduleEaseValues.reduce((sum, value) => sum + value, 0) / scheduleEaseValues.length
    : next5.projectedEase;
  const blendedFixtureEase = clamp(
    scheduleEase * 0.8 + next5.projectedEase * 0.2,
    0,
    1
  );
  const blankPenaltyPoints = blankGameweeks * 5;

  const formLast5Proxy = form * 5;
  const formScoreNorm = clamp(formLast5Proxy / 35, 0, 1);
  const pointsPerGameNorm = clamp(pointsPerGame / 8, 0, 1);
  const valueEfficiency = costMillions > 0 ? totalPoints / costMillions : 0;
  const valueEfficiencyNorm = clamp(valueEfficiency / 32, 0, 1);

  const weightedScore =
    formScoreNorm * 0.52 +
    blendedFixtureEase * 0.28 +
    pointsPerGameNorm * 0.12 +
    valueEfficiencyNorm * 0.08;
  const recommendationScore =
    weightedScore * 100 - availabilityPenalty * 24 - blankPenaltyPoints;

  const team = teamContext.teamsByID.get(teamID) || null;
  const chanceNext = parseFiniteNumber(element && element.chance_of_playing_next_round, 100);
  const chanceThis = parseFiniteNumber(element && element.chance_of_playing_this_round, chanceNext);
  const rawStatus = String((element && element.status) || "").trim().toLowerCase();
  const status = rawStatus || "a";
  const availability = (() => {
    if (status === "a" && availabilityPenalty < 0.05) return "available";
    if (status === "d" || chanceNext < 100 || chanceThis < 100) return "doubtful";
    return "unavailable";
  })();

  return {
    element_id: parseFiniteNumber(element && element.id, 0),
    web_name: String((element && element.web_name) || "").trim(),
    player_name: assistantPlayerName(element),
    team_id: teamID,
    team_name: team && team.name ? team.name : "Unknown",
    team_short_name: team && team.shortName ? team.shortName : "",
    position_id: parseFiniteNumber(element && element.element_type, 0),
    position: positionNameByID.get(parseFiniteNumber(element && element.element_type, 0)) || "Player",
    now_cost_millions: roundTo(costMillions, 1),
    value_delta_millions: roundTo(costMillions - targetCostMillions, 1),
    form,
    form_last5_proxy_points: roundTo(formLast5Proxy, 1),
    points_per_game: roundTo(pointsPerGame, 2),
    ep_next: roundTo(parseFiniteNumber(element && element.ep_next, form), 2),
    total_points: totalPoints,
    event_points: eventPoints,
    status,
    chance_of_playing_next_round: chanceNext,
    chance_of_playing_this_round: chanceThis,
    news: String((element && element.news) || "").trim(),
    availability,
    projected_next5_difficulty: nextFixture
      ? (nextFixture.is_blank
        ? 5
        : nextFixture.difficulty)
      : next5.projectedDifficulty,
    projected_next5_ease: roundTo(blendedFixtureEase, 3),
    next_fixture: nextFixture
      ? {
        gameweek: nextFixture.gameweek,
        opponent_team_id: nextFixture.opponent_team_id,
        opponent_short_name: nextFixture.opponent_short_name,
        is_home: nextFixture.is_home,
        difficulty: nextFixture.difficulty,
        is_blank: Boolean(nextFixture.is_blank),
        label: nextFixture.is_blank
          ? "No game"
          : `${nextFixture.opponent_short_name} (${nextFixture.is_home ? "H" : "A"})`,
      }
      : null,
    next_five_fixtures: upcomingFixtures.map((fixture) => ({
      gameweek: fixture.gameweek,
      opponent_team_id: fixture.opponent_team_id,
      opponent_short_name: fixture.opponent_short_name,
      is_home: fixture.is_home,
      difficulty: fixture.difficulty,
      is_blank: Boolean(fixture.is_blank),
      label: fixture.is_blank
        ? "No game"
        : `${fixture.opponent_short_name} (${fixture.is_home ? "H" : "A"})`,
    })),
    recommendation_score: roundTo(recommendationScore, 2),
    score_breakdown: {
      form_score: roundTo(formScoreNorm * 100, 2),
      fixture_score: roundTo(blendedFixtureEase * 100, 2),
      points_per_game_score: roundTo(pointsPerGameNorm * 100, 2),
      value_efficiency_score: roundTo(valueEfficiencyNorm * 100, 2),
      availability_penalty: roundTo(availabilityPenalty, 3),
      blank_gameweeks: blankGameweeks,
      blank_penalty_points: blankPenaltyPoints,
    },
  };
}

function fantasyAssistantNowIso() {
  return new Date().toISOString();
}

function fantasyAssistantDataSignature() {
  return [
    fantasyBootstrapLastUpdated || "bootstrap:none",
    fantasyFixturesLastUpdated || "fixtures:none",
    parseFiniteNumber(fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id, 0),
    parseFiniteNumber(fantasyBootstrapNextEvent && fantasyBootstrapNextEvent.id, 0),
  ].join("|");
}

function ensureFantasyAssistantEntryState(entryID) {
  let state = fantasyAssistantManagerEntries.get(entryID);
  if (!state) {
    state = {
      entryID,
      lastSeenAt: null,
      lastRefreshStartedAt: null,
      lastRefreshCompletedAt: null,
      lastRefreshTrigger: null,
      lastError: null,
      picksSignature: null,
      dataSignature: null,
      payload: null,
    };
    fantasyAssistantManagerEntries.set(entryID, state);
  }
  return state;
}

function touchFantasyAssistantEntry(entryID) {
  const state = ensureFantasyAssistantEntryState(entryID);
  state.lastSeenAt = fantasyAssistantNowIso();
  return state;
}

async function fetchFantasyRemoteJSON(targetUrl, operation) {
  const controller = new AbortController();
  const timeout = setTimeout(() => {
    controller.abort(new Error(`${operation} timed out after ${FANTASY_ASSISTANT_MANAGER_FETCH_TIMEOUT_MS}ms`));
  }, FANTASY_ASSISTANT_MANAGER_FETCH_TIMEOUT_MS);

  try {
    const response = await fetch(targetUrl, {
      headers: {
        Accept: "application/json",
        "User-Agent": "top-scores-assistant-manager",
      },
      cache: "no-store",
      signal: controller.signal,
    });
    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.length > FANTASY_ASSISTANT_MANAGER_MAX_BYTES) {
      throw new Error(
        `${operation} exceeded max payload size (${FANTASY_ASSISTANT_MANAGER_MAX_BYTES} bytes)`
      );
    }

    const text = buffer.toString("utf8");
    let payload = null;
    try {
      payload = JSON.parse(text);
    } catch (error) {
      throw new Error(`${operation} returned invalid JSON: ${error.message || error}`);
    }

    const gameUpdatingMessage = extractFplGameUpdatingMessage(payload);
    if (gameUpdatingMessage) {
      const updatingError = new Error(`${operation} upstream update in progress: ${gameUpdatingMessage}`);
      updatingError.code = "FPL_GAME_UPDATING";
      updatingError.upstreamMessage = gameUpdatingMessage;
      throw updatingError;
    }

    if (!response.ok) {
      const snippet = text.replace(/\s+/g, " ").trim().slice(0, 240);
      throw new Error(`${operation} failed with status ${response.status}: ${snippet}`);
    }

    return payload;
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchFantasyEntryPicksPayload(entryID, eventID) {
  const targetUrl = `https://fantasy.premierleague.com/api/entry/${entryID}/event/${eventID}/picks/`;
  const payload = await fetchFantasyRemoteJSON(
    targetUrl,
    `fpl_entry_picks entry_id=${entryID} event_id=${eventID}`
  );
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("FPL picks payload was not a JSON object");
  }
  return payload;
}

function assistantFixtureEase(fixture) {
  if (!fixture || fixture.is_blank) return 0;
  const difficulty = clamp(parseFiniteNumber(fixture && fixture.difficulty, 3), 1, 5);
  return clamp((6 - difficulty) / 5, 0, 1);
}

function projectAssistantFixturePoints(baseExpectedPoints, fixture, availabilityMultiplier, index) {
  if (!fixture || fixture.is_blank) return 0;
  const decay = clamp(1 - index * 0.08, 0.72, 1);
  const ease = assistantFixtureEase(fixture);
  return baseExpectedPoints * (0.64 + ease * 0.72) * availabilityMultiplier * decay;
}

function assistantBlankPenaltyScore(fixtures) {
  const normalizedFixtures = Array.isArray(fixtures) ? fixtures : [];
  const blankCountNext3 = normalizedFixtures
    .slice(0, 3)
    .reduce((count, fixture) => count + (fixture && fixture.is_blank ? 1 : 0), 0);
  const blankCountNext2 = normalizedFixtures
    .slice(0, 2)
    .reduce((count, fixture) => count + (fixture && fixture.is_blank ? 1 : 0), 0);
  const blankCountNext5 = normalizedFixtures
    .slice(0, 5)
    .reduce((count, fixture) => count + (fixture && fixture.is_blank ? 1 : 0), 0);

  return {
    blankCountNext3,
    blankCountNext5,
    penaltyScore: roundTo(
      blankCountNext3 * FANTASY_ASSISTANT_MANAGER_NEAR_TERM_BLANK_PENALTY +
        blankCountNext2 * FANTASY_ASSISTANT_MANAGER_IMMINENT_BLANK_PENALTY +
        Math.max(0, blankCountNext5 - blankCountNext3) * FANTASY_ASSISTANT_MANAGER_EXTENDED_BLANK_PENALTY,
      2
    ),
  };
}

function buildAssistantManagerPlayerProfile(
  element,
  teamContext,
  positionNameByID,
  upcomingFixturesByTeam,
  baselineEvent
) {
  const recommendation = buildTransferRecommendation(
    element,
    element,
    teamContext,
    positionNameByID,
    upcomingFixturesByTeam,
    baselineEvent
  );
  const availabilityPenalty = parseFiniteNumber(
    recommendation &&
      recommendation.score_breakdown &&
      recommendation.score_breakdown.availability_penalty,
    0
  );
  const availabilityMultiplier = clamp(1 - availabilityPenalty * 0.55, 0.12, 1);
  const baseExpectedPoints = Math.max(
    0,
    parseFiniteNumber(recommendation && recommendation.ep_next, 0) * 0.68 +
      parseFiniteNumber(recommendation && recommendation.points_per_game, 0) * 0.32
  );
  const nextFixtures = Array.isArray(recommendation && recommendation.next_five_fixtures)
    ? recommendation.next_five_fixtures
    : [];
  const nextGameweekPoints = roundTo(
    projectAssistantFixturePoints(baseExpectedPoints, nextFixtures[0], availabilityMultiplier, 0),
    2
  );
  const nextThreeGameweeksPoints = roundTo(
    nextFixtures
      .slice(0, 3)
      .reduce(
        (sum, fixture, index) =>
          sum + projectAssistantFixturePoints(baseExpectedPoints, fixture, availabilityMultiplier, index),
        0
      ),
    2
  );
  const blankPenalty = assistantBlankPenaltyScore(nextFixtures);
  const assistantRankScore = roundTo(
    nextGameweekPoints * 0.24 +
      nextThreeGameweeksPoints * 0.5 +
      parseFiniteNumber(recommendation && recommendation.recommendation_score, 0) * 0.26 -
      blankPenalty.penaltyScore,
    2
  );

  return {
    ...recommendation,
    assistant_expected_points_next_gameweek: nextGameweekPoints,
    assistant_expected_points_next3_gameweeks: nextThreeGameweeksPoints,
    assistant_rank_score: assistantRankScore,
    assistant_blank_count_next3: blankPenalty.blankCountNext3,
    assistant_blank_count_next5: blankPenalty.blankCountNext5,
    assistant_blank_penalty_score: blankPenalty.penaltyScore,
    assistant_cost_units: parseFiniteNumber(element && element.now_cost, 0),
  };
}

function formatAssistantPrice(millions) {
  return `£${roundTo(parseFiniteNumber(millions, 0), 1).toFixed(1)}m`;
}

function formatAssistantSignedPoints(value) {
  const rounded = roundTo(parseFiniteNumber(value, 0), 1);
  const prefix = rounded > 0 ? "+" : "";
  return `${prefix}${rounded.toFixed(1)} pts`;
}

function formatAssistantPlayerList(values, limit = 3) {
  const unique = Array.from(
    new Set(
      (Array.isArray(values) ? values : [])
        .map((value) => String(value || "").trim())
        .filter(Boolean)
    )
  );
  if (unique.length === 0) return "";
  if (unique.length === 1) return unique[0];
  if (unique.length === 2) return `${unique[0]} and ${unique[1]}`;
  const trimmed = unique.slice(0, limit);
  return `${trimmed.slice(0, -1).join(", ")}, and ${trimmed[trimmed.length - 1]}`;
}

function buildAssistantTransferMove(outgoingProfile, incomingProfile) {
  const priceChangeMillions = roundTo(
    parseFiniteNumber(incomingProfile && incomingProfile.now_cost_millions, 0) -
      parseFiniteNumber(outgoingProfile && outgoingProfile.now_cost_millions, 0),
    1
  );
  const nextGameweekGain = roundTo(
    parseFiniteNumber(incomingProfile && incomingProfile.assistant_expected_points_next_gameweek, 0) -
      parseFiniteNumber(outgoingProfile && outgoingProfile.assistant_expected_points_next_gameweek, 0),
    2
  );
  const next3Gain = roundTo(
    parseFiniteNumber(incomingProfile && incomingProfile.assistant_expected_points_next3_gameweeks, 0) -
      parseFiniteNumber(outgoingProfile && outgoingProfile.assistant_expected_points_next3_gameweeks, 0),
    2
  );
  const projectedScoreDelta = roundTo(
    parseFiniteNumber(incomingProfile && incomingProfile.assistant_rank_score, 0) -
      parseFiniteNumber(outgoingProfile && outgoingProfile.assistant_rank_score, 0),
    2
  );

  const reasons = [];
  if (
    outgoingProfile &&
    outgoingProfile.availability !== "available" &&
    incomingProfile &&
    incomingProfile.availability === "available"
  ) {
    reasons.push(`Moves on from ${outgoingProfile.player_name}'s availability risk.`);
  }
  reasons.push(
    `Projects ${formatAssistantSignedPoints(nextGameweekGain)} next gameweek and ${formatAssistantSignedPoints(next3Gain)} across the next 3.`
  );
  if (incomingProfile && incomingProfile.next_fixture && incomingProfile.next_fixture.label) {
    reasons.push(
      `${incomingProfile.player_name} has ${incomingProfile.next_fixture.label} next and is ${incomingProfile.availability}.`
    );
  }
  if (priceChangeMillions < -0.05) {
    reasons.push(`Saves ${formatAssistantPrice(Math.abs(priceChangeMillions))} for future flexibility.`);
  } else if (priceChangeMillions > 0.05) {
    reasons.push(`Costs ${formatAssistantPrice(priceChangeMillions)} more for a stronger upside bet.`);
  }

  return {
    outProfile: outgoingProfile,
    inProfile: incomingProfile,
    out_element_id: parseFiniteNumber(outgoingProfile && outgoingProfile.element_id, 0),
    out_player_name: assistantPlayerName(outgoingProfile),
    out_team_id: parseFiniteNumber(outgoingProfile && outgoingProfile.team_id, 0),
    out_team_name: String((outgoingProfile && outgoingProfile.team_name) || "").trim(),
    out_team_short_name: String((outgoingProfile && outgoingProfile.team_short_name) || "").trim(),
    out_price_millions: parseFiniteNumber(outgoingProfile && outgoingProfile.now_cost_millions, 0),
    out_cost_units: parseFiniteNumber(outgoingProfile && outgoingProfile.assistant_cost_units, 0),
    in_element_id: parseFiniteNumber(incomingProfile && incomingProfile.element_id, 0),
    in_player_name: assistantPlayerName(incomingProfile),
    in_team_id: parseFiniteNumber(incomingProfile && incomingProfile.team_id, 0),
    in_team_name: String((incomingProfile && incomingProfile.team_name) || "").trim(),
    in_team_short_name: String((incomingProfile && incomingProfile.team_short_name) || "").trim(),
    in_price_millions: parseFiniteNumber(incomingProfile && incomingProfile.now_cost_millions, 0),
    in_cost_units: parseFiniteNumber(incomingProfile && incomingProfile.assistant_cost_units, 0),
    price_change_millions: priceChangeMillions,
    projected_gain_next_gameweek: nextGameweekGain,
    projected_gain_next3_gameweeks: next3Gain,
    projected_score_delta: projectedScoreDelta,
    reasons: reasons.slice(0, 3),
  };
}

function assistantMoveSortScore(move) {
  return (
    parseFiniteNumber(move && move.projected_gain_next_gameweek, 0) * 0.2 +
    parseFiniteNumber(move && move.projected_gain_next3_gameweeks, 0) * 0.5 +
    parseFiniteNumber(move && move.projected_score_delta, 0) * 0.3
  );
}

function compareAssistantMoves(left, right) {
  const rightScore = assistantMoveSortScore(right);
  const leftScore = assistantMoveSortScore(left);
  if (rightScore !== leftScore) return rightScore - leftScore;
  if (right.projected_gain_next3_gameweeks !== left.projected_gain_next3_gameweeks) {
    return right.projected_gain_next3_gameweeks - left.projected_gain_next3_gameweeks;
  }
  if (right.projected_gain_next_gameweek !== left.projected_gain_next_gameweek) {
    return right.projected_gain_next_gameweek - left.projected_gain_next_gameweek;
  }
  return left.price_change_millions - right.price_change_millions;
}

function isAssistantTransferPackageValid(
  moves,
  baseClubCounts,
  currentSquadCostUnits,
  availableBudgetUnits,
  budgetLimited
) {
  const outgoingSeen = new Set();
  const incomingSeen = new Set();
  const counts = new Map(baseClubCounts instanceof Map ? baseClubCounts.entries() : []);
  let squadCostUnits = currentSquadCostUnits;

  for (const move of moves) {
    if (!move) return false;
    if (outgoingSeen.has(move.out_element_id) || incomingSeen.has(move.in_element_id)) {
      return false;
    }
    outgoingSeen.add(move.out_element_id);
    incomingSeen.add(move.in_element_id);

    const outTeamID = parseFiniteNumber(move.out_team_id, 0);
    const inTeamID = parseFiniteNumber(move.in_team_id, 0);
    if (outTeamID > 0) {
      counts.set(outTeamID, Math.max(0, (counts.get(outTeamID) || 0) - 1));
    }
    if (inTeamID > 0) {
      counts.set(inTeamID, (counts.get(inTeamID) || 0) + 1);
      if ((counts.get(inTeamID) || 0) > 3) {
        return false;
      }
    }

    squadCostUnits =
      squadCostUnits -
      parseFiniteNumber(move.out_cost_units, 0) +
      parseFiniteNumber(move.in_cost_units, 0);
  }

  if (budgetLimited && squadCostUnits > availableBudgetUnits) {
    return false;
  }

  return true;
}

function buildAssistantPlanReasons(
  moves,
  budgetLimited,
  currentSquadCostUnits,
  availableBudgetUnits
) {
  const reasons = [];
  const gainNextGameweek = roundTo(
    moves.reduce((sum, move) => sum + parseFiniteNumber(move && move.projected_gain_next_gameweek, 0), 0),
    2
  );
  const gainNext3 = roundTo(
    moves.reduce((sum, move) => sum + parseFiniteNumber(move && move.projected_gain_next3_gameweeks, 0), 0),
    2
  );
  reasons.push(
    `Projects ${formatAssistantSignedPoints(gainNextGameweek)} next gameweek and ${formatAssistantSignedPoints(gainNext3)} across the next 3 gameweeks.`
  );

  const netSpendUnits = moves.reduce(
    (sum, move) =>
      sum +
      parseFiniteNumber(move && move.in_cost_units, 0) -
      parseFiniteNumber(move && move.out_cost_units, 0),
    0
  );
  if (budgetLimited) {
    const remainingBudgetUnits = roundTo(
      availableBudgetUnits - (currentSquadCostUnits + netSpendUnits),
      1
    );
    if (netSpendUnits > 0) {
      reasons.push(
        `Uses ${formatAssistantPrice(netSpendUnits / 10)} of headroom and still fits the current team value limit.`
      );
    } else if (netSpendUnits < 0) {
      reasons.push(
        `Saves ${formatAssistantPrice(Math.abs(netSpendUnits) / 10)} while improving the squad.`
      );
    } else {
      reasons.push("Stays flat on spend while upgrading projected output.");
    }
    if (remainingBudgetUnits > 0.05) {
      reasons.push(`Leaves ${formatAssistantPrice(remainingBudgetUnits / 10)} of budget flexibility unused.`);
    }
  } else {
    reasons.push("Ignores budget and focuses purely on short-term upside.");
  }

  const flaggedOutgoing = moves
    .filter((move) => move.outProfile && move.outProfile.availability !== "available")
    .map((move) => move.out_player_name);
  if (flaggedOutgoing.length > 0) {
    reasons.push(`Moves on from flagged players such as ${formatAssistantPlayerList(flaggedOutgoing)}.`);
  } else {
    const incomingFixtures = moves
      .map((move) => move.inProfile && move.inProfile.next_fixture && move.inProfile.next_fixture.label)
      .filter(Boolean);
    if (incomingFixtures.length > 0) {
      reasons.push(`Targets immediate fixtures like ${formatAssistantPlayerList(incomingFixtures)}.`);
    }
  }

  reasons.push("Keeps squad structure intact and respects the three-per-club rule.");
  return reasons.slice(0, 4);
}

function buildAssistantTransferPlan(
  title,
  summary,
  moves,
  budgetLimited,
  currentSquadCostUnits,
  availableBudgetUnits
) {
  if (!Array.isArray(moves) || moves.length === 0) return null;

  const projectedGainNextGameweek = roundTo(
    moves.reduce((sum, move) => sum + parseFiniteNumber(move && move.projected_gain_next_gameweek, 0), 0),
    2
  );
  const projectedGainNext3Gameweeks = roundTo(
    moves.reduce((sum, move) => sum + parseFiniteNumber(move && move.projected_gain_next3_gameweeks, 0), 0),
    2
  );
  const projectedScoreDelta = roundTo(
    moves.reduce((sum, move) => sum + parseFiniteNumber(move && move.projected_score_delta, 0), 0),
    2
  );

  return {
    title,
    summary,
    projected_gain_next_gameweek: projectedGainNextGameweek,
    projected_gain_next3_gameweeks: projectedGainNext3Gameweeks,
    projected_score_delta: projectedScoreDelta,
    reasons: buildAssistantPlanReasons(
      moves,
      budgetLimited,
      currentSquadCostUnits,
      availableBudgetUnits
    ),
    transfers: moves.map((move) => ({
      out_element_id: move.out_element_id,
      out_player_name: move.out_player_name,
      out_team_name: move.out_team_name,
      out_team_short_name: move.out_team_short_name,
      out_price_millions: move.out_price_millions,
      in_element_id: move.in_element_id,
      in_player_name: move.in_player_name,
      in_team_name: move.in_team_name,
      in_team_short_name: move.in_team_short_name,
      in_price_millions: move.in_price_millions,
      price_change_millions: move.price_change_millions,
      projected_gain_next_gameweek: move.projected_gain_next_gameweek,
      projected_gain_next3_gameweeks: move.projected_gain_next3_gameweeks,
      projected_score_delta: move.projected_score_delta,
      reasons: move.reasons,
    })),
  };
}

function buildAssistantCaptainCandidate(profile) {
  const reasons = [
    `Projects ${roundTo(parseFiniteNumber(profile && profile.assistant_expected_points_next_gameweek, 0), 1).toFixed(1)} points next gameweek.`,
  ];
  if (profile && profile.next_fixture && profile.next_fixture.label) {
    reasons.push(`${profile.player_name} faces ${profile.next_fixture.label} next.`);
  }
  reasons.push(
    `Form/fixture blend score: ${roundTo(parseFiniteNumber(profile && profile.assistant_rank_score, 0), 1).toFixed(1)}.`
  );
  if (profile && profile.availability !== "available") {
    reasons.unshift(`${profile.player_name} carries an availability flag, so risk is slightly elevated.`);
  }

  return {
    element_id: parseFiniteNumber(profile && profile.element_id, 0),
    player_name: assistantPlayerName(profile),
    team_name: String((profile && profile.team_name) || "").trim(),
    team_short_name: String((profile && profile.team_short_name) || "").trim(),
    opponent_label:
      profile && profile.next_fixture && profile.next_fixture.label
        ? profile.next_fixture.label
        : "Fixture unavailable",
    availability: String((profile && profile.availability) || "unknown").trim(),
    expected_points_next_gameweek: roundTo(
      parseFiniteNumber(profile && profile.assistant_expected_points_next_gameweek, 0),
      2
    ),
    expected_points_next3_gameweeks: roundTo(
      parseFiniteNumber(profile && profile.assistant_expected_points_next3_gameweeks, 0),
      2
    ),
    reasons: reasons.slice(0, 3),
  };
}

function buildAssistantExpectedPointsPlayer(profile, pick) {
  const nextFixture = profile && profile.next_fixture ? profile.next_fixture : null;
  return {
    element_id: parseFiniteNumber(profile && profile.element_id, 0),
    pick_position: parseFiniteNumber(pick && pick.position, 0),
    is_starter: parseFiniteNumber(pick && pick.position, 0) > 0 && parseFiniteNumber(pick && pick.position, 0) <= 11,
    player_name: assistantPlayerName(profile),
    team_name: String((profile && profile.team_name) || "").trim(),
    team_short_name: String((profile && profile.team_short_name) || "").trim(),
    opponent_team_name: nextFixture && !nextFixture.is_blank
      ? String((nextFixture && nextFixture.opponent_short_name) || "").trim()
      : "No game",
    opponent_label: nextFixture && nextFixture.label
      ? String(nextFixture.label).trim()
      : "No game",
    difficulty: nextFixture && !nextFixture.is_blank
      ? parseFiniteNumber(nextFixture && nextFixture.difficulty, 0)
      : null,
    expected_points_next_gameweek: roundTo(
      parseFiniteNumber(profile && profile.assistant_expected_points_next_gameweek, 0),
      2
    ),
    is_blank: !(nextFixture && !nextFixture.is_blank),
  };
}

function idealSquadPoolForPosition(playerProfiles, positionID) {
  const limit = FANTASY_ASSISTANT_MANAGER_IDEAL_POOL_LIMITS[positionID] || 12;
  return playerProfiles
    .filter((profile) => parseFiniteNumber(profile && profile.position_id, 0) === positionID)
    .sort((left, right) => {
      const rightScore = assistantIdealProfileScore(right);
      const leftScore = assistantIdealProfileScore(left);
      if (rightScore !== leftScore) return rightScore - leftScore;
      return (
        parseFiniteNumber(right && right.assistant_cost_units, 0) -
        parseFiniteNumber(left && left.assistant_cost_units, 0)
      );
    })
    .slice(0, limit);
}

function assistantIdealProfileScore(profile) {
  return (
    parseFiniteNumber(profile && profile.assistant_expected_points_next3_gameweeks, 0) * 0.58 +
    parseFiniteNumber(profile && profile.assistant_expected_points_next_gameweek, 0) * 0.28 +
    parseFiniteNumber(profile && profile.assistant_rank_score, 0) * 0.14
  );
}

function idealBenchPoolForPosition(playerProfiles, positionID) {
  const limitByPosition = Object.freeze({
    1: 6,
    2: 8,
    3: 8,
    4: 6,
  });
  const limit = limitByPosition[positionID] || 6;
  return playerProfiles
    .filter((profile) => parseFiniteNumber(profile && profile.position_id, 0) === positionID)
    .sort((left, right) => {
      const leftCost = parseFiniteNumber(left && left.assistant_cost_units, 0);
      const rightCost = parseFiniteNumber(right && right.assistant_cost_units, 0);
      if (leftCost !== rightCost) return leftCost - rightCost;
      const leftScore = assistantIdealProfileScore(left);
      const rightScore = assistantIdealProfileScore(right);
      if (leftScore !== rightScore) return leftScore - rightScore;
      return String((left && left.player_name) || "").localeCompare(String((right && right.player_name) || ""));
    })
    .slice(0, limit);
}

function buildAssistantIdealDisplayContext(teams, currentEventID) {
  const teamsByID = new Map(
    (Array.isArray(teams) ? teams : [])
      .map((team) => [parseFiniteNumber(team && team.id, 0), team])
      .filter(([teamID]) => teamID > 0)
  );
  const allFixtures = Array.isArray(cachedFantasyFixtures) ? cachedFantasyFixtures : [];
  const currentFixtures = (Array.isArray(cachedFantasyFixtures) ? cachedFantasyFixtures : [])
    .filter((fixture) => parseFiniteNumber(fixture && fixture.event, 0) === currentEventID);
  const activeTeamIDs = new Set();
  const upcomingTeamIDs = new Set();
  const teamsWithAnyFixture = new Set();
  let hasStartedFixturesInGameweek = false;
  let hasFixturesPlayedToday = false;

  const now = new Date();
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const startOfTomorrow = new Date(startOfToday.getTime() + 24 * 60 * 60 * 1000);

  const upcomingOpponentByTeamID = new Map();
  allFixtures
    .filter((fixture) => {
      const eventID = parseFiniteNumber(fixture && fixture.event, 0);
      return currentEventID > 0 ? eventID >= currentEventID : true;
    })
    .sort((left, right) =>
      parseFiniteNumber(left && left.event, Number.MAX_SAFE_INTEGER) -
        parseFiniteNumber(right && right.event, Number.MAX_SAFE_INTEGER) ||
      fixtureKickoffSortValue(left && left.kickoff_time) - fixtureKickoffSortValue(right && right.kickoff_time) ||
      parseFiniteNumber(left && left.id, 0) - parseFiniteNumber(right && right.id, 0)
    )
    .forEach((fixture) => {
      const teamH = parseFiniteNumber(fixture && fixture.team_h, 0);
      const teamA = parseFiniteNumber(fixture && fixture.team_a, 0);
      if (teamH <= 0 || teamA <= 0) return;

      const started = fixture && fixture.started === true;
      const finished = fixture && (fixture.finished === true || fixture.finished_provisional === true);
      if (!started && !finished) {
        if (!upcomingOpponentByTeamID.has(teamH)) {
          upcomingOpponentByTeamID.set(
            teamH,
            `${teamShortLabel(teamsByID.get(teamA) || null)} (H)`
          );
        }
        if (!upcomingOpponentByTeamID.has(teamA)) {
          upcomingOpponentByTeamID.set(
            teamA,
            `${teamShortLabel(teamsByID.get(teamH) || null)} (A)`
          );
        }
      }
    });

  [...currentFixtures]
    .sort((left, right) =>
      fixtureKickoffSortValue(left && left.kickoff_time) - fixtureKickoffSortValue(right && right.kickoff_time)
    )
    .forEach((fixture) => {
      const teamH = parseFiniteNumber(fixture && fixture.team_h, 0);
      const teamA = parseFiniteNumber(fixture && fixture.team_a, 0);
      if (teamH <= 0 || teamA <= 0) return;

      const started = fixture && fixture.started === true;
      const finished = fixture && (fixture.finished === true || fixture.finished_provisional === true);
      teamsWithAnyFixture.add(teamH);
      teamsWithAnyFixture.add(teamA);

      if (started && !finished) {
        activeTeamIDs.add(teamH);
        activeTeamIDs.add(teamA);
      }
      if (!started && !finished) {
        upcomingTeamIDs.add(teamH);
        upcomingTeamIDs.add(teamA);
      }
      if (started || finished) {
        hasStartedFixturesInGameweek = true;
      }
      if (started) {
        const kickoffRaw = String((fixture && fixture.kickoff_time) || "").trim();
        const kickoffAtMs = Date.parse(kickoffRaw);
        if (Number.isFinite(kickoffAtMs)) {
          const kickoffAt = new Date(kickoffAtMs);
          if (kickoffAt >= startOfToday && kickoffAt < startOfTomorrow) {
            hasFixturesPlayedToday = true;
          }
        }
      }
    });

  return {
    activeTeamIDs,
    upcomingTeamIDs,
    teamsWithAnyFixture,
    hasActiveFixtures: activeTeamIDs.size > 0,
    hasStartedFixturesInGameweek,
    hasFixturesPlayedToday,
    upcomingOpponentByTeamID,
  };
}

function assistantIdealCanSelect(teamCounts, candidate, replacing = null) {
  const candidateTeamID = parseFiniteNumber(candidate && candidate.team_id, 0);
  const replacingTeamID = parseFiniteNumber(replacing && replacing.team_id, 0);
  const nextTeamCounts = new Map(teamCounts);
  if (replacing && replacingTeamID > 0) {
    nextTeamCounts.set(replacingTeamID, Math.max(0, (nextTeamCounts.get(replacingTeamID) || 0) - 1));
  }
  if (candidateTeamID > 0) {
    nextTeamCounts.set(candidateTeamID, (nextTeamCounts.get(candidateTeamID) || 0) + 1);
    if ((nextTeamCounts.get(candidateTeamID) || 0) > 3) {
      return false;
    }
  }
  return true;
}

function buildAssistantIdealBenchOptions(playerProfiles) {
  const goalkeepers = idealBenchPoolForPosition(playerProfiles, 1);
  const defenders = idealBenchPoolForPosition(playerProfiles, 2);
  const midfielders = idealBenchPoolForPosition(playerProfiles, 3);
  const forwards = idealBenchPoolForPosition(playerProfiles, 4);
  const options = [];
  const seen = new Set();

  for (const goalkeeper of goalkeepers) {
    for (const defender of defenders) {
      for (const midfielder of midfielders) {
        for (const forward of forwards) {
          const profiles = [goalkeeper, defender, midfielder, forward];
          const ids = profiles.map((profile) => parseFiniteNumber(profile && profile.element_id, 0));
          if (new Set(ids).size !== profiles.length) continue;

          const teamCounts = new Map();
          let valid = true;
          for (const profile of profiles) {
            const teamID = parseFiniteNumber(profile && profile.team_id, 0);
            if (teamID <= 0) continue;
            teamCounts.set(teamID, (teamCounts.get(teamID) || 0) + 1);
            if ((teamCounts.get(teamID) || 0) > 3) {
              valid = false;
              break;
            }
          }
          if (!valid) continue;

          const key = [...ids].sort((left, right) => left - right).join("-");
          if (seen.has(key)) continue;
          seen.add(key);

          options.push({
            profiles,
            totalCostUnits: profiles.reduce(
              (sum, profile) => sum + parseFiniteNumber(profile && profile.assistant_cost_units, 0),
              0
            ),
            totalBenchScore: roundTo(
              profiles.reduce((sum, profile) => sum + assistantIdealProfileScore(profile), 0),
              2
            ),
          });
        }
      }
    }
  }

  return options
    .sort((left, right) => {
      if (left.totalCostUnits !== right.totalCostUnits) {
        return left.totalCostUnits - right.totalCostUnits;
      }
      if (left.totalBenchScore !== right.totalBenchScore) {
        return left.totalBenchScore - right.totalBenchScore;
      }
      return 0;
    })
    .slice(0, 40);
}

function chooseAssistantStartingXI(playerProfiles, formation, lockedProfiles, budgetUnits) {
  const quotas = [
    { positionID: 1, count: 1 },
    { positionID: 2, count: formation.defendersCount },
    { positionID: 3, count: formation.midfieldersCount },
    { positionID: 4, count: formation.forwardsCount },
  ];
  const pools = new Map(
    quotas.map(({ positionID }) => [positionID, idealSquadPoolForPosition(playerProfiles, positionID)])
  );
  const selectedProfiles = [...lockedProfiles];
  const lockedIDs = new Set(lockedProfiles.map((profile) => parseFiniteNumber(profile && profile.element_id, 0)));
  const selectedIDs = new Set(lockedIDs);
  const replaceableIDs = new Set();
  const teamCounts = lockedProfiles.reduce((counts, profile) => {
    const teamID = parseFiniteNumber(profile && profile.team_id, 0);
    if (teamID > 0) {
      counts.set(teamID, (counts.get(teamID) || 0) + 1);
    }
    return counts;
  }, new Map());
  const addedCounts = new Map();

  const applySelection = (candidate) => {
    selectedProfiles.push(candidate);
    selectedIDs.add(candidate.element_id);
    replaceableIDs.add(candidate.element_id);
    const positionID = parseFiniteNumber(candidate && candidate.position_id, 0);
    addedCounts.set(positionID, (addedCounts.get(positionID) || 0) + 1);
    const teamID = parseFiniteNumber(candidate && candidate.team_id, 0);
    if (teamID > 0) {
      teamCounts.set(teamID, (teamCounts.get(teamID) || 0) + 1);
    }
  };

  for (const { positionID, count } of quotas) {
    const candidates = pools.get(positionID) || [];
    for (const candidate of candidates) {
      if ((addedCounts.get(positionID) || 0) >= count) break;
      if (selectedIDs.has(candidate.element_id)) continue;
      if (!assistantIdealCanSelect(teamCounts, candidate)) continue;
      applySelection(candidate);
    }
    if ((addedCounts.get(positionID) || 0) < count) {
      return null;
    }
  }

  let totalCostUnits = selectedProfiles.reduce(
    (sum, profile) => sum + parseFiniteNumber(profile && profile.assistant_cost_units, 0),
    0
  );

  const replacePlayer = (currentProfile, candidateProfile) => {
    const currentIndex = selectedProfiles.findIndex((profile) => profile.element_id === currentProfile.element_id);
    if (currentIndex < 0) return;
    selectedProfiles[currentIndex] = candidateProfile;
    selectedIDs.delete(currentProfile.element_id);
    selectedIDs.add(candidateProfile.element_id);
    replaceableIDs.delete(currentProfile.element_id);
    replaceableIDs.add(candidateProfile.element_id);

    const currentTeamID = parseFiniteNumber(currentProfile && currentProfile.team_id, 0);
    const candidateTeamID = parseFiniteNumber(candidateProfile && candidateProfile.team_id, 0);
    if (currentTeamID > 0) {
      teamCounts.set(currentTeamID, Math.max(0, (teamCounts.get(currentTeamID) || 0) - 1));
    }
    if (candidateTeamID > 0) {
      teamCounts.set(candidateTeamID, (teamCounts.get(candidateTeamID) || 0) + 1);
    }
    totalCostUnits +=
      parseFiniteNumber(candidateProfile && candidateProfile.assistant_cost_units, 0) -
      parseFiniteNumber(currentProfile && currentProfile.assistant_cost_units, 0);
  };

  while (totalCostUnits > budgetUnits) {
    let bestDowngrade = null;

    for (const currentProfile of selectedProfiles) {
      if (!replaceableIDs.has(currentProfile.element_id)) continue;
      const positionID = parseFiniteNumber(currentProfile && currentProfile.position_id, 0);
      const pool = pools.get(positionID) || [];
      for (const candidate of pool) {
        if (selectedIDs.has(candidate.element_id)) continue;
        const currentCost = parseFiniteNumber(currentProfile && currentProfile.assistant_cost_units, 0);
        const candidateCost = parseFiniteNumber(candidate && candidate.assistant_cost_units, 0);
        if (candidateCost >= currentCost) continue;
        if (!assistantIdealCanSelect(teamCounts, candidate, currentProfile)) continue;

        const save = currentCost - candidateCost;
        const loss = assistantIdealProfileScore(currentProfile) - assistantIdealProfileScore(candidate);
        const ratio = loss / Math.max(save, 1);
        if (
          !bestDowngrade ||
          ratio < bestDowngrade.ratio ||
          (ratio === bestDowngrade.ratio && loss < bestDowngrade.loss)
        ) {
          bestDowngrade = {
            currentProfile,
            candidate,
            loss,
            ratio,
          };
        }
      }
    }

    if (!bestDowngrade) {
      return null;
    }
    replacePlayer(bestDowngrade.currentProfile, bestDowngrade.candidate);
  }

  let improved = true;
  while (improved) {
    improved = false;
    let bestUpgrade = null;

    for (const currentProfile of selectedProfiles) {
      if (!replaceableIDs.has(currentProfile.element_id)) continue;
      const positionID = parseFiniteNumber(currentProfile && currentProfile.position_id, 0);
      const pool = pools.get(positionID) || [];
      for (const candidate of pool) {
        if (selectedIDs.has(candidate.element_id)) continue;
        if (!assistantIdealCanSelect(teamCounts, candidate, currentProfile)) continue;
        const deltaCost =
          parseFiniteNumber(candidate && candidate.assistant_cost_units, 0) -
          parseFiniteNumber(currentProfile && currentProfile.assistant_cost_units, 0);
        if (totalCostUnits + deltaCost > budgetUnits) continue;

        const gain = assistantIdealProfileScore(candidate) - assistantIdealProfileScore(currentProfile);
        if (gain <= 0) continue;
        if (!bestUpgrade || gain > bestUpgrade.gain) {
          bestUpgrade = {
            currentProfile,
            candidate,
            gain,
          };
        }
      }
    }

    if (bestUpgrade) {
      replacePlayer(bestUpgrade.currentProfile, bestUpgrade.candidate);
      improved = true;
    }
  }

  const starterProfiles = selectedProfiles.filter((profile) => replaceableIDs.has(profile.element_id));
  return {
    formation: `${formation.defendersCount}-${formation.midfieldersCount}-${formation.forwardsCount}`,
    allProfiles: [...selectedProfiles],
    starterProfiles,
    totalCostUnits,
    starterScore: roundTo(
      starterProfiles.reduce((sum, profile) => sum + assistantIdealProfileScore(profile), 0),
      2
    ),
    starterExpectedPoints: roundTo(
      starterProfiles.reduce(
        (sum, profile) => sum + parseFiniteNumber(profile && profile.assistant_expected_points_next_gameweek, 0),
        0
      ),
      2
    ),
  };
}

function buildAssistantIdealSquadPlayer(profile, displayContext, options = {}) {
  const pickPosition = parseFiniteNumber(options && options.pickPosition, 0);
  const multiplier = Math.max(1, parseFiniteNumber(options && options.multiplier, 1));
  const rawPoints = parseFiniteNumber(profile && profile.event_points, 0);
  const teamID = parseFiniteNumber(profile && profile.team_id, 0);
  const rawStatus = String((profile && profile.status) || "").trim().toLowerCase();
  const chanceOfPlaying = parseFiniteNumber(profile && profile.chance_of_playing_next_round, 100);
  const isUnavailable =
    rawStatus === "i" || rawStatus === "d" || rawStatus === "s" || rawStatus === "u";
  const isDefinitelyUnavailable =
    rawStatus === "i" ||
    rawStatus === "s" ||
    rawStatus === "u" ||
    (rawStatus === "d" && chanceOfPlaying <= 0);
  const futureBlankFixture = (Array.isArray(profile && profile.next_five_fixtures)
    ? profile.next_five_fixtures
    : []
  ).find((fixture) => fixture && fixture.is_blank);

  return {
    element_id: parseFiniteNumber(profile && profile.element_id, 0),
    pick_position: pickPosition,
    player_name: assistantPlayerName(profile),
    team_id: parseFiniteNumber(profile && profile.team_id, 0),
    team_name: String((profile && profile.team_name) || "").trim(),
    team_short_name: String((profile && profile.team_short_name) || "").trim(),
    position_id: parseFiniteNumber(profile && profile.position_id, 0),
    position: String((profile && profile.position) || "").trim(),
    now_cost_millions: roundTo(parseFiniteNumber(profile && profile.now_cost_millions, 0), 1),
    expected_points_next_gameweek: roundTo(
      parseFiniteNumber(profile && profile.assistant_expected_points_next_gameweek, 0),
      2
    ),
    expected_points_next3_gameweeks: roundTo(
      parseFiniteNumber(profile && profile.assistant_expected_points_next3_gameweeks, 0),
      2
    ),
    assistant_rank_score: roundTo(parseFiniteNumber(profile && profile.assistant_rank_score, 0), 2),
    raw_points: rawPoints,
    applied_points: rawPoints * multiplier,
    multiplier,
    is_captain: Boolean(options && options.isCaptain),
    is_vice_captain: Boolean(options && options.isViceCaptain),
    is_playing_now: displayContext.activeTeamIDs.has(teamID),
    is_unavailable: isUnavailable,
    is_definitely_unavailable: isDefinitelyUnavailable,
    has_any_fixture_this_gameweek: displayContext.teamsWithAnyFixture.has(teamID),
    has_upcoming_fixture_this_gameweek: displayContext.upcomingTeamIDs.has(teamID),
    has_active_fixture_this_gameweek: displayContext.activeTeamIDs.has(teamID),
    has_future_availability_issue: Boolean(futureBlankFixture),
    future_availability_issue_gameweek: futureBlankFixture
      ? parseFiniteNumber(futureBlankFixture && futureBlankFixture.gameweek, 0)
      : null,
    minutes_played: rawPoints > 0 ? 1 : 0,
    upcoming_opponent_display: displayContext.upcomingOpponentByTeamID.get(teamID) || null,
    goals_scored: 0,
    assists: 0,
    yellow_cards: 0,
    red_cards: 0,
  };
}

function buildAssistantIdealSquad(playerProfiles, teams, currentEventID) {
  const benchOptions = buildAssistantIdealBenchOptions(playerProfiles);
  if (benchOptions.length === 0) return null;

  let best = null;
  for (const benchSelection of benchOptions) {
    for (let defendersCount = 3; defendersCount <= 5; defendersCount += 1) {
      for (let midfieldersCount = 2; midfieldersCount <= 5; midfieldersCount += 1) {
        for (let forwardsCount = 1; forwardsCount <= 3; forwardsCount += 1) {
          if (defendersCount + midfieldersCount + forwardsCount !== 10) continue;
          const formation = {
            defendersCount,
            midfieldersCount,
            forwardsCount,
          };
          const candidate = chooseAssistantStartingXI(
            playerProfiles,
            formation,
            benchSelection.profiles,
            FANTASY_ASSISTANT_MANAGER_IDEAL_SQUAD_BUDGET_UNITS
          );
          if (!candidate) continue;
          if (
            !best ||
            candidate.starterScore > best.starterScore ||
            (candidate.starterScore === best.starterScore &&
              candidate.starterExpectedPoints > best.starterExpectedPoints) ||
            (candidate.starterScore === best.starterScore &&
              candidate.starterExpectedPoints === best.starterExpectedPoints &&
              candidate.totalCostUnits > best.totalCostUnits)
          ) {
            best = {
              ...candidate,
              benchProfiles: [...benchSelection.profiles],
              benchCostUnits: benchSelection.totalCostUnits,
              benchScore: benchSelection.totalBenchScore,
            };
          }
        }
      }
    }
  }

  if (!best) return null;

  const starters = [...best.starterProfiles].sort((left, right) => {
    const leftPosition = parseFiniteNumber(left && left.position_id, 0);
    const rightPosition = parseFiniteNumber(right && right.position_id, 0);
    if (leftPosition !== rightPosition) return leftPosition - rightPosition;
    return (
      parseFiniteNumber(right && right.assistant_expected_points_next_gameweek, 0) -
      parseFiniteNumber(left && left.assistant_expected_points_next_gameweek, 0)
    );
  });
  const bench = [...best.benchProfiles].sort((left, right) => {
    const leftPosition = parseFiniteNumber(left && left.position_id, 0);
    const rightPosition = parseFiniteNumber(right && right.position_id, 0);
    if (leftPosition !== rightPosition) return leftPosition - rightPosition;
    return (
      parseFiniteNumber(left && left.assistant_cost_units, 0) -
      parseFiniteNumber(right && right.assistant_cost_units, 0)
    );
  });
  const captainCandidates = [...starters].sort((left, right) => {
    const rightExpected = parseFiniteNumber(right && right.assistant_expected_points_next_gameweek, 0);
    const leftExpected = parseFiniteNumber(left && left.assistant_expected_points_next_gameweek, 0);
    if (rightExpected !== leftExpected) return rightExpected - leftExpected;
    return assistantIdealProfileScore(right) - assistantIdealProfileScore(left);
  });
  const captainElementID = parseFiniteNumber(captainCandidates[0] && captainCandidates[0].element_id, 0);
  const viceCaptainElementID = parseFiniteNumber(captainCandidates[1] && captainCandidates[1].element_id, 0);
  const displayContext = buildAssistantIdealDisplayContext(teams, currentEventID);

  let nextPickPosition = 1;
  const startersByPosition = {
    1: [],
    2: [],
    3: [],
    4: [],
  };
  for (const starter of starters) {
    const built = buildAssistantIdealSquadPlayer(starter, displayContext, {
      pickPosition: nextPickPosition,
      multiplier:
        parseFiniteNumber(starter && starter.element_id, 0) === captainElementID ? 2 : 1,
      isCaptain: parseFiniteNumber(starter && starter.element_id, 0) === captainElementID,
      isViceCaptain: parseFiniteNumber(starter && starter.element_id, 0) === viceCaptainElementID,
    });
    startersByPosition[parseFiniteNumber(starter && starter.position_id, 0)] = [
      ...(startersByPosition[parseFiniteNumber(starter && starter.position_id, 0)] || []),
      built,
    ];
    nextPickPosition += 1;
  }

  const builtBench = bench.map((profile) => {
    const built = buildAssistantIdealSquadPlayer(profile, displayContext, {
      pickPosition: nextPickPosition,
      multiplier: 1,
      isCaptain: false,
      isViceCaptain: false,
    });
    nextPickPosition += 1;
    return built;
  });
  const displayedTotalPoints = Object.values(startersByPosition)
    .flat()
    .reduce((sum, player) => sum + parseFiniteNumber(player && player.applied_points, 0), 0);
  const displayedBenchPoints = builtBench.reduce(
    (sum, player) => sum + parseFiniteNumber(player && player.raw_points, 0),
    0
  );
  const unusedBudgetUnits = Math.max(0, FANTASY_ASSISTANT_MANAGER_IDEAL_SQUAD_BUDGET_UNITS - best.totalCostUnits);
  const idealReasons = [
    `Commits ${formatAssistantPrice((best.totalCostUnits - (best.benchCostUnits || 0)) / 10)} to the starting XI and keeps the bench to ${formatAssistantPrice((best.benchCostUnits || 0) / 10)}.`,
    `Formation ${best.formation} gives the strongest projected starting XI at ${roundTo(best.starterExpectedPoints, 1).toFixed(1)} points next gameweek.`,
    unusedBudgetUnits > 0
      ? `Leaves ${formatAssistantPrice(unusedBudgetUnits / 10)} unused because no legal upgrade improved the XI within budget and club-limit constraints.`
      : "Uses the full budget while keeping the squad legal under club and formation rules.",
  ];

  return {
    title: "If I had my way...",
    summary:
      "A full 15-man squad picked under standard Fantasy rules, with a cost-cutting bench to leave as much value as possible in the starting XI.",
    reasons: idealReasons,
    formation: best.formation,
    total_value_millions: roundTo(best.totalCostUnits / 10, 1),
    expected_points_next_gameweek: roundTo(best.starterExpectedPoints, 2),
    displayed_total_points: displayedTotalPoints,
    displayed_bench_points: displayedBenchPoints,
    has_active_fixtures: displayContext.hasActiveFixtures,
    has_started_fixtures_in_gameweek: displayContext.hasStartedFixturesInGameweek,
    has_fixtures_played_today: displayContext.hasFixturesPlayedToday,
    starters: {
      goalkeepers: startersByPosition[1] || [],
      defenders: startersByPosition[2] || [],
      midfielders: startersByPosition[3] || [],
      forwards: startersByPosition[4] || [],
    },
    bench: builtBench,
  };
}

function buildBestAssistantTransferPackage(
  packageSize,
  squadProfiles,
  candidateMovesByOutgoingID,
  baseClubCounts,
  currentSquadCostUnits,
  availableBudgetUnits
) {
  let bestMoves = null;
  let bestScore = Number.NEGATIVE_INFINITY;

  function search(startIndex, selectedMoves) {
    if (selectedMoves.length === packageSize) {
      const score = selectedMoves.reduce((sum, move) => sum + assistantMoveSortScore(move), 0);
      if (score > bestScore) {
        bestScore = score;
        bestMoves = [...selectedMoves];
      }
      return;
    }

    for (let index = startIndex; index < squadProfiles.length; index += 1) {
      const outgoing = squadProfiles[index];
      const moveCandidates = candidateMovesByOutgoingID.get(outgoing.element_id) || [];
      if (moveCandidates.length === 0) continue;

      for (const move of moveCandidates) {
        if (selectedMoves.some((candidate) => candidate.in_element_id === move.in_element_id)) {
          continue;
        }
        const nextMoves = [...selectedMoves, move];
        if (
          !isAssistantTransferPackageValid(
            nextMoves,
            baseClubCounts,
            currentSquadCostUnits,
            availableBudgetUnits,
            true
          )
        ) {
          continue;
        }
        search(index + 1, nextMoves);
      }
    }
  }

  search(0, []);
  return bestMoves;
}

function buildMoneyNoObjectAssistantMoves(
  squadProfiles,
  candidateMovesByOutgoingID,
  baseClubCounts,
  currentSquadCostUnits
) {
  const rankedMoves = squadProfiles
    .flatMap((profile) => candidateMovesByOutgoingID.get(profile.element_id) || [])
    .sort(compareAssistantMoves);
  const selectedMoves = [];

  for (const move of rankedMoves) {
    if (assistantMoveSortScore(move) <= 0) continue;
    if (selectedMoves.some((candidate) => candidate.out_element_id === move.out_element_id)) continue;
    if (selectedMoves.some((candidate) => candidate.in_element_id === move.in_element_id)) continue;
    const nextMoves = [...selectedMoves, move];
    if (
      !isAssistantTransferPackageValid(
        nextMoves,
        baseClubCounts,
        currentSquadCostUnits,
        Number.POSITIVE_INFINITY,
        false
      )
    ) {
      continue;
    }
    selectedMoves.push(move);
    if (selectedMoves.length >= FANTASY_ASSISTANT_MANAGER_MONEY_NO_OBJECT_LIMIT) {
      break;
    }
  }

  return selectedMoves;
}

function buildFantasyAssistantManagerPayload(entryID, picksPayload) {
  if (!cachedFantasyBootstrap) {
    throw new Error("Fantasy bootstrap-static dataset not loaded yet.");
  }

  const payload = cachedFantasyBootstrap && typeof cachedFantasyBootstrap === "object"
    ? cachedFantasyBootstrap
    : {};
  const elements = Array.isArray(payload.elements) ? payload.elements : [];
  const teams = Array.isArray(payload.teams) ? payload.teams : [];
  const elementTypes = Array.isArray(payload.element_types) ? payload.element_types : [];
  const picks = Array.isArray(picksPayload && picksPayload.picks) ? picksPayload.picks : [];

  const positionNameByID = new Map(
    elementTypes
      .map((item) => [
        parseFiniteNumber(item && item.id, 0),
        String((item && item.singular_name) || "").trim() || "Player",
      ])
      .filter(([id]) => id > 0)
  );
  const teamContext = teamStrengthContext(teams);
  const currentEventID = parseFiniteNumber(fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id, 0);
  const nextEventID = parseFiniteNumber(fantasyBootstrapNextEvent && fantasyBootstrapNextEvent.id, 0);
  const baselineEvent = nextEventID > 0 ? nextEventID : Math.max(1, currentEventID);
  const upcomingFixturesByTeam = buildUpcomingFixturesByTeam(
    cachedFantasyFixtures,
    teamContext,
    baselineEvent
  );
  const playerProfiles = elements
    .filter((item) => parseFiniteNumber(item && item.id, 0) > 0)
    .map((item) =>
      buildAssistantManagerPlayerProfile(
        item,
        teamContext,
        positionNameByID,
        upcomingFixturesByTeam,
        baselineEvent
      )
    );
  const profilesByElementID = new Map(playerProfiles.map((item) => [item.element_id, item]));
  const squadProfiles = picks
    .map((pick) => {
      const elementID = parseFiniteNumber(pick && pick.element, 0);
      const profile = profilesByElementID.get(elementID) || null;
      if (!profile) return null;
      const sellingPriceUnits = parseFiniteNumber(pick && pick.selling_price, 0);
      if (sellingPriceUnits > 0) {
        return {
          ...profile,
          assistant_cost_units: sellingPriceUnits,
        };
      }
      return profile;
    })
    .filter(Boolean);

  if (squadProfiles.length === 0) {
    throw new Error("Could not map any squad players to the fantasy bootstrap cache.");
  }

  const squadElementIDs = new Set(squadProfiles.map((profile) => profile.element_id));
  const currentSquadCostUnits = squadProfiles.reduce(
    (sum, profile) => sum + parseFiniteNumber(profile && profile.assistant_cost_units, 0),
    0
  );
  const currentTeamValueUnits = Math.max(
    0,
    parseFiniteNumber(
      picksPayload &&
        picksPayload.entry_history &&
        picksPayload.entry_history.value,
      currentSquadCostUnits
    )
  );
  const bankUnits = Math.max(
    0,
    parseFiniteNumber(
      picksPayload &&
        picksPayload.entry_history &&
        picksPayload.entry_history.bank,
      0
    )
  );
  const availableBudgetUnits = Math.max(currentSquadCostUnits, currentTeamValueUnits);
  const baseClubCounts = squadProfiles.reduce((counts, profile) => {
    const teamID = parseFiniteNumber(profile && profile.team_id, 0);
    if (teamID > 0) {
      counts.set(teamID, (counts.get(teamID) || 0) + 1);
    }
    return counts;
  }, new Map());
  const profilesByPositionID = playerProfiles.reduce((map, profile) => {
    const positionID = parseFiniteNumber(profile && profile.position_id, 0);
    if (positionID <= 0) return map;
    map.set(positionID, [...(map.get(positionID) || []), profile]);
    return map;
  }, new Map());
  const candidateMovesByOutgoingID = new Map();

  squadProfiles.forEach((outgoingProfile) => {
    const positionID = parseFiniteNumber(outgoingProfile && outgoingProfile.position_id, 0);
    const allCandidates = (profilesByPositionID.get(positionID) || [])
      .filter((incomingProfile) => !squadElementIDs.has(incomingProfile.element_id))
      .map((incomingProfile) => buildAssistantTransferMove(outgoingProfile, incomingProfile))
      .sort(compareAssistantMoves);
    const candidates = allCandidates
      .filter((move) =>
        isAssistantTransferPackageValid(
          [move],
          baseClubCounts,
          currentSquadCostUnits,
          availableBudgetUnits,
          true
        )
      )
      .slice(0, FANTASY_ASSISTANT_MANAGER_CANDIDATE_LIMIT);
    candidateMovesByOutgoingID.set(outgoingProfile.element_id, candidates);
  });

  const bestTripleMoves = buildBestAssistantTransferPackage(
    3,
    squadProfiles,
    candidateMovesByOutgoingID,
    baseClubCounts,
    currentSquadCostUnits,
    availableBudgetUnits
  );
  const idealSquad = buildAssistantIdealSquad(playerProfiles, teams, currentEventID);
  const expectedPointsPlayers = picks
    .map((pick) => {
      const profile = profilesByElementID.get(parseFiniteNumber(pick && pick.element, 0)) || null;
      if (!profile) return null;
      return buildAssistantExpectedPointsPlayer(profile, pick);
    })
    .filter(Boolean)
    .sort((left, right) => {
      const leftPosition = parseFiniteNumber(left && left.pick_position, 0);
      const rightPosition = parseFiniteNumber(right && right.pick_position, 0);
      return leftPosition - rightPosition;
    });
  const expectedPointsSection = {
    starters: expectedPointsPlayers.filter((player) => Boolean(player && player.is_starter)),
    bench: expectedPointsPlayers.filter((player) => player && !player.is_starter),
  };

  const captainCandidates = [...squadProfiles]
    .sort((left, right) => {
      if (
        parseFiniteNumber(right && right.assistant_expected_points_next_gameweek, 0) !==
        parseFiniteNumber(left && left.assistant_expected_points_next_gameweek, 0)
      ) {
        return (
          parseFiniteNumber(right && right.assistant_expected_points_next_gameweek, 0) -
          parseFiniteNumber(left && left.assistant_expected_points_next_gameweek, 0)
        );
      }
      return (
        parseFiniteNumber(right && right.assistant_rank_score, 0) -
        parseFiniteNumber(left && left.assistant_rank_score, 0)
      );
    })
    .map(buildAssistantCaptainCandidate);
  const primaryCaptainElementID =
    captainCandidates.length > 0 ? parseFiniteNumber(captainCandidates[0].element_id, 0) : 0;

  return {
    entry_id: entryID,
    current_event_id: currentEventID,
    current_event_name:
      String((fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.name) || "").trim() ||
      `Gameweek ${currentEventID}`,
    generated_at: fantasyAssistantNowIso(),
    algorithm_summary:
      "Transfer plans balance next-gameweek upside, three-gameweek planning, blank gameweeks, availability, affordability, and the three-per-club rule.",
    squad_summary: {
      players_count: squadProfiles.length,
      current_squad_value_millions: roundTo(currentSquadCostUnits / 10, 1),
      reported_team_value_millions: roundTo(currentSquadCostUnits / 10, 1),
      bank_millions: roundTo(bankUnits / 10, 1),
      effective_budget_millions: roundTo(availableBudgetUnits / 10, 1),
      team_value_cap_millions: 100.0,
      transfer_options_considered: Array.from(candidateMovesByOutgoingID.values()).reduce(
        (sum, moves) => sum + moves.length,
        0
      ),
    },
    top_triple_transfers: buildAssistantTransferPlan(
      "Top triple transfers",
      "Best three-player reshuffle while still respecting the team value cap and club limits.",
      bestTripleMoves,
      true,
      currentSquadCostUnits,
      availableBudgetUnits
    ),
    ideal_squad: idealSquad,
    captain_recommendations: {
      summary:
        "Captaincy is ranked on next-game expected points first, with availability and overall assistant score only used to split ties.",
      captain: captainCandidates.slice(0, 3),
    },
    expected_points: expectedPointsSection,
  };
}

function buildFantasyAssistantManagerResponse(entryID) {
  const state = ensureFantasyAssistantEntryState(entryID);
  const dataSignature = fantasyAssistantDataSignature();
  const stale =
    !state.payload ||
    state.dataSignature !== dataSignature ||
    !state.lastRefreshCompletedAt ||
    Date.now() - Date.parse(state.lastRefreshCompletedAt) > FANTASY_ASSISTANT_MANAGER_STALE_AFTER_MS;
  const refreshInFlight = fantasyAssistantManagerRefreshTasks.has(entryID);

  if (!state.payload) {
    return {
      entry_id: entryID,
      ready: false,
      stale: true,
      source: refreshInFlight ? "warming" : "missing",
      generated_at: null,
      algorithm_summary:
        "Transfer plans balance next-gameweek upside, three-gameweek planning, blank gameweeks, availability, affordability, and the three-per-club rule.",
      squad_summary: null,
      top_single_transfer: null,
      top_double_transfers: null,
      top_triple_transfers: null,
      money_no_object_transfers: null,
      ideal_squad: null,
      captain_recommendations: null,
      sync_status: {
        state: refreshInFlight ? "refreshing" : (state.lastError ? "error" : "warming"),
        last_seen_at: state.lastSeenAt,
        last_refresh_started_at: state.lastRefreshStartedAt,
        last_refresh_completed_at: state.lastRefreshCompletedAt,
        last_refresh_trigger: state.lastRefreshTrigger,
        last_error: state.lastError,
      },
    };
  }

  return {
    ...state.payload,
    ready: true,
    stale,
    source: "memory_cache",
    sync_status: {
      state: refreshInFlight ? "refreshing" : "ready",
      last_seen_at: state.lastSeenAt,
      last_refresh_started_at: state.lastRefreshStartedAt,
      last_refresh_completed_at: state.lastRefreshCompletedAt,
      last_refresh_trigger: state.lastRefreshTrigger,
      last_error: state.lastError,
    },
  };
}

async function refreshFantasyAssistantManagerEntry(entryID, options = {}) {
  if (fantasyAssistantManagerRefreshTasks.has(entryID)) {
    return fantasyAssistantManagerRefreshTasks.get(entryID);
  }

  const task = (async () => {
    const state = touchFantasyAssistantEntry(entryID);
    const trigger = options && options.trigger ? String(options.trigger) : "manual";
    state.lastRefreshTrigger = trigger;
    state.lastRefreshStartedAt = fantasyAssistantNowIso();

    if (!cachedFantasyBootstrap) {
      throw new Error("Fantasy bootstrap-static dataset not loaded yet.");
    }
    if (!fantasyBootstrapCurrentEvent) {
      throw new Error("No current gameweek found in the fantasy bootstrap cache.");
    }

    try {
      const eventID = parseFiniteNumber(fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id, 0);
      const picksPayload = await fetchFantasyEntryPicksPayload(entryID, eventID);
      const picks = Array.isArray(picksPayload && picksPayload.picks) ? picksPayload.picks : [];
      const picksSignature = [
        eventID,
        parseFiniteNumber(
          picksPayload && picksPayload.entry_history && picksPayload.entry_history.value,
          0
        ),
        parseFiniteNumber(
          picksPayload && picksPayload.entry_history && picksPayload.entry_history.bank,
          0
        ),
        picks.map((pick) => parseFiniteNumber(pick && pick.element, 0)).join(","),
      ].join("|");
      const dataSignature = fantasyAssistantDataSignature();
      const cacheFresh =
        state.payload &&
        state.picksSignature === picksSignature &&
        state.dataSignature === dataSignature &&
        state.lastRefreshCompletedAt &&
        Date.now() - Date.parse(state.lastRefreshCompletedAt) <= FANTASY_ASSISTANT_MANAGER_STALE_AFTER_MS;

      if (cacheFresh && !(options && options.force === true)) {
        state.lastRefreshCompletedAt = fantasyAssistantNowIso();
        state.lastError = null;
        return state.payload;
      }

      state.payload = buildFantasyAssistantManagerPayload(entryID, picksPayload);
      state.picksSignature = picksSignature;
      state.dataSignature = dataSignature;
      state.lastRefreshCompletedAt = fantasyAssistantNowIso();
      state.lastError = null;
      return state.payload;
    } catch (error) {
      state.lastRefreshCompletedAt = fantasyAssistantNowIso();
      state.lastError = error && error.message ? error.message : String(error);
      throw error;
    }
  })();

  fantasyAssistantManagerRefreshTasks.set(entryID, task);
  try {
    return await task;
  } finally {
    fantasyAssistantManagerRefreshTasks.delete(entryID);
  }
}

function pollFantasyAssistantManagerEntries() {
  const nowMs = Date.now();

  fantasyAssistantManagerEntries.forEach((state, entryID) => {
    const lastSeenAtMs = Date.parse(state && state.lastSeenAt);
    if (
      !Number.isFinite(lastSeenAtMs) ||
      nowMs - lastSeenAtMs > FANTASY_ASSISTANT_MANAGER_ACTIVE_WATCH_WINDOW_MS
    ) {
      fantasyAssistantManagerEntries.delete(entryID);
      fantasyAssistantManagerRefreshTasks.delete(entryID);
      return;
    }
    if (fantasyAssistantManagerRefreshTasks.has(entryID)) return;

    const lastRefreshCompletedAtMs = Date.parse(state && state.lastRefreshCompletedAt);
    if (
      Number.isFinite(lastRefreshCompletedAtMs) &&
      nowMs - lastRefreshCompletedAtMs < FANTASY_ASSISTANT_MANAGER_POLL_INTERVAL_MS
    ) {
      return;
    }

    void refreshFantasyAssistantManagerEntry(entryID, { trigger: "interval" }).catch((error) => {
      console.warn(
        `[FantasyAssistantManager] refresh failed entry_id=${entryID}:`,
        error && error.message ? error.message : error
      );
    });
  });
}

function buildPrometheusMetricsText() {
  const lines = [];
  const nowMs = Date.now();
  const cpuUsage = process.cpuUsage(PROCESS_CPU_USAGE_START);
  const cpuUserSeconds = cpuUsage.user / 1_000_000;
  const cpuSystemSeconds = cpuUsage.system / 1_000_000;
  const cpuUsageSinceLastSample = process.cpuUsage(processCpuUsageSample.usage);
  const cpuSampleElapsedMs = Math.max(1, nowMs - processCpuUsageSample.capturedAtMs);
  const processCpuUsageRatio =
    (cpuUsageSinceLastSample.user + cpuUsageSinceLastSample.system) / (cpuSampleElapsedMs * 1_000);
  processCpuUsageSample = {
    capturedAtMs: nowMs,
    usage: process.cpuUsage(),
  };
  const memoryUsage = process.memoryUsage();
  const heapStats = v8.getHeapStatistics();
  const heapSpaceStats = v8.getHeapSpaceStatistics();
  const currentEventLoopUtilization = performance.eventLoopUtilization();
  const eventLoopUtilizationDelta = performance.eventLoopUtilization(
    eventLoopUtilizationSample,
    currentEventLoopUtilization
  );
  eventLoopUtilizationSample = currentEventLoopUtilization;

  const normalizeLagSeconds = (valueNs) => {
    if (!Number.isFinite(valueNs) || valueNs < 0 || valueNs > 1e16) return 0;
    return valueNs / 1_000_000_000;
  };
  const eventLoopLagSeconds = normalizeLagSeconds(eventLoopDelayMonitor.mean);
  const eventLoopLagMinSeconds = normalizeLagSeconds(eventLoopDelayMonitor.min);
  const eventLoopLagMaxSeconds = normalizeLagSeconds(eventLoopDelayMonitor.max);
  const eventLoopLagStdDevSeconds = normalizeLagSeconds(eventLoopDelayMonitor.stddev);
  const eventLoopLagP50Seconds = normalizeLagSeconds(eventLoopDelayMonitor.percentile(50));
  const eventLoopLagP90Seconds = normalizeLagSeconds(eventLoopDelayMonitor.percentile(90));
  const eventLoopLagP99Seconds = normalizeLagSeconds(eventLoopDelayMonitor.percentile(99));
  const eventLoopUtilizationRatio =
    eventLoopUtilizationDelta && Number.isFinite(eventLoopUtilizationDelta.utilization)
      ? Math.max(0, eventLoopUtilizationDelta.utilization)
      : 0;
  const processUptimeSeconds = Math.max(0, process.uptime());
  const heapUtilizationRatio =
    heapStats.total_heap_size > 0
      ? heapStats.used_heap_size / heapStats.total_heap_size
      : 0;
  const heapLimitUtilizationRatio =
    heapStats.heap_size_limit > 0
      ? heapStats.used_heap_size / heapStats.heap_size_limit
      : 0;

  lines.push("# HELP process_cpu_user_seconds_total Total user CPU time spent in seconds.");
  lines.push("# TYPE process_cpu_user_seconds_total counter");
  pushPrometheusSample(lines, "process_cpu_user_seconds_total", cpuUserSeconds);

  lines.push("# HELP process_cpu_system_seconds_total Total system CPU time spent in seconds.");
  lines.push("# TYPE process_cpu_system_seconds_total counter");
  pushPrometheusSample(lines, "process_cpu_system_seconds_total", cpuSystemSeconds);

  lines.push("# HELP process_cpu_seconds_total Total user and system CPU time spent in seconds.");
  lines.push("# TYPE process_cpu_seconds_total counter");
  pushPrometheusSample(lines, "process_cpu_seconds_total", cpuUserSeconds + cpuSystemSeconds);

  lines.push("# HELP process_start_time_seconds Start time of the process since unix epoch in seconds.");
  lines.push("# TYPE process_start_time_seconds gauge");
  pushPrometheusSample(lines, "process_start_time_seconds", PROCESS_START_TIME_SECONDS);

  lines.push("# HELP process_resident_memory_bytes Resident memory size in bytes.");
  lines.push("# TYPE process_resident_memory_bytes gauge");
  pushPrometheusSample(lines, "process_resident_memory_bytes", memoryUsage.rss);

  lines.push("# HELP process_virtual_memory_bytes Virtual memory size in bytes.");
  lines.push("# TYPE process_virtual_memory_bytes gauge");
  pushPrometheusSample(
    lines,
    "process_virtual_memory_bytes",
    memoryUsage.rss + memoryUsage.heapTotal + memoryUsage.external + (memoryUsage.arrayBuffers || 0)
  );

  lines.push("# HELP process_heap_bytes Process heap size in bytes.");
  lines.push("# TYPE process_heap_bytes gauge");
  pushPrometheusSample(lines, "process_heap_bytes", memoryUsage.heapTotal);

  lines.push("# HELP top_scores_runtime_info Runtime identity for the top-scores API process.");
  lines.push("# TYPE top_scores_runtime_info gauge");
  pushPrometheusSample(lines, "top_scores_runtime_info", 1, {
    service: RUNTIME_SERVICE_NAME,
    environment: RUNTIME_ENVIRONMENT,
    node_version: process.version,
    pid: String(process.pid),
  });

  lines.push("# HELP top_scores_process_uptime_seconds Current uptime of the top-scores API process.");
  lines.push("# TYPE top_scores_process_uptime_seconds gauge");
  pushPrometheusSample(lines, "top_scores_process_uptime_seconds", processUptimeSeconds);

  lines.push("# HELP top_scores_process_cpu_usage_ratio CPU usage ratio since the previous metrics scrape.");
  lines.push("# TYPE top_scores_process_cpu_usage_ratio gauge");
  pushPrometheusSample(lines, "top_scores_process_cpu_usage_ratio", processCpuUsageRatio);

  lines.push("# HELP nodejs_eventloop_lag_seconds Lag of event loop in seconds.");
  lines.push("# TYPE nodejs_eventloop_lag_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_seconds", eventLoopLagSeconds);

  lines.push("# HELP nodejs_eventloop_lag_min_seconds The minimum recorded event loop delay.");
  lines.push("# TYPE nodejs_eventloop_lag_min_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_min_seconds", eventLoopLagMinSeconds);

  lines.push("# HELP nodejs_eventloop_lag_max_seconds The maximum recorded event loop delay.");
  lines.push("# TYPE nodejs_eventloop_lag_max_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_max_seconds", eventLoopLagMaxSeconds);

  lines.push("# HELP nodejs_eventloop_lag_mean_seconds The mean of the recorded event loop delays.");
  lines.push("# TYPE nodejs_eventloop_lag_mean_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_mean_seconds", eventLoopLagSeconds);

  lines.push("# HELP nodejs_eventloop_lag_stddev_seconds The standard deviation of the recorded event loop delays.");
  lines.push("# TYPE nodejs_eventloop_lag_stddev_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_stddev_seconds", eventLoopLagStdDevSeconds);

  lines.push("# HELP nodejs_eventloop_lag_p50_seconds The 50th percentile of the recorded event loop delays.");
  lines.push("# TYPE nodejs_eventloop_lag_p50_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_p50_seconds", eventLoopLagP50Seconds);

  lines.push("# HELP nodejs_eventloop_lag_p90_seconds The 90th percentile of the recorded event loop delays.");
  lines.push("# TYPE nodejs_eventloop_lag_p90_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_p90_seconds", eventLoopLagP90Seconds);

  lines.push("# HELP nodejs_eventloop_lag_p99_seconds The 99th percentile of the recorded event loop delays.");
  lines.push("# TYPE nodejs_eventloop_lag_p99_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_p99_seconds", eventLoopLagP99Seconds);

  lines.push("# HELP nodejs_eventloop_utilization_ratio Event loop utilization since the previous metrics scrape.");
  lines.push("# TYPE nodejs_eventloop_utilization_ratio gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_utilization_ratio", eventLoopUtilizationRatio);

  const activeResourceCounts = countByType(
    typeof process.getActiveResourcesInfo === "function" ? process.getActiveResourcesInfo() : [],
    (name) => name
  );
  lines.push("# HELP nodejs_active_resources Number of active resources that are currently keeping the event loop alive, grouped by async resource type.");
  lines.push("# TYPE nodejs_active_resources gauge");
  Array.from(activeResourceCounts.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([type, count]) => {
      pushPrometheusSample(lines, "nodejs_active_resources", count, { type });
    });
  lines.push("# HELP nodejs_active_resources_total Total number of active resources.");
  lines.push("# TYPE nodejs_active_resources_total gauge");
  pushPrometheusSample(
    lines,
    "nodejs_active_resources_total",
    Array.from(activeResourceCounts.values()).reduce((sum, count) => sum + count, 0)
  );

  const activeHandleCounts = countByType(
    typeof process._getActiveHandles === "function" ? process._getActiveHandles() : [],
    (handle) => handle && handle.constructor && handle.constructor.name
  );
  lines.push("# HELP nodejs_active_handles Number of active libuv handles grouped by handle type. Every handle type is C++ class name.");
  lines.push("# TYPE nodejs_active_handles gauge");
  Array.from(activeHandleCounts.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([type, count]) => {
      pushPrometheusSample(lines, "nodejs_active_handles", count, { type });
    });
  lines.push("# HELP nodejs_active_handles_total Total number of active handles.");
  lines.push("# TYPE nodejs_active_handles_total gauge");
  pushPrometheusSample(
    lines,
    "nodejs_active_handles_total",
    Array.from(activeHandleCounts.values()).reduce((sum, count) => sum + count, 0)
  );

  const activeRequestCounts = countByType(
    typeof process._getActiveRequests === "function" ? process._getActiveRequests() : [],
    (request) => request && request.constructor && request.constructor.name
  );
  lines.push("# HELP nodejs_active_requests Number of active libuv requests grouped by request type. Every request type is C++ class name.");
  lines.push("# TYPE nodejs_active_requests gauge");
  Array.from(activeRequestCounts.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([type, count]) => {
      pushPrometheusSample(lines, "nodejs_active_requests", count, { type });
    });
  lines.push("# HELP nodejs_active_requests_total Total number of active requests.");
  lines.push("# TYPE nodejs_active_requests_total gauge");
  pushPrometheusSample(
    lines,
    "nodejs_active_requests_total",
    Array.from(activeRequestCounts.values()).reduce((sum, count) => sum + count, 0)
  );

  lines.push("# HELP nodejs_heap_size_total_bytes Process heap size from Node.js in bytes.");
  lines.push("# TYPE nodejs_heap_size_total_bytes gauge");
  pushPrometheusSample(lines, "nodejs_heap_size_total_bytes", heapStats.total_heap_size);

  lines.push("# HELP nodejs_heap_size_used_bytes Process heap size used from Node.js in bytes.");
  lines.push("# TYPE nodejs_heap_size_used_bytes gauge");
  pushPrometheusSample(lines, "nodejs_heap_size_used_bytes", heapStats.used_heap_size);

  lines.push("# HELP nodejs_heap_size_physical_bytes Process physical heap size from Node.js in bytes.");
  lines.push("# TYPE nodejs_heap_size_physical_bytes gauge");
  pushPrometheusSample(lines, "nodejs_heap_size_physical_bytes", heapStats.total_physical_size);

  lines.push("# HELP nodejs_heap_size_limit_bytes Process heap size limit from Node.js in bytes.");
  lines.push("# TYPE nodejs_heap_size_limit_bytes gauge");
  pushPrometheusSample(lines, "nodejs_heap_size_limit_bytes", heapStats.heap_size_limit);

  lines.push("# HELP nodejs_heap_size_available_bytes Available heap size from Node.js in bytes.");
  lines.push("# TYPE nodejs_heap_size_available_bytes gauge");
  pushPrometheusSample(lines, "nodejs_heap_size_available_bytes", heapStats.total_available_size);

  lines.push("# HELP nodejs_heap_utilization_ratio Ratio of used heap to total heap.");
  lines.push("# TYPE nodejs_heap_utilization_ratio gauge");
  pushPrometheusSample(lines, "nodejs_heap_utilization_ratio", heapUtilizationRatio);

  lines.push("# HELP nodejs_heap_limit_utilization_ratio Ratio of used heap to heap limit.");
  lines.push("# TYPE nodejs_heap_limit_utilization_ratio gauge");
  pushPrometheusSample(lines, "nodejs_heap_limit_utilization_ratio", heapLimitUtilizationRatio);

  lines.push("# HELP nodejs_external_memory_bytes Node.js external memory size in bytes.");
  lines.push("# TYPE nodejs_external_memory_bytes gauge");
  pushPrometheusSample(lines, "nodejs_external_memory_bytes", heapStats.external_memory);

  lines.push("# HELP nodejs_array_buffers_bytes Node.js array buffer memory size in bytes.");
  lines.push("# TYPE nodejs_array_buffers_bytes gauge");
  pushPrometheusSample(lines, "nodejs_array_buffers_bytes", memoryUsage.arrayBuffers || 0);

  lines.push("# HELP nodejs_malloced_memory_bytes Node.js malloced memory size in bytes.");
  lines.push("# TYPE nodejs_malloced_memory_bytes gauge");
  pushPrometheusSample(lines, "nodejs_malloced_memory_bytes", heapStats.malloced_memory);

  lines.push("# HELP nodejs_peak_malloced_memory_bytes Peak Node.js malloced memory size in bytes.");
  lines.push("# TYPE nodejs_peak_malloced_memory_bytes gauge");
  pushPrometheusSample(lines, "nodejs_peak_malloced_memory_bytes", heapStats.peak_malloced_memory);

  lines.push("# HELP nodejs_native_contexts_total Number of active native contexts.");
  lines.push("# TYPE nodejs_native_contexts_total gauge");
  pushPrometheusSample(lines, "nodejs_native_contexts_total", heapStats.number_of_native_contexts);

  lines.push("# HELP nodejs_detached_contexts_total Number of detached contexts.");
  lines.push("# TYPE nodejs_detached_contexts_total gauge");
  pushPrometheusSample(lines, "nodejs_detached_contexts_total", heapStats.number_of_detached_contexts);

  lines.push("# HELP nodejs_heap_space_size_total_bytes Node.js heap space size in bytes by space.");
  lines.push("# TYPE nodejs_heap_space_size_total_bytes gauge");
  heapSpaceStats.forEach((space) => {
    pushPrometheusSample(lines, "nodejs_heap_space_size_total_bytes", space.space_size, {
      space: space.space_name,
    });
  });

  lines.push("# HELP nodejs_heap_space_size_used_bytes Node.js heap space used size in bytes by space.");
  lines.push("# TYPE nodejs_heap_space_size_used_bytes gauge");
  heapSpaceStats.forEach((space) => {
    pushPrometheusSample(lines, "nodejs_heap_space_size_used_bytes", space.space_used_size, {
      space: space.space_name,
    });
  });

  lines.push("# HELP nodejs_heap_space_size_available_bytes Node.js heap space available size in bytes by space.");
  lines.push("# TYPE nodejs_heap_space_size_available_bytes gauge");
  heapSpaceStats.forEach((space) => {
    pushPrometheusSample(lines, "nodejs_heap_space_size_available_bytes", space.space_available_size, {
      space: space.space_name,
    });
  });

  lines.push("# HELP top_scores_match_details_active_refresh_targets Active match details refresh targets.");
  lines.push("# TYPE top_scores_match_details_active_refresh_targets gauge");
  pushPrometheusSample(lines, "top_scores_match_details_active_refresh_targets", matchDetailsActiveRefreshUntilById.size);

  lines.push("# HELP top_scores_match_details_backfill_tasks Active match details backfill tasks.");
  lines.push("# TYPE top_scores_match_details_backfill_tasks gauge");
  pushPrometheusSample(lines, "top_scores_match_details_backfill_tasks", matchDetailsBackfillTasks.size);

  lines.push("# HELP top_scores_match_details_warm_tasks Active match details warm tasks.");
  lines.push("# TYPE top_scores_match_details_warm_tasks gauge");
  pushPrometheusSample(lines, "top_scores_match_details_warm_tasks", matchDetailsWarmTasks.size);

  const nodeVersion = process.version.replace(/^v/, "");
  const versionParts = nodeVersion.split(".");
  lines.push("# HELP nodejs_version_info Node.js version info.");
  lines.push("# TYPE nodejs_version_info gauge");
  pushPrometheusSample(lines, "nodejs_version_info", 1, {
    version: process.version,
    major: versionParts[0] || "0",
    minor: versionParts[1] || "0",
    patch: versionParts[2] || "0",
  });

  const httpMetricEntries = Array.from(httpRequestMetrics.values()).sort((lhs, rhs) =>
    metricLabelKey(lhs.labels).localeCompare(metricLabelKey(rhs.labels))
  );
  appendHistogramMetrics(
    lines,
    "http_request_duration_seconds",
    "Duration of HTTP requests in seconds",
    HTTP_REQUEST_DURATION_BUCKETS,
    httpMetricEntries
  );
  lines.push("# HELP http_requests_total Total number of HTTP requests");
  lines.push("# TYPE http_requests_total counter");
  httpMetricEntries.forEach((entry) => {
    pushPrometheusSample(lines, "http_requests_total", entry.count, entry.labels);
  });

  const sourceMetricEntries = Array.from(sourceFetchMetrics.values()).sort((lhs, rhs) =>
    metricLabelKey(lhs.labels).localeCompare(metricLabelKey(rhs.labels))
  );
  appendHistogramMetrics(
    lines,
    "source_fetch_duration_seconds",
    "Duration of source fetch/update operations in seconds",
    SOURCE_FETCH_DURATION_BUCKETS,
    sourceMetricEntries
  );
  lines.push("# HELP source_fetches_total Total number of source fetch/update operations");
  lines.push("# TYPE source_fetches_total counter");
  sourceMetricEntries.forEach((entry) => {
    pushPrometheusSample(lines, "source_fetches_total", entry.count, entry.labels);
  });

  lines.push("# HELP source_records_fetched_total Total number of source records fetched.");
  lines.push("# TYPE source_records_fetched_total counter");
  Array.from(sourceRecordsFetchedTotalBySource.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([source, count]) => {
      pushPrometheusSample(lines, "source_records_fetched_total", count, { source });
    });

  lines.push("# HELP source_cache_size Number of records currently cached by source.");
  lines.push("# TYPE source_cache_size gauge");
  Array.from(sourceCacheSizeBySource.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([source, count]) => {
      pushPrometheusSample(lines, "source_cache_size", count, { source });
    });

  lines.push("# HELP source_last_success_timestamp_seconds Last successful source update timestamp.");
  lines.push("# TYPE source_last_success_timestamp_seconds gauge");
  Array.from(sourceLastSuccessAtSeconds.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([source, timestampSeconds]) => {
      pushPrometheusSample(lines, "source_last_success_timestamp_seconds", timestampSeconds, {
        source,
      });
    });
  const fantasyBootstrapSuccessTimestampSeconds = isoTimestampToSeconds(
    fantasyBootstrapLastSuccessAt
  );
  const fantasyBootstrapFailureTimestampSeconds = isoTimestampToSeconds(
    fantasyBootstrapLastFailureAt
  );
  const fantasyBootstrapUpdatedTimestampSeconds = isoTimestampToSeconds(
    fantasyBootstrapLastUpdated
  );
  const fantasyBootstrapGameUpdatingTimestampSeconds = isoTimestampToSeconds(
    fantasyBootstrapGameUpdatingDetectedAt
  );
  const fantasyBootstrapCurrentEventId = (() => {
    const parsed = Number(fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
  })();
  const fantasyBootstrapNextEventId = (() => {
    const parsed = Number(fantasyBootstrapNextEvent && fantasyBootstrapNextEvent.id);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
  })();
  const fantasyBootstrapAgeGaugeSeconds = fantasyBootstrapAgeSeconds();
  const fantasyBootstrapStaleGauge = isFantasyBootstrapStale() ? 1 : 0;

  lines.push(
    "# HELP fpl_bootstrap_payload_bytes Last downloaded FPL bootstrap-static payload size in bytes."
  );
  lines.push("# TYPE fpl_bootstrap_payload_bytes gauge");
  pushPrometheusSample(lines, "fpl_bootstrap_payload_bytes", fantasyBootstrapPayloadBytes);

  lines.push(
    "# HELP fpl_bootstrap_events_count Number of FPL events in the latest bootstrap-static payload."
  );
  lines.push("# TYPE fpl_bootstrap_events_count gauge");
  pushPrometheusSample(lines, "fpl_bootstrap_events_count", fantasyBootstrapEventsCount);

  lines.push(
    "# HELP fpl_bootstrap_last_updated_timestamp_seconds Last successful FPL bootstrap-static refresh timestamp."
  );
  lines.push("# TYPE fpl_bootstrap_last_updated_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "fpl_bootstrap_last_updated_timestamp_seconds",
    fantasyBootstrapUpdatedTimestampSeconds
  );

  lines.push("# HELP fpl_bootstrap_current_event_id Current FPL event ID from bootstrap-static.");
  lines.push("# TYPE fpl_bootstrap_current_event_id gauge");
  pushPrometheusSample(lines, "fpl_bootstrap_current_event_id", fantasyBootstrapCurrentEventId);

  lines.push("# HELP fpl_bootstrap_next_event_id Next FPL event ID from bootstrap-static.");
  lines.push("# TYPE fpl_bootstrap_next_event_id gauge");
  pushPrometheusSample(lines, "fpl_bootstrap_next_event_id", fantasyBootstrapNextEventId);

  lines.push(
    "# HELP fpl_bootstrap_updating Whether an FPL bootstrap-static refresh is currently running (1=true, 0=false)."
  );
  lines.push("# TYPE fpl_bootstrap_updating gauge");
  pushPrometheusSample(lines, "fpl_bootstrap_updating", fantasyBootstrapUpdating ? 1 : 0);

  lines.push(
    "# HELP fpl_bootstrap_game_updating Whether FPL currently reports 'The game is being updated' for bootstrap-static (1=true, 0=false)."
  );
  lines.push("# TYPE fpl_bootstrap_game_updating gauge");
  pushPrometheusSample(
    lines,
    "fpl_bootstrap_game_updating",
    fantasyBootstrapGameUpdating ? 1 : 0
  );

  lines.push(
    "# HELP fpl_bootstrap_game_updating_detected_timestamp_seconds Timestamp when the most recent FPL 'game updating' response was detected."
  );
  lines.push("# TYPE fpl_bootstrap_game_updating_detected_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "fpl_bootstrap_game_updating_detected_timestamp_seconds",
    fantasyBootstrapGameUpdatingTimestampSeconds
  );

  lines.push(
    "# HELP fpl_bootstrap_last_success_timestamp_seconds Last successful FPL bootstrap-static refresh timestamp."
  );
  lines.push("# TYPE fpl_bootstrap_last_success_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "fpl_bootstrap_last_success_timestamp_seconds",
    fantasyBootstrapSuccessTimestampSeconds
  );

  lines.push(
    "# HELP fpl_bootstrap_last_failure_timestamp_seconds Last failed FPL bootstrap-static refresh timestamp."
  );
  lines.push("# TYPE fpl_bootstrap_last_failure_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "fpl_bootstrap_last_failure_timestamp_seconds",
    fantasyBootstrapFailureTimestampSeconds
  );

  lines.push(
    "# HELP fpl_bootstrap_last_success_duration_seconds Duration of the most recent successful FPL bootstrap-static refresh."
  );
  lines.push("# TYPE fpl_bootstrap_last_success_duration_seconds gauge");
  pushPrometheusSample(
    lines,
    "fpl_bootstrap_last_success_duration_seconds",
    fantasyBootstrapLastSuccessDurationSeconds
  );

  lines.push(
    "# HELP fpl_bootstrap_last_failure_duration_seconds Duration of the most recent failed FPL bootstrap-static refresh."
  );
  lines.push("# TYPE fpl_bootstrap_last_failure_duration_seconds gauge");
  pushPrometheusSample(
    lines,
    "fpl_bootstrap_last_failure_duration_seconds",
    fantasyBootstrapLastFailureDurationSeconds
  );

  lines.push(
    "# HELP fpl_bootstrap_age_seconds Age of the in-memory FPL bootstrap-static cache in seconds."
  );
  lines.push("# TYPE fpl_bootstrap_age_seconds gauge");
  pushPrometheusSample(
    lines,
    "fpl_bootstrap_age_seconds",
    Number.isFinite(fantasyBootstrapAgeGaugeSeconds) ? fantasyBootstrapAgeGaugeSeconds : 0
  );

  lines.push(
    "# HELP fpl_bootstrap_stale Whether the in-memory FPL bootstrap cache is older than the configured freshness threshold (1=true, 0=false)."
  );
  lines.push("# TYPE fpl_bootstrap_stale gauge");
  pushPrometheusSample(lines, "fpl_bootstrap_stale", fantasyBootstrapStaleGauge);

  const transferRecommendationMetricEntries = Array.from(
    fantasyTransferRecommendationMetrics.values()
  );
  appendHistogramMetrics(
    lines,
    "fpl_transfer_recommendation_duration_seconds",
    "Duration of in-memory FPL transfer recommendation requests in seconds.",
    FPL_TRANSFER_RECOMMENDATION_DURATION_BUCKETS,
    transferRecommendationMetricEntries
  );
  lines.push(
    "# HELP fpl_transfer_recommendation_requests_total Total transfer recommendation requests served."
  );
  lines.push("# TYPE fpl_transfer_recommendation_requests_total counter");
  pushPrometheusSample(
    lines,
    "fpl_transfer_recommendation_requests_total",
    fantasyTransferRecommendationRequestsTotal
  );

  lines.push(
    "# HELP fpl_transfer_recommendation_failures_total Total transfer recommendation requests that failed."
  );
  lines.push("# TYPE fpl_transfer_recommendation_failures_total counter");
  pushPrometheusSample(
    lines,
    "fpl_transfer_recommendation_failures_total",
    fantasyTransferRecommendationFailuresTotal
  );

  const clubEloSuccessTimestampSeconds = isoTimestampToSeconds(clubEloLastSuccessAt);
  const clubEloFailureTimestampSeconds = isoTimestampToSeconds(clubEloLastFailureAt);
  const clubEloOldestFromTimestampSeconds = (() => {
    if (!isDateOnly(clubEloOldestFromDate)) return 0;
    const parsed = Date.parse(`${clubEloOldestFromDate}T00:00:00Z`);
    if (!Number.isFinite(parsed) || parsed <= 0) return 0;
    return Math.floor(parsed / 1000);
  })();
  const clubEloNewestFromTimestampSeconds = (() => {
    if (!isDateOnly(clubEloNewestFromDate)) return 0;
    const parsed = Date.parse(`${clubEloNewestFromDate}T00:00:00Z`);
    if (!Number.isFinite(parsed) || parsed <= 0) return 0;
    return Math.floor(parsed / 1000);
  })();
  const footballDatabaseSuccessTimestampSeconds = isoTimestampToSeconds(
    footballDatabaseLastSuccessAt
  );
  const footballDatabaseFailureTimestampSeconds = isoTimestampToSeconds(
    footballDatabaseLastFailureAt
  );
  const footballDatabaseDataTimestampSeconds = (() => {
    if (!isDateOnly(footballDatabaseDataDate)) return 0;
    const parsed = Date.parse(`${footballDatabaseDataDate}T00:00:00Z`);
    if (!Number.isFinite(parsed) || parsed <= 0) return 0;
    return Math.floor(parsed / 1000);
  })();
  const nationalEloSuccessTimestampSeconds = isoTimestampToSeconds(nationalEloLastSuccessAt);
  const nationalEloFailureTimestampSeconds = isoTimestampToSeconds(nationalEloLastFailureAt);
  const nationalEloDataTimestampSeconds = (() => {
    if (!isDateOnly(nationalEloDataDate)) return 0;
    const parsed = Date.parse(`${nationalEloDataDate}T00:00:00Z`);
    if (!Number.isFinite(parsed) || parsed <= 0) return 0;
    return Math.floor(parsed / 1000);
  })();

  lines.push("# HELP club_elo_last_success_timestamp_seconds Last successful Club Elo download+import timestamp.");
  lines.push("# TYPE club_elo_last_success_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "club_elo_last_success_timestamp_seconds",
    clubEloSuccessTimestampSeconds
  );

  lines.push("# HELP club_elo_last_failure_timestamp_seconds Last failed Club Elo download+import timestamp.");
  lines.push("# TYPE club_elo_last_failure_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "club_elo_last_failure_timestamp_seconds",
    clubEloFailureTimestampSeconds
  );

  lines.push("# HELP club_elo_oldest_from_timestamp_seconds Oldest Club Elo 'From' date in latest parsed dataset.");
  lines.push("# TYPE club_elo_oldest_from_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "club_elo_oldest_from_timestamp_seconds",
    clubEloOldestFromTimestampSeconds
  );

  lines.push("# HELP club_elo_newest_from_timestamp_seconds Newest Club Elo 'From' date in latest parsed dataset.");
  lines.push("# TYPE club_elo_newest_from_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "club_elo_newest_from_timestamp_seconds",
    clubEloNewestFromTimestampSeconds
  );

  lines.push("# HELP club_elo_latest_from_timestamp_seconds Latest Club Elo 'From' date in latest parsed dataset.");
  lines.push("# TYPE club_elo_latest_from_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "club_elo_latest_from_timestamp_seconds",
    clubEloNewestFromTimestampSeconds
  );

  lines.push("# HELP club_elo_latest_pull_team_count Number of teams in the latest parsed Club Elo pull.");
  lines.push("# TYPE club_elo_latest_pull_team_count gauge");
  pushPrometheusSample(
    lines,
    "club_elo_latest_pull_team_count",
    clubEloLatestPullTeamCount
  );

  const clubEloMetricSeries = buildClubEloMetricSeries(cachedClubEloTeams);

  lines.push("# HELP club_elo_team_ranking_score Club Elo ranking score by club.");
  lines.push("# TYPE club_elo_team_ranking_score gauge");
  clubEloMetricSeries.teamScores.forEach((teamScore) => {
    const labels = { club: teamScore.club };
    if (teamScore.country) {
      labels.country = teamScore.country;
    }
    pushPrometheusSample(lines, "club_elo_team_ranking_score", teamScore.score, labels);
  });

  lines.push("# HELP club_elo_country_average_ranking_score Average Club Elo ranking score by country.");
  lines.push("# TYPE club_elo_country_average_ranking_score gauge");
  clubEloMetricSeries.countryAverageScores.forEach((countryScore) => {
    pushPrometheusSample(
      lines,
      "club_elo_country_average_ranking_score",
      countryScore.averageScore,
      { country: countryScore.country }
    );
  });

  lines.push("# HELP club_elo_unmatched_team_count Number of teams without Club Elo ranking data after matching.");
  lines.push("# TYPE club_elo_unmatched_team_count gauge");
  pushPrometheusSample(
    lines,
    "club_elo_unmatched_team_count",
    clubEloUnmatchedTeamCount
  );

  lines.push("# HELP club_elo_last_success_duration_seconds Duration of the most recent successful Club Elo download+import.");
  lines.push("# TYPE club_elo_last_success_duration_seconds gauge");
  pushPrometheusSample(
    lines,
    "club_elo_last_success_duration_seconds",
    clubEloLastSuccessDurationSeconds
  );

  lines.push("# HELP club_elo_last_failure_duration_seconds Duration of the most recent failed Club Elo download+import.");
  lines.push("# TYPE club_elo_last_failure_duration_seconds gauge");
  pushPrometheusSample(
    lines,
    "club_elo_last_failure_duration_seconds",
    clubEloLastFailureDurationSeconds
  );

  lines.push("# HELP football_database_last_success_timestamp_seconds Last successful FootballDatabase download+import timestamp.");
  lines.push("# TYPE football_database_last_success_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "football_database_last_success_timestamp_seconds",
    footballDatabaseSuccessTimestampSeconds
  );

  lines.push("# HELP football_database_last_failure_timestamp_seconds Last failed FootballDatabase download+import timestamp.");
  lines.push("# TYPE football_database_last_failure_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "football_database_last_failure_timestamp_seconds",
    footballDatabaseFailureTimestampSeconds
  );

  lines.push("# HELP football_database_latest_data_timestamp_seconds FootballDatabase dataset date from ranking page metadata.");
  lines.push("# TYPE football_database_latest_data_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "football_database_latest_data_timestamp_seconds",
    footballDatabaseDataTimestampSeconds
  );

  lines.push("# HELP football_database_latest_pull_team_count Number of teams in the latest FootballDatabase pull.");
  lines.push("# TYPE football_database_latest_pull_team_count gauge");
  pushPrometheusSample(
    lines,
    "football_database_latest_pull_team_count",
    footballDatabaseLatestPullTeamCount
  );

  const footballDatabaseMetricSeries =
    buildFootballDatabaseMetricSeries(cachedFootballDatabaseTeams);

  lines.push("# HELP football_database_team_ranking_points FootballDatabase ranking points by club.");
  lines.push("# TYPE football_database_team_ranking_points gauge");
  footballDatabaseMetricSeries.teamScores.forEach((teamScore) => {
    const labels = { club: teamScore.club };
    if (teamScore.country) {
      labels.country = teamScore.country;
    }
    pushPrometheusSample(lines, "football_database_team_ranking_points", teamScore.score, labels);
  });

  lines.push("# HELP football_database_country_average_ranking_points Average FootballDatabase ranking points by country.");
  lines.push("# TYPE football_database_country_average_ranking_points gauge");
  footballDatabaseMetricSeries.countryAverageScores.forEach((countryScore) => {
    pushPrometheusSample(
      lines,
      "football_database_country_average_ranking_points",
      countryScore.averageScore,
      { country: countryScore.country }
    );
  });

  lines.push("# HELP football_database_unmatched_team_count Number of teams without FootballDatabase ranking data after matching.");
  lines.push("# TYPE football_database_unmatched_team_count gauge");
  pushPrometheusSample(
    lines,
    "football_database_unmatched_team_count",
    footballDatabaseUnmatchedTeamCount
  );

  lines.push("# HELP football_database_last_success_duration_seconds Duration of the most recent successful FootballDatabase download+import.");
  lines.push("# TYPE football_database_last_success_duration_seconds gauge");
  pushPrometheusSample(
    lines,
    "football_database_last_success_duration_seconds",
    footballDatabaseLastSuccessDurationSeconds
  );

  lines.push("# HELP football_database_last_failure_duration_seconds Duration of the most recent failed FootballDatabase download+import.");
  lines.push("# TYPE football_database_last_failure_duration_seconds gauge");
  pushPrometheusSample(
    lines,
    "football_database_last_failure_duration_seconds",
    footballDatabaseLastFailureDurationSeconds
  );

  lines.push("# HELP national_elo_last_success_timestamp_seconds Last successful National Elo download+import timestamp.");
  lines.push("# TYPE national_elo_last_success_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "national_elo_last_success_timestamp_seconds",
    nationalEloSuccessTimestampSeconds
  );

  lines.push("# HELP national_elo_last_failure_timestamp_seconds Last failed National Elo download+import timestamp.");
  lines.push("# TYPE national_elo_last_failure_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "national_elo_last_failure_timestamp_seconds",
    nationalEloFailureTimestampSeconds
  );

  lines.push("# HELP national_elo_latest_data_timestamp_seconds National Elo dataset timestamp from rankings source.");
  lines.push("# TYPE national_elo_latest_data_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "national_elo_latest_data_timestamp_seconds",
    nationalEloDataTimestampSeconds
  );

  lines.push("# HELP national_elo_latest_pull_team_count Number of teams in the latest National Elo pull.");
  lines.push("# TYPE national_elo_latest_pull_team_count gauge");
  pushPrometheusSample(
    lines,
    "national_elo_latest_pull_team_count",
    nationalEloLatestPullTeamCount
  );

  const nationalEloMetricSeries = buildNationalEloMetricSeries(cachedNationalEloTeams);

  lines.push("# HELP national_elo_team_ranking_score National Elo rating by national team.");
  lines.push("# TYPE national_elo_team_ranking_score gauge");
  nationalEloMetricSeries.teamScores.forEach((teamScore) => {
    const labels = { team: teamScore.team };
    if (teamScore.country) {
      labels.country = teamScore.country;
    }
    pushPrometheusSample(lines, "national_elo_team_ranking_score", teamScore.score, labels);
  });

  lines.push("# HELP national_elo_unmatched_team_count Number of likely national teams without National Elo ranking data after matching.");
  lines.push("# TYPE national_elo_unmatched_team_count gauge");
  pushPrometheusSample(
    lines,
    "national_elo_unmatched_team_count",
    nationalEloUnmatchedTeamCount
  );

  lines.push("# HELP national_elo_last_success_duration_seconds Duration of the most recent successful National Elo download+import.");
  lines.push("# TYPE national_elo_last_success_duration_seconds gauge");
  pushPrometheusSample(
    lines,
    "national_elo_last_success_duration_seconds",
    nationalEloLastSuccessDurationSeconds
  );

  lines.push("# HELP national_elo_last_failure_duration_seconds Duration of the most recent failed National Elo download+import.");
  lines.push("# TYPE national_elo_last_failure_duration_seconds gauge");
  pushPrometheusSample(
    lines,
    "national_elo_last_failure_duration_seconds",
    nationalEloLastFailureDurationSeconds
  );

  lines.push("# HELP top_scores_api_requests_total Total API requests.");
  lines.push("# TYPE top_scores_api_requests_total counter");
  pushPrometheusSample(lines, "top_scores_api_requests_total", appUsageMetrics.apiRequestsTotal);

  lines.push("# HELP top_scores_api_requests_with_device_token_total API requests with X-Device-Token.");
  lines.push("# TYPE top_scores_api_requests_with_device_token_total counter");
  pushPrometheusSample(
    lines,
    "top_scores_api_requests_with_device_token_total",
    appUsageMetrics.apiRequestsWithDeviceTokenTotal
  );

  lines.push("# HELP top_scores_api_requests_without_device_token_total API requests without X-Device-Token.");
  lines.push("# TYPE top_scores_api_requests_without_device_token_total counter");
  pushPrometheusSample(
    lines,
    "top_scores_api_requests_without_device_token_total",
    appUsageMetrics.apiRequestsWithoutDeviceTokenTotal
  );

  lines.push("# HELP top_scores_app_metrics_events_total App metrics events accepted by /api/v1/app-metrics.");
  lines.push("# TYPE top_scores_app_metrics_events_total counter");
  pushPrometheusSample(
    lines,
    "top_scores_app_metrics_events_total",
    appUsageMetrics.appMetricEventsTotal
  );

  lines.push("# HELP top_scores_app_metrics_events_rejected_total App metrics events rejected by /api/v1/app-metrics.");
  lines.push("# TYPE top_scores_app_metrics_events_rejected_total counter");
  pushPrometheusSample(
    lines,
    "top_scores_app_metrics_events_rejected_total",
    appUsageMetrics.appMetricEventsRejectedTotal
  );

  lines.push("# HELP top_scores_app_metrics_unique_devices_total Unique devices observed.");
  lines.push("# TYPE top_scores_app_metrics_unique_devices_total gauge");
  pushPrometheusSample(lines, "top_scores_app_metrics_unique_devices_total", seenDeviceTokens.size);

  lines.push("# HELP top_scores_app_metrics_active_devices_total Active devices seen recently.");
  lines.push("# TYPE top_scores_app_metrics_active_devices_total gauge");
  pushPrometheusSample(lines, "top_scores_app_metrics_active_devices_total", activeDeviceCount());

  lines.push("# HELP top_scores_app_metrics_active_window_seconds Active-device lookback window.");
  lines.push("# TYPE top_scores_app_metrics_active_window_seconds gauge");
  pushPrometheusSample(
    lines,
    "top_scores_app_metrics_active_window_seconds",
    Math.floor(APP_METRICS_ACTIVE_DEVICE_WINDOW_MS / 1000)
  );

  lines.push("# HELP top_scores_app_metrics_events_by_device_total App metric events by normalized app dimensions.");
  lines.push("# TYPE top_scores_app_metrics_events_by_device_total counter");
  lines.push("# HELP app_actions_total Total number of app actions recorded");
  lines.push("# TYPE app_actions_total counter");
  Array.from(appMetricEventsByDimension.values())
    .sort((lhs, rhs) => appMetricEventKey(lhs.labels).localeCompare(appMetricEventKey(rhs.labels)))
    .forEach((entry) => {
      pushPrometheusSample(
        lines,
        "top_scores_app_metrics_events_by_device_total",
        entry.count,
        entry.labels
      );
      pushPrometheusSample(lines, "app_actions_total", entry.count, {
        action: entry.labels.event,
        screen: entry.labels.screen || "unknown",
        build_type: entry.labels.build_type || "unknown",
        platform: entry.labels.platform,
      });
    });

  liveActivityMetrics.appendPrometheusMetrics(lines, pushPrometheusSample);

  const redisSyncSnapshot = currentRedisReconciliationSnapshot();
  const redisSyncGeneratedAtSeconds = isoTimestampToSeconds(redisSyncSnapshot.generated_at);
  const redisSyncStartedAtSeconds = isoTimestampToSeconds(redisSyncSnapshot.last_run_started_at);
  const redisSyncCompletedAtSeconds = isoTimestampToSeconds(
    redisSyncSnapshot.last_run_completed_at
  );
  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_generated_timestamp_seconds Timestamp of the latest stored Redis reconciliation snapshot."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_generated_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "top_scores_operational_redis_reconciliation_generated_timestamp_seconds",
    redisSyncGeneratedAtSeconds
  );

  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_started_timestamp_seconds Timestamp when the latest Redis reconciliation run started."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_started_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "top_scores_operational_redis_reconciliation_started_timestamp_seconds",
    redisSyncStartedAtSeconds
  );

  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_completed_timestamp_seconds Timestamp when the latest Redis reconciliation run completed."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_completed_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "top_scores_operational_redis_reconciliation_completed_timestamp_seconds",
    redisSyncCompletedAtSeconds
  );

  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_duration_seconds Duration of the latest Redis reconciliation run."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_duration_seconds gauge");
  pushPrometheusSample(
    lines,
    "top_scores_operational_redis_reconciliation_duration_seconds",
    (redisSyncSnapshot.last_duration_ms || 0) / 1000
  );

  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_running Whether a Redis reconciliation run is currently executing (1=true, 0=false)."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_running gauge");
  pushPrometheusSample(
    lines,
    "top_scores_operational_redis_reconciliation_running",
    redisSyncSnapshot.running ? 1 : 0
  );

  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_healthy Whether the latest Redis reconciliation snapshot is fully healthy (1=true, 0=false)."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_healthy gauge");
  pushPrometheusSample(
    lines,
    "top_scores_operational_redis_reconciliation_healthy",
    redisSyncSnapshot.healthy ? 1 : 0
  );

  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_components_total Component counts from the latest Redis reconciliation snapshot."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_components_total gauge");
  pushPrometheusSample(
    lines,
    "top_scores_operational_redis_reconciliation_components_total",
    Number(redisSyncSnapshot.summary && redisSyncSnapshot.summary.total_components) || 0,
    { status: "total" }
  );
  pushPrometheusSample(
    lines,
    "top_scores_operational_redis_reconciliation_components_total",
    Number(redisSyncSnapshot.summary && redisSyncSnapshot.summary.healthy_components) || 0,
    { status: "healthy" }
  );
  pushPrometheusSample(
    lines,
    "top_scores_operational_redis_reconciliation_components_total",
    Number(redisSyncSnapshot.summary && redisSyncSnapshot.summary.unhealthy_components) || 0,
    { status: "unhealthy" }
  );
  pushPrometheusSample(
    lines,
    "top_scores_operational_redis_reconciliation_components_total",
    Number(redisSyncSnapshot.summary && redisSyncSnapshot.summary.repaired_components) || 0,
    { status: "repaired" }
  );

  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_component_status_code Status code for each operational component."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_component_status_code gauge");
  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_component_in_sync Whether the component is currently in sync (1=true, 0=false)."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_component_in_sync gauge");
  lines.push(
    "# HELP top_scores_operational_memory_age_seconds Age of the in-memory operational component snapshot in seconds."
  );
  lines.push("# TYPE top_scores_operational_memory_age_seconds gauge");
  lines.push(
    "# HELP top_scores_operational_redis_age_seconds Age of the Redis operational component snapshot in seconds."
  );
  lines.push("# TYPE top_scores_operational_redis_age_seconds gauge");
  lines.push(
    "# HELP top_scores_operational_memory_updated_timestamp_seconds Last updated timestamp of the in-memory operational component snapshot."
  );
  lines.push("# TYPE top_scores_operational_memory_updated_timestamp_seconds gauge");
  lines.push(
    "# HELP top_scores_operational_redis_updated_timestamp_seconds Last updated timestamp of the Redis operational component snapshot."
  );
  lines.push("# TYPE top_scores_operational_redis_updated_timestamp_seconds gauge");
  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_updated_at_delta_seconds Signed delta between memory and Redis updated_at timestamps."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_updated_at_delta_seconds gauge");
  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_count_delta Signed delta between memory and Redis record counts."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_count_delta gauge");
  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_diff_total Sampled diff totals from the latest reconciliation snapshot."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_diff_total gauge");
  lines.push(
    "# HELP top_scores_operational_redis_reconciliation_component_duration_seconds Time spent comparing and optionally repairing each component."
  );
  lines.push("# TYPE top_scores_operational_redis_reconciliation_component_duration_seconds gauge");

  (Array.isArray(redisSyncSnapshot.components) ? redisSyncSnapshot.components : []).forEach((component) => {
    const componentLabel = { component: component.name || "unknown" };
    pushPrometheusSample(
      lines,
      "top_scores_operational_redis_reconciliation_component_status_code",
      redisReconciliationStatusCode(component.status),
      componentLabel
    );
    pushPrometheusSample(
      lines,
      "top_scores_operational_redis_reconciliation_component_in_sync",
      component.status === "in_sync" ? 1 : 0,
      componentLabel
    );
    pushPrometheusSample(
      lines,
      "top_scores_operational_memory_age_seconds",
      Number.isFinite(component.memory && component.memory.age_seconds)
        ? component.memory.age_seconds
        : 0,
      componentLabel
    );
    pushPrometheusSample(
      lines,
      "top_scores_operational_redis_age_seconds",
      Number.isFinite(component.redis && component.redis.age_seconds)
        ? component.redis.age_seconds
        : 0,
      componentLabel
    );
    pushPrometheusSample(
      lines,
      "top_scores_operational_memory_updated_timestamp_seconds",
      isoTimestampToSeconds(component.memory && component.memory.updated_at),
      componentLabel
    );
    pushPrometheusSample(
      lines,
      "top_scores_operational_redis_updated_timestamp_seconds",
      isoTimestampToSeconds(component.redis && component.redis.updated_at),
      componentLabel
    );
    pushPrometheusSample(
      lines,
      "top_scores_operational_redis_reconciliation_updated_at_delta_seconds",
      Number.isFinite(component.updated_at_delta_seconds) ? component.updated_at_delta_seconds : 0,
      componentLabel
    );
    pushPrometheusSample(
      lines,
      "top_scores_operational_redis_reconciliation_count_delta",
      Number.isFinite(component.count_delta) ? component.count_delta : 0,
      componentLabel
    );
    pushPrometheusSample(
      lines,
      "top_scores_operational_redis_reconciliation_component_duration_seconds",
      Number(
        (
          ((component.timings && component.timings.total_ms) || 0) / 1000
        ).toFixed(6)
      ),
      componentLabel
    );
    const diffSummary =
      component.diff && component.diff.summary && typeof component.diff.summary === "object"
        ? component.diff.summary
        : {};
    Object.entries(diffSummary).forEach(([kind, count]) => {
      pushPrometheusSample(
        lines,
        "top_scores_operational_redis_reconciliation_diff_total",
        Number(count) || 0,
        {
          component: component.name || "unknown",
          kind,
        }
      );
    });
  });

  if (appMetricEventsLastUpdated) {
    const timestampSeconds = Math.floor(Date.parse(appMetricEventsLastUpdated) / 1000);
    if (Number.isFinite(timestampSeconds) && timestampSeconds > 0) {
      lines.push("# HELP top_scores_app_metrics_last_updated_timestamp_seconds Last accepted app metrics timestamp.");
      lines.push("# TYPE top_scores_app_metrics_last_updated_timestamp_seconds gauge");
      pushPrometheusSample(
        lines,
        "top_scores_app_metrics_last_updated_timestamp_seconds",
        timestampSeconds
      );
    }
  }

  lines.push("# HELP unique_users Number of unique users (by device token) over time periods");
  lines.push("# TYPE unique_users gauge");
  UNIQUE_USER_WINDOWS.forEach(({ period, windowMs }) => {
    pushPrometheusSample(lines, "unique_users", activeUsersWithinWindow(windowMs, nowMs), {
      period,
    });
  });
  pushPrometheusSample(lines, "unique_users", seenDeviceTokens.size, { period: "all" });

  return `${lines.join("\n")}\n`;
}

function normalizeMissingTeamLogoName(value) {
  return String(value || "")
    .trim()
    .replace(/\s+/g, " ");
}

function missingTeamLogoKey(value) {
  return normalizeMissingTeamLogoName(value).toLowerCase();
}

function sortedMissingTeamLogoNames() {
  return Array.from(missingTeamLogosByKey.values()).sort(compareInsensitive);
}

function missingTeamLogoNamesFromPayload(payload) {
  if (Array.isArray(payload)) return payload;
  if (payload && typeof payload === "object" && Array.isArray(payload.team_names)) {
    return payload.team_names;
  }
  return null;
}

function ingestMissingTeamLogoNames(teamNames) {
  pruneResolvableMissingTeamLogos();

  let acceptedCount = 0;
  let addedCount = 0;
  const added = [];
  const seenInRequest = new Set();

  (Array.isArray(teamNames) ? teamNames : []).forEach((rawTeamName) => {
    if (typeof rawTeamName !== "string") return;
    const normalized = normalizeMissingTeamLogoName(rawTeamName);
    if (!normalized) return;
    const key = missingTeamLogoKey(normalized);
    if (!key || seenInRequest.has(key)) return;
    seenInRequest.add(key);
    acceptedCount += 1;
    if (resolveKnownTeamLogoAsset(normalized)) return;
    if (missingTeamLogosByKey.has(key)) return;
    missingTeamLogosByKey.set(key, normalized);
    added.push(normalized);
    addedCount += 1;
  });

  if (addedCount > 0) {
    missingTeamLogosLastUpdated = new Date().toISOString();
    const names = sortedMissingTeamLogoNames();
    writeMissingTeamLogos(MISSING_TEAM_LOGOS_OUTPUT_PATH, names);
    void persistOperationalDatasetSafe(OP_DATASET_MISSING_TEAM_LOGOS, names, {
      updated_at: missingTeamLogosLastUpdated,
      source: "missing_team_logos_ingest",
    });
  }

  return {
    acceptedCount,
    addedCount,
    added,
    totalCount: missingTeamLogosByKey.size,
  };
}

function removeMissingTeamLogoNames(teamNames) {
  let acceptedCount = 0;
  let removedCount = 0;
  const removed = [];
  const seenInRequest = new Set();

  (Array.isArray(teamNames) ? teamNames : []).forEach((rawTeamName) => {
    if (typeof rawTeamName !== "string") return;
    const normalized = normalizeMissingTeamLogoName(rawTeamName);
    if (!normalized) return;
    const key = missingTeamLogoKey(normalized);
    if (!key || seenInRequest.has(key)) return;
    seenInRequest.add(key);
    acceptedCount += 1;
    if (!missingTeamLogosByKey.has(key)) return;
    removed.push(missingTeamLogosByKey.get(key));
    missingTeamLogosByKey.delete(key);
    removedCount += 1;
  });

  if (removedCount > 0) {
    missingTeamLogosLastUpdated = new Date().toISOString();
    const names = sortedMissingTeamLogoNames();
    writeMissingTeamLogos(MISSING_TEAM_LOGOS_OUTPUT_PATH, names);
    void persistOperationalDatasetSafe(OP_DATASET_MISSING_TEAM_LOGOS, names, {
      updated_at: missingTeamLogosLastUpdated,
      source: "missing_team_logos_remove",
    });
  }

  return {
    acceptedCount,
    removedCount,
    removed,
    totalCount: missingTeamLogosByKey.size,
  };
}

function clearMissingTeamLogos() {
  const removed = sortedMissingTeamLogoNames();
  const removedCount = removed.length;
  missingTeamLogosByKey = new Map();
  missingTeamLogosLastUpdated = new Date().toISOString();
  writeMissingTeamLogos(MISSING_TEAM_LOGOS_OUTPUT_PATH, []);
  void persistOperationalDatasetSafe(OP_DATASET_MISSING_TEAM_LOGOS, [], {
    updated_at: missingTeamLogosLastUpdated,
    source: "missing_team_logos_clear",
  });

  return {
    removedCount,
    removed,
    totalCount: 0,
  };
}

async function mapWithConcurrency(items, concurrency, worker) {
  if (!Array.isArray(items) || items.length === 0) return;
  const limit = Math.max(1, Number(concurrency) || 1);
  let cursor = 0;

  async function runWorker() {
    while (cursor < items.length) {
      const idx = cursor;
      cursor += 1;
      // eslint-disable-next-line no-await-in-loop
      await worker(items[idx], idx);
    }
  }

  const workers = [];
  const workerCount = Math.min(limit, items.length);
  for (let i = 0; i < workerCount; i += 1) {
    workers.push(runWorker());
  }
  await Promise.all(workers);
}

const CHANNEL_SPECIAL_OPTIONS = [
  "Amazon (all)",
  "BBC (all)",
  "ITV (all)",
  "Sky (all)",
  "TNT (all)",
];
const CHANNEL_SPECIAL_KEYWORDS = new Map([
  ["Amazon (all)", "amazon"],
  ["BBC (all)", "bbc"],
  ["ITV (all)", "itv"],
  ["Sky (all)", "sky"],
  ["TNT (all)", "tnt"],
]);

function normalizedChannelTokens(value) {
  return String(value || "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .split(/[^a-z0-9]+/i)
    .map((token) => token.trim())
    .filter(Boolean);
}

function specialChannelNameForSelection(selection) {
  const trimmed = String(selection || "")
    .trim()
    .toLowerCase();
  if (!trimmed) return null;

  for (const option of CHANNEL_SPECIAL_OPTIONS) {
    const canonical = option.toLowerCase();
    const base = option.replace(/\s*\(all\)\s*$/i, "").toLowerCase();
    if (trimmed === canonical || trimmed === base) {
      return option;
    }
  }

  return null;
}

function channelMatchesSelection(channelName, selection) {
  const trimmedSelection = String(selection || "").trim();
  if (!trimmedSelection) return false;

  const specialOption = specialChannelNameForSelection(trimmedSelection);
  if (specialOption) {
    const keyword = CHANNEL_SPECIAL_KEYWORDS.get(specialOption);
    return normalizedChannelTokens(channelName).some((token) => token.startsWith(keyword));
  }

  return compareInsensitive(String(channelName || "").trim(), trimmedSelection) === 0;
}

const SCORE_MIN_COMBINED_CONFIDENCE = 0.82;
const SCORE_MIN_TEAM_CONFIDENCE = 0.7;
const SCORE_SWAPPED_PENALTY = 0.08;
const SCORE_PREFIX_BOOST = 0.35;
const SCORE_SINGLE_TOKEN_PENALTY = 0.12;

const SCORE_STOP_WORDS = new Set([
  "fc",
  "cf",
  "sc",
  "afc",
  "ac",
  "sv",
  "fk",
  "bk",
  "bc",
  "ks",
  "nk",
  "club",
  "de",
  "the",
  "and",
]);
const TEAM_IDENTITY_STOP_WORDS = new Set([
  ...SCORE_STOP_WORDS,
  "as",
  "kf",
  "vfb",
  "vfl",
  "tsg",
  "ifk",
  "fkf",
  "fsv",
  "us",
  "ca",
  "cd",
  "ud",
  "rc",
]);
const DEDUPE_MIN_COMBINED_CONFIDENCE = 0.9;
const DEDUPE_MIN_TEAM_CONFIDENCE = 0.84;
const parsedClubEloFixturesMatchMinConfidence = Number(
  process.env.CLUB_ELO_FIXTURES_MATCH_MIN_CONFIDENCE || 0.84
);
const CLUB_ELO_FIXTURES_MATCH_MIN_CONFIDENCE = Number.isFinite(
  parsedClubEloFixturesMatchMinConfidence
)
  ? Math.min(1, Math.max(0, parsedClubEloFixturesMatchMinConfidence))
  : 0.84;
const parsedClubEloFixturesMatchMinTeamConfidence = Number(
  process.env.CLUB_ELO_FIXTURES_MATCH_MIN_TEAM_CONFIDENCE || 0.72
);
const CLUB_ELO_FIXTURES_MATCH_MIN_TEAM_CONFIDENCE = Number.isFinite(
  parsedClubEloFixturesMatchMinTeamConfidence
)
  ? Math.min(1, Math.max(0, parsedClubEloFixturesMatchMinTeamConfidence))
  : 0.72;
const parsedClubEloFixturesOpponentMargin = Number(
  process.env.CLUB_ELO_FIXTURES_MATCH_OPPONENT_MARGIN || 0.03
);
const CLUB_ELO_FIXTURES_MATCH_OPPONENT_MARGIN = Number.isFinite(
  parsedClubEloFixturesOpponentMargin
)
  ? Math.min(0.5, Math.max(0, parsedClubEloFixturesOpponentMargin))
  : 0.03;
const CLUB_ELO_FIXTURES_MATCH_AMBIGUOUS_MARGIN = 0.01;
const parsedClubEloMatchMinConfidence = Number(process.env.CLUB_ELO_MATCH_MIN_CONFIDENCE || 0.82);
const CLUB_ELO_MATCH_MIN_CONFIDENCE = Number.isFinite(parsedClubEloMatchMinConfidence)
  ? Math.min(1, Math.max(0, parsedClubEloMatchMinConfidence))
  : 0.82;
const parsedFootballDatabaseMatchMinConfidence = Number(
  process.env.FOOTBALL_DATABASE_MATCH_MIN_CONFIDENCE || CLUB_ELO_MATCH_MIN_CONFIDENCE
);
const FOOTBALL_DATABASE_MATCH_MIN_CONFIDENCE = Number.isFinite(
  parsedFootballDatabaseMatchMinConfidence
)
  ? Math.min(1, Math.max(0, parsedFootballDatabaseMatchMinConfidence))
  : CLUB_ELO_MATCH_MIN_CONFIDENCE;
const parsedFootballDatabaseManualTargetMinConfidence = Number(
  process.env.FOOTBALL_DATABASE_MANUAL_TARGET_MIN_CONFIDENCE || 0.62
);
const FOOTBALL_DATABASE_MANUAL_TARGET_MIN_CONFIDENCE = Number.isFinite(
  parsedFootballDatabaseManualTargetMinConfidence
)
  ? Math.min(1, Math.max(0, parsedFootballDatabaseManualTargetMinConfidence))
  : 0.62;
const parsedNationalEloMatchMinConfidence = Number(
  process.env.NATIONAL_ELO_MATCH_MIN_CONFIDENCE || 0.82
);
const NATIONAL_ELO_MATCH_MIN_CONFIDENCE = Number.isFinite(parsedNationalEloMatchMinConfidence)
  ? Math.min(1, Math.max(0, parsedNationalEloMatchMinConfidence))
  : 0.82;

const SCORE_ALIAS_MAP = new Map([
  ["manchester united", "man united"],
  ["man united", "manchester united"],
  ["man utd", "manchester united"],
  ["manchester city", "man city"],
  ["man city", "manchester city"],
  ["tottenham hotspur", "tottenham"],
  ["spurs", "tottenham hotspur"],
  ["wolverhampton wanderers", "wolves"],
  ["wolves", "wolverhampton wanderers"],
  ["sheffield united", "sheff utd"],
  ["sheffield wednesday", "sheff wed"],
  ["nottingham forest", "nottm forest"],
  ["nottm forest", "nottingham forest"],
  ["newcastle united", "newcastle"],
  ["brighton", "brighton and hove albion"],
  ["brighton & hove albion", "brighton"],
  ["brighton and hove albion", "brighton"],
  ["west ham united", "west ham"],
  ["west ham", "west ham united"],
  ["wolverhampton", "wolverhampton wanderers"],
  ["tottenham", "tottenham hotspur"],
  ["borussia dortmund", "dortmund"],
  ["borussia m'gladbach", "m'gladbach"],
  ["athletic club", "athletic"],
  ["real betis", "betis"],
  ["fc copenhagen", "copenhagen"],
  ["fc porto", "porto"],
  ["paok thessaloniki", "paok"],
  ["paok thessaloniki fc", "paok"],
  ["inter milan", "inter"],
  ["ac milan", "ac milan"],
  ["psg", "paris saint germain"],
  ["paris saint-germain", "psg"],
]);

const CLUB_ELO_NATIONAL_TEAM_NAME_EXTRAS = [
  "afghanistan",
  "albania",
  "algeria",
  "andorra",
  "angola",
  "argentina",
  "armenia",
  "aruba",
  "australia",
  "austria",
  "azerbaijan",
  "bahrain",
  "bangladesh",
  "belarus",
  "belgium",
  "bolivia",
  "bosnia-herzegovina",
  "bosnia and herzegovina",
  "brazil",
  "bulgaria",
  "cameroon",
  "canada",
  "chile",
  "china",
  "chinese taipei",
  "colombia",
  "costa rica",
  "croatia",
  "cyprus",
  "czechia",
  "england",
  "denmark",
  "ecuador",
  "egypt",
  "estonia",
  "finland",
  "france",
  "georgia",
  "germany",
  "ghana",
  "greece",
  "haiti",
  "hungary",
  "iceland",
  "india",
  "indonesia",
  "iran",
  "iraq",
  "israel",
  "italy",
  "jamaica",
  "japan",
  "jordan",
  "kazakhstan",
  "kenya",
  "kosovo",
  "kuwait",
  "latvia",
  "lebanon",
  "libya",
  "lithuania",
  "luxembourg",
  "malaysia",
  "mexico",
  "moldova",
  "montenegro",
  "morocco",
  "netherlands",
  "new zealand",
  "nigeria",
  "norway",
  "oman",
  "palestine",
  "panama",
  "paraguay",
  "peru",
  "philippines",
  "poland",
  "portugal",
  "qatar",
  "romania",
  "russia",
  "saudi arabia",
  "senegal",
  "serbia",
  "slovakia",
  "slovenia",
  "south africa",
  "scotland",
  "south korea",
  "spain",
  "sweden",
  "switzerland",
  "syria",
  "thailand",
  "tunisia",
  "turkey",
  "ukraine",
  "united arab emirates",
  "united states",
  "uruguay",
  "uzbekistan",
  "venezuela",
  "vietnam",
  "wales",
  "northern ireland",
  "republic of ireland",
  "usa",
  "us",
  "u s a",
  "north korea",
  "korea republic",
  "korea dpr",
  "czech republic",
  "ivory coast",
  "cote divoire",
  "bosnia and herzegovina",
  "cape verde",
  "cabo verde",
  "north macedonia",
  "dr congo",
  "congo dr",
  "congo republic",
  "st kitts and nevis",
  "st lucia",
  "st vincent and the grenadines",
  "curacao",
  "palestine",
];

let likelyNationalTeamNames = null;

function addLikelyNationalTeamName(set, value) {
  const normalized = normalizeTeamName(value).replace(/\s+/g, " ").trim();
  if (!normalized) return;
  set.add(normalized);
  if (normalized.startsWith("the ")) {
    set.add(normalized.slice(4).trim());
  }
}

function getLikelyNationalTeamNames() {
  if (likelyNationalTeamNames) return likelyNationalTeamNames;

  const set = new Set();
  if (
    typeof Intl === "object" &&
    Intl &&
    typeof Intl.DisplayNames === "function" &&
    typeof Intl.supportedValuesOf === "function"
  ) {
    try {
      const displayNames = new Intl.DisplayNames(["en"], { type: "region" });
      Intl.supportedValuesOf("region").forEach((regionCode) => {
        addLikelyNationalTeamName(set, displayNames.of(regionCode));
      });
    } catch (_error) {
      // Ignore ICU/runtime support issues and fall back to extras.
    }
  }
  CLUB_ELO_NATIONAL_TEAM_NAME_EXTRAS.forEach((name) => addLikelyNationalTeamName(set, name));
  likelyNationalTeamNames = set;
  return likelyNationalTeamNames;
}

function normalizeNationalTeamBaseName(value) {
  return normalizeTeamName(value)
    .replace(/\bunder\s*\d{2}\b/g, " ")
    .replace(/\bu\d{2}\b/g, " ")
    .replace(/\b(women|womens|ladies|olympic|olympics|futsal|beach soccer)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function isLikelyNationalTeamName(teamName) {
  const normalized = normalizeTeamName(teamName).replace(/\s+/g, " ").trim();
  if (!normalized) return false;

  const likelyNames = getLikelyNationalTeamNames();
  if (likelyNames.has(normalized)) return true;

  const baseName = normalizeNationalTeamBaseName(normalized);
  if (baseName && likelyNames.has(baseName)) return true;

  return false;
}

function normalizeTeamName(value) {
  return normalizeTeamIdentityName(canonicalTeamName(value));
}

function loadClubEloManualMappings() {
  let stat = null;
  try {
    stat = fs.statSync(CLUB_ELO_MANUAL_MAPPINGS_PATH);
  } catch (error) {
    if (error && error.code === "ENOENT") {
      clubEloManualMappings = new Map();
      clubEloManualMappingsMtimeMs = null;
      return clubEloManualMappings;
    }
    console.warn(`[Club Elo] Failed to stat manual mappings file: ${error.message || error}`);
    return clubEloManualMappings;
  }

  const mtimeMs = Number(stat && stat.mtimeMs);
  if (Number.isFinite(mtimeMs) && clubEloManualMappingsMtimeMs === mtimeMs) {
    return clubEloManualMappings;
  }

  try {
    const raw = fs.readFileSync(CLUB_ELO_MANUAL_MAPPINGS_PATH, "utf8");
    const parsed = JSON.parse(raw);
    const next = new Map();
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      Object.entries(parsed).forEach(([sourceName, targetClub]) => {
        const normalizedSource = normalizeTeamName(sourceName).replace(/\s+/g, " ").trim();
        if (!normalizedSource) return;
        if (targetClub === null || targetClub === false) {
          next.set(normalizedSource, null);
          return;
        }
        const normalizedTarget = String(targetClub || "").trim();
        if (!normalizedTarget) return;
        next.set(normalizedSource, normalizedTarget);
      });
    } else {
      console.warn(
        `[Club Elo] Manual mappings file must be a JSON object at ${CLUB_ELO_MANUAL_MAPPINGS_PATH}`
      );
    }
    clubEloManualMappings = next;
    clubEloManualMappingsMtimeMs = Number.isFinite(mtimeMs) ? mtimeMs : Date.now();
  } catch (error) {
    console.warn(`[Club Elo] Failed to load manual mappings: ${error.message || error}`);
    clubEloManualMappingsMtimeMs = Number.isFinite(mtimeMs) ? mtimeMs : Date.now();
  }

  return clubEloManualMappings;
}

function loadFantasyTeamShortNameMappings() {
  const config = loadTeamIdentityConfig();
  fantasyTeamShortNameMappings = buildFantasyShortNameMappings();
  fantasyTeamShortNameMappingsLoadedAt = config.updatedAt || new Date().toISOString();
  fantasyTeamShortNameMappingsMtimeMs = Date.parse(fantasyTeamShortNameMappingsLoadedAt) || Date.now();
  return fantasyTeamShortNameMappings;
}

function loadFantasyLoadingMessages() {
  let stat = null;
  try {
    stat = fs.statSync(FANTASY_LOADING_MESSAGES_PATH);
  } catch (error) {
    if (error && error.code === "ENOENT") {
      fantasyLoadingMessages = Object.freeze([]);
      fantasyLoadingMessagesLoadedAt = new Date().toISOString();
      fantasyLoadingMessagesMtimeMs = null;
      console.warn(
        `[FantasyLoadingMessages] Message file not found at ${FANTASY_LOADING_MESSAGES_PATH}; using empty list.`
      );
      return fantasyLoadingMessages;
    }
    console.warn(
      `[FantasyLoadingMessages] Failed to stat message file: ${error.message || error}`
    );
    return fantasyLoadingMessages;
  }

  const mtimeMs = Number(stat && stat.mtimeMs);
  if (Number.isFinite(mtimeMs) && fantasyLoadingMessagesMtimeMs === mtimeMs) {
    return fantasyLoadingMessages;
  }

  try {
    const raw = fs.readFileSync(FANTASY_LOADING_MESSAGES_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      throw new Error("Message file must be a JSON array.");
    }

    const next = parsed
      .map((message) => String(message || "").trim())
      .filter(Boolean);

    fantasyLoadingMessages = Object.freeze(next);
    fantasyLoadingMessagesLoadedAt = new Date().toISOString();
    fantasyLoadingMessagesMtimeMs = Number.isFinite(mtimeMs) ? mtimeMs : Date.now();
    console.log(
      `[FantasyLoadingMessages] Loaded ${next.length} messages from ${FANTASY_LOADING_MESSAGES_PATH}`
    );
  } catch (error) {
    console.warn(
      `[FantasyLoadingMessages] Failed to load message file: ${error.message || error}`
    );
    fantasyLoadingMessagesMtimeMs = Number.isFinite(mtimeMs) ? mtimeMs : Date.now();
  }

  return fantasyLoadingMessages;
}

function loadFantasyAssistantManagerPhrases() {
  let stat = null;
  try {
    stat = fs.statSync(FANTASY_ASSISTANT_MANAGER_PHRASES_PATH);
  } catch (error) {
    if (error && error.code === "ENOENT") {
      fantasyAssistantManagerPhrases = Object.freeze([]);
      fantasyAssistantManagerPhrasesLoadedAt = new Date().toISOString();
      fantasyAssistantManagerPhrasesMtimeMs = null;
      console.warn(
        `[FantasyAssistantPhrases] Phrase file not found at ${FANTASY_ASSISTANT_MANAGER_PHRASES_PATH}; using empty list.`
      );
      return fantasyAssistantManagerPhrases;
    }
    console.warn(
      `[FantasyAssistantPhrases] Failed to stat phrase file: ${error.message || error}`
    );
    return fantasyAssistantManagerPhrases;
  }

  const mtimeMs = Number(stat && stat.mtimeMs);
  if (Number.isFinite(mtimeMs) && fantasyAssistantManagerPhrasesMtimeMs === mtimeMs) {
    return fantasyAssistantManagerPhrases;
  }

  try {
    const raw = fs.readFileSync(FANTASY_ASSISTANT_MANAGER_PHRASES_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      throw new Error("Phrase file must be a JSON array.");
    }

    const next = parsed
      .map((phrase) => String(phrase || "").trim())
      .filter(Boolean);

    fantasyAssistantManagerPhrases = Object.freeze(next);
    fantasyAssistantManagerPhrasesLoadedAt = new Date().toISOString();
    fantasyAssistantManagerPhrasesMtimeMs = Number.isFinite(mtimeMs) ? mtimeMs : Date.now();
    console.log(
      `[FantasyAssistantPhrases] Loaded ${next.length} phrases from ${FANTASY_ASSISTANT_MANAGER_PHRASES_PATH}`
    );
  } catch (error) {
    console.warn(
      `[FantasyAssistantPhrases] Failed to load phrase file: ${error.message || error}`
    );
    fantasyAssistantManagerPhrasesMtimeMs = Number.isFinite(mtimeMs) ? mtimeMs : Date.now();
  }

  return fantasyAssistantManagerPhrases;
}

function loadTeamColorsConfig() {
  const payload = loadTeamIdentityConfig();
  teamColorsLoadedAt = payload.updatedAt || new Date().toISOString();
  teamColorsConfig = Object.freeze({
    updatedAt: teamColorsLoadedAt,
    default: Object.freeze({
      primary: payload.default?.primary || "#111111",
      secondary: payload.default?.secondary || "#FFFFFF",
      scheme: payload.default?.scheme || "default-dark",
    }),
    teams: Object.freeze(
      (Array.isArray(payload.teams) ? payload.teams : []).map((entry) =>
        Object.freeze({
          name: entry.name,
          aliases: Array.isArray(entry.aliases) ? entry.aliases : [],
          primary: entry.primary || payload.default?.primary || "#111111",
          secondary: entry.secondary || payload.default?.secondary || "#FFFFFF",
          scheme: entry.scheme ?? payload.default?.scheme ?? "default-dark",
        })
      )
    ),
    identity_groups: Object.freeze(
      (Array.isArray(payload.identityGroups) ? payload.identityGroups : []).map((entry) =>
        Object.freeze({
          name: entry.name,
          aliases: Array.isArray(entry.aliases) ? entry.aliases : [],
        })
      )
    ),
  });
  return teamColorsConfig;
}

function resolveManualMappingCandidates(normalizedName, manualMappings) {
  const safeName = String(normalizedName || "").trim();
  const safeMappings =
    manualMappings && typeof manualMappings.forEach === "function" ? manualMappings : new Map();

  let explicitUnmatched = false;
  const candidates = [];
  const seenCandidateKeys = new Set();
  const addCandidate = (clubName, direction) => {
    const value = String(clubName || "").replace(/\s+/g, " ").trim();
    if (!value) return;
    const dedupeKey = `${direction}:${normalizeTeamName(value).replace(/\s+/g, " ").trim()}`;
    if (!dedupeKey || seenCandidateKeys.has(dedupeKey)) return;
    seenCandidateKeys.add(dedupeKey);
    candidates.push({
      clubName: value,
      direction,
    });
  };

  if (safeMappings.has(safeName)) {
    const directTarget = safeMappings.get(safeName);
    if (directTarget === null) {
      explicitUnmatched = true;
    } else {
      addCandidate(directTarget, "forward");
    }
  }

  safeMappings.forEach((targetClub, sourceName) => {
    if (!targetClub) return;
    const normalizedTarget = normalizeTeamName(targetClub).replace(/\s+/g, " ").trim();
    if (!normalizedTarget || normalizedTarget !== safeName) return;
    if (sourceName === safeName) return;
    addCandidate(sourceName, "reverse");
  });

  return {
    explicitUnmatched,
    candidates,
  };
}

function normalizedTeamKey(value) {
  return normalizeTeamName(value).replace(/\s+/g, " ").trim();
}

function resolveManualCanonicalTeamKey(teamName, manualMappings = null) {
  const safeMappings = manualMappings || loadClubEloManualMappings();
  let current = normalizedTeamKey(teamName);
  if (!current) return "";

  const visited = new Set();
  for (let depth = 0; depth < 12; depth += 1) {
    if (!current || visited.has(current)) break;
    visited.add(current);
    if (!safeMappings.has(current)) break;

    const target = safeMappings.get(current);
    if (!target) break;
    const next = normalizedTeamKey(target);
    if (!next || next === current) break;
    current = next;
  }
  return current;
}

function areTeamNamesEquivalentByManualMappings(lhs, rhs, manualMappings = null) {
  const left = normalizedTeamKey(lhs);
  const right = normalizedTeamKey(rhs);
  if (!left || !right) return false;
  if (left === right) return true;
  const safeMappings = manualMappings || loadClubEloManualMappings();
  return (
    resolveManualCanonicalTeamKey(left, safeMappings) ===
    resolveManualCanonicalTeamKey(right, safeMappings)
  );
}

function normalizedTokens(value) {
  const lowered = normalizeTeamName(value);
  return lowered
    .split(/[^a-z0-9]+/i)
    .map((token) => token.trim())
    .filter((token) => token && !SCORE_STOP_WORDS.has(token));
}

function identityTokens(value) {
  return normalizeTeamName(value)
    .split(/[^a-z0-9]+/i)
    .map((token) => token.trim())
    .filter((token) => {
      if (!token) return false;
      if (TEAM_IDENTITY_STOP_WORDS.has(token)) return false;
      if (/^\d+$/.test(token)) return false;
      return true;
    });
}

function canonicalTeamIdentity(value) {
  const tokens = identityTokens(value);
  if (tokens.length > 0) return tokens.join(" ");
  return normalizeTeamName(value).replace(/\s+/g, " ").trim();
}

function identityTeamKeys(value) {
  const keys = [];
  const addKey = (candidate) => {
    const normalized = String(candidate || "").replace(/\s+/g, " ").trim();
    if (!normalized) return;
    if (!keys.includes(normalized)) keys.push(normalized);
  };

  addKey(normalizeTeamName(value));
  addKey(canonicalTeamIdentity(value));

  nameVariants(value).forEach((variant) => {
    addKey(variant.tokens.join(" "));
    const canonicalVariant = variant.tokens
      .filter((token) => {
        if (TEAM_IDENTITY_STOP_WORDS.has(token)) return false;
        if (/^\d+$/.test(token)) return false;
        return true;
      })
      .join(" ");
    addKey(canonicalVariant);
  });

  return keys;
}

function nameVariants(name) {
  const lowered = String(name || "").toLowerCase();
  const candidates = [lowered];
  if (SCORE_ALIAS_MAP.has(lowered)) {
    candidates.push(SCORE_ALIAS_MAP.get(lowered));
  }

  const variants = [];
  candidates.forEach((candidate) => {
    const tokens = normalizedTokens(candidate);
    const key = tokens.join("");
    if (!key) return;
    const exists = variants.some((variant) => variant.key === key);
    if (!exists) variants.push({ key, tokens });
  });
  return variants;
}

function diceCoefficient(lhs, rhs) {
  if (!lhs.length && !rhs.length) return 1;
  const left = new Set(lhs);
  const right = new Set(rhs);
  let intersection = 0;
  left.forEach((token) => {
    if (right.has(token)) intersection += 1;
  });
  return (2 * intersection) / (lhs.length + rhs.length);
}

function prefixScore(lhs, rhs) {
  if (Math.min(lhs.tokens.length, rhs.tokens.length) !== 1) return 0;
  if (lhs.key.startsWith(rhs.key) || rhs.key.startsWith(lhs.key)) {
    const minLength = Math.min(lhs.key.length, rhs.key.length);
    const maxLength = Math.max(lhs.key.length, rhs.key.length);
    if (!maxLength) return 1;
    return Math.min(1, minLength / maxLength + SCORE_PREFIX_BOOST);
  }
  return 0;
}

function levenshtein(lhs, rhs) {
  const left = Array.from(lhs);
  const right = Array.from(rhs);
  const previous = Array.from({ length: right.length + 1 }, (_, i) => i);
  let current = Array.from({ length: right.length + 1 }, () => 0);

  for (let i = 0; i < left.length; i += 1) {
    current[0] = i + 1;
    for (let j = 0; j < right.length; j += 1) {
      const cost = left[i] === right[j] ? 0 : 1;
      current[j + 1] = Math.min(
        previous[j + 1] + 1,
        current[j] + 1,
        previous[j] + cost
      );
    }
    for (let k = 0; k < current.length; k += 1) {
      previous[k] = current[k];
    }
  }

  return previous[right.length];
}

function similarity(lhs, rhs) {
  const maxLength = Math.max(lhs.length, rhs.length);
  if (!maxLength) return 1;
  return 1 - levenshtein(lhs, rhs) / maxLength;
}

function similarityScore(lhs, rhs) {
  const leftVariants = nameVariants(lhs);
  const rightVariants = nameVariants(rhs);
  let best = 0;

  leftVariants.forEach((left) => {
    rightVariants.forEach((right) => {
      const base = similarity(left.key, right.key);
      const dice = diceCoefficient(left.tokens, right.tokens);
      const prefix = prefixScore(left, right);
      let candidate = Math.max(base, dice, prefix);

      if (left.tokens.length >= 2 && right.tokens.length >= 2) {
        const intersection = left.tokens.filter((token) => right.tokens.includes(token)).length;
        if (intersection === 1) {
          candidate = Math.max(0, candidate - SCORE_SINGLE_TOKEN_PENALTY);
        }
      }

      best = Math.max(best, candidate);
    });
  });

  return Math.min(1, best);
}

function canonicalIdentityConfidenceBoost(lhs, rhs) {
  const leftIdentity = canonicalTeamIdentity(lhs);
  const rightIdentity = canonicalTeamIdentity(rhs);
  if (!leftIdentity || !rightIdentity) return 0;
  return leftIdentity === rightIdentity ? 1 : 0;
}

function scoreTeams(home, away, bbcHome, bbcAway, penalty) {
  const homeScore = similarityScore(home, bbcHome);
  const awayScore = similarityScore(away, bbcAway);
  const combined = Math.max(0, (homeScore + awayScore) / 2 - penalty);
  return { confidence: combined, minTeamConfidence: Math.min(homeScore, awayScore) };
}

function buildClubEloFixturesCandidatesByDate(records = matchDetailsById) {
  const byDate = new Map();
  const addCandidate = (detailsId, payload) => {
    const normalizedId = normalizeMatchDetailsId(detailsId || (payload && payload.id));
    if (!normalizedId) return;
    const date = String(payload && payload.date ? payload.date : "").trim();
    if (!isDateOnly(date)) return;
    const homeTeam = String(payload && payload.home_team ? payload.home_team : "").trim();
    const awayTeam = String(payload && payload.away_team ? payload.away_team : "").trim();
    if (!homeTeam || !awayTeam) return;

    if (!byDate.has(date)) {
      byDate.set(date, []);
    }
    byDate.get(date).push({
      details_id: normalizedId,
      date,
      home_team: homeTeam,
      away_team: awayTeam,
    });
  };

  if (records instanceof Map) {
    records.forEach((payload, detailsId) => addCandidate(detailsId, payload));
  } else if (records && typeof records === "object") {
    Object.entries(records).forEach(([detailsId, payload]) => addCandidate(detailsId, payload));
  }

  return byDate;
}

function scoreClubEloFixtureCandidate(fixture, candidate) {
  const homeBase = similarityScore(fixture.home_team, candidate.home_team);
  const awayBase = similarityScore(fixture.away_team, candidate.away_team);
  const homeScore = Math.max(
    homeBase,
    canonicalIdentityConfidenceBoost(fixture.home_team, candidate.home_team)
  );
  const awayScore = Math.max(
    awayBase,
    canonicalIdentityConfidenceBoost(fixture.away_team, candidate.away_team)
  );
  const confidence = (homeScore + awayScore) / 2;
  const opponentConfidence =
    (
      similarityScore(fixture.home_team, candidate.away_team) +
      similarityScore(fixture.away_team, candidate.home_team)
    ) / 2;

  return {
    confidence,
    minTeamConfidence: Math.min(homeScore, awayScore),
    opponentConfidence,
  };
}

function findBestMatchDetailsForClubEloFixture(fixture, candidatesByDate) {
  if (!fixture || typeof fixture !== "object") return null;
  const fixtureDate = String(fixture.date || "").trim();
  if (!isDateOnly(fixtureDate)) return null;

  const candidates = candidatesByDate.get(fixtureDate);
  if (!Array.isArray(candidates) || candidates.length === 0) return null;

  let best = null;
  let secondBestConfidence = Number.NEGATIVE_INFINITY;
  candidates.forEach((candidate) => {
    const scored = scoreClubEloFixtureCandidate(fixture, candidate);
    if (
      scored.confidence < CLUB_ELO_FIXTURES_MATCH_MIN_CONFIDENCE ||
      scored.minTeamConfidence < CLUB_ELO_FIXTURES_MATCH_MIN_TEAM_CONFIDENCE
    ) {
      return;
    }
    // Ensure the home/away orientation is reliable before applying GD probabilities.
    if (
      scored.opponentConfidence + CLUB_ELO_FIXTURES_MATCH_OPPONENT_MARGIN >=
      scored.confidence
    ) {
      return;
    }
    if (!best || scored.confidence > best.confidence) {
      if (best) {
        secondBestConfidence = Math.max(secondBestConfidence, best.confidence);
      }
      best = {
        details_id: candidate.details_id,
        confidence: scored.confidence,
        minTeamConfidence: scored.minTeamConfidence,
      };
      return;
    }
    secondBestConfidence = Math.max(secondBestConfidence, scored.confidence);
  });

  if (!best) return null;
  if (secondBestConfidence >= best.confidence - CLUB_ELO_FIXTURES_MATCH_AMBIGUOUS_MARGIN) {
    return null;
  }
  return best;
}

function mergeClubEloFixtureMetadata(payload, fixture, matchResult, nowIso, sourceUrl) {
  const metadata = payload && payload.metadata && typeof payload.metadata === "object"
    ? payload.metadata
    : {};
  return {
    ...payload,
    updated_at: nowIso,
    metadata: {
      ...metadata,
      club_elo_fixture_probabilities: {
        source: sourceUrl || CLUB_ELO_FIXTURES_URL,
        updated_at: nowIso,
        fixture_date: fixture.date,
        country: fixture.country || null,
        home_team: fixture.home_team,
        away_team: fixture.away_team,
        match_confidence: Number(matchResult.confidence.toFixed(4)),
        match_min_team_confidence: Number(matchResult.minTeamConfidence.toFixed(4)),
        result_chances: Array.isArray(fixture.result_chances) ? fixture.result_chances : [],
      },
    },
  };
}

function bestScoreCandidate(match, bbcMatches) {
  let best = null;
  bbcMatches.forEach((bbc) => {
    const direct = scoreTeams(match.home_team, match.away_team, bbc.home_team, bbc.away_team, 0);
    const swapped = scoreTeams(
      match.home_team,
      match.away_team,
      bbc.away_team,
      bbc.home_team,
      SCORE_SWAPPED_PENALTY
    );
    const directCandidate = {
      match: bbc,
      confidence: direct.confidence,
      minTeamConfidence: direct.minTeamConfidence,
      swapped: false,
    };
    const swappedCandidate = {
      match: bbc,
      confidence: swapped.confidence,
      minTeamConfidence: swapped.minTeamConfidence,
      swapped: true,
    };
    const chosen = directCandidate.confidence >= swappedCandidate.confidence
      ? directCandidate
      : swappedCandidate;
    const candidate = {
      match: chosen.match,
      confidence: chosen.confidence,
      minTeamConfidence: chosen.minTeamConfidence,
      swapped: chosen.swapped,
    };

    if (!best || candidate.confidence > best.confidence) {
      best = candidate;
    }
  });

  if (!best) return null;
  if (
    best.confidence < SCORE_MIN_COMBINED_CONFIDENCE ||
    best.minTeamConfidence < SCORE_MIN_TEAM_CONFIDENCE
  ) {
    return null;
  }

  return best;
}

function matchKey(match) {
  return [
    match.date,
    match.time,
    String(match.league || "").toLowerCase().trim(),
    String(match.home_team || "").toLowerCase().trim(),
    String(match.away_team || "").toLowerCase().trim(),
  ].join("|");
}

const DATE_ONLY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
const TIME_ONLY_PATTERN = /^\d{2}:\d{2}$/;

function isDateOnly(value) {
  return DATE_ONLY_PATTERN.test(String(value || "").trim());
}

function normalizeTimeValue(value) {
  const normalized = String(value || "").trim();
  return TIME_ONLY_PATTERN.test(normalized) ? normalized : "00:00";
}

function parseNumericScore(value) {
  if (value === undefined || value === null || value === "") return null;
  const num = Number(value);
  return Number.isFinite(num) ? num : null;
}

function uniqueChannels(channels) {
  const output = [];
  (Array.isArray(channels) ? channels : []).forEach((channel) => {
    const trimmed = String(channel || "").trim();
    if (!trimmed) return;
    if (!output.includes(trimmed)) output.push(trimmed);
  });
  return output;
}

const MATCH_STATUS_IN_PROGRESS_TOKENS = new Set(["LIVE", "HT", "ET", "PENS", "PEN", "PEN."]);
const MATCH_STATUS_COMPLETE_TOKENS = new Set(["FT", "AET"]);
const MATCH_STATUS_POSTPONED_TOKENS = new Set(["POSTPONED", "MATCH POSTPONED"]);
const MATCH_STATUS_MINUTE_PATTERN = /^\d{1,3}(?:\+\d{1,2})?'?$/;
const MATCH_DETAILS_ID_PATTERN = /^[a-z0-9]+$/i;
const MATCH_DETAILS_EVENT_FIELDS = [
  "home_goal_scorers",
  "away_goal_scorers",
  "home_assists",
  "away_assists",
  "home_yellow_cards",
  "away_yellow_cards",
  "home_red_cards",
  "away_red_cards",
];
const MATCH_LINEUP_POSITION_CATEGORIES = new Set([
  "goalkeeper",
  "defender",
  "midfielder",
  "attacker",
]);

function normalizeMatchLineupPlayer(value, options = {}) {
  if (!value || typeof value !== "object") return null;

  const rawNumber = Number(value.number);
  if (!Number.isFinite(rawNumber)) return null;

  const name = String(value.name || "").trim();
  if (!name) return null;

  const normalized = {
    number: Math.trunc(rawNumber),
    name,
  };

  if (options.includePositionCategory) {
    const positionCategory = String(value.position_category || "").trim().toLowerCase();
    if (MATCH_LINEUP_POSITION_CATEGORIES.has(positionCategory)) {
      normalized.position_category = positionCategory;
    } else {
      normalized.position_category = null;
    }

    const formationRowIndex = Number(value.formation_row_index);
    normalized.formation_row_index = Number.isInteger(formationRowIndex) && formationRowIndex >= 0
      ? formationRowIndex
      : null;

    const formationSlotIndex = Number(value.formation_slot_index);
    normalized.formation_slot_index = Number.isInteger(formationSlotIndex) && formationSlotIndex >= 0
      ? formationSlotIndex
      : null;

    const formationRowSize = Number(value.formation_row_size);
    normalized.formation_row_size = Number.isInteger(formationRowSize) && formationRowSize > 0
      ? formationRowSize
      : null;
  }

  return normalized;
}

function normalizeMatchLineupSubstitution(value) {
  if (!value || typeof value !== "object") return null;

  const minute = String(value.minute || "").trim();
  const playerOff = normalizeMatchLineupPlayer(value.player_off);
  const playerOn = normalizeMatchLineupPlayer(value.player_on);
  if (!minute || !playerOff || !playerOn) return null;

  return {
    minute,
    player_off: playerOff,
    player_on: playerOn,
  };
}

function normalizeMatchLineupSide(value) {
  if (!value || typeof value !== "object") return null;

  const team = String(value.team || "").trim() || null;
  const manager = String(value.manager || "").trim() || null;
  const formation = String(value.formation || "").trim() || null;
  const startingLineup = Array.isArray(value.starting_lineup)
    ? value.starting_lineup
        .map((player) => normalizeMatchLineupPlayer(player, { includePositionCategory: true }))
        .filter(Boolean)
    : [];
  const substitutes = Array.isArray(value.substitutes)
    ? value.substitutes
        .map((player) => normalizeMatchLineupPlayer(player))
        .filter(Boolean)
    : [];
  const substitutions = Array.isArray(value.substitutions)
    ? value.substitutions.map(normalizeMatchLineupSubstitution).filter(Boolean)
    : [];

  if (!team && startingLineup.length === 0 && substitutes.length === 0 && substitutions.length === 0) {
    return null;
  }

  return {
    team,
    manager,
    formation,
    starting_lineup: startingLineup,
    substitutes,
    substitutions,
  };
}

function normalizeTeamLineupsPayload(value) {
  if (!value || typeof value !== "object") return null;

  const home = normalizeMatchLineupSide(value.home);
  const away = normalizeMatchLineupSide(value.away);
  if (!home && !away) return null;

  return {
    home,
    away,
  };
}

function hasCompleteTeamLineups(value) {
  const lineups = normalizeTeamLineupsPayload(value);
  if (!lineups || !lineups.home || !lineups.away) return false;
  const hasFormationMetadata = (players) =>
    Array.isArray(players) &&
    players.every((player) =>
      Number.isInteger(player.formation_row_index) &&
      player.formation_row_index >= 0 &&
      Number.isInteger(player.formation_slot_index) &&
      player.formation_slot_index >= 0 &&
      Number.isInteger(player.formation_row_size) &&
      player.formation_row_size > 0
    );
  return (
    Array.isArray(lineups.home.starting_lineup) &&
    lineups.home.starting_lineup.length === 11 &&
    hasFormationMetadata(lineups.home.starting_lineup) &&
    Array.isArray(lineups.away.starting_lineup) &&
    lineups.away.starting_lineup.length === 11 &&
    hasFormationMetadata(lineups.away.starting_lineup)
  );
}

function normalizeMatchStatusValue(status) {
  const normalized = String(status || "").trim();
  if (!normalized) return null;
  if (TIME_ONLY_PATTERN.test(normalized)) return null;
  if (MATCH_STATUS_MINUTE_PATTERN.test(normalized)) {
    return normalized.replace(/'$/, "");
  }

  const token = normalized.toUpperCase();
  if (MATCH_STATUS_POSTPONED_TOKENS.has(token)) return "POSTPONED";
  if (token === "PENS" || token === "PEN" || token === "PEN.") return "Pens";
  if (token === "HALF TIME" || token === "HALF-TIME") return "HT";
  if (token === "FULL TIME" || token === "FULL-TIME") return "FT";
  if (token === "EXTRA TIME") return "ET";
  if (
    MATCH_STATUS_COMPLETE_TOKENS.has(token) ||
    MATCH_STATUS_IN_PROGRESS_TOKENS.has(token)
  ) {
    return token;
  }
  return normalized;
}

function isPostponedMatchStatus(status) {
  return normalizeMatchStatusValue(status) === "POSTPONED";
}

function parseMatchStatusMinute(status) {
  const normalized = normalizeMatchStatusValue(status);
  if (!normalized) return null;
  const match = normalized.match(/^(\d{1,3})(?:\+(\d{1,2}))?$/);
  if (!match) return null;
  const base = Number(match[1]);
  const added = Number(match[2] || 0);
  if (!Number.isFinite(base) || !Number.isFinite(added)) return null;
  return base + added;
}

function isFirstHalfMinuteStatus(status) {
  const normalized = normalizeMatchStatusValue(status);
  if (!normalized) return false;
  const match = normalized.match(/^(\d{1,3})(?:\+(\d{1,2}))?$/);
  if (!match) return false;
  const base = Number(match[1]);
  return Number.isFinite(base) && base <= 45;
}

function isPenaltyShootoutStatusToken(status) {
  const normalized = normalizeMatchStatusValue(status);
  if (!normalized) return false;
  const token = normalized.toUpperCase();
  return token === "PENS" || token === "PEN" || token === "PEN.";
}

function finishedStatusRank(status) {
  const normalized = normalizeMatchStatusValue(status);
  if (!normalized) return 0;
  const token = normalized.toUpperCase();
  if (token === "AET") return 2;
  if (token === "FT") return 1;
  return 0;
}

function pickPreferredMatchStatus(existingStatus, incomingStatus, options = {}) {
  const preferIncomingOnTie = options.preferIncomingOnTie !== false;
  const allowTerminalRegression = options.allowTerminalRegression === true;
  const existing = normalizeMatchStatusValue(existingStatus);
  const incoming = normalizeMatchStatusValue(incomingStatus);

  if (!existing) return incoming;
  if (!incoming) return existing;

  const existingToken = existing.toUpperCase();
  const incomingToken = incoming.toUpperCase();
  const existingFinished = MATCH_STATUS_COMPLETE_TOKENS.has(existingToken);
  const incomingFinished = MATCH_STATUS_COMPLETE_TOKENS.has(incomingToken);
  const existingPostponed = isPostponedMatchStatus(existing);
  const incomingPostponed = isPostponedMatchStatus(incoming);
  const existingMinute = parseMatchStatusMinute(existing);
  const incomingMinute = parseMatchStatusMinute(incoming);
  const incomingLive =
    incomingMinute !== null || MATCH_STATUS_IN_PROGRESS_TOKENS.has(incomingToken);

  if (existingPostponed && !incomingPostponed) {
    if (incomingFinished || incomingLive) return incoming;
    return existing;
  }
  if (incomingPostponed && !existingPostponed) {
    const existingLive =
      existingMinute !== null || MATCH_STATUS_IN_PROGRESS_TOKENS.has(existingToken);
    if (existingFinished || existingLive) return existing;
    return incoming;
  }
  if (existingPostponed && incomingPostponed) {
    return preferIncomingOnTie ? incoming : existing;
  }

  // Never regress a terminal status back to an in-progress token.
  if (existingFinished && !incomingFinished) {
    if (allowTerminalRegression && incomingLive) return incoming;
    return existing;
  }
  if (incomingFinished && !existingFinished) return incoming;
  if (existingFinished && incomingFinished) {
    const existingRank = finishedStatusRank(existing);
    const incomingRank = finishedStatusRank(incoming);
    if (existingRank > incomingRank) return existing;
    if (incomingRank > existingRank) return incoming;
    return preferIncomingOnTie ? incoming : existing;
  }

  if (existingMinute !== null && incomingMinute !== null) {
    if (incomingMinute > existingMinute) return incoming;
    if (existingMinute > incomingMinute) return existing;
    return preferIncomingOnTie ? incoming : existing;
  }

  if (existingMinute !== null || incomingMinute !== null) {
    if (incomingMinute !== null) {
      if (existingToken === "LIVE") return incoming;
      if (existingToken === "HT" && isFirstHalfMinuteStatus(incoming)) return existing;
      if (existingToken === "ET" && incomingMinute <= 90) return existing;
      return incoming;
    }

    // Existing has a minute; keep it unless incoming represents a strictly later phase.
    if (incomingToken === "LIVE") return existing;
    if (incomingToken === "HT" && !isFirstHalfMinuteStatus(existing)) return existing;
    if (incomingToken === "ET" || isPenaltyShootoutStatusToken(incoming)) return incoming;
    return preferIncomingOnTie ? incoming : existing;
  }

  if (isPenaltyShootoutStatusToken(existing) !== isPenaltyShootoutStatusToken(incoming)) {
    return isPenaltyShootoutStatusToken(incoming) ? incoming : existing;
  }

  return preferIncomingOnTie ? incoming : existing;
}

function resolveMatchScoreStatus(match) {
  if (!match || typeof match !== "object") return null;
  return pickPreferredMatchStatus(match.score_status, match.match_time, {
    preferIncomingOnTie: true,
  });
}

function isInProgressMatchStatus(status) {
  const normalized = normalizeMatchStatusValue(status);
  if (!normalized) return false;
  if (MATCH_STATUS_MINUTE_PATTERN.test(normalized)) return true;

  const token = normalized.toUpperCase();
  if (MATCH_STATUS_COMPLETE_TOKENS.has(token)) return false;
  return MATCH_STATUS_IN_PROGRESS_TOKENS.has(token);
}

function matchDetailsIdFromUrl(detailsUrl) {
  if (!detailsUrl) return null;
  try {
    const parsed = new URL(String(detailsUrl));
    const pathname = String(parsed.pathname || "");
    if (!pathname.includes("/football/")) return null;
    const parts = pathname.split("/").filter(Boolean);
    if (parts.length === 0) return null;
    const last = String(parts[parts.length - 1] || "").trim();
    if (!MATCH_DETAILS_ID_PATTERN.test(last)) return null;
    return last.toLowerCase();
  } catch (_err) {
    return null;
  }
}

function normalizeMatchDetailsId(value) {
  const normalized = String(value || "").trim().toLowerCase();
  if (!MATCH_DETAILS_ID_PATTERN.test(normalized)) return null;
  return normalized;
}

function matchKickoffTimeMs(date, time) {
  if (!isDateOnly(date)) return null;
  const normalizedTime = normalizeTimeValue(time);
  const kickoff = new Date(`${String(date).trim()}T${normalizedTime}:00`);
  const kickoffMs = kickoff.getTime();
  return Number.isFinite(kickoffMs) ? kickoffMs : null;
}

function stabilizeMatchStatus(status, options = {}) {
  const normalized = normalizeMatchStatusValue(status);
  if (!normalized) return null;
  if (!options.hasScore || !isInProgressMatchStatus(normalized)) return normalized;

  const kickoffMs = matchKickoffTimeMs(options.date, options.time);
  if (!Number.isFinite(kickoffMs)) return normalized;

  const nowMs = Number.isFinite(options.nowMs) ? options.nowMs : Date.now();
  return nowMs - kickoffMs >= MATCH_STATUS_MAXIMUM_LIVE_WINDOW_MS ? "FT" : normalized;
}

function resolveStableMatchScoreStatus(match, options = {}) {
  if (!match || typeof match !== "object") return null;
  const homeScore = parseNumericScore(match.home_score);
  const awayScore = parseNumericScore(match.away_score);
  return stabilizeMatchStatus(resolveMatchScoreStatus(match) || match.score_status || null, {
    date: match.date || null,
    time: match.time || null,
    hasScore: homeScore !== null && awayScore !== null,
    nowMs: options.nowMs,
  });
}

function hasExplicitNoScoreState(match) {
  if (!match || typeof match !== "object") return false;
  const homeScore = parseNumericScore(match.home_score);
  const awayScore = parseNumericScore(match.away_score);
  if (homeScore !== null || awayScore !== null) return false;

  const status = resolveMatchScoreStatus(match) || match.score_status || match.match_time || null;
  const normalizedStatus = normalizeMatchStatusValue(status);
  return !normalizedStatus || TIME_ONLY_PATTERN.test(normalizedStatus);
}

function hasPostponedNoScoreState(match) {
  if (!match || typeof match !== "object") return false;
  const homeScore = parseNumericScore(match.home_score);
  const awayScore = parseNumericScore(match.away_score);
  if (homeScore !== null || awayScore !== null) return false;

  const status = resolveMatchScoreStatus(match) || match.score_status || match.match_time || null;
  return isPostponedMatchStatus(status);
}

function withStableMatchDetailsState(payload, options = {}) {
  if (!payload || typeof payload !== "object") return null;
  const scoreStatus = resolveStableMatchScoreStatus(payload, options);
  return {
    ...payload,
    score_status: scoreStatus,
    in_progress: isInProgressMatchStatus(scoreStatus),
  };
}

function pruneInactiveMatchDetailsRefreshEntries(nowMs = Date.now()) {
  matchDetailsActiveRefreshUntilById.forEach((refreshUntilMs, matchId) => {
    if (!Number.isFinite(refreshUntilMs) || refreshUntilMs <= nowMs) {
      matchDetailsActiveRefreshUntilById.delete(matchId);
    }
  });
}

function markMatchDetailsActive(matchId, ttlMs = MATCH_DETAILS_ACTIVE_REFRESH_WINDOW_MS) {
  const normalizedMatchId = normalizeMatchDetailsId(matchId);
  if (!normalizedMatchId) return false;
  const normalizedTtlMs = Number.isFinite(ttlMs)
    ? Math.max(30 * 1000, Math.floor(ttlMs))
    : MATCH_DETAILS_ACTIVE_REFRESH_WINDOW_MS;
  const refreshUntilMs = Date.now() + normalizedTtlMs;
  const existing = matchDetailsActiveRefreshUntilById.get(normalizedMatchId) || 0;
  if (refreshUntilMs > existing) {
    matchDetailsActiveRefreshUntilById.set(normalizedMatchId, refreshUntilMs);
  }
  return true;
}

function isMatchDetailsActive(matchId, nowMs = Date.now()) {
  const normalizedMatchId = normalizeMatchDetailsId(matchId);
  if (!normalizedMatchId) return false;
  const refreshUntilMs = matchDetailsActiveRefreshUntilById.get(normalizedMatchId);
  if (!Number.isFinite(refreshUntilMs) || refreshUntilMs <= nowMs) {
    matchDetailsActiveRefreshUntilById.delete(normalizedMatchId);
    return false;
  }
  return true;
}

function getMatchDetailsLookupEntry(matchDetailsLookup, detailsId) {
  if (!matchDetailsLookup || !detailsId) return null;
  if (matchDetailsLookup instanceof Map) {
    return matchDetailsLookup.get(detailsId) || null;
  }
  if (typeof matchDetailsLookup === "object") {
    return matchDetailsLookup[detailsId] || null;
  }
  return null;
}

function buildResolvedListMatchState(listMatch, detailsPayload, nowMs = Date.now()) {
  const listHomeScore = parseNumericScore(listMatch && listMatch.home_score);
  const listAwayScore = parseNumericScore(listMatch && listMatch.away_score);
  const detailsHomeScore = parseNumericScore(detailsPayload && detailsPayload.home_score);
  const detailsAwayScore = parseNumericScore(detailsPayload && detailsPayload.away_score);
  const homeScore = detailsHomeScore !== null ? detailsHomeScore : listHomeScore;
  const awayScore = detailsAwayScore !== null ? detailsAwayScore : listAwayScore;

  const listAggregate = resolveKnownAggregateScores(listMatch);
  const detailsAggregate = resolveKnownAggregateScores(detailsPayload);

  const listStatus = resolveMatchScoreStatus(listMatch) || (listMatch && listMatch.score_status) || null;
  const detailsStatus =
    resolveMatchScoreStatus(detailsPayload) || (detailsPayload && detailsPayload.score_status) || null;
  const preferredStatus = pickPreferredMatchStatus(listStatus, detailsStatus, {
    preferIncomingOnTie: true,
  });

  const kickoffDate = (listMatch && listMatch.date) || (detailsPayload && detailsPayload.date) || null;
  const kickoffTime = (listMatch && listMatch.time) || (detailsPayload && detailsPayload.time) || null;
  const scoreStatus = stabilizeMatchStatus(preferredStatus, {
    date: kickoffDate,
    time: kickoffTime,
    hasScore: homeScore !== null && awayScore !== null,
    nowMs,
  });

  return {
    home_score: homeScore,
    away_score: awayScore,
    aggregate_home_score:
      detailsAggregate.home !== null ? detailsAggregate.home : listAggregate.home,
    aggregate_away_score:
      detailsAggregate.away !== null ? detailsAggregate.away : listAggregate.away,
    score_status: scoreStatus,
    penalty_result:
      String((detailsPayload && detailsPayload.penalty_result) || "").trim() ||
      String((listMatch && listMatch.penalty_result) || "").trim() ||
      null,
  };
}

function resolveKnownAggregateScores(payload) {
  if (!payload || typeof payload !== "object") {
    return { home: null, away: null };
  }

  const aggregateHomeScore = parseNumericScore(payload.aggregate_home_score);
  const aggregateAwayScore = parseNumericScore(payload.aggregate_away_score);
  if (aggregateHomeScore !== null && aggregateAwayScore !== null) {
    return { home: aggregateHomeScore, away: aggregateAwayScore };
  }

  const firstLegHomeScore = parseNumericScore(payload.first_leg_home_score);
  const firstLegAwayScore = parseNumericScore(payload.first_leg_away_score);
  if (firstLegHomeScore === null || firstLegAwayScore === null) {
    return { home: aggregateHomeScore, away: aggregateAwayScore };
  }

  const homeScore = parseNumericScore(payload.home_score);
  const awayScore = parseNumericScore(payload.away_score);
  if (homeScore !== null && awayScore !== null) {
    return {
      home: firstLegHomeScore + homeScore,
      away: firstLegAwayScore + awayScore,
    };
  }

  return { home: firstLegHomeScore, away: firstLegAwayScore };
}

function normalizeMatchDetailsPayload(match, options = {}) {
  if (!match || typeof match !== "object") return null;
  const detailsUrl = String(match.details_url || "").trim();
  if (!detailsUrl) return null;
  const detailsId = matchDetailsIdFromUrl(detailsUrl);
  if (!detailsId) return null;

  const homeTeam = String(match.home_team || "").trim();
  const awayTeam = String(match.away_team || "").trim();
  if (!homeTeam || !awayTeam) return null;

  const date = isDateOnly(match.date) ? String(match.date).trim() : null;
  const time = TIME_ONLY_PATTERN.test(String(match.time || "").trim())
    ? String(match.time).trim()
    : null;
  const league = String(match.league || "").trim() || null;
  const leagueSubcategory = String(match.league_subcategory || "").trim() || null;
  const homeScore = parseNumericScore(match.home_score);
  const awayScore = parseNumericScore(match.away_score);
  const aggregateHomeScore = parseNumericScore(match.aggregate_home_score);
  const aggregateAwayScore = parseNumericScore(match.aggregate_away_score);
  const scoreStatus = resolveStableMatchScoreStatus(match, {
    nowMs: options.nowMs,
  });

  const payload = {
    id: detailsId,
    details_url: detailsUrl,
    date,
    time,
    league,
    league_subcategory: leagueSubcategory,
    home_team: homeTeam,
    away_team: awayTeam,
    home_score: homeScore,
    away_score: awayScore,
    aggregate_home_score: aggregateHomeScore,
    aggregate_away_score: aggregateAwayScore,
    score_status: scoreStatus,
    in_progress: isInProgressMatchStatus(scoreStatus),
  };

  MATCH_DETAILS_EVENT_FIELDS.forEach((field) => {
    payload[field] = Array.isArray(match[field]) ? match[field] : [];
  });

  const penaltyResult = String(match.penalty_result || "").trim();
  if (penaltyResult) {
    payload.penalty_result = penaltyResult;
  }

  const teamLineups = normalizeTeamLineupsPayload(match.team_lineups);
  if (teamLineups) {
    payload.team_lineups = teamLineups;
  }

  return payload;
}

function mergeMatchDetailsPayload(existing, incoming, updatedAtIso) {
  const incomingClearsScoreState = hasExplicitNoScoreState(incoming);
  const incomingPostponedNoScoreState = hasPostponedNoScoreState(incoming);
  const existingAggregate = resolveKnownAggregateScores(existing);
  const incomingAggregate = resolveKnownAggregateScores(incoming);
  const merged = {
    ...(existing || {}),
    ...incoming,
    id: incoming.id,
    details_url: incoming.details_url || (existing ? existing.details_url : null),
    date: incoming.date || (existing ? existing.date : null),
    time: incoming.time || (existing ? existing.time : null),
    league: incoming.league || (existing ? existing.league : null),
    league_subcategory:
      incoming.league_subcategory || (existing ? existing.league_subcategory : null),
    home_team: incoming.home_team || (existing ? existing.home_team : null),
    away_team: incoming.away_team || (existing ? existing.away_team : null),
    updated_at: updatedAtIso,
  };

  if (incomingClearsScoreState || incomingPostponedNoScoreState) {
    merged.home_score = null;
  } else if (incoming.home_score !== null && incoming.home_score !== undefined) {
    merged.home_score = incoming.home_score;
  } else if (existing && existing.home_score !== undefined) {
    merged.home_score = existing.home_score;
  } else {
    merged.home_score = null;
  }

  if (incomingClearsScoreState || incomingPostponedNoScoreState) {
    merged.away_score = null;
  } else if (incoming.away_score !== null && incoming.away_score !== undefined) {
    merged.away_score = incoming.away_score;
  } else if (existing && existing.away_score !== undefined) {
    merged.away_score = existing.away_score;
  } else {
    merged.away_score = null;
  }

  if (incomingClearsScoreState || incomingPostponedNoScoreState) {
    merged.aggregate_home_score =
      incomingAggregate.home !== null ? incomingAggregate.home : existingAggregate.home;
  } else if (incomingAggregate.home !== null && incomingAggregate.away !== null) {
    merged.aggregate_home_score = incomingAggregate.home;
  } else if (existingAggregate.home !== null && existingAggregate.away !== null) {
    merged.aggregate_home_score = existingAggregate.home;
  } else {
    merged.aggregate_home_score = null;
  }

  if (incomingClearsScoreState || incomingPostponedNoScoreState) {
    merged.aggregate_away_score =
      incomingAggregate.away !== null ? incomingAggregate.away : existingAggregate.away;
  } else if (incomingAggregate.home !== null && incomingAggregate.away !== null) {
    merged.aggregate_away_score = incomingAggregate.away;
  } else if (existingAggregate.home !== null && existingAggregate.away !== null) {
    merged.aggregate_away_score = existingAggregate.away;
  } else {
    merged.aggregate_away_score = null;
  }

  merged.score_status = incomingClearsScoreState
    ? null
    : incomingPostponedNoScoreState
      ? "POSTPONED"
      : pickPreferredMatchStatus(
      existing && existing.score_status !== undefined ? existing.score_status : null,
      incoming && incoming.score_status !== undefined ? incoming.score_status : null,
      {
        preferIncomingOnTie: true,
        allowTerminalRegression: true,
      }
    );

  MATCH_DETAILS_EVENT_FIELDS.forEach((field) => {
    const incomingValue = incoming[field];
    if (Array.isArray(incomingValue)) {
      merged[field] = incomingValue;
      return;
    }
    if (Array.isArray(existing && existing[field])) {
      merged[field] = existing[field];
      return;
    }
    merged[field] = Array.isArray(incomingValue) ? incomingValue : [];
  });

  if (incoming.penalty_result) {
    merged.penalty_result = incoming.penalty_result;
  } else if (incomingClearsScoreState || incomingPostponedNoScoreState) {
    merged.penalty_result = null;
  } else if (existing && existing.penalty_result) {
    merged.penalty_result = existing.penalty_result;
  }

  const incomingTeamLineups = normalizeTeamLineupsPayload(incoming && incoming.team_lineups);
  const existingTeamLineups = normalizeTeamLineupsPayload(existing && existing.team_lineups);
  if (incomingTeamLineups) {
    merged.team_lineups = incomingTeamLineups;
  } else if (existingTeamLineups) {
    merged.team_lineups = existingTeamLineups;
  }

  // If we have a penalty result (shootout complete) and status is "Pens", change to "AET"
  // The JSON data often has "Pens" status, but the HTML shows "AET" when complete
  if (merged.penalty_result && (merged.score_status === "Pens" || merged.score_status === "PEN" || merged.score_status === "PEN.")) {
    merged.score_status = "AET";
  }

  merged.in_progress = isInProgressMatchStatus(merged.score_status);

  // For knockout second legs, BBC shows only the first-leg aggregate (e.g. "(Agg 1-1)") before
  // the match starts, then switches to the running total (e.g. "(Agg 3-2)") during play.
  // Capture the first-leg result once when we first see an aggregate on a pre-kickoff match
  // so the match monitor can compute a real-time aggregate (first_leg + current_score) in
  // notifications rather than relying on the BBC-cached running total, which can lag goals.
  const existingFirstLegHome =
    existing && existing.first_leg_home_score != null ? existing.first_leg_home_score : null;
  if (existingFirstLegHome !== null) {
    // Already captured — preserve it regardless of later updates
    merged.first_leg_home_score = existingFirstLegHome;
    merged.first_leg_away_score = existing.first_leg_away_score;
  } else if (
    !merged.in_progress &&
    !isFinishedMatchStatus(merged.score_status) &&
    merged.home_score === null &&
    merged.away_score === null &&
    merged.aggregate_home_score !== null &&
    merged.aggregate_away_score !== null
  ) {
    // Pre-kickoff: the aggregate IS the first-leg result — capture it now
    merged.first_leg_home_score = merged.aggregate_home_score;
    merged.first_leg_away_score = merged.aggregate_away_score;
  }

  return merged;
}

function upsertMatchDetailsFromMatch(match, updatedAtIso = new Date().toISOString()) {
  const incoming = normalizeMatchDetailsPayload(match);
  if (!incoming) return null;
  const existing = matchDetailsById.get(incoming.id);
  const merged = mergeMatchDetailsPayload(existing, incoming, updatedAtIso);
  matchDetailsById.set(incoming.id, merged);
  return incoming.id;
}

function countGoalsFromScorers(goalScorers) {
  if (!Array.isArray(goalScorers)) return 0;
  return goalScorers.reduce((total, scorer) => {
    const goalTimes = Array.isArray(scorer && scorer.goal_times) ? scorer.goal_times.length : 0;
    const ownGoalTimes = Array.isArray(scorer && scorer.own_goal_times)
      ? scorer.own_goal_times.length
      : 0;
    return total + goalTimes + ownGoalTimes;
  }, 0);
}

function matchDetailsNeedsEnrichment(payload) {
  if (!payload || typeof payload !== "object") return false;
  const homeScore = parseNumericScore(payload.home_score);
  const awayScore = parseNumericScore(payload.away_score);
  const totalScore =
    (homeScore !== null ? homeScore : 0) + (awayScore !== null ? awayScore : 0);
  const recordedGoals =
    countGoalsFromScorers(payload.home_goal_scorers) +
    countGoalsFromScorers(payload.away_goal_scorers);
  if (totalScore <= 0) return false;
  return recordedGoals < totalScore;
}

function matchDetailsMissingCoreMetadata(payload) {
  if (!payload || typeof payload !== "object") return false;
  if (!payload.details_url) return false;

  const hasDate = isDateOnly(String(payload.date || "").trim());
  const hasTime = TIME_ONLY_PATTERN.test(String(payload.time || "").trim());
  const hasLeague = String(payload.league || "").trim().length > 0;
  const hasHomeTeam = String(payload.home_team || "").trim().length > 0;
  const hasAwayTeam = String(payload.away_team || "").trim().length > 0;

  return !hasDate || !hasTime || !hasLeague || !hasHomeTeam || !hasAwayTeam;
}

function matchDetailsHasMalformedCompetitionMetadata(payload) {
  if (!payload || typeof payload !== "object") return false;
  if (!payload.details_url) return false;

  const league = String(payload.league || "").trim();
  if (!league) return false;

  return /\s*[-–—]\s*$/.test(league);
}

function matchDetailsMissingTeamLineups(payload) {
  if (!payload || typeof payload !== "object") return false;
  if (!payload.details_url) return false;
  return !hasCompleteTeamLineups(payload.team_lineups);
}

function matchDetailsHasStaleInProgressStatus(payload, nowMs = Date.now()) {
  if (!payload || typeof payload !== "object") return false;

  const scoreStatus = resolveStableMatchScoreStatus(payload, { nowMs });
  const statusMinute = parseMatchStatusMinute(scoreStatus);
  if (statusMinute === null || statusMinute < MATCH_DETAILS_STALE_MINUTE_THRESHOLD) {
    return false;
  }

  const inProgressFlag = isInProgressMatchStatus(scoreStatus);
  if (!inProgressFlag) return false;

  const updatedAtMs = Date.parse(String(payload.updated_at || "").trim());
  if (!Number.isFinite(updatedAtMs)) return true;
  if (nowMs <= updatedAtMs) return false;
  return nowMs - updatedAtMs >= MATCH_DETAILS_STALE_IN_PROGRESS_MS;
}

const TWO_LEG_KNOCKOUT_SUBCATEGORY_PATTERNS = [
  /\bLast\s+\d+\b/i,
  /\bRound\s+of\s+\d+\b/i,
  /\bQuarter[- ]Finals?\b/i,
  /\bSemi[- ]Finals?\b/i,
  /\bPlay-?Offs?\b/i,
  /\bQualifying\b/i,
  /\bQualification\b/i,
  /\bPreliminary\s+Round\b/i,
  /\b(?:First|Second|1st|2nd)\s+Leg\b/i,
];

function isLikelyTwoLegKnockoutSubcategory(value) {
  const normalized = String(value || "").trim();
  if (!normalized) return false;
  return TWO_LEG_KNOCKOUT_SUBCATEGORY_PATTERNS.some((pattern) => pattern.test(normalized));
}

function matchDetailsMissingKnockoutAggregate(payload, nowMs = Date.now()) {
  if (!payload || typeof payload !== "object") return false;
  const subcategory = String(payload.league_subcategory || "").trim();
  if (!isLikelyTwoLegKnockoutSubcategory(subcategory)) return false;
  const aggHome = parseNumericScore(payload.aggregate_home_score);
  const aggAway = parseNumericScore(payload.aggregate_away_score);
  if (aggHome !== null && aggAway !== null) return false;
  const effectiveNowMs = Number.isFinite(nowMs) ? Number(nowMs) : Date.now();
  const matchDay = parseMatchDayLocal(payload.date);
  if (matchDay) {
    const matchDayStartMs = matchDay.getTime();
    if (Number.isFinite(matchDayStartMs)) {
      const matchDayEndMs = matchDayStartMs + 24 * 60 * 60 * 1000;
      if (effectiveNowMs >= matchDayStartMs && effectiveNowMs < matchDayEndMs) {
        return true;
      }
    }
  }
  const kickoffMs = kickoffTimestampMs(payload);
  if (!Number.isFinite(kickoffMs)) return false;
  return (
    effectiveNowMs >= kickoffMs - 12 * 60 * 60 * 1000 &&
    effectiveNowMs <= kickoffMs + 2 * 60 * 60 * 1000
  );
}

function matchDetailsNeedsBackfill(payload, nowMs = Date.now()) {
  if (!payload || typeof payload !== "object") return false;
  if (!payload.details_url) return false;
  return (
    matchDetailsMissingCoreMetadata(payload) ||
    matchDetailsMissingTeamLineups(payload) ||
    matchDetailsHasMalformedCompetitionMetadata(payload) ||
    matchDetailsNeedsEnrichment(payload) ||
    matchDetailsHasStaleInProgressStatus(payload, nowMs) ||
    matchDetailsMissingKnockoutAggregate(payload, nowMs)
  );
}

async function enrichMatchDetailsAggregateImmediately(seedPayload, options = {}) {
  const payload = seedPayload && typeof seedPayload === "object" ? seedPayload : null;
  const nowMs =
    options && Number.isFinite(options.nowMs) ? Number(options.nowMs) : Date.now();
  if (!payload || !matchDetailsMissingKnockoutAggregate(payload, nowMs)) {
    return payload;
  }

  const detailsUrl = String(payload.details_url || "").trim();
  if (!detailsUrl) return payload;

  const fetchMatchByDetailsUrl =
    options && typeof options.fetchMatchByDetailsUrl === "function"
      ? options.fetchMatchByDetailsUrl
      : fetchBbcMatchByDetailsUrl;
  const persistFn =
    options && typeof options.persistOperationalMatchDetailsSafe === "function"
      ? options.persistOperationalMatchDetailsSafe
      : persistOperationalMatchDetailsSafe;
  const nowIso =
    options && typeof options.nowIso === "string" && options.nowIso.trim()
      ? options.nowIso.trim()
      : new Date().toISOString();
  const persistSource =
    options && typeof options.persistSource === "string" && options.persistSource.trim()
      ? options.persistSource.trim()
      : "request_knockout_aggregate_enrichment";

  try {
    const fetched = await fetchMatchByDetailsUrl(detailsUrl);
    if (!fetched) return payload;

    const combined = buildMergedMatchDetailsCandidate(payload, fetched, detailsUrl);
    const upsertedMatchId = upsertMatchDetailsFromMatch(combined, nowIso);
    const updatedPayload = upsertedMatchId ? matchDetailsById.get(upsertedMatchId) || null : null;
    if (upsertedMatchId && updatedPayload) {
      await persistFn(
        { [upsertedMatchId]: updatedPayload },
        {
          replace: false,
          updated_at: nowIso,
          source: persistSource,
        }
      );
      await persistLiveActivityMatchTimelineSnapshotsSafe(
        { [upsertedMatchId]: updatedPayload },
        {
          updated_at: nowIso,
          observed_at_ms: Date.parse(nowIso),
          source: persistSource,
        }
      );
      return updatedPayload;
    }
  } catch (error) {
    console.warn(
      `[API] Immediate aggregate enrichment failed for ${detailsUrl}:`,
      error.message || error
    );
  }

  return payload;
}

async function enrichKnockoutAggregatesForListMatches(matches, matchDetailsLookup, options = {}) {
  const list = Array.isArray(matches) ? matches : [];
  if (list.length === 0) return { lookup: matchDetailsLookup || {}, enrichedCount: 0 };

  const lookup =
    matchDetailsLookup instanceof Map
      ? new Map(matchDetailsLookup)
      : matchDetailsLookup && typeof matchDetailsLookup === "object"
        ? { ...matchDetailsLookup }
        : {};
  const candidates = [];
  const seenIds = new Set();

  list.forEach((match) => {
    const normalized = normalizeMatchRecord(match);
    if (!normalized) return;
    const detailsId =
      matchDetailsIdFromUrl(normalized.details_url) ||
      normalizeMatchDetailsId(normalized.match_details_id);
    if (!detailsId || seenIds.has(detailsId)) return;
    const existingPayload = getMatchDetailsLookupEntry(lookup, detailsId);
    const seedPayload = existingPayload || buildFallbackMatchDetailsPayload(detailsId, normalized);
    const nowMs =
      options && Number.isFinite(options.nowMs) ? Number(options.nowMs) : Date.now();
    if (!seedPayload || !matchDetailsMissingKnockoutAggregate(seedPayload, nowMs)) return;
    seenIds.add(detailsId);
    candidates.push({ detailsId, seedPayload });
  });

  if (candidates.length === 0) {
    return { lookup, enrichedCount: 0 };
  }

  let enrichedCount = 0;
  for (const candidate of candidates) {
    // eslint-disable-next-line no-await-in-loop
    const enrichedPayload = await enrichMatchDetailsAggregateImmediately(candidate.seedPayload, {
      ...options,
      persistSource: "matches_list_request_knockout_aggregate_enrichment",
    });
    if (!enrichedPayload || !enrichedPayload.id) continue;
    if (lookup instanceof Map) {
      lookup.set(candidate.detailsId, enrichedPayload);
    } else {
      lookup[candidate.detailsId] = enrichedPayload;
    }
    const aggHome = parseNumericScore(enrichedPayload.aggregate_home_score);
    const aggAway = parseNumericScore(enrichedPayload.aggregate_away_score);
    if (aggHome !== null && aggAway !== null) {
      enrichedCount += 1;
    }
  }

  return { lookup, enrichedCount };
}

function matchDetailsBackfillCooldownMs(payload, reason = "success") {
  if (reason === "failure") return MATCH_DETAILS_BACKFILL_FAILURE_COOLDOWN_MS;
  const isInProgress =
    payload && payload.in_progress !== undefined
      ? Boolean(payload.in_progress)
      : isInProgressMatchStatus(resolveMatchScoreStatus(payload));
  return isInProgress
    ? MATCH_DETAILS_BACKFILL_COOLDOWN_MS
    : MATCH_DETAILS_BACKFILL_IDLE_COOLDOWN_MS;
}

function scheduleMatchDetailsBackfill(payload, options = {}) {
  if (!payload || typeof payload !== "object") return false;

  const matchId = normalizeMatchDetailsId(payload.id);
  if (!matchId || !payload.details_url) return false;

  const nowMs = Date.now();
  const nextAllowedAt = matchDetailsBackfillNextAttemptAt.get(matchId) || 0;
  if (matchDetailsBackfillTasks.has(matchId) || nextAllowedAt > nowMs) return false;
  if (!matchDetailsNeedsBackfill(payload, nowMs)) return false;

  const trigger = options && options.trigger ? String(options.trigger) : "request";
  matchDetailsBackfillNextAttemptAt.set(
    matchId,
    nowMs + MATCH_DETAILS_BACKFILL_IN_FLIGHT_COOLDOWN_MS
  );

  const task = (async () => {
    try {
      const fetched = await fetchBbcMatchByDetailsUrl(payload.details_url);
      if (!fetched) {
        matchDetailsBackfillNextAttemptAt.set(
          matchId,
          Date.now() + MATCH_DETAILS_BACKFILL_FAILURE_COOLDOWN_MS
        );
        return;
      }

      const nowIso = new Date().toISOString();
      const currentPayload = matchDetailsById.get(matchId) || payload;
      const combined = buildMergedMatchDetailsCandidate(
        currentPayload,
        fetched,
        payload.details_url
      );
      const upsertedMatchId = upsertMatchDetailsFromMatch(combined, nowIso);
      const updatedPayload = upsertedMatchId ? matchDetailsById.get(upsertedMatchId) : null;
      if (upsertedMatchId && updatedPayload) {
        await persistOperationalMatchDetailsSafe(
          {
            [upsertedMatchId]: updatedPayload,
          },
          {
            replace: false,
            updated_at: nowIso,
            source: `async_match_details_backfill:${trigger}`,
          }
        );
        await persistLiveActivityMatchTimelineSnapshotsSafe(
          {
            [upsertedMatchId]: updatedPayload,
          },
          {
            updated_at: nowIso,
            observed_at_ms: Date.parse(nowIso),
            source: `async_match_details_backfill:${trigger}`,
          }
        );
      }

      if (updatedPayload && matchDetailsNeedsBackfill(updatedPayload)) {
        matchDetailsBackfillNextAttemptAt.set(
          matchId,
          Date.now() + matchDetailsBackfillCooldownMs(updatedPayload, "success")
        );
      } else {
        matchDetailsBackfillNextAttemptAt.delete(matchId);
      }
    } catch (error) {
      matchDetailsBackfillNextAttemptAt.set(
        matchId,
        Date.now() + MATCH_DETAILS_BACKFILL_FAILURE_COOLDOWN_MS
      );
      console.warn(
        `Failed to asynchronously backfill match details for ${matchId}:`,
        error.message || error
      );
    } finally {
      matchDetailsBackfillTasks.delete(matchId);
    }
  })();

  matchDetailsBackfillTasks.set(matchId, task);
  return true;
}

function buildMergedMatchDetailsCandidate(seedMatch, fetchedMatch, detailsUrl) {
  const seed = seedMatch && typeof seedMatch === "object" ? seedMatch : {};
  const fetched = fetchedMatch && typeof fetchedMatch === "object" ? fetchedMatch : {};

  const combined = {
    ...seed,
    ...fetched,
  };

  if (detailsUrl) {
    combined.details_url = detailsUrl;
  }

  const preferredStatus = pickPreferredMatchStatus(
    seed.score_status || seed.match_time,
    fetched.score_status || fetched.match_time,
    {
      preferIncomingOnTie: true,
      allowTerminalRegression: true,
    }
  );
  if (preferredStatus) {
    combined.score_status = preferredStatus;
  }

  return combined;
}

function indexMatchDetailsFromMatches(matches, updatedAtIso = new Date().toISOString()) {
  if (!Array.isArray(matches) || matches.length === 0) return 0;
  let inserted = 0;
  matches.forEach((match) => {
    if (upsertMatchDetailsFromMatch(match, updatedAtIso)) {
      inserted += 1;
    }
  });
  if (inserted > 0) {
    matchDetailsLastUpdated = updatedAtIso;
  }
  return inserted;
}

function collectMatchDetailsSubsetByMatches(matches) {
  const subset = {};
  (Array.isArray(matches) ? matches : []).forEach((match) => {
    const detailsId =
      matchDetailsIdFromUrl(match && match.details_url) ||
      normalizeMatchDetailsId(match && match.match_details_id);
    if (!detailsId) return;
    const payload = matchDetailsById.get(detailsId);
    if (payload && typeof payload === "object") {
      subset[detailsId] = payload;
    }
  });
  return subset;
}

async function rebuildMatchDetailsCache(source = "match_details_rebuild") {
  const nowIso = new Date().toISOString();
  indexMatchDetailsFromMatches(cachedMergedMatches, nowIso);
  indexMatchDetailsFromMatches(cachedBbcMatches, nowIso);
  indexMatchDetailsFromMatches(cachedRecentMatches, nowIso);
  matchDetailsLastUpdated = nowIso;
  setSourceCacheSize(SOURCE_BBC_MATCH_DETAILS, matchDetailsById.size);
  await persistOperationalMatchDetailsSafe(Object.fromEntries(matchDetailsById), {
    replace: true,
    updated_at: nowIso,
    source,
  });
}

function collectInProgressMatchDetailTargets() {
  const nowMs = Date.now();
  pruneInactiveMatchDetailsRefreshEntries(nowMs);
  if (matchDetailsActiveRefreshUntilById.size === 0) return [];

  const targets = new Map();
  const upsertTarget = (detailsPayload) => {
    const stablePayload = withStableMatchDetailsState(detailsPayload);
    if (!stablePayload || typeof stablePayload !== "object") return;

    const detailsId = normalizeMatchDetailsId(stablePayload.id);
    if (!detailsId) return;
    if (!isMatchDetailsActive(detailsId, nowMs)) return;

    const detailsUrl = String(stablePayload.details_url || "").trim();
    if (!detailsUrl) return;

    const isInProgress = Boolean(stablePayload.in_progress);
    if (!isInProgress) {
      targets.delete(detailsId);
      return;
    }

    const existing = targets.get(detailsId);
    const mergedSeedMatch = existing && existing.seed_match
      ? { ...existing.seed_match, ...stablePayload }
      : { ...stablePayload };

    const preferredStatus = pickPreferredMatchStatus(
      existing && existing.seed_match ? existing.seed_match.score_status : null,
      stablePayload.score_status,
      { preferIncomingOnTie: true }
    );
    if (preferredStatus) {
      mergedSeedMatch.score_status = preferredStatus;
    }

    mergedSeedMatch.id = detailsId;
    mergedSeedMatch.details_url = detailsUrl;
    mergedSeedMatch.in_progress =
      isInProgressMatchStatus(mergedSeedMatch.score_status) || Boolean(mergedSeedMatch.in_progress);

    targets.set(detailsId, {
      id: detailsId,
      details_url: detailsUrl,
      seed_match: mergedSeedMatch,
    });
  };

  matchDetailsById.forEach((payload, matchId) => {
    if (!payload || typeof payload !== "object") return;
    const normalizedId = normalizeMatchDetailsId(payload.id || matchId);
    if (!normalizedId) return;
    upsertTarget({
      ...withStableMatchDetailsState(payload),
      id: normalizedId,
    });
  });

  return Array.from(targets.values());
}

async function refreshInProgressMatchDetails(options = {}) {
  if (matchDetailsUpdating) return;
  matchDetailsUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = 0;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_BBC_MATCH_DETAILS, {
    trigger,
    poll_interval_ms: MATCH_DETAILS_POLL_INTERVAL_MS,
  });

  try {
    const targets = collectInProgressMatchDetailTargets();
    if (targets.length === 0) {
      success = true;
      logPollSuccess("bbc_match_details", {
        source: SOURCE_BBC_MATCH_DETAILS,
        trigger,
        targets: 0,
        refreshed: 0,
        in_progress_cache_size: matchDetailsById.size,
        note: "no_in_progress_matches",
      });
      return;
    }
    const nowIso = new Date().toISOString();
    const refreshedDetailsIds = new Set();

    await mapWithConcurrency(
      targets,
      MATCH_DETAILS_POLL_CONCURRENCY,
      async (target) => {
        try {
          const fetched = await fetchBbcMatchByDetailsUrl(target.details_url);
          if (!fetched) return;
          const combined = buildMergedMatchDetailsCandidate(
            target.seed_match,
            fetched,
            target.details_url
          );
          const detailsId = upsertMatchDetailsFromMatch(combined, nowIso);
          if (detailsId) refreshedDetailsIds.add(detailsId);
        } catch (err) {
          console.warn(
            `Failed to refresh match details for ${target.details_url}:`,
            err.message || err
          );
        }
      }
    );

    recordsFetched = targets.length;
    success = true;
    matchDetailsLastUpdated = nowIso;
    setSourceCacheSize(SOURCE_BBC_MATCH_DETAILS, matchDetailsById.size);
    const updatedDetailsSubset = {};
    refreshedDetailsIds.forEach((detailsId) => {
      const payload = matchDetailsById.get(detailsId);
      if (payload && typeof payload === "object") {
        updatedDetailsSubset[detailsId] = payload;
      }
    });
    if (Object.keys(updatedDetailsSubset).length > 0) {
      await persistOperationalMatchDetailsSafe(updatedDetailsSubset, {
        replace: false,
        updated_at: nowIso,
        source: SOURCE_BBC_MATCH_DETAILS,
      });
      await persistLiveActivityMatchTimelineSnapshotsSafe(updatedDetailsSubset, {
        updated_at: nowIso,
        observed_at_ms: Date.parse(nowIso),
        source: SOURCE_BBC_MATCH_DETAILS,
      });
    }
    logPollSuccess("bbc_match_details", {
      source: SOURCE_BBC_MATCH_DETAILS,
      trigger,
      targets: targets.length,
      refreshed: refreshedDetailsIds.size,
      updated_at: nowIso,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_BBC_MATCH_DETAILS, {
      trigger,
      targets: targets.length,
      refreshed: refreshedDetailsIds.size,
      updated_at: nowIso,
      poll_interval_ms: MATCH_DETAILS_POLL_INTERVAL_MS,
    });
  } catch (err) {
    recordRuntimeComponentFailure(COMPONENT_SOURCE_BBC_MATCH_DETAILS, err, {
      trigger,
      poll_interval_ms: MATCH_DETAILS_POLL_INTERVAL_MS,
    });
    console.warn("Failed to refresh in-progress match details:", err.message || err);
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_BBC_MATCH_DETAILS,
      startedAtMs,
      success,
      recordsFetched,
    });
    matchDetailsUpdating = false;
  }
}

function normalizeMatchRecord(match) {
  if (!match || typeof match !== "object") return null;
  const date = String(match.date || "").trim();
  if (!isDateOnly(date)) return null;
  const home = String(match.home_team || "").trim();
  const away = String(match.away_team || "").trim();
  if (!home || !away) return null;

  const record = {
    date,
    time: normalizeTimeValue(match.time),
    league: normalizeLeagueName(match.league || "") || "",
    home_team: home,
    away_team: away,
    tv_channels: uniqueChannels(match.tv_channels),
  };

  if (match.league_subcategory) {
    record.league_subcategory = String(match.league_subcategory).trim();
  }

  const homeScore = parseNumericScore(match.home_score);
  const awayScore = parseNumericScore(match.away_score);
  if (homeScore !== null && awayScore !== null) {
    record.home_score = homeScore;
    record.away_score = awayScore;
  }

  const aggregateHomeScore = parseNumericScore(match.aggregate_home_score);
  const aggregateAwayScore = parseNumericScore(match.aggregate_away_score);
  if (aggregateHomeScore !== null && aggregateAwayScore !== null) {
    record.aggregate_home_score = aggregateHomeScore;
    record.aggregate_away_score = aggregateAwayScore;
  }

  const scoreStatus = String(match.score_status || match.match_time || "").trim();
  if (scoreStatus) {
    record.score_status = scoreStatus;
  }

  if (match.details_url) {
    record.details_url = String(match.details_url);
  }

  if (match.match_details_id) {
    record.match_details_id = String(match.match_details_id);
  }

  if (match.has_bbc_source === true) {
    record.has_bbc_source = true;
  }

  [
    "home_goal_scorers",
    "away_goal_scorers",
    "home_assists",
    "away_assists",
    "home_yellow_cards",
    "away_yellow_cards",
    "home_red_cards",
    "away_red_cards",
  ].forEach((field) => {
    if (Array.isArray(match[field])) record[field] = match[field];
  });

  const penaltyResult = String(match.penalty_result || "").trim();
  if (penaltyResult) {
    record.penalty_result = penaltyResult;
  }

  const teamLineups = normalizeTeamLineupsPayload(match.team_lineups);
  if (teamLineups) {
    record.team_lineups = teamLineups;
  }

  return record;
}

function normalizeTeamIdentity(value) {
  return normalizeTeamName(value).replace(/\s+/g, " ").trim();
}

function normalizeLeagueIdentity(value) {
  return normalizeLeagueName(value || "").toLowerCase().trim();
}

function normalizeLookupDateValue(value) {
  const date = String(value || "").trim();
  return isDateOnly(date) ? date : null;
}

function normalizeLookupTimeValue(value) {
  const trimmed = String(value || "").trim();
  if (!trimmed) return null;
  return TIME_ONLY_PATTERN.test(trimmed) ? normalizeTimeValue(trimmed) : null;
}

function parseLookupTimeMinutes(value) {
  const normalized = normalizeLookupTimeValue(value);
  if (!normalized) return null;
  const [hours, minutes] = normalized.split(":").map((part) => Number(part));
  if (!Number.isFinite(hours) || !Number.isFinite(minutes)) return null;
  return (hours * 60) + minutes;
}

function isComparableLookupTime(lhs, rhs) {
  if (!lhs || !rhs) return true;
  if (lhs === rhs || lhs === "00:00" || rhs === "00:00") return true;

  const leftMinutes = parseLookupTimeMinutes(lhs);
  const rightMinutes = parseLookupTimeMinutes(rhs);
  if (!Number.isFinite(leftMinutes) || !Number.isFinite(rightMinutes)) {
    return false;
  }

  return Math.abs(leftMinutes - rightMinutes) <= 120;
}

function buildMatchDetailsIdentityIndex(matchDetailsLookup) {
  const byExact = new Map();
  const byTeams = new Map();
  const entries =
    matchDetailsLookup instanceof Map
      ? Array.from(matchDetailsLookup.entries())
      : Object.entries(matchDetailsLookup || {});

  entries.forEach(([lookupKey, value]) => {
    if (!value || typeof value !== "object") return;
    const detailsId = normalizeMatchDetailsId(value.id || lookupKey);
    if (!detailsId) return;

    const home = normalizeTeamIdentity(value.home_team);
    const away = normalizeTeamIdentity(value.away_team);
    if (!home || !away) return;

    const date = normalizeLookupDateValue(value.date);
    const time = normalizeLookupTimeValue(value.time);
    const league = normalizeLeagueIdentity(value.league);
    const teamKey = `${home}|${away}`;
    const candidate = {
      id: detailsId,
      home,
      away,
      date,
      time,
      league,
      payload: value,
    };

    if (!byTeams.has(teamKey)) byTeams.set(teamKey, []);
    byTeams.get(teamKey).push(candidate);

    if (date) {
      const exactKey = `${date}|${time || "00:00"}|${league}|${teamKey}`;
      if (!byExact.has(exactKey)) byExact.set(exactKey, []);
      byExact.get(exactKey).push(candidate);
    }
  });

  return { byExact, byTeams };
}

function isCompatibleMatchDetailsCandidate(candidate, normalizedMatch) {
  if (!candidate || !normalizedMatch) return false;

  if (candidate.date && candidate.date !== normalizedMatch.date) {
    return false;
  }

  const matchTime = normalizeLookupTimeValue(normalizedMatch.time) || "00:00";
  if (candidate.time && !isComparableLookupTime(candidate.time, matchTime)) {
    return false;
  }

  const matchLeague = normalizeLeagueIdentity(normalizedMatch.league);
  if (candidate.league && matchLeague && candidate.league !== matchLeague) {
    const normalizedHome = normalizeTeamIdentity(normalizedMatch.home_team);
    const normalizedAway = normalizeTeamIdentity(normalizedMatch.away_team);
    const exactTeamMatch =
      candidate.home === normalizedHome && candidate.away === normalizedAway;
    const exactDateMatch = candidate.date === normalizedMatch.date;
    const comparableTimeMatch = isComparableLookupTime(candidate.time, matchTime);
    if (!(exactTeamMatch && exactDateMatch && comparableTimeMatch)) {
      return false;
    }
  }

  return true;
}

function scoreMatchDetailsCandidate(candidate, normalizedMatch) {
  const matchTime = normalizeLookupTimeValue(normalizedMatch.time) || "00:00";
  const matchLeague = normalizeLeagueIdentity(normalizedMatch.league);
  let score = 0;

  if (candidate.date && candidate.date === normalizedMatch.date) score += 8;
  else if (!candidate.date) score += 1;

  if (candidate.time && candidate.time === matchTime) score += 4;
  else if (candidate.time && isComparableLookupTime(candidate.time, matchTime)) score += 2;
  else if (!candidate.time) score += 1;

  if (candidate.league && matchLeague && candidate.league === matchLeague) score += 4;
  else if (!candidate.league) score += 1;

  const status = normalizeMatchStatusValue(candidate.payload && candidate.payload.score_status);
  if (isInProgressMatchStatus(status)) score += 2;

  return score;
}

function pickBestMatchDetailsCandidate(candidates, normalizedMatch) {
  if (!Array.isArray(candidates) || candidates.length === 0) return null;

  const compatible = candidates.filter((candidate) =>
    isCompatibleMatchDetailsCandidate(candidate, normalizedMatch)
  );
  if (compatible.length === 0) return null;
  if (compatible.length === 1) return compatible[0];

  let best = null;
  let bestScore = -Infinity;
  let bestUpdatedAt = -Infinity;
  let hasAmbiguousBest = false;

  compatible.forEach((candidate) => {
    const score = scoreMatchDetailsCandidate(candidate, normalizedMatch);
    const updatedAtValue = Date.parse(
      String(candidate && candidate.payload && candidate.payload.updated_at ? candidate.payload.updated_at : "")
    );
    const updatedAt = Number.isFinite(updatedAtValue) ? updatedAtValue : -Infinity;

    if (score > bestScore || (score === bestScore && updatedAt > bestUpdatedAt)) {
      best = candidate;
      bestScore = score;
      bestUpdatedAt = updatedAt;
      hasAmbiguousBest = false;
      return;
    }

    if (score === bestScore && updatedAt === bestUpdatedAt) {
      hasAmbiguousBest = true;
    }
  });

  if (hasAmbiguousBest) return null;
  return best;
}

function resolveMatchDetailsIdFromLookup(normalizedMatch, options = {}) {
  if (!normalizedMatch || typeof normalizedMatch !== "object") return null;
  const matchDetailsLookup = options.matchDetailsLookup;
  if (!matchDetailsLookup) return null;

  const home = normalizeTeamIdentity(normalizedMatch.home_team);
  const away = normalizeTeamIdentity(normalizedMatch.away_team);
  if (!home || !away) return null;

  const index = options.matchDetailsIdentityIndex || buildMatchDetailsIdentityIndex(matchDetailsLookup);
  const matchTime = normalizeLookupTimeValue(normalizedMatch.time) || "00:00";
  const matchLeague = normalizeLeagueIdentity(normalizedMatch.league);
  const teamKey = `${home}|${away}`;
  const exactKey = `${normalizedMatch.date}|${matchTime}|${matchLeague}|${teamKey}`;

  const exactMatch = pickBestMatchDetailsCandidate(index.byExact.get(exactKey) || [], normalizedMatch);
  if (exactMatch) return exactMatch.id;

  const teamMatch = pickBestMatchDetailsCandidate(index.byTeams.get(teamKey) || [], normalizedMatch);
  return teamMatch ? teamMatch.id : null;
}

function toMatchListPayload(match, options = {}) {
  const normalized = normalizeMatchRecord(match);
  if (!normalized) return null;

  const matchDetailsLookup =
    options && options.matchDetailsLookup ? options.matchDetailsLookup : null;
  const matchDetailsIdentityIndex =
    options && options.matchDetailsIdentityIndex ? options.matchDetailsIdentityIndex : null;

  const payload = {
    date: normalized.date,
    time: normalized.time,
    league: normalized.league,
    home_team: normalized.home_team,
    away_team: normalized.away_team,
    tv_channels: uniqueChannels(normalized.tv_channels),
  };

  if (normalized.league_subcategory) {
    payload.league_subcategory = normalized.league_subcategory;
  }
  if (normalized.has_bbc_source === true) {
    payload.has_bbc_source = true;
  }

  // Try to get match details ID from details_url or explicit match_details_id field
  let detailsId = matchDetailsIdFromUrl(normalized.details_url);
  if (!detailsId && normalized.match_details_id) {
    // For test matches or matches with explicit match_details_id
    detailsId = normalizeMatchDetailsId(normalized.match_details_id);
  }
  if (!detailsId && matchDetailsLookup) {
    detailsId = resolveMatchDetailsIdFromLookup(normalized, {
      matchDetailsLookup,
      matchDetailsIdentityIndex,
    });
  }
  if (detailsId) {
    payload.match_details_id = detailsId;
  }

  const resolvedState = buildResolvedListMatchState(
    normalized,
    getMatchDetailsLookupEntry(matchDetailsLookup, detailsId),
    Number.isFinite(options.nowMs) ? options.nowMs : Date.now()
  );

  if (resolvedState.home_score !== null && resolvedState.away_score !== null) {
    payload.home_score = resolvedState.home_score;
    payload.away_score = resolvedState.away_score;
  }
  if (
    resolvedState.aggregate_home_score !== null &&
    resolvedState.aggregate_away_score !== null
  ) {
    payload.aggregate_home_score = resolvedState.aggregate_home_score;
    payload.aggregate_away_score = resolvedState.aggregate_away_score;
  }
  if (resolvedState.score_status) {
    payload.score_status = resolvedState.score_status;
  }
  if (resolvedState.penalty_result) {
    payload.penalty_result = resolvedState.penalty_result;
  }

  return payload;
}

function monitorCandidateSortAsc(lhs, rhs) {
  const lhsDate = String(lhs && lhs.date ? lhs.date : "").trim();
  const rhsDate = String(rhs && rhs.date ? rhs.date : "").trim();
  const dateCompare = lhsDate.localeCompare(rhsDate);
  if (dateCompare !== 0) return dateCompare;

  const lhsTime = normalizeTimeValue(lhs && lhs.time ? lhs.time : null);
  const rhsTime = normalizeTimeValue(rhs && rhs.time ? rhs.time : null);
  const timeCompare = lhsTime.localeCompare(rhsTime);
  if (timeCompare !== 0) return timeCompare;

  const lhsId = String(lhs && lhs.match_details_id ? lhs.match_details_id : "");
  const rhsId = String(rhs && rhs.match_details_id ? rhs.match_details_id : "");
  return lhsId.localeCompare(rhsId);
}

function toMonitorCandidateFromDetailsPayload(payload, options = {}) {
  if (!payload || typeof payload !== "object") return null;
  const matchId = normalizeMatchDetailsId(payload.id);
  if (!matchId) return null;

  const date = isDateOnly(payload.date) ? String(payload.date).trim() : null;
  if (!date && !options.allowMissingDate) return null;

  const time = TIME_ONLY_PATTERN.test(String(payload.time || "").trim())
    ? String(payload.time).trim()
    : date
      ? "00:00"
      : null;
  const homeScore = parseNumericScore(payload.home_score);
  const awayScore = parseNumericScore(payload.away_score);
  const aggregate = resolveKnownAggregateScores(payload);
  const firstLegHomeScore = parseNumericScore(payload.first_leg_home_score);
  const firstLegAwayScore = parseNumericScore(payload.first_leg_away_score);

  const candidate = {
    match_details_id: matchId,
    date,
    time,
    league: String(payload.league || "").trim() || null,
    home_team: String(payload.home_team || "").trim() || null,
    away_team: String(payload.away_team || "").trim() || null,
    score_status: String(payload.score_status || "").trim() || null,
    details_url: String(payload.details_url || "").trim() || null,
    tv_channels: [],
    source_details_updated_at: String(payload.updated_at || "").trim() || null,
  };

  if (homeScore !== null) candidate.home_score = homeScore;
  if (awayScore !== null) candidate.away_score = awayScore;
  if (aggregate.home !== null && aggregate.away !== null) {
    candidate.aggregate_home_score = aggregate.home;
    candidate.aggregate_away_score = aggregate.away;
  }
  if (firstLegHomeScore !== null && firstLegAwayScore !== null) {
    candidate.first_leg_home_score = firstLegHomeScore;
    candidate.first_leg_away_score = firstLegAwayScore;
  }

  return candidate;
}

function mergeMonitorCandidate(existing, incoming) {
  if (!existing) return incoming ? { ...incoming } : null;
  if (!incoming) return { ...existing };

  const merged = { ...existing };
  const textFields = [
    "date",
    "time",
    "league",
    "home_team",
    "away_team",
    "score_status",
    "details_url",
    "source_details_updated_at",
  ];
  textFields.forEach((field) => {
    const value = incoming[field];
    if (value !== null && value !== undefined && String(value).trim().length > 0) {
      merged[field] = value;
    }
  });

  if (Number.isFinite(Number(incoming.home_score))) merged.home_score = Number(incoming.home_score);
  if (Number.isFinite(Number(incoming.away_score))) merged.away_score = Number(incoming.away_score);
  if (Number.isFinite(Number(incoming.aggregate_home_score))) {
    merged.aggregate_home_score = Number(incoming.aggregate_home_score);
  }
  if (Number.isFinite(Number(incoming.aggregate_away_score))) {
    merged.aggregate_away_score = Number(incoming.aggregate_away_score);
  }
  if (Number.isFinite(Number(incoming.first_leg_home_score))) {
    merged.first_leg_home_score = Number(incoming.first_leg_home_score);
  }
  if (Number.isFinite(Number(incoming.first_leg_away_score))) {
    merged.first_leg_away_score = Number(incoming.first_leg_away_score);
  }

  const mergedChannels = uniqueChannels([
    ...(Array.isArray(existing.tv_channels) ? existing.tv_channels : []),
    ...(Array.isArray(incoming.tv_channels) ? incoming.tv_channels : []),
  ]);
  if (mergedChannels.length > 0) {
    merged.tv_channels = mergedChannels;
  } else if (!Array.isArray(merged.tv_channels)) {
    merged.tv_channels = [];
  }

  return merged;
}

function buildMonitorCandidatesForDate(date, mergedItems, matchDetailsLookup) {
  if (!isDateOnly(date)) return [];

  const candidatesById = new Map();
  const sourceTagsById = new Map();
  const markSource = (matchId, source) => {
    if (!sourceTagsById.has(matchId)) sourceTagsById.set(matchId, new Set());
    sourceTagsById.get(matchId).add(source);
  };

  const mergedList = Array.isArray(mergedItems) ? mergedItems : [];
  const detailsLookup =
    matchDetailsLookup && typeof matchDetailsLookup === "object" ? matchDetailsLookup : {};
  const detailsIdentityIndex = buildMatchDetailsIdentityIndex(detailsLookup);
  const detailPayloads =
    detailsLookup instanceof Map ? Array.from(detailsLookup.values()) : Object.values(detailsLookup);

  for (const rawMatch of mergedList) {
    const rawDate = String(rawMatch && rawMatch.date ? rawMatch.date : "").trim();
    if (rawDate && rawDate !== date) continue;

    const candidate = toMatchListPayload(rawMatch, {
      matchDetailsLookup: detailsLookup,
      matchDetailsIdentityIndex: detailsIdentityIndex,
    });
    const matchId = normalizeMatchDetailsId(candidate && candidate.match_details_id);
    if (!candidate || !matchId) continue;
    if (String(candidate.date || "") !== date) continue;

    const existing = candidatesById.get(matchId);
    candidatesById.set(matchId, mergeMonitorCandidate(existing, candidate));
    markSource(matchId, "merged");
  }

  for (const payload of detailPayloads) {
    const candidate = toMonitorCandidateFromDetailsPayload(payload, { allowMissingDate: true });
    const matchId = normalizeMatchDetailsId(candidate && candidate.match_details_id);
    if (!candidate || !matchId) continue;

    const existing = candidatesById.get(matchId);
    if (!existing) {
      // Keep monitor candidates aligned with /matches; details may enrich, but not add new rows.
      continue;
    }

    const effectiveDate = String(candidate.date || existing.date || "");
    if (effectiveDate !== date) continue;

    candidatesById.set(matchId, mergeMonitorCandidate(existing, candidate));
    markSource(matchId, "details");
  }

  return Array.from(candidatesById.values())
    .map((candidate) => {
      const matchId = normalizeMatchDetailsId(candidate && candidate.match_details_id);
      const sources = matchId && sourceTagsById.has(matchId)
        ? Array.from(sourceTagsById.get(matchId).values()).sort()
        : [];
      return {
        ...candidate,
        sources,
      };
    })
    .sort(monitorCandidateSortAsc);
}

function mergeTvChannels(lhs, rhs) {
  const merged = uniqueChannels(lhs);
  uniqueChannels(rhs).forEach((channel) => {
    if (!merged.includes(channel)) merged.push(channel);
  });
  return merged;
}

function mergePreferredMatch(existing, incoming, preferIncoming) {
  const merged = { ...existing };
  const incomingClearsScoreState = hasExplicitNoScoreState(incoming);
  const incomingPostponedNoScoreState = hasPostponedNoScoreState(incoming);
  const existingAggregate = resolveKnownAggregateScores(existing);
  const incomingAggregate = resolveKnownAggregateScores(incoming);

  if (preferIncoming && incoming.league) merged.league = incoming.league;
  if (!merged.league && incoming.league) merged.league = incoming.league;

  // Merge league_subcategory field
  if (preferIncoming && incoming.league_subcategory) {
    merged.league_subcategory = incoming.league_subcategory;
  } else if (!merged.league_subcategory && incoming.league_subcategory) {
    merged.league_subcategory = incoming.league_subcategory;
  }

  if (preferIncoming) {
    if (incoming.time && (incoming.time !== "00:00" || merged.time === "00:00")) {
      merged.time = incoming.time;
    }
  } else if ((merged.time === "00:00" || !merged.time) && incoming.time) {
    merged.time = incoming.time;
  }

  if (incomingClearsScoreState || incomingPostponedNoScoreState) {
    merged.home_score = null;
    merged.away_score = null;
    merged.aggregate_home_score =
      incomingAggregate.home !== null ? incomingAggregate.home : existingAggregate.home;
    merged.aggregate_away_score =
      incomingAggregate.away !== null ? incomingAggregate.away : existingAggregate.away;
    merged.score_status = incomingPostponedNoScoreState ? "POSTPONED" : null;
  } else if (incoming.home_score !== undefined && incoming.home_score !== null) {
    merged.home_score = incoming.home_score;
  }
  if (
    !incomingClearsScoreState &&
    !incomingPostponedNoScoreState &&
    incoming.away_score !== undefined &&
    incoming.away_score !== null
  ) {
    merged.away_score = incoming.away_score;
  }
  if (
    !incomingClearsScoreState &&
    !incomingPostponedNoScoreState &&
    incomingAggregate.home !== null &&
    incomingAggregate.away !== null
  ) {
    merged.aggregate_home_score = incomingAggregate.home;
  }
  if (
    !incomingClearsScoreState &&
    !incomingPostponedNoScoreState &&
    incomingAggregate.home !== null &&
    incomingAggregate.away !== null
  ) {
    merged.aggregate_away_score = incomingAggregate.away;
  }
  if (!incomingClearsScoreState && !incomingPostponedNoScoreState && incoming.score_status) {
    merged.score_status = incoming.score_status;
  }
  if (incoming.details_url) merged.details_url = incoming.details_url;
  if (existing.has_bbc_source === true || incoming.has_bbc_source === true) {
    merged.has_bbc_source = true;
  }

  [
    "home_goal_scorers",
    "away_goal_scorers",
    "home_assists",
    "away_assists",
    "home_yellow_cards",
    "away_yellow_cards",
    "home_red_cards",
    "away_red_cards",
  ].forEach((field) => {
    if (Array.isArray(incoming[field])) {
      merged[field] = incoming[field];
    }
  });

  if (incoming.penalty_result) {
    merged.penalty_result = incoming.penalty_result;
  }

  const incomingTeamLineups = normalizeTeamLineupsPayload(incoming.team_lineups);
  if (incomingTeamLineups) {
    merged.team_lineups = incomingTeamLineups;
  } else if (!merged.team_lineups) {
    const existingTeamLineups = normalizeTeamLineupsPayload(existing.team_lineups);
    if (existingTeamLineups) {
      merged.team_lineups = existingTeamLineups;
    }
  }

  // If we have a penalty result (shootout complete) and status is "Pens", change to "AET"
  if (merged.penalty_result && (merged.score_status === "Pens" || merged.score_status === "PEN" || merged.score_status === "PEN.")) {
    merged.score_status = "AET";
  }

  merged.tv_channels = mergeTvChannels(existing.tv_channels, incoming.tv_channels);
  return merged;
}

function identityKeysForMatch(match) {
  const date = String(match.date || "").trim();
  const time = normalizeTimeValue(match.time);
  const league = normalizeLeagueName(match.league || "").toLowerCase();
  const homeKeys = identityTeamKeys(match.home_team || "");
  const awayKeys = identityTeamKeys(match.away_team || "");
  const keys = new Set();

  homeKeys.forEach((home) => {
    awayKeys.forEach((away) => {
      keys.add(`${date}|${time}|${league}|${home}|${away}`);
      keys.add(`${date}|${league}|${home}|${away}`);
      keys.add(`${date}|${time}|${home}|${away}`);
      keys.add(`${date}|${home}|${away}`);
    });
  });

  return Array.from(keys);
}

function isComparableKickoffTime(lhs, rhs) {
  const leftTime = normalizeTimeValue(lhs.time);
  const rightTime = normalizeTimeValue(rhs.time);
  return leftTime === rightTime || leftTime === "00:00" || rightTime === "00:00";
}

function findFuzzyDuplicatePrimaryKey(normalized, byPrimaryKey) {
  let best = null;
  byPrimaryKey.forEach((existing, primaryKey) => {
    if (!existing) return;
    if (String(existing.date || "") !== String(normalized.date || "")) return;
    if (!isComparableKickoffTime(existing, normalized)) return;
    if (
      compareInsensitive(
        normalizeLeagueName(existing.league || ""),
        normalizeLeagueName(normalized.league || "")
      ) !== 0
    ) {
      return;
    }

    // Check if at least one team matches with high confidence
    const homeHomeScore = similarityScore(normalized.home_team, existing.home_team);
    const awayAwayScore = similarityScore(normalized.away_team, existing.away_team);
    const homeAwayScore = similarityScore(normalized.home_team, existing.away_team);
    const awayHomeScore = similarityScore(normalized.away_team, existing.home_team);

    // If any single team matches with high confidence, consider it a duplicate
    // This handles cases like "Bodø / Glimt" vs "Bodo/Glimt" where the away team "Inter Milan" is identical
    const maxSingleTeamScore = Math.max(homeHomeScore, awayAwayScore, homeAwayScore, awayHomeScore);

    if (maxSingleTeamScore < DEDUPE_MIN_TEAM_CONFIDENCE) {
      return;
    }

    // Calculate overall confidence for ranking purposes
    const direct = scoreTeams(
      normalized.home_team,
      normalized.away_team,
      existing.home_team,
      existing.away_team,
      0
    );

    if (!best || direct.confidence > best.confidence) {
      best = { primaryKey, confidence: direct.confidence };
    }
  });
  return best ? best.primaryKey : null;
}

function compareMatches(lhs, rhs) {
  const leftDateTime = `${lhs.date || ""} ${normalizeTimeValue(lhs.time)}`;
  const rightDateTime = `${rhs.date || ""} ${normalizeTimeValue(rhs.time)}`;
  if (leftDateTime !== rightDateTime) {
    return leftDateTime < rightDateTime ? -1 : 1;
  }
  const leagueCompare = compareInsensitive(lhs.league || "", rhs.league || "");
  if (leagueCompare !== 0) return leagueCompare;
  const homeCompare = compareInsensitive(lhs.home_team || "", rhs.home_team || "");
  if (homeCompare !== 0) return homeCompare;
  return compareInsensitive(lhs.away_team || "", rhs.away_team || "");
}

function mergeBbcAndLiveMatches(liveMatches, bbcMatches) {
  const byPrimaryKey = new Map();
  const keyToPrimary = new Map();

  function upsert(rawMatch, preferIncoming) {
    const normalized = normalizeMatchRecord(rawMatch);
    if (!normalized) return;
    if (!isAllowedCompetition(normalized.league)) return;

    const identityKeys = identityKeysForMatch(normalized);
    let primaryKey = null;
    identityKeys.forEach((key) => {
      if (!primaryKey && keyToPrimary.has(key)) {
        primaryKey = keyToPrimary.get(key);
      }
    });
    if (!primaryKey) {
      primaryKey = findFuzzyDuplicatePrimaryKey(normalized, byPrimaryKey);
    }
    if (!primaryKey) primaryKey = identityKeys[0];

    const existing = byPrimaryKey.get(primaryKey);
    const merged = existing
      ? mergePreferredMatch(existing, normalized, preferIncoming)
      : normalized;
    byPrimaryKey.set(primaryKey, merged);
    identityKeys.forEach((key) => keyToPrimary.set(key, primaryKey));
  }

  (Array.isArray(liveMatches) ? liveMatches : []).forEach((match) => upsert(match, false));
  (Array.isArray(bbcMatches) ? bbcMatches : []).forEach((match) => upsert(match, true));

  return Array.from(byPrimaryKey.values()).sort(compareMatches);
}

async function rebuildMergedMatchesCache(source = "cache_rebuild") {
  // Include test matches in the merged cache
  const allTestMatches = testMatchState.getAllMatches();
  const testMatchesForMerge = allTestMatches.map(testMatch => ({
    date: testMatch.date,
    time: testMatch.time,
    home_team: testMatch.home_team,
    away_team: testMatch.away_team,
    league: testMatch.league,
    league_subcategory: testMatch.league_subcategory,
    details_url: testMatch.details_url,
    match_details_id: testMatch.match_details_id,
    tv_channels: testMatch.tv_channels || [],
    home_score: testMatch.home_score,
    away_score: testMatch.away_score,
    score_status: testMatch.score_status,
    home_goal_scorers: testMatch.home_goal_scorers || [],
    away_goal_scorers: testMatch.away_goal_scorers || [],
    home_assists: testMatch.home_assists || [],
    away_assists: testMatch.away_assists || [],
    home_yellow_cards: testMatch.home_yellow_cards || [],
    away_yellow_cards: testMatch.away_yellow_cards || [],
    home_red_cards: testMatch.home_red_cards || [],
    away_red_cards: testMatch.away_red_cards || [],
    penalty_result: testMatch.penalty_result,
    is_test_match: true
  }));

  const liveMatchesForMerge = Array.isArray(cachedMatches) ? cachedMatches : [];
  const preferredMatchesForMerge = [
    ...(Array.isArray(cachedBbcRangeMatches)
      ? cachedBbcRangeMatches.map((match) => ({ ...match, has_bbc_source: true }))
      : []),
    ...testMatchesForMerge,
  ];

  cachedMergedMatches = mergeBbcAndLiveMatches(
    liveMatchesForMerge,
    preferredMatchesForMerge
  );
  indexMatchDetailsFromMatches(cachedMergedMatches);
  refreshClubEloUnmatchedTeamMetric(cachedMergedMatches, cachedClubEloTeams);
  refreshFootballDatabaseUnmatchedTeamMetric(
    cachedMergedMatches,
    cachedFootballDatabaseTeams
  );
  refreshNationalEloUnmatchedTeamMetric(cachedMergedMatches, cachedNationalEloTeams);

  const updatedAt =
    newestIsoTimestamp([bbcRangeLastUpdated, lastUpdated, bbcLastUpdated, recentLastUpdated]) ||
    new Date().toISOString();
  await Promise.all([
    persistOperationalDatasetSafe(OP_DATASET_MERGED_MATCHES, cachedMergedMatches, {
      updated_at: updatedAt,
      source,
    }),
    persistOperationalMatchDetailsSafe(Object.fromEntries(matchDetailsById), {
      replace: true,
      updated_at: matchDetailsLastUpdated || updatedAt,
      source,
    }),
  ]);
}

function newestIsoTimestamp(values) {
  let best = null;
  values.forEach((value) => {
    if (!value) return;
    const timestamp = Date.parse(value);
    if (!Number.isFinite(timestamp)) return;
    if (!best || timestamp > best.timestamp) {
      best = { timestamp, value };
    }
  });
  return best ? best.value : null;
}

function parseKickoff(match) {
  if (!match || !match.date || !match.time) return null;
  const dateParts = String(match.date).split("-").map((part) => Number(part));
  const timeParts = String(match.time).split(":").map((part) => Number(part));
  if (dateParts.length !== 3 || timeParts.length < 2) return null;
  const [year, month, day] = dateParts;
  const [hour, minute] = timeParts;
  if (
    !Number.isFinite(year) ||
    !Number.isFinite(month) ||
    !Number.isFinite(day) ||
    !Number.isFinite(hour) ||
    !Number.isFinite(minute)
  ) {
    return null;
  }
  return new Date(year, month - 1, day, hour, minute);
}

function isWithinRetention(match, now = new Date()) {
  const kickoff = parseKickoff(match);
  if (!kickoff) return false;
  const diff = now - kickoff;
  return diff >= 0 && diff <= RECENT_CACHE_MS;
}

function mergeScoreFields(base, scored) {
  const merged = { ...base };
  if (scored.home_score !== undefined && scored.home_score !== null) {
    merged.home_score = scored.home_score;
  }
  if (scored.away_score !== undefined && scored.away_score !== null) {
    merged.away_score = scored.away_score;
  }
  if (scored.aggregate_home_score !== undefined && scored.aggregate_home_score !== null) {
    merged.aggregate_home_score = scored.aggregate_home_score;
  }
  if (scored.aggregate_away_score !== undefined && scored.aggregate_away_score !== null) {
    merged.aggregate_away_score = scored.aggregate_away_score;
  }
  if (scored.score_status !== undefined && scored.score_status !== null) {
    merged.score_status = scored.score_status;
  }
  if (Array.isArray(scored.home_goal_scorers)) {
    merged.home_goal_scorers = scored.home_goal_scorers;
  }
  if (Array.isArray(scored.away_goal_scorers)) {
    merged.away_goal_scorers = scored.away_goal_scorers;
  }
  if (Array.isArray(scored.home_assists)) {
    merged.home_assists = scored.home_assists;
  }
  if (Array.isArray(scored.away_assists)) {
    merged.away_assists = scored.away_assists;
  }
  if (Array.isArray(scored.home_yellow_cards)) {
    merged.home_yellow_cards = scored.home_yellow_cards;
  }
  if (Array.isArray(scored.away_yellow_cards)) {
    merged.away_yellow_cards = scored.away_yellow_cards;
  }
  if (Array.isArray(scored.home_red_cards)) {
    merged.home_red_cards = scored.home_red_cards;
  }
  if (Array.isArray(scored.away_red_cards)) {
    merged.away_red_cards = scored.away_red_cards;
  }
  return merged;
}

function applyScoresToMatches(matches, bbcMatches, now = new Date()) {
  if (!Array.isArray(bbcMatches) || bbcMatches.length === 0) return matches;
  return matches.map((match) => {
    const kickoff = parseKickoff(match);
    if (!kickoff || kickoff > now) return match;
    const candidate = bestScoreCandidate(match, bbcMatches);
    if (!candidate) return match;
    const source = candidate.match;
    const swapped = candidate.swapped;
    const merged = {
      ...match,
      home_score: swapped ? source.away_score : source.home_score,
      away_score: swapped ? source.home_score : source.away_score,
      score_status: source.match_time,
    };

    if (source.aggregate_home_score !== undefined && source.aggregate_home_score !== null) {
      merged.aggregate_home_score = swapped
        ? source.aggregate_away_score
        : source.aggregate_home_score;
    }
    if (source.aggregate_away_score !== undefined && source.aggregate_away_score !== null) {
      merged.aggregate_away_score = swapped
        ? source.aggregate_home_score
        : source.aggregate_away_score;
    }

    const homeGoalScorers = swapped ? source.away_goal_scorers : source.home_goal_scorers;
    const awayGoalScorers = swapped ? source.home_goal_scorers : source.away_goal_scorers;
    const homeAssists = swapped ? source.away_assists : source.home_assists;
    const awayAssists = swapped ? source.home_assists : source.away_assists;
    const homeYellowCards = swapped ? source.away_yellow_cards : source.home_yellow_cards;
    const awayYellowCards = swapped ? source.home_yellow_cards : source.away_yellow_cards;
    const homeRedCards = swapped ? source.away_red_cards : source.home_red_cards;
    const awayRedCards = swapped ? source.home_red_cards : source.away_red_cards;

    if (Array.isArray(homeGoalScorers)) merged.home_goal_scorers = homeGoalScorers;
    if (Array.isArray(awayGoalScorers)) merged.away_goal_scorers = awayGoalScorers;
    if (Array.isArray(homeAssists)) merged.home_assists = homeAssists;
    if (Array.isArray(awayAssists)) merged.away_assists = awayAssists;
    if (Array.isArray(homeYellowCards)) merged.home_yellow_cards = homeYellowCards;
    if (Array.isArray(awayYellowCards)) merged.away_yellow_cards = awayYellowCards;
    if (Array.isArray(homeRedCards)) merged.home_red_cards = homeRedCards;
    if (Array.isArray(awayRedCards)) merged.away_red_cards = awayRedCards;

    return merged;
  });
}

function buildLeagueList(matches) {
  const set = new Set();
  matches.forEach((match) => {
    if (!match || !match.league) return;
    const normalized = normalizeLeagueName(match.league);
    if (normalized) set.add(normalized);
  });
  return Array.from(set).sort(compareInsensitive);
}

function buildTeamList(matches, leagueFilter) {
  const set = new Set();
  const normalizedFilter = leagueFilter ? normalizeLeagueName(leagueFilter) : null;
  matches.forEach((match) => {
    if (!match) return;
    if (normalizedFilter) {
      const matchLeague = normalizeLeagueName(match.league || "");
      if (compareInsensitive(matchLeague, normalizedFilter) !== 0) {
        return;
      }
    }
    if (match.home_team) set.add(match.home_team);
    if (match.away_team) set.add(match.away_team);
  });
  return Array.from(set).sort(compareInsensitive);
}

function normalizeClubEloTeamRecord(record) {
  if (!record || typeof record !== "object") return null;
  const parseNumericField = (value) => {
    if (value === undefined || value === null || value === "") return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  };
  const club = String(record.Club || record.club || record.Name || record.name || "")
    .replace(/\s+/g, " ")
    .trim();
  if (!club) return null;
  const rankValue = parseNumericField(record.Rank);
  const levelValue = parseNumericField(record.Level);
  const eloValue = parseNumericField(record.Elo);
  const fromValue = String(record.From || "").trim();
  const toValue = String(record.To || "").trim();
  const countryValue = String(record.Country || "").trim();
  return {
    Name: String(record.Name || club).replace(/\s+/g, " ").trim(),
    Rank: Number.isFinite(rankValue) && rankValue > 0 ? Math.floor(rankValue) : null,
    Club: club,
    Country: countryValue || null,
    Level: Number.isFinite(levelValue) ? levelValue : null,
    Elo: Number.isFinite(eloValue) ? eloValue : null,
    From: isDateOnly(fromValue) ? fromValue : null,
    To: isDateOnly(toValue) ? toValue : null,
  };
}

function normalizeClubEloTeamsPayload(records) {
  if (!Array.isArray(records)) return [];
  return records
    .map((record) => normalizeClubEloTeamRecord(record))
    .filter(Boolean)
    .sort((left, right) => {
      const leftRank = Number.isFinite(left.Rank) ? left.Rank : Number.MAX_SAFE_INTEGER;
      const rightRank = Number.isFinite(right.Rank) ? right.Rank : Number.MAX_SAFE_INTEGER;
      if (leftRank !== rightRank) return leftRank - rightRank;
      return String(left.Club || "").localeCompare(String(right.Club || ""));
    });
}

function normalizeFootballDatabaseTeamRecord(record) {
  if (!record || typeof record !== "object") return null;
  const parseNumericField = (value) => {
    if (value === undefined || value === null || value === "") return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  };
  const club = String(record.Club || record.club || record.Name || record.name || "")
    .replace(/\s+/g, " ")
    .trim();
  if (!club) return null;
  const rankValue = parseNumericField(record.Rank || record.rank);
  const pointsValue = parseNumericField(record.Points || record.points || record.Elo || record.elo);
  const countryValue = String(record.Country || record.country || "").replace(/\s+/g, " ").trim();
  const oneYearChangeValue = parseNumericField(
    record.OneYearChange || record.one_year_change || record.change_1y || record.change1y
  );
  const previousPointsValue = parseNumericField(
    record.PreviousPoints || record.previous_points || record.previous
  );
  return {
    Name: String(record.Name || club).replace(/\s+/g, " ").trim(),
    Rank: Number.isFinite(rankValue) && rankValue > 0 ? Math.floor(rankValue) : null,
    Club: club,
    Country: countryValue || null,
    Points: Number.isFinite(pointsValue) ? pointsValue : null,
    // Keep Elo populated for compatibility with downstream "ranking score" consumers.
    Elo: Number.isFinite(pointsValue) ? pointsValue : null,
    OneYearChange: Number.isFinite(oneYearChangeValue) ? oneYearChangeValue : null,
    PreviousPoints: Number.isFinite(previousPointsValue) ? previousPointsValue : null,
  };
}

function normalizeFootballDatabaseTeamsPayload(records) {
  if (!Array.isArray(records)) return [];
  return records
    .map((record) => normalizeFootballDatabaseTeamRecord(record))
    .filter(Boolean)
    .sort((left, right) => {
      const leftRank = Number.isFinite(left.Rank) ? left.Rank : Number.MAX_SAFE_INTEGER;
      const rightRank = Number.isFinite(right.Rank) ? right.Rank : Number.MAX_SAFE_INTEGER;
      if (leftRank !== rightRank) return leftRank - rightRank;
      return String(left.Club || "").localeCompare(String(right.Club || ""));
    });
}

function normalizeNationalEloTeamRecord(record) {
  if (!record || typeof record !== "object") return null;
  const parseNumericField = (value) => {
    if (value === undefined || value === null || value === "") return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  };
  const teamName = String(record.Team || record.Name || record.Country || "")
    .replace(/\s+/g, " ")
    .trim();
  if (!teamName) return null;
  const rankValue = parseNumericField(record.Rank || record.rank);
  const eloValue = parseNumericField(record.Elo || record.elo || record.Points || record.points);
  const codeValue = String(record.TeamCode || record.Code || record.code || "")
    .replace(/\s+/g, " ")
    .trim();
  const aliases = Array.isArray(record.Aliases)
    ? record.Aliases.map((alias) => String(alias || "").replace(/\s+/g, " ").trim()).filter(Boolean)
    : [];
  const dedupedAliases = Array.from(new Set(aliases)).filter(
    (alias) => compareInsensitive(alias, teamName) !== 0
  );
  return {
    Name: teamName,
    Team: teamName,
    Country: String(record.Country || teamName).replace(/\s+/g, " ").trim() || teamName,
    Rank: Number.isFinite(rankValue) && rankValue > 0 ? Math.floor(rankValue) : null,
    Elo: Number.isFinite(eloValue) ? eloValue : null,
    Points: Number.isFinite(eloValue) ? eloValue : null,
    TeamCode: codeValue || null,
    Aliases: dedupedAliases,
    OneYearRankChange: parseNumericField(
      record.OneYearRankChange || record.one_year_rank_change
    ),
    OneYearRatingChange: parseNumericField(
      record.OneYearRatingChange || record.one_year_rating_change
    ),
  };
}

function normalizeNationalEloTeamsPayload(records) {
  if (!Array.isArray(records)) return [];
  return records
    .map((record) => normalizeNationalEloTeamRecord(record))
    .filter(Boolean)
    .sort((left, right) => {
      const leftRank = Number.isFinite(left.Rank) ? left.Rank : Number.MAX_SAFE_INTEGER;
      const rightRank = Number.isFinite(right.Rank) ? right.Rank : Number.MAX_SAFE_INTEGER;
      if (leftRank !== rightRank) return leftRank - rightRank;
      return String(left.Team || "").localeCompare(String(right.Team || ""));
    });
}

function refreshClubEloDataMetrics(teams) {
  const normalizedTeams = Array.isArray(teams) ? teams : [];
  clubEloLatestPullTeamCount = normalizedTeams.length;
  let oldest = null;
  let newest = null;
  normalizedTeams.forEach((team) => {
    const fromDate = String(team && team.From ? team.From : "").trim();
    if (!isDateOnly(fromDate)) return;
    if (!oldest || fromDate < oldest) oldest = fromDate;
    if (!newest || fromDate > newest) newest = fromDate;
  });
  clubEloOldestFromDate = oldest;
  clubEloNewestFromDate = newest;
}

function markClubEloSuccess(updatedAtIso, teams, durationSeconds = null) {
  const parsedMs = Date.parse(String(updatedAtIso || ""));
  if (Number.isFinite(parsedMs) && parsedMs > 0) {
    clubEloLastSuccessAt = new Date(parsedMs).toISOString();
  }
  if (Number.isFinite(durationSeconds) && durationSeconds >= 0) {
    clubEloLastSuccessDurationSeconds = durationSeconds;
  }
  refreshClubEloDataMetrics(teams);
  refreshClubEloUnmatchedTeamMetric();
}

function markClubEloFailure(failedAtIso = new Date().toISOString(), durationSeconds = null) {
  const parsedMs = Date.parse(String(failedAtIso || ""));
  if (Number.isFinite(parsedMs) && parsedMs > 0) {
    clubEloLastFailureAt = new Date(parsedMs).toISOString();
  }
  if (Number.isFinite(durationSeconds) && durationSeconds >= 0) {
    clubEloLastFailureDurationSeconds = durationSeconds;
  }
}

function refreshClubEloUnmatchedTeamMetric(matches = cachedMergedMatches, clubEloTeams = cachedClubEloTeams) {
  try {
    const mapped = mapTeamsToClubElo(matches, clubEloTeams);
    clubEloUnmatchedTeamCount = mapped.filter(
      (team) => !team.Club && !team._excluded_from_matching
    ).length;
  } catch (_error) {
    clubEloUnmatchedTeamCount = 0;
  }
}

function refreshFootballDatabaseDataMetrics(teams) {
  const normalizedTeams = Array.isArray(teams) ? teams : [];
  footballDatabaseLatestPullTeamCount = normalizedTeams.length;
}

function markFootballDatabaseSuccess(
  updatedAtIso,
  teams,
  durationSeconds = null,
  dataDate = null
) {
  const parsedMs = Date.parse(String(updatedAtIso || ""));
  if (Number.isFinite(parsedMs) && parsedMs > 0) {
    footballDatabaseLastSuccessAt = new Date(parsedMs).toISOString();
  }
  if (Number.isFinite(durationSeconds) && durationSeconds >= 0) {
    footballDatabaseLastSuccessDurationSeconds = durationSeconds;
  }
  const normalizedDataDate = isDateOnly(String(dataDate || "").trim())
    ? String(dataDate).trim()
    : null;
  if (normalizedDataDate) {
    footballDatabaseDataDate = normalizedDataDate;
  }
  refreshFootballDatabaseDataMetrics(teams);
  refreshFootballDatabaseUnmatchedTeamMetric();
}

function markFootballDatabaseFailure(
  failedAtIso = new Date().toISOString(),
  durationSeconds = null
) {
  const parsedMs = Date.parse(String(failedAtIso || ""));
  if (Number.isFinite(parsedMs) && parsedMs > 0) {
    footballDatabaseLastFailureAt = new Date(parsedMs).toISOString();
  }
  if (Number.isFinite(durationSeconds) && durationSeconds >= 0) {
    footballDatabaseLastFailureDurationSeconds = durationSeconds;
  }
}

function refreshFootballDatabaseUnmatchedTeamMetric(
  matches = cachedMergedMatches,
  footballDatabaseTeams = cachedFootballDatabaseTeams
) {
  try {
    const mapped = mapTeamsToFootballDatabase(matches, footballDatabaseTeams);
    footballDatabaseUnmatchedTeamCount = mapped.filter(
      (team) => !team.Club && !team._excluded_from_matching
    ).length;
  } catch (_error) {
    footballDatabaseUnmatchedTeamCount = 0;
  }
}

function refreshNationalEloDataMetrics(teams) {
  const normalizedTeams = Array.isArray(teams) ? teams : [];
  nationalEloLatestPullTeamCount = normalizedTeams.length;
}

function markNationalEloSuccess(updatedAtIso, teams, durationSeconds = null, dataDate = null) {
  const parsedMs = Date.parse(String(updatedAtIso || ""));
  if (Number.isFinite(parsedMs) && parsedMs > 0) {
    nationalEloLastSuccessAt = new Date(parsedMs).toISOString();
  }
  if (Number.isFinite(durationSeconds) && durationSeconds >= 0) {
    nationalEloLastSuccessDurationSeconds = durationSeconds;
  }
  const normalizedDataDate = isDateOnly(String(dataDate || "").trim())
    ? String(dataDate).trim()
    : null;
  if (normalizedDataDate) {
    nationalEloDataDate = normalizedDataDate;
  }
  refreshNationalEloDataMetrics(teams);
  refreshNationalEloUnmatchedTeamMetric();
}

function markNationalEloFailure(failedAtIso = new Date().toISOString(), durationSeconds = null) {
  const parsedMs = Date.parse(String(failedAtIso || ""));
  if (Number.isFinite(parsedMs) && parsedMs > 0) {
    nationalEloLastFailureAt = new Date(parsedMs).toISOString();
  }
  if (Number.isFinite(durationSeconds) && durationSeconds >= 0) {
    nationalEloLastFailureDurationSeconds = durationSeconds;
  }
}

function refreshNationalEloUnmatchedTeamMetric(
  matches = cachedMergedMatches,
  nationalEloTeams = cachedNationalEloTeams
) {
  try {
    const mapped = mapTeamsToNationalElo(matches, nationalEloTeams);
    nationalEloUnmatchedTeamCount = mapped.filter(
      (team) => !team.Team && !team._excluded_from_matching
    ).length;
  } catch (_error) {
    nationalEloUnmatchedTeamCount = 0;
  }
}

function buildClubEloMetricSeries(teams = cachedClubEloTeams) {
  const teamScores = [];
  const countryAggregates = new Map();

  (Array.isArray(teams) ? teams : []).forEach((team) => {
    const club = String(team && (team.Club || team.Name) ? team.Club || team.Name : "")
      .replace(/\s+/g, " ")
      .trim();
    if (!club) return;

    const score = Number(team && team.Elo);
    if (!Number.isFinite(score)) return;

    const country = String(team && team.Country ? team.Country : "")
      .replace(/\s+/g, " ")
      .trim();

    teamScores.push({
      club,
      country: country || null,
      score,
    });

    if (country) {
      if (!countryAggregates.has(country)) {
        countryAggregates.set(country, { totalScore: 0, count: 0 });
      }
      const aggregate = countryAggregates.get(country);
      aggregate.totalScore += score;
      aggregate.count += 1;
    }
  });

  teamScores.sort((left, right) => {
    if (right.score !== left.score) return right.score - left.score;
    return left.club.localeCompare(right.club);
  });

  const countryAverageScores = Array.from(countryAggregates.entries())
    .map(([country, aggregate]) => ({
      country,
      averageScore: aggregate.count > 0 ? aggregate.totalScore / aggregate.count : 0,
    }))
    .sort((left, right) => {
      if (right.averageScore !== left.averageScore) return right.averageScore - left.averageScore;
      return left.country.localeCompare(right.country);
    });

  return {
    teamScores,
    countryAverageScores,
  };
}

function buildFootballDatabaseMetricSeries(teams = cachedFootballDatabaseTeams) {
  const teamScores = [];
  const countryAggregates = new Map();

  (Array.isArray(teams) ? teams : []).forEach((team) => {
    const club = String(team && (team.Club || team.Name) ? team.Club || team.Name : "")
      .replace(/\s+/g, " ")
      .trim();
    if (!club) return;

    const score = Number(team && (team.Points !== undefined ? team.Points : team.Elo));
    if (!Number.isFinite(score)) return;

    const country = String(team && team.Country ? team.Country : "")
      .replace(/\s+/g, " ")
      .trim();

    teamScores.push({
      club,
      country: country || null,
      score,
    });

    if (country) {
      if (!countryAggregates.has(country)) {
        countryAggregates.set(country, { totalScore: 0, count: 0 });
      }
      const aggregate = countryAggregates.get(country);
      aggregate.totalScore += score;
      aggregate.count += 1;
    }
  });

  teamScores.sort((left, right) => {
    if (right.score !== left.score) return right.score - left.score;
    return left.club.localeCompare(right.club);
  });

  const countryAverageScores = Array.from(countryAggregates.entries())
    .map(([country, aggregate]) => ({
      country,
      averageScore: aggregate.count > 0 ? aggregate.totalScore / aggregate.count : 0,
    }))
    .sort((left, right) => {
      if (right.averageScore !== left.averageScore) return right.averageScore - left.averageScore;
      return left.country.localeCompare(right.country);
    });

  return {
    teamScores,
    countryAverageScores,
  };
}

function buildNationalEloMetricSeries(teams = cachedNationalEloTeams) {
  const teamScores = [];

  (Array.isArray(teams) ? teams : []).forEach((team) => {
    const nationalTeam = String(team && (team.Team || team.Name) ? team.Team || team.Name : "")
      .replace(/\s+/g, " ")
      .trim();
    if (!nationalTeam) return;

    const score = Number(team && (team.Elo !== undefined ? team.Elo : team.Points));
    if (!Number.isFinite(score)) return;

    const country = String(team && team.Country ? team.Country : nationalTeam)
      .replace(/\s+/g, " ")
      .trim();

    teamScores.push({
      team: nationalTeam,
      country: country || null,
      score,
    });
  });

  teamScores.sort((left, right) => {
    if (right.score !== left.score) return right.score - left.score;
    return left.team.localeCompare(right.team);
  });

  return {
    teamScores,
  };
}

function uniqueMatchTeamNames(matches, leagueFilter = null) {
  const set = new Set();
  const normalizedFilter = leagueFilter ? normalizeLeagueName(leagueFilter) : null;
  (Array.isArray(matches) ? matches : []).forEach((match) => {
    if (!match || typeof match !== "object") return;
    if (normalizedFilter) {
      const matchLeague = normalizeLeagueName(match.league || "");
      if (compareInsensitive(matchLeague, normalizedFilter) !== 0) {
        return;
      }
    }
    const homeTeam = String(match.home_team || "").trim();
    const awayTeam = String(match.away_team || "").trim();
    if (homeTeam) set.add(homeTeam);
    if (awayTeam) set.add(awayTeam);
  });
  return Array.from(set).sort(compareInsensitive);
}

function buildClubEloCandidateIndex(clubEloTeams) {
  const byNormalizedName = new Map();
  const byIdentityKey = new Map();
  const entries = Array.isArray(clubEloTeams) ? clubEloTeams : [];

  entries.forEach((team) => {
    if (!team || typeof team !== "object") return;
    const club = String(team.Club || "").trim();
    if (!club) return;

    const normalizedClub = normalizeTeamName(club);
    if (normalizedClub && !byNormalizedName.has(normalizedClub)) {
      byNormalizedName.set(normalizedClub, team);
    }

    identityTeamKeys(club).forEach((key) => {
      if (!key) return;
      if (!byIdentityKey.has(key)) {
        byIdentityKey.set(key, []);
      }
      byIdentityKey.get(key).push(team);
    });
  });

  return { byNormalizedName, byIdentityKey };
}

function normalizeMatchConfidenceThreshold(value, fallback) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(1, Math.max(0, parsed));
}

function findClubEloTeamByClubName(clubName, clubEloTeams, index = null, options = {}) {
  const normalizedClubName = normalizeTeamName(clubName);
  if (!normalizedClubName) return null;
  const minConfidence = normalizeMatchConfidenceThreshold(
    options.minConfidence,
    CLUB_ELO_MATCH_MIN_CONFIDENCE
  );
  const safeIndex = index || buildClubEloCandidateIndex(clubEloTeams);
  const direct = safeIndex.byNormalizedName.get(normalizedClubName);
  if (direct) return direct;

  const candidates = new Map();
  identityTeamKeys(clubName).forEach((key) => {
    const matches = safeIndex.byIdentityKey.get(key);
    (Array.isArray(matches) ? matches : []).forEach((team) => {
      const candidateClub = String(team && team.Club ? team.Club : "").trim();
      if (!candidateClub) return;
      if (!candidates.has(candidateClub)) {
        candidates.set(candidateClub, team);
      }
    });
  });

  let best = null;
  Array.from(candidates.values()).forEach((candidate) => {
    const candidateClub = String(candidate && candidate.Club ? candidate.Club : "").trim();
    if (!candidateClub) return;
    const confidence = Math.max(
      similarityScore(clubName, candidateClub),
      canonicalIdentityConfidenceBoost(clubName, candidateClub)
    );
    if (!best || confidence > best.confidence) {
      best = { team: candidate, confidence };
    }
  });
  if (!best || best.confidence < minConfidence) return null;
  return best.team;
}

function findBestClubEloMatch(
  teamName,
  clubEloTeams,
  index = null,
  manualMappings = null,
  options = {}
) {
  const normalizedName = normalizeTeamName(teamName);
  if (!normalizedName) return null;
  const minConfidence = normalizeMatchConfidenceThreshold(
    options.minConfidence,
    CLUB_ELO_MATCH_MIN_CONFIDENCE
  );
  const manualTargetFallbackMinConfidence = normalizeMatchConfidenceThreshold(
    options.manualTargetFallbackMinConfidence,
    Math.min(minConfidence, 0.62)
  );
  const safeIndex = index || buildClubEloCandidateIndex(clubEloTeams);
  let manualTargetMissingForFallback = false;

  const safeManualMappings = manualMappings || loadClubEloManualMappings();
  const manualResolution = resolveManualMappingCandidates(normalizedName, safeManualMappings);
  if (manualResolution.explicitUnmatched) {
    return {
      team: null,
      confidence: 1,
      method: "manual_unmatched",
      accepted: false,
    };
  }

  if (manualResolution.candidates.length > 0) {
    let manualMatchFound = null;

    for (const candidate of manualResolution.candidates) {
      const strictMatch = findClubEloTeamByClubName(
        candidate.clubName,
        clubEloTeams,
        safeIndex,
        {
          minConfidence,
        }
      );
      if (strictMatch) {
        manualMatchFound = {
          team: strictMatch,
          method:
            candidate.direction === "reverse" ? "manual_override_reverse" : "manual_override",
        };
        break;
      }
    }

    if (!manualMatchFound) {
      for (const candidate of manualResolution.candidates) {
        const relaxedMatch = findClubEloTeamByClubName(
          candidate.clubName,
          clubEloTeams,
          safeIndex,
          {
            minConfidence: manualTargetFallbackMinConfidence,
          }
        );
        if (relaxedMatch) {
          manualMatchFound = {
            team: relaxedMatch,
            method:
              candidate.direction === "reverse"
                ? "manual_override_reverse_fuzzy_target"
                : "manual_override_fuzzy_target",
          };
          break;
        }
      }
    }

    if (!manualMatchFound) {
      const directPostManual = safeIndex.byNormalizedName.get(normalizedName);
      if (directPostManual) {
        manualMatchFound = {
          team: directPostManual,
          method: "exact",
        };
      }
    }

    if (manualMatchFound) {
      return {
        team: manualMatchFound.team,
        confidence: 1,
        method: manualMatchFound.method,
        accepted: true,
      };
    }

    if (options.fallbackToAutomaticOnMissingManualTarget) {
      manualTargetMissingForFallback = true;
      // Continue into non-manual matching below when no manual candidate exists in the
      // selected ranking source.
    } else {
      return {
        team: null,
        confidence: 0,
        method: "manual_override_missing_target",
        accepted: false,
      };
    }
  }

  if (isLikelyNationalTeamName(teamName)) {
    return {
      team: null,
      confidence: 0,
      method: "excluded_national_team",
      accepted: false,
    };
  }

  const direct = safeIndex.byNormalizedName.get(normalizedName);
  if (direct) {
    return {
      team: direct,
      confidence: 1,
      method: "exact",
      accepted: true,
    };
  }

  const candidates = new Map();
  identityTeamKeys(teamName).forEach((key) => {
    const matches = safeIndex.byIdentityKey.get(key);
    (Array.isArray(matches) ? matches : []).forEach((team) => {
      const club = String(team && team.Club ? team.Club : "").trim();
      if (!club) return;
      if (!candidates.has(club)) {
        candidates.set(club, team);
      }
    });
  });

  const candidateList = candidates.size > 0
    ? Array.from(candidates.values())
    : (Array.isArray(clubEloTeams) ? clubEloTeams : []);

  let best = null;
  candidateList.forEach((candidate) => {
    const candidateClub = String(candidate && candidate.Club ? candidate.Club : "").trim();
    if (!candidateClub) return;
    const confidence = Math.max(
      similarityScore(teamName, candidateClub),
      canonicalIdentityConfidenceBoost(teamName, candidateClub)
    );
    if (!best || confidence > best.confidence) {
      best = {
        team: candidate,
        confidence,
      };
    }
  });
  if (!best) return null;
  const requiredConfidence = manualTargetMissingForFallback
    ? Math.min(minConfidence, manualTargetFallbackMinConfidence)
    : minConfidence;
  return {
    ...best,
    method: candidates.size > 0 ? "identity_fuzzy" : "global_fuzzy",
    accepted: best.confidence >= requiredConfidence,
  };
}

function mapTeamsToClubElo(matches, clubEloTeams, leagueFilter = null, options = {}) {
  const names = uniqueMatchTeamNames(matches, leagueFilter);
  const normalizedClubEloTeams = normalizeClubEloTeamsPayload(clubEloTeams);
  const index = buildClubEloCandidateIndex(normalizedClubEloTeams);
  const manualMappings = loadClubEloManualMappings();
  const minConfidence = normalizeMatchConfidenceThreshold(
    options.minConfidence,
    CLUB_ELO_MATCH_MIN_CONFIDENCE
  );
  return names.map((name) => {
    const match = findBestClubEloMatch(
      name,
      normalizedClubEloTeams,
      index,
      manualMappings,
      {
        minConfidence,
      }
    );
    const excludedFromMatching = match && match.method === "excluded_national_team";
    if (!match || !match.team || !match.accepted) {
      return {
        Name: name,
        Rank: null,
        Club: null,
        Country: null,
        Level: null,
        Elo: null,
        From: null,
        To: null,
        _match_confidence: match && Number.isFinite(match.confidence) ? match.confidence : 0,
        _closest_club: match && match.team ? match.team.Club : null,
        _match_method: match && match.method ? match.method : null,
        _excluded_from_matching: Boolean(excludedFromMatching),
      };
    }
    const team = match.team;
    return {
      Name: name,
      Rank: Number.isFinite(team.Rank) ? team.Rank : null,
      Club: team.Club || null,
      Country: team.Country || null,
      Level: Number.isFinite(team.Level) ? team.Level : null,
      Elo: Number.isFinite(team.Elo) ? team.Elo : null,
      From: team.From || null,
      To: team.To || null,
      _match_confidence: match.confidence,
      _match_method: match.method || null,
      _excluded_from_matching: false,
    };
  });
}

function mapTeamsToFootballDatabase(
  matches,
  footballDatabaseTeams,
  leagueFilter = null,
  options = {}
) {
  const names = uniqueMatchTeamNames(matches, leagueFilter);
  const normalizedFootballDatabaseTeams =
    normalizeFootballDatabaseTeamsPayload(footballDatabaseTeams);
  const index = buildClubEloCandidateIndex(normalizedFootballDatabaseTeams);
  const manualMappings = loadClubEloManualMappings();
  const minConfidence = normalizeMatchConfidenceThreshold(
    options.minConfidence,
    FOOTBALL_DATABASE_MATCH_MIN_CONFIDENCE
  );
  return names.map((name) => {
    const match = findBestClubEloMatch(
      name,
      normalizedFootballDatabaseTeams,
      index,
      manualMappings,
      {
        minConfidence,
        manualTargetFallbackMinConfidence: FOOTBALL_DATABASE_MANUAL_TARGET_MIN_CONFIDENCE,
        fallbackToAutomaticOnMissingManualTarget: true,
      }
    );
    const excludedFromMatching = match && match.method === "excluded_national_team";
    if (!match || !match.team || !match.accepted) {
      return {
        Name: name,
        Rank: null,
        Club: null,
        Country: null,
        Points: null,
        Elo: null,
        _match_confidence: match && Number.isFinite(match.confidence) ? match.confidence : 0,
        _closest_club: match && match.team ? match.team.Club : null,
        _match_method: match && match.method ? match.method : null,
        _excluded_from_matching: Boolean(excludedFromMatching),
      };
    }
    const team = match.team;
    const points = Number.isFinite(team.Points)
      ? team.Points
      : Number.isFinite(team.Elo)
        ? team.Elo
        : null;
    return {
      Name: name,
      Rank: Number.isFinite(team.Rank) ? team.Rank : null,
      Club: team.Club || null,
      Country: team.Country || null,
      Points: Number.isFinite(points) ? points : null,
      Elo: Number.isFinite(points) ? points : null,
      _match_confidence: match.confidence,
      _match_method: match.method || null,
      _excluded_from_matching: false,
    };
  });
}

function buildNationalEloCandidateIndex(nationalEloTeams) {
  const byNormalizedName = new Map();
  const byIdentityKey = new Map();
  const entries = Array.isArray(nationalEloTeams) ? nationalEloTeams : [];

  entries.forEach((team) => {
    if (!team || typeof team !== "object") return;
    const canonicalName = String(team.Team || team.Name || "").trim();
    if (!canonicalName) return;
    const names = [canonicalName, ...(Array.isArray(team.Aliases) ? team.Aliases : [])]
      .map((value) => String(value || "").trim())
      .filter(Boolean);

    names.forEach((name) => {
      const normalizedName = normalizeTeamName(name).replace(/\s+/g, " ").trim();
      if (normalizedName && !byNormalizedName.has(normalizedName)) {
        byNormalizedName.set(normalizedName, team);
      }
      identityTeamKeys(name).forEach((key) => {
        if (!key) return;
        if (!byIdentityKey.has(key)) {
          byIdentityKey.set(key, []);
        }
        byIdentityKey.get(key).push(team);
      });
    });
  });

  return { byNormalizedName, byIdentityKey };
}

function findBestNationalEloMatch(teamName, nationalEloTeams, index = null, options = {}) {
  const minConfidence = normalizeMatchConfidenceThreshold(
    options.minConfidence,
    NATIONAL_ELO_MATCH_MIN_CONFIDENCE
  );
  if (!isLikelyNationalTeamName(teamName)) {
    return {
      team: null,
      confidence: 0,
      method: "excluded_non_national_team",
      accepted: false,
    };
  }

  const safeIndex = index || buildNationalEloCandidateIndex(nationalEloTeams);
  const normalizedName = normalizeTeamName(teamName).replace(/\s+/g, " ").trim();
  const baseName = normalizeNationalTeamBaseName(teamName);
  const normalizedBaseName = normalizeTeamName(baseName).replace(/\s+/g, " ").trim();

  const exact = safeIndex.byNormalizedName.get(normalizedName) ||
    safeIndex.byNormalizedName.get(normalizedBaseName);
  if (exact) {
    return {
      team: exact,
      confidence: 1,
      method: "exact",
      accepted: true,
    };
  }

  const candidates = new Map();
  const addCandidatesFromName = (value) => {
    identityTeamKeys(value).forEach((key) => {
      const matches = safeIndex.byIdentityKey.get(key);
      (Array.isArray(matches) ? matches : []).forEach((team) => {
        const canonical = String(team && (team.Team || team.Name) ? team.Team || team.Name : "").trim();
        if (!canonical) return;
        if (!candidates.has(canonical)) {
          candidates.set(canonical, team);
        }
      });
    });
  };
  addCandidatesFromName(teamName);
  addCandidatesFromName(baseName);

  const candidateList = candidates.size > 0
    ? Array.from(candidates.values())
    : (Array.isArray(nationalEloTeams) ? nationalEloTeams : []);

  let best = null;
  candidateList.forEach((candidate) => {
    const candidateNames = [
      String(candidate && (candidate.Team || candidate.Name) ? candidate.Team || candidate.Name : ""),
      ...(Array.isArray(candidate && candidate.Aliases) ? candidate.Aliases : []),
    ]
      .map((value) => String(value || "").trim())
      .filter(Boolean);
    if (candidateNames.length === 0) return;

    let confidence = 0;
    candidateNames.forEach((candidateName) => {
      confidence = Math.max(
        confidence,
        similarityScore(baseName || teamName, candidateName),
        similarityScore(teamName, candidateName),
        canonicalIdentityConfidenceBoost(baseName || teamName, candidateName)
      );
    });
    if (!best || confidence > best.confidence) {
      best = {
        team: candidate,
        confidence,
      };
    }
  });

  if (!best) return null;
  return {
    ...best,
    method: candidates.size > 0 ? "identity_fuzzy" : "global_fuzzy",
    accepted: best.confidence >= minConfidence,
  };
}

function mapTeamsToNationalElo(matches, nationalEloTeams, leagueFilter = null, options = {}) {
  const names = uniqueMatchTeamNames(matches, leagueFilter);
  const normalizedNationalTeams = normalizeNationalEloTeamsPayload(nationalEloTeams);
  const index = buildNationalEloCandidateIndex(normalizedNationalTeams);
  const minConfidence = normalizeMatchConfidenceThreshold(
    options.minConfidence,
    NATIONAL_ELO_MATCH_MIN_CONFIDENCE
  );

  return names.map((name) => {
    const match = findBestNationalEloMatch(name, normalizedNationalTeams, index, {
      minConfidence,
    });
    const excludedFromMatching = match && match.method === "excluded_non_national_team";
    if (!match || !match.team || !match.accepted) {
      return {
        Name: name,
        Rank: null,
        Team: null,
        Country: null,
        Elo: null,
        Points: null,
        TeamCode: null,
        Aliases: [],
        _match_confidence: match && Number.isFinite(match.confidence) ? match.confidence : 0,
        _closest_club: match && match.team ? match.team.Team : null,
        _match_method: match && match.method ? match.method : null,
        _excluded_from_matching: Boolean(excludedFromMatching),
      };
    }
    const team = match.team;
    const points = Number.isFinite(team.Points)
      ? team.Points
      : Number.isFinite(team.Elo)
        ? team.Elo
        : null;
    return {
      Name: name,
      Rank: Number.isFinite(team.Rank) ? team.Rank : null,
      Team: team.Team || team.Name || null,
      Country: team.Country || team.Team || team.Name || null,
      Elo: Number.isFinite(points) ? points : null,
      Points: Number.isFinite(points) ? points : null,
      TeamCode: team.TeamCode || null,
      Aliases: Array.isArray(team.Aliases) ? team.Aliases : [],
      _match_confidence: match.confidence,
      _match_method: match.method || null,
      _excluded_from_matching: false,
    };
  });
}

const CLUB_ELO_COUNTRY_CODE_TO_NAME = Object.freeze({
  ALB: "Albania",
  AND: "Andorra",
  ARM: "Armenia",
  AUT: "Austria",
  AZE: "Azerbaijan",
  BEL: "Belgium",
  BHZ: "Bosnia and Herzegovina",
  BLR: "Belarus",
  BUL: "Bulgaria",
  CRO: "Croatia",
  CYP: "Cyprus",
  CZE: "Czech Republic",
  DEN: "Denmark",
  ENG: "England",
  ESP: "Spain",
  EST: "Estonia",
  FAR: "Faroe Islands",
  FIN: "Finland",
  FRA: "France",
  GEO: "Georgia",
  GER: "Germany",
  GIB: "Gibraltar",
  GRE: "Greece",
  HUN: "Hungary",
  IRL: "Ireland",
  ISL: "Iceland",
  ISR: "Israel",
  ITA: "Italy",
  KAZ: "Kazakhstan",
  KOS: "Kosovo",
  LAT: "Latvia",
  LIE: "Liechtenstein",
  LIT: "Lithuania",
  LUX: "Luxembourg",
  MAC: "North Macedonia",
  MLT: "Malta",
  MNT: "Montenegro",
  MOL: "Moldova",
  NED: "Netherlands",
  NIR: "Northern Ireland",
  NOR: "Norway",
  POL: "Poland",
  POR: "Portugal",
  ROM: "Romania",
  RUS: "Russia",
  SCO: "Scotland",
  SLK: "Slovakia",
  SMR: "San Marino",
  SRB: "Serbia",
  SUI: "Switzerland",
  SVN: "Slovenia",
  SWE: "Sweden",
  TUR: "Turkey",
  UKR: "Ukraine",
  WAL: "Wales",
});

const TEAM_TYPE_CLUB = "club";
const TEAM_TYPE_NATIONAL = "national";

function rankingDatasourceLabel(source) {
  if (source === TEAM_RANKING_SOURCE_NATIONAL_ELO) return "National Elo";
  if (source === TEAM_RANKING_SOURCE_FOOTBALLDATABASE) return "FootballDatabase";
  return "Club Elo";
}

const TEAM_DATASOURCE_SORT_ORDER = Object.freeze({
  "Club Elo": 1,
  FootballDatabase: 2,
  "National Elo": 3,
});

function sortDatasourceLabels(values) {
  const labels = Array.isArray(values) ? values.filter(Boolean) : [];
  return labels.slice().sort((left, right) => {
    const leftRank = TEAM_DATASOURCE_SORT_ORDER[left] || 999;
    const rightRank = TEAM_DATASOURCE_SORT_ORDER[right] || 999;
    if (leftRank !== rightRank) return leftRank - rightRank;
    return compareInsensitive(left, right);
  });
}

function normalizeClubEloCountryName(value) {
  const raw = String(value || "").replace(/\s+/g, " ").trim();
  if (!raw) return null;
  const mapped = CLUB_ELO_COUNTRY_CODE_TO_NAME[String(raw).toUpperCase()];
  if (mapped) return mapped;
  return raw;
}

function normalizeCountryForRankingSource(country, source) {
  if (source === TEAM_RANKING_SOURCE_CLUBELO) {
    return normalizeClubEloCountryName(country);
  }
  const raw = String(country || "").replace(/\s+/g, " ").trim();
  return raw || null;
}

function isRankedTeamRow(row) {
  return (
    row &&
    row.Points !== null &&
    row.Points !== undefined &&
    Number.isFinite(row.Points)
  );
}

function mapTeamsForRankingSource(
  matches,
  clubEloTeams,
  footballDatabaseTeams,
  leagueFilter,
  source
) {
  if (source === TEAM_RANKING_SOURCE_FOOTBALLDATABASE) {
    return mapTeamsToFootballDatabase(matches, footballDatabaseTeams, leagueFilter, {
      minConfidence: FOOTBALL_DATABASE_MATCH_MIN_CONFIDENCE,
    });
  }
  return mapTeamsToClubElo(matches, clubEloTeams, leagueFilter, {
    minConfidence: CLUB_ELO_MATCH_MIN_CONFIDENCE,
  });
}

function mapNationalTeamsForRankingSource(matches, nationalEloTeams, leagueFilter) {
  return mapTeamsToNationalElo(matches, nationalEloTeams, leagueFilter, {
    minConfidence: NATIONAL_ELO_MATCH_MIN_CONFIDENCE,
  });
}

function toUnifiedTeamRows(mappedTeams, source, teamType = TEAM_TYPE_CLUB) {
  const sourceLabel = rankingDatasourceLabel(source);
  return (Array.isArray(mappedTeams) ? mappedTeams : []).map((team) => {
    let points = null;
    let ranked = false;
    if (source === TEAM_RANKING_SOURCE_FOOTBALLDATABASE) {
      points = Number(team && (team.Points !== undefined ? team.Points : team.Elo));
      ranked = team && team.Club && Number.isFinite(points);
    } else if (source === TEAM_RANKING_SOURCE_NATIONAL_ELO) {
      points = Number(team && (team.Points !== undefined ? team.Points : team.Elo));
      ranked = team && team.Team && Number.isFinite(points);
    } else {
      points = Number(team && team.Elo);
      ranked = team && team.Club && Number.isFinite(points);
    }
    return {
      Name: String(team && team.Name ? team.Name : "").trim(),
      Rank: null,
      Country: ranked ? normalizeCountryForRankingSource(team.Country, source) : null,
      Points: ranked ? points : null,
      Datasource: ranked ? [sourceLabel] : [],
      aliases: [],
      Type: teamType,
      _source: source,
      _match_confidence:
        team && Number.isFinite(team._match_confidence) ? team._match_confidence : 0,
      _closest_club: team && team._closest_club ? team._closest_club : null,
      _match_method: team && team._match_method ? team._match_method : null,
      _excluded_from_matching: Boolean(team && team._excluded_from_matching),
    };
  }).filter((team) => team.Name);
}

function chooseMergedTeamRow(clubRow, footballDatabaseRow) {
  const clubRanked = isRankedTeamRow(clubRow);
  const footballDatabaseRanked = isRankedTeamRow(footballDatabaseRow);

  if (clubRanked && !footballDatabaseRanked) return clubRow;
  if (footballDatabaseRanked && !clubRanked) return footballDatabaseRow;
  if (clubRanked && footballDatabaseRanked) {
    const clubPoints = Number(clubRow.Points);
    const footballDatabasePoints = Number(footballDatabaseRow.Points);
    const mergedCountry = footballDatabaseRow.Country || clubRow.Country || null;
    const datasources = [];
    const addDatasource = (value) => {
      const label = String(value || "").trim();
      if (!label) return;
      if (!datasources.includes(label)) datasources.push(label);
    };
    (Array.isArray(clubRow.Datasource) ? clubRow.Datasource : []).forEach(addDatasource);
    (Array.isArray(footballDatabaseRow.Datasource) ? footballDatabaseRow.Datasource : []).forEach(
      addDatasource
    );
    return {
      ...clubRow,
      Rank: null,
      Country: mergedCountry,
      Points: (clubPoints + footballDatabasePoints) / 2,
      Datasource: sortDatasourceLabels(datasources),
      aliases: [],
      Type: TEAM_TYPE_CLUB,
      _match_confidence: Math.max(
        Number(clubRow._match_confidence || 0),
        Number(footballDatabaseRow._match_confidence || 0)
      ),
      _closest_club: footballDatabaseRow._closest_club || clubRow._closest_club || null,
      _match_method: "merged_average",
      _excluded_from_matching: Boolean(
        clubRow._excluded_from_matching || footballDatabaseRow._excluded_from_matching
      ),
    };
  }

  const clubConfidence = Number(clubRow && clubRow._match_confidence ? clubRow._match_confidence : 0);
  const footballDatabaseConfidence = Number(
    footballDatabaseRow && footballDatabaseRow._match_confidence
      ? footballDatabaseRow._match_confidence
      : 0
  );
  const preferred = footballDatabaseConfidence > clubConfidence
    ? footballDatabaseRow
    : clubRow;
  if (!preferred) return null;
  return {
    ...preferred,
    Rank: null,
    Country: null,
    Points: null,
    Datasource: [],
    aliases: [],
    Type: TEAM_TYPE_CLUB,
    _excluded_from_matching: Boolean(
      (clubRow && clubRow._excluded_from_matching) ||
      (footballDatabaseRow && footballDatabaseRow._excluded_from_matching)
    ),
  };
}

function mergeUnifiedTeamRows(clubRows, footballDatabaseRows) {
  const byName = new Map();
  (Array.isArray(clubRows) ? clubRows : []).forEach((row) => {
    byName.set(row.Name, { club: row, footballDatabase: null });
  });
  (Array.isArray(footballDatabaseRows) ? footballDatabaseRows : []).forEach((row) => {
    const existing = byName.get(row.Name) || { club: null, footballDatabase: null };
    existing.footballDatabase = row;
    byName.set(row.Name, existing);
  });

  return Array.from(byName.entries())
    .map(([name, pair]) => {
      const chosen = chooseMergedTeamRow(pair.club, pair.footballDatabase);
      if (chosen) return chosen;
      return {
        Name: name,
        Rank: null,
        Country: null,
        Points: null,
        Datasource: [],
        aliases: [],
        Type: TEAM_TYPE_CLUB,
        _source: null,
        _match_confidence: 0,
        _closest_club: null,
        _match_method: null,
        _excluded_from_matching: false,
      };
    })
    .sort((left, right) => compareInsensitive(left.Name || "", right.Name || ""));
}

function dedupeUnifiedTeamRowsByManualMappings(rows, manualMappings = null) {
  const safeMappings = manualMappings || loadClubEloManualMappings();
  const groups = new Map();

  (Array.isArray(rows) ? rows : []).forEach((row) => {
    const name = String(row && row.Name ? row.Name : "").trim();
    if (!name) return;
    const teamType = String(row && row.Type ? row.Type : TEAM_TYPE_CLUB).toLowerCase();
    const canonicalKey = teamType === TEAM_TYPE_NATIONAL
      ? normalizedTeamKey(name)
      : (resolveManualCanonicalTeamKey(name, safeMappings) || normalizedTeamKey(name));
    const nameKey = canonicalKey || normalizedTeamKey(name) || name.toLowerCase();
    const key = `${teamType}:${nameKey}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  });

  const deduped = [];
  groups.forEach((groupRows) => {
    if (!Array.isArray(groupRows) || groupRows.length === 0) return;

    const aliasNames = Array.from(
      new Set(
        groupRows
          .map((row) => String(row && row.Name ? row.Name : "").trim())
          .filter(Boolean)
      )
    ).sort((left, right) => {
      const lenDiff = left.length - right.length;
      if (lenDiff !== 0) return lenDiff;
      return compareInsensitive(left, right);
    });

    const primaryName = aliasNames[0] || String(groupRows[0].Name || "").trim();
    const rankedRows = groupRows.filter((row) => isRankedTeamRow(row));

    const bestRanked = rankedRows
      .slice()
      .sort((left, right) => {
        const leftSources = Array.isArray(left.Datasource) ? left.Datasource.length : 0;
        const rightSources = Array.isArray(right.Datasource) ? right.Datasource.length : 0;
        if (rightSources !== leftSources) return rightSources - leftSources;
        const leftConfidence = Number(left._match_confidence || 0);
        const rightConfidence = Number(right._match_confidence || 0);
        if (rightConfidence !== leftConfidence) return rightConfidence - leftConfidence;
        if (Number(right.Points) !== Number(left.Points)) {
          return Number(right.Points) - Number(left.Points);
        }
        return compareInsensitive(String(left.Name || ""), String(right.Name || ""));
      })[0] || null;

    const datasourceSet = new Set();
    rankedRows.forEach((row) => {
      (Array.isArray(row.Datasource) ? row.Datasource : []).forEach((label) => {
        if (label) datasourceSet.add(label);
      });
    });

    const mergedRow = bestRanked
      ? {
        ...bestRanked,
        Name: primaryName,
        aliases: aliasNames.filter((name) => compareInsensitive(name, primaryName) !== 0),
        Datasource: sortDatasourceLabels(Array.from(datasourceSet.values())),
        _match_confidence: Math.max(
          ...groupRows.map((row) => Number(row && row._match_confidence ? row._match_confidence : 0))
        ),
        _closest_club:
          groupRows.find((row) => row && row._closest_club)
            ? groupRows.find((row) => row && row._closest_club)._closest_club
            : null,
        _match_method:
          groupRows.find((row) => row && row._match_method)
            ? groupRows.find((row) => row && row._match_method)._match_method
            : null,
        _excluded_from_matching: false,
      }
      : {
        ...groupRows[0],
        Name: primaryName,
        Rank: null,
        Country: null,
        Points: null,
        Datasource: [],
        aliases: aliasNames.filter((name) => compareInsensitive(name, primaryName) !== 0),
        _match_confidence: Math.max(
          ...groupRows.map((row) => Number(row && row._match_confidence ? row._match_confidence : 0))
        ),
        _closest_club:
          groupRows.find((row) => row && row._closest_club)
            ? groupRows.find((row) => row && row._closest_club)._closest_club
            : null,
        _match_method:
          groupRows.find((row) => row && row._match_method)
            ? groupRows.find((row) => row && row._match_method)._match_method
            : null,
        _excluded_from_matching: groupRows.every((row) => Boolean(row && row._excluded_from_matching)),
      };

    deduped.push(mergedRow);
  });

  return deduped.sort((left, right) => compareInsensitive(left.Name || "", right.Name || ""));
}

function applyRankingToUnifiedTeamRows(rows) {
  const rankedRows = (Array.isArray(rows) ? rows : [])
    .filter((row) => isRankedTeamRow(row))
    .slice()
    .sort((left, right) => {
      if (right.Points !== left.Points) return right.Points - left.Points;
      return compareInsensitive(left.Name || "", right.Name || "");
    });
  const typeRankCounters = new Map();
  const rankedRowsWithRank = rankedRows.map((row, index) => {
    const teamType = String(
      row && row.Type ? row.Type : isLikelyNationalTeamName(row && row.Name ? row.Name : "")
        ? TEAM_TYPE_NATIONAL
        : TEAM_TYPE_CLUB
    )
      .trim()
      .toLowerCase();
    const nextTypeRank = (typeRankCounters.get(teamType) || 0) + 1;
    typeRankCounters.set(teamType, nextTypeRank);
    return {
      ...row,
      Rank: index + 1,
      TypeRank: nextTypeRank,
    };
  });
  const unrankedRows = (Array.isArray(rows) ? rows : [])
    .filter((row) => !isRankedTeamRow(row))
    .map((row) => ({
      ...row,
      Rank: null,
      TypeRank: null,
    }));

  return [...rankedRowsWithRank, ...unrankedRows]
    .sort((left, right) => {
      const leftRank = Number.isFinite(left.Rank) ? left.Rank : Number.MAX_SAFE_INTEGER;
      const rightRank = Number.isFinite(right.Rank) ? right.Rank : Number.MAX_SAFE_INTEGER;
      if (leftRank !== rightRank) return leftRank - rightRank;
      if (left.Type !== right.Type) return compareInsensitive(left.Type || "", right.Type || "");
      return compareInsensitive(left.Name || "", right.Name || "");
    });
}

function buildRankedTeamsForSource(
  matches,
  clubEloTeams,
  footballDatabaseTeams,
  nationalEloTeams,
  source,
  leagueFilter = null
) {
  const nationalRows = toUnifiedTeamRows(
    mapNationalTeamsForRankingSource(matches, nationalEloTeams, leagueFilter),
    TEAM_RANKING_SOURCE_NATIONAL_ELO,
    TEAM_TYPE_NATIONAL
  ).filter((row) => isLikelyNationalTeamName(row.Name));
  const dedupedNationalRows = dedupeUnifiedTeamRowsByManualMappings(nationalRows);

  if (source === TEAM_RANKING_SOURCE_NATIONAL_ELO) {
    return applyRankingToUnifiedTeamRows(dedupedNationalRows);
  }

  if (source === TEAM_RANKING_SOURCE_CLUBELO) {
    const clubRows = toUnifiedTeamRows(
      mapTeamsForRankingSource(
        matches,
        clubEloTeams,
        footballDatabaseTeams,
        leagueFilter,
        TEAM_RANKING_SOURCE_CLUBELO
      ),
      TEAM_RANKING_SOURCE_CLUBELO,
      TEAM_TYPE_CLUB
    );
    const dedupedRows = dedupeUnifiedTeamRowsByManualMappings(
      clubRows.filter((row) => !isLikelyNationalTeamName(row.Name))
    );
    return applyRankingToUnifiedTeamRows([...dedupedRows, ...dedupedNationalRows]);
  }
  if (source === TEAM_RANKING_SOURCE_FOOTBALLDATABASE) {
    const footballDatabaseRows = toUnifiedTeamRows(
      mapTeamsForRankingSource(
        matches,
        clubEloTeams,
        footballDatabaseTeams,
        leagueFilter,
        TEAM_RANKING_SOURCE_FOOTBALLDATABASE
      ),
      TEAM_RANKING_SOURCE_FOOTBALLDATABASE,
      TEAM_TYPE_CLUB
    );
    const dedupedRows = dedupeUnifiedTeamRowsByManualMappings(
      footballDatabaseRows.filter((row) => !isLikelyNationalTeamName(row.Name))
    );
    return applyRankingToUnifiedTeamRows([...dedupedRows, ...dedupedNationalRows]);
  }
  const clubRows = toUnifiedTeamRows(
    mapTeamsForRankingSource(
      matches,
      clubEloTeams,
      footballDatabaseTeams,
      leagueFilter,
      TEAM_RANKING_SOURCE_CLUBELO
    ),
    TEAM_RANKING_SOURCE_CLUBELO,
    TEAM_TYPE_CLUB
  );
  const footballDatabaseRows = toUnifiedTeamRows(
    mapTeamsForRankingSource(
      matches,
      clubEloTeams,
      footballDatabaseTeams,
      leagueFilter,
      TEAM_RANKING_SOURCE_FOOTBALLDATABASE
    ),
    TEAM_RANKING_SOURCE_FOOTBALLDATABASE,
    TEAM_TYPE_CLUB
  );
  const mergedRows = mergeUnifiedTeamRows(
    clubRows.filter((row) => !isLikelyNationalTeamName(row.Name)),
    footballDatabaseRows.filter((row) => !isLikelyNationalTeamName(row.Name))
  );
  const dedupedRows = dedupeUnifiedTeamRowsByManualMappings(mergedRows);
  return applyRankingToUnifiedTeamRows([...dedupedRows, ...dedupedNationalRows]);
}

function toTeamsApiTeamPayload(rows) {
  return (Array.isArray(rows) ? rows : []).map((row) => ({
    Name: row.Name || null,
    OverallRank: Number.isFinite(row.Rank) ? row.Rank : null,
    TypeRank: Number.isFinite(row.TypeRank) ? row.TypeRank : null,
    Country: row.Country || null,
    Points: Number.isFinite(row.Points) ? row.Points : null,
    Datasource: sortDatasourceLabels(Array.isArray(row.Datasource) ? row.Datasource : []),
    Type: row.Type || (isLikelyNationalTeamName(row.Name) ? TEAM_TYPE_NATIONAL : TEAM_TYPE_CLUB),
    aliases: Array.isArray(row.aliases) ? row.aliases : [],
  }));
}

function buildUnmatchedTeamPayloadFromUnifiedRows(rows) {
  return (Array.isArray(rows) ? rows : [])
    .filter((row) => !isRankedTeamRow(row) && !row._excluded_from_matching)
    .map((row) => ({
      Name: row.Name,
      Type: row.Type || (isLikelyNationalTeamName(row.Name) ? TEAM_TYPE_NATIONAL : TEAM_TYPE_CLUB),
      confidence: Number.isFinite(row._match_confidence)
        ? Number(row._match_confidence.toFixed(4))
        : 0,
      closest_club: row._closest_club || null,
      match_method: row._match_method || null,
    }))
    .sort((left, right) => compareInsensitive(left.Name || "", right.Name || ""));
}

function teamSourceConfidenceThreshold(source) {
  if (source === TEAM_RANKING_SOURCE_NATIONAL_ELO) {
    return {
      nationalelo: NATIONAL_ELO_MATCH_MIN_CONFIDENCE,
    };
  }
  if (source === TEAM_RANKING_SOURCE_CLUBELO) {
    return {
      clubelo: CLUB_ELO_MATCH_MIN_CONFIDENCE,
      nationalelo: NATIONAL_ELO_MATCH_MIN_CONFIDENCE,
    };
  }
  if (source === TEAM_RANKING_SOURCE_FOOTBALLDATABASE) {
    return {
      footballdatabase: FOOTBALL_DATABASE_MATCH_MIN_CONFIDENCE,
      nationalelo: NATIONAL_ELO_MATCH_MIN_CONFIDENCE,
    };
  }
  return {
    clubelo: CLUB_ELO_MATCH_MIN_CONFIDENCE,
    footballdatabase: FOOTBALL_DATABASE_MATCH_MIN_CONFIDENCE,
    nationalelo: NATIONAL_ELO_MATCH_MIN_CONFIDENCE,
  };
}

const SUPPORTED_TEAM_RANKING_SOURCES = [
  TEAM_RANKING_SOURCE_MERGED,
  TEAM_RANKING_SOURCE_CLUBELO,
  TEAM_RANKING_SOURCE_FOOTBALLDATABASE,
  TEAM_RANKING_SOURCE_NATIONAL_ELO,
];
const SUPPORTED_TEAM_TYPES = [TEAM_TYPE_CLUB, TEAM_TYPE_NATIONAL];

function normalizeExtendedTeamRankingSource(rawSource) {
  const normalized = normalizeTeamRankingSource(rawSource);
  if (normalized) return normalized;
  const fallback = String(rawSource || "").trim().toLowerCase();
  if (["nationalelo", "national_elo", "national-elo", "national"].includes(fallback)) {
    return TEAM_RANKING_SOURCE_NATIONAL_ELO;
  }
  return null;
}

function resolveTeamRankingSource(rawSource) {
  const normalized = normalizeExtendedTeamRankingSource(rawSource);
  if (normalized) {
    return { source: normalized, fromQuery: true, valid: true };
  }
  if (rawSource !== undefined && rawSource !== null && String(rawSource).trim() !== "") {
    return {
      source: TEAM_RANKING_DEFAULT_SOURCE,
      fromQuery: true,
      valid: false,
    };
  }
  return {
    source: TEAM_RANKING_DEFAULT_SOURCE,
    fromQuery: false,
    valid: true,
  };
}

function resolveTeamTypeFilter(rawType) {
  if (rawType === undefined || rawType === null || String(rawType).trim() === "") {
    return {
      type: null,
      fromQuery: false,
      valid: true,
    };
  }
  const normalized = String(rawType).trim().toLowerCase();
  if (normalized === TEAM_TYPE_CLUB || normalized === TEAM_TYPE_NATIONAL) {
    return {
      type: normalized,
      fromQuery: true,
      valid: true,
    };
  }
  return {
    type: null,
    fromQuery: true,
    valid: false,
  };
}

function filterRankedRowsByTeamType(rows, teamType) {
  if (!teamType) return Array.isArray(rows) ? rows : [];
  return (Array.isArray(rows) ? rows : []).filter((row) => {
    const rowType = String(
      row && row.Type ? row.Type : isLikelyNationalTeamName(row && row.Name ? row.Name : "")
        ? TEAM_TYPE_NATIONAL
        : TEAM_TYPE_CLUB
    )
      .trim()
      .toLowerCase();
    return rowType === teamType;
  });
}

const TEAM_LOOKUP_DEFAULT_MIN_CONFIDENCE = 0.82;

function teamRowQualityScore(row) {
  if (!row || typeof row !== "object") return 0;
  let score = 0;
  if (isRankedTeamRow(row)) score += 100;
  if (Array.isArray(row.Datasource)) score += row.Datasource.length * 4;
  if (Number.isFinite(row.Points)) score += Number(row.Points) / 1000;
  if (Number.isFinite(row._match_confidence)) score += Number(row._match_confidence);
  return score;
}

function findBestRankedTeamRowMatch(teamName, rows, options = {}) {
  const query = String(teamName || "").replace(/\s+/g, " ").trim();
  if (!query) return null;
  const manualMappings = options.manualMappings || loadClubEloManualMappings();
  const minConfidence = normalizeMatchConfidenceThreshold(
    options.minConfidence,
    TEAM_LOOKUP_DEFAULT_MIN_CONFIDENCE
  );

  let best = null;
  (Array.isArray(rows) ? rows : []).forEach((row) => {
    if (!row || typeof row !== "object") return;
    const primaryName = String(row.Name || "").replace(/\s+/g, " ").trim();
    if (!primaryName) return;
    const aliases = Array.isArray(row.aliases)
      ? row.aliases.map((alias) => String(alias || "").replace(/\s+/g, " ").trim()).filter(Boolean)
      : [];
    const candidates = [
      { value: primaryName, isAlias: false },
      ...aliases.map((alias) => ({ value: alias, isAlias: true })),
    ];

    candidates.forEach((candidate) => {
      const candidateName = String(candidate.value || "").trim();
      if (!candidateName) return;

      let method = null;
      let confidence = 0;
      if (compareInsensitive(query, candidateName) === 0) {
        method = candidate.isAlias ? "alias_exact" : "exact";
        confidence = 1;
      } else if (areTeamNamesEquivalentByManualMappings(query, candidateName, manualMappings)) {
        method = "manual_alias";
        confidence = 1;
      } else {
        confidence = Math.max(
          similarityScore(query, candidateName),
          canonicalIdentityConfidenceBoost(query, candidateName)
        );
        if (confidence < minConfidence) {
          return;
        }
        method = candidate.isAlias ? "alias_fuzzy" : "fuzzy";
      }

      const next = {
        row,
        query,
        matched_name: candidateName,
        matched_alias: Boolean(candidate.isAlias),
        method,
        confidence,
      };
      if (!best) {
        best = next;
        return;
      }

      if (next.confidence > best.confidence) {
        best = next;
        return;
      }
      if (next.confidence < best.confidence) {
        return;
      }

      const nextQuality = teamRowQualityScore(next.row);
      const bestQuality = teamRowQualityScore(best.row);
      if (nextQuality > bestQuality) {
        best = next;
        return;
      }
      if (nextQuality < bestQuality) {
        return;
      }

      if (compareInsensitive(next.row.Name || "", best.row.Name || "") < 0) {
        best = next;
      }
    });
  });

  return best;
}

function buildChannelList(matches) {
  const set = new Set(CHANNEL_SPECIAL_OPTIONS);
  matches.forEach((match) => {
    if (!match || !Array.isArray(match.tv_channels)) return;
    match.tv_channels.forEach((channel) => {
      const trimmed = String(channel || "").trim();
      if (trimmed) set.add(trimmed);
    });
  });
  return Array.from(set).sort(compareInsensitive);
}

function normalizeListParam(value) {
  if (!value) return [];
  const raw = Array.isArray(value) ? value : [value];
  const items = [];
  raw.forEach((entry) => {
    String(entry)
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean)
      .forEach((item) => items.push(item));
  });
  return items;
}

function isTruthyParam(value) {
  if (value === undefined || value === null) return false;
  const normalized = String(value).trim().toLowerCase();
  return ["1", "true", "yes", "on"].includes(normalized);
}

function teamMatchesPremierLeague(teamName, premierLeagueTeams) {
  if (!teamName) {
    return false;
  }

  // If Premier League teams haven't loaded yet, fail open (allow all teams)
  // to avoid filtering out all matches
  if (!Array.isArray(premierLeagueTeams) || premierLeagueTeams.length === 0) {
    return true;
  }

  const normalizedTeamName = String(teamName).trim();
  return premierLeagueTeams.some((candidate) => {
    if (!candidate) return false;
    const normalizedCandidate = String(candidate).trim();
    if (compareInsensitive(normalizedTeamName, normalizedCandidate) === 0) {
      return true;
    }
    return similarityScore(normalizedTeamName, normalizedCandidate) >= EPL_TEAM_MIN_CONFIDENCE;
  });
}

function matchIncludesPremierLeagueTeam(match, premierLeagueTeams) {
  if (!match) return false;
  return (
    teamMatchesPremierLeague(match.home_team, premierLeagueTeams) ||
    teamMatchesPremierLeague(match.away_team, premierLeagueTeams)
  );
}

const HOME_NATIONS_TEAMS = new Set([
  "england",
  "northern ireland",
  "scotland",
  "wales",
]);

const MAJOR_TOURNAMENT_PATTERNS = [
  /^fifa world cup(?:\s+\d{4})?$/i,
  /^(?:uefa\s+)?european championship(?:\s+\d{4})?$/i,
  /^(?:uefa\s+)?euro(?:\s+\d{4})?$/i,
];

const QUALIFYING_COMPETITION_PATTERN = /\bqualif(?:ying|ication)\b/i;

function normalizeFilterTeamName(teamName) {
  return normalizeTeamName(teamName).replace(/\s+/g, " ").trim().toLowerCase();
}

function matchIncludesHomeNation(match) {
  if (!match) return false;
  return [match.home_team, match.away_team].some((teamName) =>
    HOME_NATIONS_TEAMS.has(normalizeFilterTeamName(teamName))
  );
}

function matchIsMajorTournament(match) {
  if (!match) return false;

  const rawLeague = String(match.league || "").trim();
  const rawSubcategory = String(match.league_subcategory || "").trim();
  if (!rawLeague) return false;
  if (
    QUALIFYING_COMPETITION_PATTERN.test(rawLeague) ||
    QUALIFYING_COMPETITION_PATTERN.test(rawSubcategory)
  ) {
    return false;
  }

  const normalizedLeague = normalizeLeagueName(rawLeague).replace(/\s+/g, " ").trim().toLowerCase();
  if (!normalizedLeague) return false;

  return MAJOR_TOURNAMENT_PATTERNS.some((pattern) => pattern.test(normalizedLeague));
}

function matchPassesCategoryFilters(match, options = {}) {
  const predicates = [];
  if (options.eplOnly) {
    predicates.push((candidate) =>
      matchIncludesPremierLeagueTeam(candidate, options.premierLeagueTeams)
    );
  }
  if (options.homeNations) {
    predicates.push(matchIncludesHomeNation);
  }
  if (options.majorTournaments) {
    predicates.push(matchIsMajorTournament);
  }

  if (predicates.length === 0) return true;
  return predicates.some((predicate) => predicate(match));
}

function teamMatchesSelectionAliasAware(teamName, selection, manualMappings = null) {
  const lhs = String(teamName || "").trim();
  const rhs = String(selection || "").trim();
  if (!lhs || !rhs) return false;
  if (compareInsensitive(lhs, rhs) === 0) return true;
  return areTeamNamesEquivalentByManualMappings(lhs, rhs, manualMappings);
}

function matchesFilters(match, filters) {
  const { leagues, teams, channels, dateFrom, dateTo, filterMode, manualMappings } = filters;

  const matchLeague = normalizeCompetitionFilterName(match.league || "");
  const leagueOk =
    leagues.length === 0 ||
    leagues.some((league) => compareInsensitive(matchLeague, league) === 0);

  const home = match.home_team || "";
  const away = match.away_team || "";
  const teamOk =
    teams.length === 0 ||
    teams.some(
      (team) =>
        teamMatchesSelectionAliasAware(home, team, manualMappings) ||
        teamMatchesSelectionAliasAware(away, team, manualMappings)
    );

  if (leagues.length > 0 || teams.length > 0) {
    const mode = filterMode === "intersection" ? "intersection" : "union";
    if (mode === "intersection") {
      if (!(leagueOk && teamOk)) return false;
    } else {
      if (!(leagueOk || teamOk)) return false;
    }
  }

  const channelList = Array.isArray(match.tv_channels) ? match.tv_channels : [];
  const channelOk =
    channels.length === 0 ||
    channelList.some((channel) =>
      channels.some((selection) => channelMatchesSelection(channel, selection))
    );
  if (!channelOk) return false;

  if (dateFrom || dateTo) {
    const matchDate = match.date || "";
    if (dateFrom && matchDate < dateFrom) return false;
    if (dateTo && matchDate > dateTo) return false;
  }

  return true;
}

function loadFromDisk() {
  try {
    if (!fs.existsSync(OUTPUT_PATH)) return;
    const raw = fs.readFileSync(OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedMatches = filterMatchesByCompetition(parsed);
      setSourceCacheSize(SOURCE_LIVE_FOOTBALL, cachedMatches.length);
      const stat = fs.statSync(OUTPUT_PATH);
      lastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load matches from disk:", err.message || err);
  }
}

function loadBbcFromDisk() {
  try {
    if (!fs.existsSync(BBC_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(BBC_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedBbcMatches = parsed;
      setSourceCacheSize(SOURCE_BBC_LIVE, cachedBbcMatches.length);
      const stat = fs.statSync(BBC_OUTPUT_PATH);
      bbcLastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load BBC matches from disk:", err.message || err);
  }
}

function loadBbcRangeFromDisk() {
  try {
    if (!fs.existsSync(BBC_RANGE_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(BBC_RANGE_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedBbcRangeMatches = filterMatchesByCompetition(parsed);
      setSourceCacheSize(SOURCE_BBC_RANGE, cachedBbcRangeMatches.length);
      const stat = fs.statSync(BBC_RANGE_OUTPUT_PATH);
      bbcRangeLastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load BBC range matches from disk:", err.message || err);
  }
}

function loadRecentFromDisk() {
  try {
    if (!fs.existsSync(RECENT_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(RECENT_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedRecentMatches = filterMatchesByCompetition(parsed);
      setSourceCacheSize(SOURCE_RECENT_CACHE, cachedRecentMatches.length);
      const stat = fs.statSync(RECENT_OUTPUT_PATH);
      recentLastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load recent matches from disk:", err.message || err);
  }
}

function loadPremierLeagueFromDisk() {
  try {
    if (!fs.existsSync(EPL_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(EPL_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedPremierLeagueTeams = parsed
        .map((team) => String(team || "").trim())
        .filter(Boolean);
      setSourceCacheSize(SOURCE_BBC_PREMIER_LEAGUE, cachedPremierLeagueTeams.length);
      const stat = fs.statSync(EPL_OUTPUT_PATH);
      eplLastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load Premier League teams from disk:", err.message || err);
  }
}

function loadLeagueTablesFromDisk() {
  try {
    if (!fs.existsSync(LEAGUE_TABLES_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(LEAGUE_TABLES_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedLeagueTables = sortLeagueTablesForResponse(parsed);
      setSourceCacheSize(SOURCE_BBC_LEAGUE_TABLES, leagueTableRowsCount(cachedLeagueTables));
      const stat = fs.statSync(LEAGUE_TABLES_OUTPUT_PATH);
      leagueTablesLastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load league tables from disk:", err.message || err);
  }
}

function loadClubEloFromDisk() {
  try {
    if (!fs.existsSync(CLUB_ELO_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(CLUB_ELO_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedClubEloTeams = normalizeClubEloTeamsPayload(parsed);
      setSourceCacheSize(SOURCE_CLUB_ELO, cachedClubEloTeams.length);
      const stat = fs.statSync(CLUB_ELO_OUTPUT_PATH);
      clubEloLastUpdated = stat.mtime.toISOString();
      markClubEloSuccess(clubEloLastUpdated, cachedClubEloTeams);
    }
  } catch (err) {
    console.warn("Failed to load Club Elo teams from disk:", err.message || err);
  }
}

function loadClubEloFixturesFromDisk() {
  try {
    if (!fs.existsSync(CLUB_ELO_FIXTURES_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(CLUB_ELO_FIXTURES_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedClubEloFixtures = parsed;
      setSourceCacheSize(SOURCE_CLUB_ELO_FIXTURES, cachedClubEloFixtures.length);
      const stat = fs.statSync(CLUB_ELO_FIXTURES_OUTPUT_PATH);
      clubEloFixturesLastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load Club Elo fixtures from disk:", err.message || err);
  }
}

function loadFootballDatabaseFromDisk() {
  try {
    if (!fs.existsSync(FOOTBALL_DATABASE_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(FOOTBALL_DATABASE_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedFootballDatabaseTeams = normalizeFootballDatabaseTeamsPayload(parsed);
      setSourceCacheSize(SOURCE_FOOTBALL_DATABASE, cachedFootballDatabaseTeams.length);
      const stat = fs.statSync(FOOTBALL_DATABASE_OUTPUT_PATH);
      footballDatabaseLastUpdated = stat.mtime.toISOString();
      markFootballDatabaseSuccess(
        footballDatabaseLastUpdated,
        cachedFootballDatabaseTeams
      );
    }
  } catch (err) {
    console.warn("Failed to load FootballDatabase teams from disk:", err.message || err);
  }
}

function loadNationalEloFromDisk() {
  try {
    if (!fs.existsSync(NATIONAL_ELO_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(NATIONAL_ELO_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedNationalEloTeams = normalizeNationalEloTeamsPayload(parsed);
      setSourceCacheSize(SOURCE_NATIONAL_ELO, cachedNationalEloTeams.length);
      const stat = fs.statSync(NATIONAL_ELO_OUTPUT_PATH);
      nationalEloLastUpdated = stat.mtime.toISOString();
      markNationalEloSuccess(
        nationalEloLastUpdated,
        cachedNationalEloTeams,
        null,
        nationalEloLastUpdated.slice(0, 10)
      );
    }
  } catch (err) {
    console.warn("Failed to load National Elo teams from disk:", err.message || err);
  }
}

function loadMissingTeamLogosFromDisk() {
  try {
    if (!fs.existsSync(MISSING_TEAM_LOGOS_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(MISSING_TEAM_LOGOS_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      missingTeamLogosByKey = new Map();
      parsed.forEach((teamName) => {
        const normalized = normalizeMissingTeamLogoName(teamName);
        if (!normalized) return;
        missingTeamLogosByKey.set(missingTeamLogoKey(normalized), normalized);
      });
      const stat = fs.statSync(MISSING_TEAM_LOGOS_OUTPUT_PATH);
      missingTeamLogosLastUpdated = stat.mtime.toISOString();
      const removed = pruneResolvableMissingTeamLogos();
      if (removed.length > 0) {
        missingTeamLogosLastUpdated = new Date().toISOString();
        writeMissingTeamLogos(MISSING_TEAM_LOGOS_OUTPUT_PATH, sortedMissingTeamLogoNames());
      }
    }
  } catch (err) {
    console.warn("Failed to load missing team logos from disk:", err.message || err);
  }
}

function writeRecentMatches(outputPath, matches) {
  try {
    fs.writeFileSync(outputPath, JSON.stringify(matches, null, 2), "utf8");
  } catch (err) {
    console.warn("Failed to write recent matches to disk:", err.message || err);
  }
}

function writeBbcRangeMatches(outputPath, matches) {
  try {
    fs.writeFileSync(outputPath, JSON.stringify(matches, null, 2), "utf8");
  } catch (err) {
    console.warn("Failed to write BBC range matches to disk:", err.message || err);
  }
}

function writeClubEloTeams(outputPath, teams) {
  try {
    writeClubEloRankings(outputPath, teams);
  } catch (err) {
    console.warn("Failed to write Club Elo teams to disk:", err.message || err);
  }
}

function writeClubEloFixturesData(outputPath, fixtures) {
  try {
    writeClubEloFixtures(outputPath, fixtures);
  } catch (err) {
    console.warn("Failed to write Club Elo fixtures to disk:", err.message || err);
  }
}

function writeFootballDatabaseTeams(outputPath, teams) {
  try {
    writeFootballDatabaseRankings(outputPath, teams);
  } catch (err) {
    console.warn("Failed to write FootballDatabase teams to disk:", err.message || err);
  }
}

function writeNationalEloTeams(outputPath, teams) {
  try {
    writeNationalEloRankings(outputPath, teams);
  } catch (err) {
    console.warn("Failed to write National Elo teams to disk:", err.message || err);
  }
}

function writeMissingTeamLogos(outputPath, teamNames) {
  try {
    fs.writeFileSync(outputPath, JSON.stringify(teamNames, null, 2), "utf8");
  } catch (err) {
    console.warn("Failed to write missing team logos to disk:", err.message || err);
  }
}

async function persistOperationalDatasetSafe(name, payload, options = {}) {
  if (!name) return null;
  try {
    const result = await saveOperationalDataset(name, payload, options);
    recordRuntimeComponentSuccess(COMPONENT_OPERATIONAL_REDIS, {
      operation: "save_dataset",
      dataset: name,
      updated_at: options.updated_at || null,
      source: options.source || null,
      count: Array.isArray(payload)
        ? payload.length
        : payload && typeof payload === "object"
          ? Object.keys(payload).length
          : 0,
    });
    return result;
  } catch (error) {
    recordRuntimeComponentFailure(COMPONENT_OPERATIONAL_REDIS, error, {
      operation: "save_dataset",
      dataset: name,
      updated_at: options.updated_at || null,
      source: options.source || null,
    });
    console.warn(
      `[OperationalState] Failed to persist dataset ${name}:`,
      error.message || error
    );
    return null;
  }
}

async function loadOperationalDatasetSafe(name) {
  if (!name) return null;
  try {
    return await getOperationalDataset(name);
  } catch (error) {
    console.warn(
      `[OperationalState] Failed to load dataset ${name}:`,
      error.message || error
    );
    return null;
  }
}

async function persistOperationalMatchDetailsSafe(recordsById, options = {}) {
  try {
    const result = await saveOperationalMatchDetailsRecords(recordsById, options);
    recordRuntimeComponentSuccess(COMPONENT_OPERATIONAL_REDIS, {
      operation: "save_match_details",
      updated_at: options.updated_at || null,
      source: options.source || null,
      replace: Boolean(options.replace),
      count:
        recordsById && typeof recordsById === "object" ? Object.keys(recordsById).length : 0,
    });
    return result;
  } catch (error) {
    recordRuntimeComponentFailure(COMPONENT_OPERATIONAL_REDIS, error, {
      operation: "save_match_details",
      updated_at: options.updated_at || null,
      source: options.source || null,
      replace: Boolean(options.replace),
    });
    console.warn(
      "[OperationalState] Failed to persist match details to Redis:",
      error.message || error
    );
    return null;
  }
}

function shouldPersistLiveActivityTimelineSnapshot(payload) {
  if (!payload || typeof payload !== "object") return false;

  const matchId = normalizeMatchDetailsId(payload.id || payload.match_details_id);
  if (!matchId) return false;

  const status = String(payload.score_status || "").trim();
  if (isInProgressMatchStatus(status) || isFinishedMatchStatus(status)) {
    return true;
  }

  const homeScoreKnown = payload.home_score !== null && payload.home_score !== undefined;
  const awayScoreKnown = payload.away_score !== null && payload.away_score !== undefined;
  return homeScoreKnown && awayScoreKnown;
}

async function persistLiveActivityMatchTimelineSnapshotsSafe(recordsById, options = {}) {
  const candidates = {};

  Object.entries(recordsById && typeof recordsById === "object" ? recordsById : {}).forEach(
    ([matchId, payload]) => {
      if (!shouldPersistLiveActivityTimelineSnapshot(payload)) return;
      const normalizedMatchId = normalizeMatchDetailsId(
        matchId || (payload && (payload.id || payload.match_details_id))
      );
      if (!normalizedMatchId) return;
      candidates[normalizedMatchId] = payload;
    }
  );

  if (Object.keys(candidates).length === 0) {
    return {
      observed_at_ms: null,
      upserted: 0,
    };
  }

  const observedAtMsRaw =
    options && Object.prototype.hasOwnProperty.call(options, "observed_at_ms")
      ? Number(options.observed_at_ms)
      : Date.parse(String(options && options.updated_at ? options.updated_at : "").trim());
  const observedAtMs = Number.isFinite(observedAtMsRaw) ? Math.floor(observedAtMsRaw) : Date.now();

  try {
    return await saveLiveActivityMatchTimelineSnapshots(candidates, {
      observed_at_ms: observedAtMs,
    });
  } catch (error) {
    console.warn(
      "[OperationalState] Failed to persist live activity match timeline snapshots:",
      error.message || error
    );
    return null;
  }
}

function normalizeCacheStateGeneration(value, fallback = 1) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 1 ? Math.floor(parsed) : fallback;
}

function normalizeCacheStateLabel(value, fallback) {
  const normalized = String(value || "").trim();
  return normalized || fallback;
}

function buildCacheStateDomainSnapshot(options = {}) {
  return {
    generation: normalizeCacheStateGeneration(options.generation, 1),
    updated_at: options.updated_at || null,
    reason: normalizeCacheStateLabel(options.reason, "initial_seed"),
    source: normalizeCacheStateLabel(options.source, "startup"),
  };
}

function buildDefaultOperationalCacheState(nowIso = new Date().toISOString()) {
  return {
    updated_at: nowIso,
    domains: {
      matches: buildCacheStateDomainSnapshot({
        generation: 1,
        updated_at: nowIso,
      }),
      match_details: buildCacheStateDomainSnapshot({
        generation: 1,
        updated_at: nowIso,
      }),
      bbc_live: buildCacheStateDomainSnapshot({
        generation: 1,
        updated_at: nowIso,
      }),
    },
  };
}

function normalizeOperationalCacheState(payload, fallbackUpdatedAt = null) {
  const base = buildDefaultOperationalCacheState(
    fallbackUpdatedAt || new Date().toISOString()
  );
  if (!payload || typeof payload !== "object") {
    return base;
  }

  const payloadDomains =
    payload.domains && typeof payload.domains === "object" ? payload.domains : payload;
  const next = {
    updated_at: payload.updated_at || base.updated_at,
    domains: {},
  };

  CACHE_STATE_DOMAINS.forEach((domain) => {
    const domainPayload =
      payloadDomains && typeof payloadDomains[domain] === "object"
        ? payloadDomains[domain]
        : null;
    const fallbackDomain = base.domains[domain];
    next.domains[domain] = buildCacheStateDomainSnapshot({
      generation:
        domainPayload && domainPayload.generation !== undefined
          ? domainPayload.generation
          : fallbackDomain.generation,
      updated_at:
        (domainPayload && domainPayload.updated_at) ||
        payload.updated_at ||
        fallbackDomain.updated_at,
      reason:
        (domainPayload && domainPayload.reason) || fallbackDomain.reason,
      source:
        (domainPayload && domainPayload.source) || fallbackDomain.source,
    });
  });

  next.updated_at =
    payload.updated_at ||
    newestIsoTimestamp(
      CACHE_STATE_DOMAINS.map((domain) => next.domains[domain].updated_at)
    ) ||
    base.updated_at;

  return next;
}

function currentCacheStateSnapshot() {
  return normalizeOperationalCacheState(
    operationalCacheState,
    operationalCacheState && operationalCacheState.updated_at
      ? operationalCacheState.updated_at
      : null
  );
}

function normalizeCacheStateDomains(input) {
  if (input === undefined || input === null) {
    return {
      domains: CACHE_STATE_DOMAINS.slice(),
      invalid: [],
    };
  }

  const rawValues = Array.isArray(input) ? input : [input];
  const domains = [];
  const invalid = [];
  const seen = new Set();

  rawValues.forEach((value) => {
    const normalizedKey = String(value || "").trim().toLowerCase();
    if (!normalizedKey) return;
    const domain = CACHE_STATE_DOMAIN_ALIASES[normalizedKey] || null;
    if (!domain) {
      invalid.push(String(value));
      return;
    }
    if (seen.has(domain)) return;
    seen.add(domain);
    domains.push(domain);
  });

  return { domains, invalid };
}

function bumpCacheStateSnapshot(existingState, domains, options = {}) {
  const base = normalizeOperationalCacheState(existingState);
  const normalized = normalizeCacheStateDomains(domains);
  const selectedDomains = normalized.domains.length
    ? normalized.domains
    : CACHE_STATE_DOMAINS.slice();
  const updatedAt = options.updated_at || new Date().toISOString();
  const reason = normalizeCacheStateLabel(options.reason, "manual_invalidation");
  const source = normalizeCacheStateLabel(options.source, "admin_api");
  const next = {
    updated_at: updatedAt,
    domains: {},
  };

  CACHE_STATE_DOMAINS.forEach((domain) => {
    next.domains[domain] = { ...base.domains[domain] };
  });

  selectedDomains.forEach((domain) => {
    const previous = base.domains[domain] || buildCacheStateDomainSnapshot();
    next.domains[domain] = buildCacheStateDomainSnapshot({
      generation: previous.generation + 1,
      updated_at: updatedAt,
      reason,
      source,
    });
  });

  return next;
}

function invalidateCacheDomains(domains, options = {}) {
  const nextState = bumpCacheStateSnapshot(operationalCacheState, domains, options);
  operationalCacheState = nextState;
  void persistOperationalDatasetSafe(OP_DATASET_CACHE_STATE, nextState, {
    updated_at: nextState.updated_at || new Date().toISOString(),
    source: normalizeCacheStateLabel(options.source, "admin_api"),
  });
  return currentCacheStateSnapshot();
}

function setOperationalCacheStateHeaders(res, state = operationalCacheState) {
  const snapshot = normalizeOperationalCacheState(state);
  if (snapshot.updated_at) {
    res.set("X-Cache-State-Updated-At", snapshot.updated_at);
  }
  CACHE_STATE_DOMAINS.forEach((domain) => {
    const headerName = CACHE_STATE_HEADERS_BY_DOMAIN[domain];
    const generation =
      snapshot.domains &&
      snapshot.domains[domain] &&
      snapshot.domains[domain].generation !== undefined
        ? snapshot.domains[domain].generation
        : 1;
    res.set(headerName, String(generation));
  });
}

async function hydrateOperationalStateFromRedis() {
  recordRuntimeComponentStart(COMPONENT_OPERATIONAL_REDIS, {
    operation: "hydrate_operational_state",
  });
  try {
    const datasetRecords = await getOperationalDatasets([
      OP_DATASET_LIVE_MATCHES,
      OP_DATASET_BBC_LIVE_MATCHES,
      OP_DATASET_BBC_RANGE_MATCHES,
      OP_DATASET_RECENT_MATCHES,
      OP_DATASET_MERGED_MATCHES,
      OP_DATASET_PREMIER_LEAGUE_TEAMS,
      OP_DATASET_LEAGUE_TABLES,
      OP_DATASET_CLUB_ELO_TEAMS,
      OP_DATASET_FOOTBALL_DATABASE_TEAMS,
      OP_DATASET_NATIONAL_ELO_TEAMS,
      OP_DATASET_MISSING_TEAM_LOGOS,
      OP_DATASET_CACHE_STATE,
    ]);
    const matchDetailsSnapshot = await getAllOperationalMatchDetails();

    const liveRecord = datasetRecords[OP_DATASET_LIVE_MATCHES];
    if (liveRecord && Array.isArray(liveRecord.payload)) {
      cachedMatches = filterMatchesByCompetition(liveRecord.payload);
      lastUpdated = liveRecord.updated_at || lastUpdated;
      setSourceCacheSize(SOURCE_LIVE_FOOTBALL, cachedMatches.length);
    }

    const bbcLiveRecord = datasetRecords[OP_DATASET_BBC_LIVE_MATCHES];
    if (bbcLiveRecord && Array.isArray(bbcLiveRecord.payload)) {
      cachedBbcMatches = bbcLiveRecord.payload;
      bbcLastUpdated = bbcLiveRecord.updated_at || bbcLastUpdated;
      setSourceCacheSize(SOURCE_BBC_LIVE, cachedBbcMatches.length);
    }

    const bbcRangeRecord = datasetRecords[OP_DATASET_BBC_RANGE_MATCHES];
    if (bbcRangeRecord && Array.isArray(bbcRangeRecord.payload)) {
      cachedBbcRangeMatches = filterMatchesByCompetition(bbcRangeRecord.payload);
      bbcRangeLastUpdated = bbcRangeRecord.updated_at || bbcRangeLastUpdated;
      setSourceCacheSize(SOURCE_BBC_RANGE, cachedBbcRangeMatches.length);
    }

    const recentRecord = datasetRecords[OP_DATASET_RECENT_MATCHES];
    if (recentRecord && Array.isArray(recentRecord.payload)) {
      cachedRecentMatches = filterMatchesByCompetition(recentRecord.payload);
      recentLastUpdated = recentRecord.updated_at || recentLastUpdated;
      setSourceCacheSize(SOURCE_RECENT_CACHE, cachedRecentMatches.length);
    }

    const mergedRecord = datasetRecords[OP_DATASET_MERGED_MATCHES];
    if (mergedRecord && Array.isArray(mergedRecord.payload)) {
      cachedMergedMatches = filterMatchesByCompetition(mergedRecord.payload);
    }

    const teamsRecord = datasetRecords[OP_DATASET_PREMIER_LEAGUE_TEAMS];
    if (teamsRecord && Array.isArray(teamsRecord.payload)) {
      cachedPremierLeagueTeams = teamsRecord.payload
        .map((team) => String(team || "").trim())
        .filter(Boolean);
      eplLastUpdated = teamsRecord.updated_at || eplLastUpdated;
      setSourceCacheSize(SOURCE_BBC_PREMIER_LEAGUE, cachedPremierLeagueTeams.length);
    }

    const leagueTablesRecord = datasetRecords[OP_DATASET_LEAGUE_TABLES];
    if (leagueTablesRecord && Array.isArray(leagueTablesRecord.payload)) {
      cachedLeagueTables = sortLeagueTablesForResponse(leagueTablesRecord.payload);
      leagueTablesLastUpdated = leagueTablesRecord.updated_at || leagueTablesLastUpdated;
      setSourceCacheSize(SOURCE_BBC_LEAGUE_TABLES, leagueTableRowsCount(cachedLeagueTables));
    }

    const clubEloRecord = datasetRecords[OP_DATASET_CLUB_ELO_TEAMS];
    if (clubEloRecord && Array.isArray(clubEloRecord.payload)) {
      cachedClubEloTeams = normalizeClubEloTeamsPayload(clubEloRecord.payload);
      clubEloLastUpdated = clubEloRecord.updated_at || clubEloLastUpdated;
      setSourceCacheSize(SOURCE_CLUB_ELO, cachedClubEloTeams.length);
      markClubEloSuccess(clubEloLastUpdated, cachedClubEloTeams);
    }

    const footballDatabaseRecord = datasetRecords[OP_DATASET_FOOTBALL_DATABASE_TEAMS];
    if (footballDatabaseRecord && Array.isArray(footballDatabaseRecord.payload)) {
      cachedFootballDatabaseTeams = normalizeFootballDatabaseTeamsPayload(
        footballDatabaseRecord.payload
      );
      footballDatabaseLastUpdated =
        footballDatabaseRecord.updated_at || footballDatabaseLastUpdated;
      setSourceCacheSize(SOURCE_FOOTBALL_DATABASE, cachedFootballDatabaseTeams.length);
      markFootballDatabaseSuccess(
        footballDatabaseLastUpdated,
        cachedFootballDatabaseTeams
      );
    }

    const nationalEloRecord = datasetRecords[OP_DATASET_NATIONAL_ELO_TEAMS];
    if (nationalEloRecord && Array.isArray(nationalEloRecord.payload)) {
      cachedNationalEloTeams = normalizeNationalEloTeamsPayload(nationalEloRecord.payload);
      nationalEloLastUpdated = nationalEloRecord.updated_at || nationalEloLastUpdated;
      setSourceCacheSize(SOURCE_NATIONAL_ELO, cachedNationalEloTeams.length);
      markNationalEloSuccess(
        nationalEloLastUpdated,
        cachedNationalEloTeams,
        null,
        nationalEloLastUpdated ? String(nationalEloLastUpdated).slice(0, 10) : null
      );
    }

    const missingLogosRecord = datasetRecords[OP_DATASET_MISSING_TEAM_LOGOS];
    if (missingLogosRecord && Array.isArray(missingLogosRecord.payload)) {
      missingTeamLogosByKey = new Map();
      missingLogosRecord.payload.forEach((teamName) => {
        const normalized = normalizeMissingTeamLogoName(teamName);
        if (!normalized) return;
        missingTeamLogosByKey.set(missingTeamLogoKey(normalized), normalized);
      });
      missingTeamLogosLastUpdated = missingLogosRecord.updated_at || missingTeamLogosLastUpdated;
      const removedResolvedEntries = pruneResolvableMissingTeamLogos();
      if (removedResolvedEntries.length > 0) {
        missingTeamLogosLastUpdated = new Date().toISOString();
        const names = sortedMissingTeamLogoNames();
        writeMissingTeamLogos(MISSING_TEAM_LOGOS_OUTPUT_PATH, names);
        await persistOperationalDatasetSafe(OP_DATASET_MISSING_TEAM_LOGOS, names, {
          updated_at: missingTeamLogosLastUpdated,
          source: "missing_team_logos_prune_resolved",
        });
      }
    }

    const cacheStateRecord = datasetRecords[OP_DATASET_CACHE_STATE];
    if (cacheStateRecord && cacheStateRecord.payload && typeof cacheStateRecord.payload === "object") {
      operationalCacheState = normalizeOperationalCacheState(
        cacheStateRecord.payload,
        cacheStateRecord.updated_at || null
      );
    }

    if (matchDetailsSnapshot && matchDetailsSnapshot.records) {
      const entries = Object.entries(matchDetailsSnapshot.records);
      matchDetailsById = new Map(entries);
      if (matchDetailsSnapshot.updated_at) {
        matchDetailsLastUpdated = matchDetailsSnapshot.updated_at;
      }
      setSourceCacheSize(SOURCE_BBC_MATCH_DETAILS, matchDetailsById.size);
    }

    refreshClubEloUnmatchedTeamMetric(cachedMergedMatches, cachedClubEloTeams);
    refreshFootballDatabaseUnmatchedTeamMetric(
      cachedMergedMatches,
      cachedFootballDatabaseTeams
    );
    refreshNationalEloUnmatchedTeamMetric(cachedMergedMatches, cachedNationalEloTeams);

    console.log(
      "[OperationalState] Hydrated from Redis:",
      JSON.stringify({
        live_matches: cachedMatches.length,
        bbc_live_matches: cachedBbcMatches.length,
        bbc_range_matches: cachedBbcRangeMatches.length,
        merged_matches: cachedMergedMatches.length,
        recent_matches: cachedRecentMatches.length,
        league_tables: cachedLeagueTables.length,
        club_elo_teams: cachedClubEloTeams.length,
        football_database_teams: cachedFootballDatabaseTeams.length,
        national_elo_teams: cachedNationalEloTeams.length,
        match_details: matchDetailsById.size,
        cache_state_updated_at: operationalCacheState.updated_at,
      })
    );
    recordRuntimeComponentSuccess(COMPONENT_OPERATIONAL_REDIS, {
      operation: "hydrate_operational_state",
      updated_at: operationalCacheState.updated_at,
      merged_matches: cachedMergedMatches.length,
      match_details: matchDetailsById.size,
    });
  } catch (error) {
    recordRuntimeComponentFailure(COMPONENT_OPERATIONAL_REDIS, error, {
      operation: "hydrate_operational_state",
    });
    console.warn("[OperationalState] Failed to hydrate from Redis:", error.message || error);
  }
}

async function persistStartupOperationalStateFromDisk() {
  recordRuntimeComponentStart(COMPONENT_BOOTSTRAP, {
    operation: "persist_startup_state_from_disk",
  });
  await Promise.all([
    persistOperationalDatasetSafe(OP_DATASET_LIVE_MATCHES, cachedMatches, {
      updated_at: lastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_BBC_LIVE_MATCHES, cachedBbcMatches, {
      updated_at: bbcLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_BBC_RANGE_MATCHES, cachedBbcRangeMatches, {
      updated_at: bbcRangeLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_RECENT_MATCHES, cachedRecentMatches, {
      updated_at: recentLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_MERGED_MATCHES, cachedMergedMatches, {
      updated_at: newestIsoTimestamp([bbcRangeLastUpdated, lastUpdated, bbcLastUpdated]) || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_PREMIER_LEAGUE_TEAMS, cachedPremierLeagueTeams, {
      updated_at: eplLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_LEAGUE_TABLES, cachedLeagueTables, {
      updated_at: leagueTablesLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_CLUB_ELO_TEAMS, cachedClubEloTeams, {
      updated_at: clubEloLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
      ttl_seconds: CLUB_ELO_REDIS_TTL_SECONDS,
    }),
    persistOperationalDatasetSafe(
      OP_DATASET_FOOTBALL_DATABASE_TEAMS,
      cachedFootballDatabaseTeams,
      {
        updated_at: footballDatabaseLastUpdated || new Date().toISOString(),
        source: "startup_disk_seed",
        ttl_seconds: FOOTBALL_DATABASE_REDIS_TTL_SECONDS,
      }
    ),
    persistOperationalDatasetSafe(OP_DATASET_NATIONAL_ELO_TEAMS, cachedNationalEloTeams, {
      updated_at: nationalEloLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
      ttl_seconds: NATIONAL_ELO_REDIS_TTL_SECONDS,
    }),
    persistOperationalDatasetSafe(OP_DATASET_MISSING_TEAM_LOGOS, sortedMissingTeamLogoNames(), {
      updated_at: missingTeamLogosLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_CACHE_STATE, currentCacheStateSnapshot(), {
      updated_at:
        (operationalCacheState && operationalCacheState.updated_at) || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalMatchDetailsSafe(Object.fromEntries(matchDetailsById), {
      replace: true,
      updated_at: matchDetailsLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
  ]);
  recordRuntimeComponentSuccess(COMPONENT_BOOTSTRAP, {
    operation: "persist_startup_state_from_disk",
    merged_matches: cachedMergedMatches.length,
    match_details: matchDetailsById.size,
  });
}

async function getOperationalArrayDataset(name, fallback = []) {
  const record = await loadOperationalDatasetSafe(name);
  if (record && Array.isArray(record.payload)) {
    return {
      items: record.payload,
      updated_at: record.updated_at || null,
      source: "redis",
    };
  }
  const fallbackItems = Array.isArray(fallback) ? fallback : [];
  return {
    items: fallbackItems,
    updated_at: null,
    source: "memory_fallback",
  };
}

function getMatchDetailsStatePayload(payload) {
  if (!payload || typeof payload !== "object") return null;
  const id = normalizeMatchDetailsId(payload.id);
  if (!id) return null;

  const homeScore = parseNumericScore(payload.home_score);
  const awayScore = parseNumericScore(payload.away_score);
  const aggregate = resolveKnownAggregateScores(payload);
  const firstLegHomeScore = parseNumericScore(payload.first_leg_home_score);
  const firstLegAwayScore = parseNumericScore(payload.first_leg_away_score);
  const scoreStatus = resolveStableMatchScoreStatus(payload);

  const statePayload = {
    id,
    details_url: payload.details_url || null,
    date: payload.date || null,
    time: payload.time || null,
    league: payload.league || null,
    home_team: payload.home_team || null,
    away_team: payload.away_team || null,
    home_score: homeScore,
    away_score: awayScore,
    aggregate_home_score: aggregate.home,
    aggregate_away_score: aggregate.away,
    first_leg_home_score: firstLegHomeScore,
    first_leg_away_score: firstLegAwayScore,
    score_status: scoreStatus,
    penalty_result: payload.penalty_result || null,
    in_progress: isInProgressMatchStatus(scoreStatus),
    updated_at: payload.updated_at || null,
  };

  const teamLineups = normalizeTeamLineupsPayload(payload.team_lineups);
  if (teamLineups) {
    statePayload.team_lineups = teamLineups;
  }

  return statePayload;
}

function currentMatchDetailsLookupSnapshot() {
  if (matchDetailsById.size > 0) {
    return {
      lookup: matchDetailsById,
      updated_at: matchDetailsLastUpdated,
      source: "memory",
    };
  }
  return null;
}

async function getOperationalMatchDetailsByIdSafe(matchId) {
  const normalized = normalizeMatchDetailsId(matchId);
  if (!normalized) {
    return { payload: null, source: "invalid_match_id" };
  }

  const cached = matchDetailsById.get(normalized);
  if (cached && typeof cached === "object") {
    return { payload: cached, source: "memory" };
  }

  const payload = await getOperationalMatchDetails(normalized);
  if (payload && typeof payload === "object") {
    matchDetailsById.set(normalized, payload);
    if (payload.updated_at && (!matchDetailsLastUpdated || payload.updated_at > matchDetailsLastUpdated)) {
      matchDetailsLastUpdated = payload.updated_at;
    }
    return { payload, source: "redis" };
  }
  return {
    payload: null,
    source: "redis_missing",
  };
}

async function getOperationalMatchDetailsBatchSafe(matchIds) {
  const uniqueIds = [];
  const seen = new Set();
  (Array.isArray(matchIds) ? matchIds : []).forEach((matchId) => {
    const normalized = normalizeMatchDetailsId(matchId);
    if (!normalized || seen.has(normalized)) return;
    seen.add(normalized);
    uniqueIds.push(normalized);
  });

  const payloadsById = new Map();
  const missingIds = [];

  uniqueIds.forEach((matchId) => {
    const cached = matchDetailsById.get(matchId);
    if (cached && typeof cached === "object") {
      payloadsById.set(matchId, cached);
    } else {
      missingIds.push(matchId);
    }
  });

  if (missingIds.length > 0) {
    await Promise.all(
      missingIds.map(async (matchId) => {
        const payload = await getOperationalMatchDetails(matchId);
        if (!payload || typeof payload !== "object") return;
        matchDetailsById.set(matchId, payload);
        payloadsById.set(matchId, payload);
        if (payload.updated_at && (!matchDetailsLastUpdated || payload.updated_at > matchDetailsLastUpdated)) {
          matchDetailsLastUpdated = payload.updated_at;
        }
      })
    );
  }

  return {
    payloadsById,
    source: missingIds.length > 0 ? "memory+redis" : "memory",
  };
}

async function getOperationalMatchDetailsSnapshotSafe() {
  const snapshot = await getAllOperationalMatchDetails();
  if (snapshot && snapshot.records && typeof snapshot.records === "object") {
    return {
      ...snapshot,
      source: "redis",
    };
  }
  return {
    updated_at: null,
    total: 0,
    records: {},
    source: "redis_missing",
    error: snapshot && snapshot.error ? snapshot.error : null,
  };
}

const ADMIN_OPERATIONAL_DATASET_NAMES = [
  OP_DATASET_MERGED_MATCHES,
  OP_DATASET_LIVE_MATCHES,
  OP_DATASET_BBC_LIVE_MATCHES,
  OP_DATASET_BBC_RANGE_MATCHES,
  OP_DATASET_RECENT_MATCHES,
  OP_DATASET_PREMIER_LEAGUE_TEAMS,
  OP_DATASET_CLUB_ELO_TEAMS,
  OP_DATASET_FOOTBALL_DATABASE_TEAMS,
  OP_DATASET_NATIONAL_ELO_TEAMS,
  OP_DATASET_LEAGUE_TABLES,
  OP_DATASET_CACHE_STATE,
];

function toOperationalAdminMatchPayload(payload) {
  if (!payload || typeof payload !== "object") return null;
  const matchId = normalizeMatchDetailsId(payload.id) || null;
  if (!matchId) return null;
  return {
    match_id: matchId,
    id: matchId,
    details_url: payload.details_url || null,
    date: payload.date || null,
    time: payload.time || null,
    league: payload.league || null,
    home_team: payload.home_team || null,
    away_team: payload.away_team || null,
    home_score:
      payload.home_score !== undefined && payload.home_score !== null ? payload.home_score : null,
    away_score:
      payload.away_score !== undefined && payload.away_score !== null ? payload.away_score : null,
    aggregate_home_score:
      payload.aggregate_home_score !== undefined && payload.aggregate_home_score !== null
        ? payload.aggregate_home_score
        : null,
    aggregate_away_score:
      payload.aggregate_away_score !== undefined && payload.aggregate_away_score !== null
        ? payload.aggregate_away_score
        : null,
    score_status: payload.score_status || null,
    in_progress: Boolean(payload.in_progress),
    penalty_result: payload.penalty_result || null,
    home_goal_scorers: Array.isArray(payload.home_goal_scorers) ? payload.home_goal_scorers : [],
    away_goal_scorers: Array.isArray(payload.away_goal_scorers) ? payload.away_goal_scorers : [],
    home_assists: Array.isArray(payload.home_assists) ? payload.home_assists : [],
    away_assists: Array.isArray(payload.away_assists) ? payload.away_assists : [],
    home_yellow_cards: Array.isArray(payload.home_yellow_cards) ? payload.home_yellow_cards : [],
    away_yellow_cards: Array.isArray(payload.away_yellow_cards) ? payload.away_yellow_cards : [],
    home_red_cards: Array.isArray(payload.home_red_cards) ? payload.home_red_cards : [],
    away_red_cards: Array.isArray(payload.away_red_cards) ? payload.away_red_cards : [],
    team_lineups: normalizeTeamLineupsPayload(payload.team_lineups),
    updated_at: payload.updated_at || null,
  };
}

function operationalMatchSortDesc(lhs, rhs) {
  const lhsUpdated = Date.parse(lhs && lhs.updated_at ? lhs.updated_at : "");
  const rhsUpdated = Date.parse(rhs && rhs.updated_at ? rhs.updated_at : "");
  if (Number.isFinite(lhsUpdated) || Number.isFinite(rhsUpdated)) {
    const leftValue = Number.isFinite(lhsUpdated) ? lhsUpdated : 0;
    const rightValue = Number.isFinite(rhsUpdated) ? rhsUpdated : 0;
    if (rightValue !== leftValue) return rightValue - leftValue;
  }
  const lhsKickoff = Date.parse(
    `${String(lhs && lhs.date ? lhs.date : "").trim()}T${String(
      lhs && lhs.time ? lhs.time : "00:00"
    ).trim()}:00Z`
  );
  const rhsKickoff = Date.parse(
    `${String(rhs && rhs.date ? rhs.date : "").trim()}T${String(
      rhs && rhs.time ? rhs.time : "00:00"
    ).trim()}:00Z`
  );
  if (Number.isFinite(lhsKickoff) || Number.isFinite(rhsKickoff)) {
    const leftValue = Number.isFinite(lhsKickoff) ? lhsKickoff : 0;
    const rightValue = Number.isFinite(rhsKickoff) ? rhsKickoff : 0;
    if (rightValue !== leftValue) return rightValue - leftValue;
  }
  const lhsId = String(lhs && lhs.match_id ? lhs.match_id : "");
  const rhsId = String(rhs && rhs.match_id ? rhs.match_id : "");
  return lhsId.localeCompare(rhsId);
}

async function getOperationalRealtimeSnapshot(options = {}) {
  const matchIdFilter = normalizeMatchDetailsId(options.match_id || "");
  const limitMatches = parsePositiveInt(options.limit_matches, 0, 0, 1000);
  const nowIso = new Date().toISOString();

  try {
    const [datasetRecords, matchDetailsSummary] = await Promise.all([
      getOperationalDatasets(ADMIN_OPERATIONAL_DATASET_NAMES),
      getOperationalMatchDetailsSummary(),
    ]);

    let matches = [];
    let matchDetailsSource = matchDetailsSummary && matchDetailsSummary.source
      ? matchDetailsSummary.source
      : null;

    if (matchIdFilter) {
      const payload = await getOperationalMatchDetails(matchIdFilter);
      if (payload && typeof payload === "object") {
        const normalizedPayload = toOperationalAdminMatchPayload(payload);
        if (normalizedPayload) {
          matches = [normalizedPayload];
        }
      }
    } else {
      const snapshot = await getAllOperationalMatchDetails();
      if (snapshot && snapshot.records && typeof snapshot.records === "object") {
        matches = Object.values(snapshot.records)
          .map((payload) => toOperationalAdminMatchPayload(payload))
          .filter(Boolean)
          .sort(operationalMatchSortDesc);
        if (limitMatches > 0) {
          matches = matches.slice(0, limitMatches);
        }
        if (snapshot.source) {
          matchDetailsSource = snapshot.source;
        }
      }
    }

    const datasetCounts = {};
    const datasetMeta = {};
    ADMIN_OPERATIONAL_DATASET_NAMES.forEach((name) => {
      const record = datasetRecords && datasetRecords[name] ? datasetRecords[name] : null;
      const payload = record && Array.isArray(record.payload) ? record.payload : [];
      datasetCounts[name] = payload.length;
      datasetMeta[name] = {
        updated_at: record && record.updated_at ? record.updated_at : null,
        source: record && record.source ? record.source : null,
      };
    });

    return {
      generated_at: nowIso,
      filters: {
        match_id: matchIdFilter || null,
        limit_matches: limitMatches > 0 ? limitMatches : null,
      },
      count_matches: matches.length,
      count_match_details_total: Number(matchDetailsSummary && matchDetailsSummary.total
        ? matchDetailsSummary.total
        : 0),
      match_details_updated_at:
        matchDetailsSummary && matchDetailsSummary.updated_at
          ? matchDetailsSummary.updated_at
          : null,
      match_details_source: matchDetailsSource,
      dataset_counts: datasetCounts,
      dataset_meta: datasetMeta,
      matches,
    };
  } catch (error) {
    console.error("[API] Error building operational realtime snapshot:", error);
    return {
      generated_at: nowIso,
      filters: {
        match_id: matchIdFilter || null,
        limit_matches: limitMatches > 0 ? limitMatches : null,
      },
      count_matches: 0,
      count_match_details_total: 0,
      match_details_updated_at: null,
      match_details_source: null,
      dataset_counts: {},
      dataset_meta: {},
      matches: [],
      error: error.message || String(error),
    };
  }
}

async function updateRecentCache(source = "recent_cache_refresh") {
  const now = new Date();
  const live = Array.isArray(cachedMatches) ? cachedMatches : [];
  const bbc = Array.isArray(cachedBbcMatches) ? cachedBbcMatches : [];
  const liveKeys = new Set(live.map(matchKey));

  const map = new Map();
  cachedRecentMatches.forEach((match) => {
    if (!match) return;
    map.set(matchKey(match), match);
  });

  live.forEach((match) => {
    if (!match) return;
    const key = matchKey(match);
    const existing = map.get(key);
    map.set(key, existing ? { ...existing, ...match } : { ...match });
  });

  const withScores = applyScoresToMatches(Array.from(map.values()), bbc, now);
  const next = [];
  withScores.forEach((match) => {
    const key = matchKey(match);
    if (liveKeys.has(key) || isWithinRetention(match, now)) {
      next.push(match);
    }
  });

  cachedRecentMatches = next;
  recentLastUpdated = now.toISOString();
  setSourceCacheSize(SOURCE_RECENT_CACHE, cachedRecentMatches.length);
  writeRecentMatches(RECENT_OUTPUT_PATH, cachedRecentMatches);
  indexMatchDetailsFromMatches(cachedRecentMatches, recentLastUpdated);
  await persistOperationalDatasetSafe(OP_DATASET_RECENT_MATCHES, cachedRecentMatches, {
    updated_at: recentLastUpdated,
    source,
  });
}

function mergedMatchesForResponse() {
  return Array.isArray(cachedMergedMatches) ? cachedMergedMatches : [];
}

function currentMergedMatchesDatasetSnapshot() {
  return {
    items: mergedMatchesForResponse(),
    updated_at:
      newestIsoTimestamp([bbcRangeLastUpdated, lastUpdated, bbcLastUpdated, recentLastUpdated]) ||
      null,
    source: "memory",
  };
}

function currentPremierLeagueTeamsDatasetSnapshot() {
  return {
    items: Array.isArray(cachedPremierLeagueTeams) ? cachedPremierLeagueTeams : [],
    updated_at: eplLastUpdated || null,
    source: "memory",
  };
}

function scheduleMatchDetailsSnapshotWarm(trigger = "request") {
  if (matchDetailsById.size > 0 || matchDetailsSnapshotWarmTask) return false;

  matchDetailsSnapshotWarmTask = (async () => {
    try {
      const snapshot = await getAllOperationalMatchDetails();
      if (!snapshot || !snapshot.records || typeof snapshot.records !== "object") return;
      const entries = Object.entries(snapshot.records);
      if (entries.length === 0) return;
      matchDetailsById = new Map(entries);
      if (snapshot.updated_at) {
        matchDetailsLastUpdated = snapshot.updated_at;
      }
      setSourceCacheSize(SOURCE_BBC_MATCH_DETAILS, matchDetailsById.size);
    } catch (error) {
      console.warn(
        `[API] Failed to warm match details snapshot (${trigger}):`,
        error.message || error
      );
    } finally {
      matchDetailsSnapshotWarmTask = null;
    }
  })();

  return true;
}

function currentFastMatchDetailsLookupSnapshot(trigger = "request") {
  const current = currentMatchDetailsLookupSnapshot();
  if (current) return current;
  scheduleMatchDetailsSnapshotWarm(trigger);
  return {
    lookup: {},
    updated_at: matchDetailsLastUpdated,
    source: "memory_missing",
  };
}

function redisReconciliationStatusCode(status) {
  switch (status) {
    case "in_sync":
      return 0;
    case "memory_missing":
      return 1;
    case "redis_missing":
      return 2;
    case "redis_stale":
      return 3;
    case "redis_newer":
      return 4;
    case "payload_mismatch":
      return 5;
    case "meta_out_of_sync":
      return 6;
    case "empty":
      return 7;
    case "error":
      return 8;
    default:
      return 9;
  }
}

function stableJsonStringify(value) {
  if (value === null || value === undefined) return JSON.stringify(value);
  if (Array.isArray(value)) {
    return `[${value.map((entry) => stableJsonStringify(entry)).join(",")}]`;
  }
  if (typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJsonStringify(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function hashComparablePayload(value) {
  return crypto.createHash("sha1").update(stableJsonStringify(value)).digest("hex");
}

function ageSecondsFromIso(value, nowMs = Date.now()) {
  const parsed = Date.parse(String(value || "").trim());
  if (!Number.isFinite(parsed)) return null;
  return Math.max(0, Math.floor((nowMs - parsed) / 1000));
}

function secondsDeltaBetweenIso(leftIso, rightIso) {
  const leftMs = Date.parse(String(leftIso || "").trim());
  const rightMs = Date.parse(String(rightIso || "").trim());
  if (!Number.isFinite(leftMs) || !Number.isFinite(rightMs)) return null;
  return Math.floor((leftMs - rightMs) / 1000);
}

function buildRedisReconciliationStatePatch(patch = {}) {
  return {
    generated_at: patch.generated_at || new Date().toISOString(),
    last_run_started_at: patch.last_run_started_at || null,
    last_run_completed_at: patch.last_run_completed_at || null,
    last_duration_ms: Number.isFinite(patch.last_duration_ms) ? patch.last_duration_ms : 0,
    last_trigger: patch.last_trigger || null,
    running: Boolean(patch.running),
    healthy: Boolean(patch.healthy),
    auto_repair_enabled:
      patch.auto_repair_enabled !== undefined
        ? Boolean(patch.auto_repair_enabled)
        : REDIS_RECONCILIATION_AUTO_REPAIR,
    config: {
      interval_ms: REDIS_RECONCILIATION_INTERVAL_MS,
      sample_limit: REDIS_RECONCILIATION_SAMPLE_LIMIT,
      freshness_warn_seconds: REDIS_RECONCILIATION_FRESHNESS_WARN_SECONDS,
    },
    summary: patch.summary && typeof patch.summary === "object" ? patch.summary : {},
    components: Array.isArray(patch.components) ? patch.components : [],
    notes: Array.isArray(patch.notes) ? patch.notes : [],
    last_error: patch.last_error || null,
  };
}

function ensureRedisReconciliationState() {
  if (!redisReconciliationState) {
    redisReconciliationState = buildRedisReconciliationStatePatch({
      healthy: true,
      summary: {
        total_components: 0,
        healthy_components: 0,
        unhealthy_components: 0,
        status_counts: {},
      },
      notes: [
        "Runtime memory is authoritative for serving responses; Redis is a persisted operational snapshot.",
      ],
    });
  }
  return redisReconciliationState;
}

function cloneComparablePayload(value) {
  if (value === undefined) return null;
  return JSON.parse(JSON.stringify(value));
}

function currentOperationalDatasetMemorySnapshot(name) {
  switch (name) {
    case OP_DATASET_MERGED_MATCHES:
      return currentMergedMatchesDatasetSnapshot();
    case OP_DATASET_LIVE_MATCHES:
      return {
        items: Array.isArray(cachedMatches) ? cachedMatches : [],
        updated_at: lastUpdated || null,
        source: "memory",
      };
    case OP_DATASET_BBC_LIVE_MATCHES:
      return {
        items: Array.isArray(cachedBbcMatches) ? cachedBbcMatches : [],
        updated_at: bbcLastUpdated || null,
        source: "memory",
      };
    case OP_DATASET_BBC_RANGE_MATCHES:
      return {
        items: Array.isArray(cachedBbcRangeMatches) ? cachedBbcRangeMatches : [],
        updated_at: bbcRangeLastUpdated || null,
        source: "memory",
      };
    case OP_DATASET_RECENT_MATCHES:
      return {
        items: Array.isArray(cachedRecentMatches) ? cachedRecentMatches : [],
        updated_at: recentLastUpdated || null,
        source: "memory",
      };
    case OP_DATASET_PREMIER_LEAGUE_TEAMS:
      return currentPremierLeagueTeamsDatasetSnapshot();
    case OP_DATASET_CLUB_ELO_TEAMS:
      return {
        items: Array.isArray(cachedClubEloTeams) ? cachedClubEloTeams : [],
        updated_at: clubEloLastUpdated || null,
        source: "memory",
      };
    case OP_DATASET_FOOTBALL_DATABASE_TEAMS:
      return {
        items: Array.isArray(cachedFootballDatabaseTeams) ? cachedFootballDatabaseTeams : [],
        updated_at: footballDatabaseLastUpdated || null,
        source: "memory",
      };
    case OP_DATASET_NATIONAL_ELO_TEAMS:
      return {
        items: Array.isArray(cachedNationalEloTeams) ? cachedNationalEloTeams : [],
        updated_at: nationalEloLastUpdated || null,
        source: "memory",
      };
    case OP_DATASET_LEAGUE_TABLES:
      return {
        items: Array.isArray(cachedLeagueTables) ? cachedLeagueTables : [],
        updated_at: leagueTablesLastUpdated || null,
        source: "memory",
      };
    case OP_DATASET_CACHE_STATE:
      return {
        payload: currentCacheStateSnapshot(),
        updated_at:
          operationalCacheState && operationalCacheState.updated_at
            ? operationalCacheState.updated_at
            : null,
        source: "memory",
      };
    default:
      return {
        items: [],
        updated_at: null,
        source: "memory_unknown",
      };
  }
}

function currentOperationalMemoryDatasetSnapshots() {
  const output = {};
  ADMIN_OPERATIONAL_DATASET_NAMES.forEach((name) => {
    output[name] = currentOperationalDatasetMemorySnapshot(name);
  });
  return output;
}

function currentOperationalMatchDetailsMemorySnapshot() {
  const snapshot = currentMatchDetailsLookupSnapshot();
  const records = {};
  if (snapshot && snapshot.lookup instanceof Map) {
    Array.from(snapshot.lookup.entries())
      .sort(([leftId], [rightId]) => leftId.localeCompare(rightId))
      .forEach(([matchId, payload]) => {
        records[matchId] = payload;
      });
  }
  return {
    updated_at: snapshot && snapshot.updated_at ? snapshot.updated_at : matchDetailsLastUpdated || null,
    total: Object.keys(records).length,
    records,
    source: snapshot && snapshot.source ? snapshot.source : "memory_missing",
  };
}

function operationalPersistOptionsForDataset(name, updatedAt, source) {
  const options = {
    updated_at: updatedAt || new Date().toISOString(),
    source,
  };
  if (name === OP_DATASET_CLUB_ELO_TEAMS) {
    options.ttl_seconds = CLUB_ELO_REDIS_TTL_SECONDS;
  } else if (name === OP_DATASET_FOOTBALL_DATABASE_TEAMS) {
    options.ttl_seconds = FOOTBALL_DATABASE_REDIS_TTL_SECONDS;
  } else if (name === OP_DATASET_NATIONAL_ELO_TEAMS) {
    options.ttl_seconds = NATIONAL_ELO_REDIS_TTL_SECONDS;
  }
  return options;
}

function comparableEntryIdentity(item, index) {
  if (item && typeof item === "object") {
    const candidates = [
      item.id,
      item.match_id,
      item.matchId,
      item.details_url,
      item.detailsUrl,
      item.name,
      item.club,
      item.team,
      item.code,
    ];
    const first = candidates.find((candidate) => String(candidate || "").trim());
    if (first) {
      return String(first).trim();
    }
    const homeTeam = item.home_team || item.homeTeam;
    const awayTeam = item.away_team || item.awayTeam;
    const league = item.league || item.competition;
    const date = item.date || "";
    const time = item.time || "";
    if (homeTeam || awayTeam || league || date || time) {
      return [date, time, league, homeTeam, awayTeam].map((value) => String(value || "").trim()).join("|");
    }
  }
  return `index:${index}`;
}

function comparableEntryPreview(item, index) {
  if (item && typeof item === "object") {
    return {
      key: comparableEntryIdentity(item, index),
      id: item.id || item.match_id || item.matchId || null,
      date: item.date || null,
      time: item.time || null,
      league: item.league || item.competition || null,
      home_team: item.home_team || item.homeTeam || null,
      away_team: item.away_team || item.awayTeam || null,
      status: item.score_status || item.match_time || item.matchTime || null,
      updated_at: item.updated_at || null,
      value:
        typeof item === "object" && !Array.isArray(item)
          ? undefined
          : item,
    };
  }
  return {
    key: `index:${index}`,
    value: item,
  };
}

function buildArrayDiffSamples(memoryItems, redisItems, sampleLimit = REDIS_RECONCILIATION_SAMPLE_LIMIT) {
  const memoryMap = new Map();
  const redisMap = new Map();

  (Array.isArray(memoryItems) ? memoryItems : []).forEach((item, index) => {
    const identity = comparableEntryIdentity(item, index);
    const key = memoryMap.has(identity) ? `${identity}#${index}` : identity;
    memoryMap.set(key, {
      hash: hashComparablePayload(item),
      preview: comparableEntryPreview(item, index),
    });
  });

  (Array.isArray(redisItems) ? redisItems : []).forEach((item, index) => {
    const identity = comparableEntryIdentity(item, index);
    const key = redisMap.has(identity) ? `${identity}#${index}` : identity;
    redisMap.set(key, {
      hash: hashComparablePayload(item),
      preview: comparableEntryPreview(item, index),
    });
  });

  const onlyInMemory = [];
  const onlyInRedis = [];
  const changed = [];
  const keys = Array.from(new Set([...memoryMap.keys(), ...redisMap.keys()])).sort();

  keys.forEach((key) => {
    const memoryEntry = memoryMap.get(key);
    const redisEntry = redisMap.get(key);
    if (memoryEntry && !redisEntry) {
      if (onlyInMemory.length < sampleLimit) {
        onlyInMemory.push(memoryEntry.preview);
      }
      return;
    }
    if (!memoryEntry && redisEntry) {
      if (onlyInRedis.length < sampleLimit) {
        onlyInRedis.push(redisEntry.preview);
      }
      return;
    }
    if (memoryEntry && redisEntry && memoryEntry.hash !== redisEntry.hash && changed.length < sampleLimit) {
      changed.push({
        key,
        memory: memoryEntry.preview,
        redis: redisEntry.preview,
      });
    }
  });

  return {
    only_in_memory: onlyInMemory,
    only_in_redis: onlyInRedis,
    changed,
    summary: {
      only_in_memory: keys.filter((key) => memoryMap.has(key) && !redisMap.has(key)).length,
      only_in_redis: keys.filter((key) => !memoryMap.has(key) && redisMap.has(key)).length,
      changed: keys.filter((key) => {
        const memoryEntry = memoryMap.get(key);
        const redisEntry = redisMap.get(key);
        return memoryEntry && redisEntry && memoryEntry.hash !== redisEntry.hash;
      }).length,
    },
  };
}

function collectObjectDiffPaths(memoryValue, redisValue, basePath = "", output = [], limit = REDIS_RECONCILIATION_SAMPLE_LIMIT) {
  if (output.length >= limit) return output;

  const bothObjects =
    memoryValue &&
    redisValue &&
    typeof memoryValue === "object" &&
    typeof redisValue === "object" &&
    !Array.isArray(memoryValue) &&
    !Array.isArray(redisValue);

  if (bothObjects) {
    const keys = Array.from(
      new Set([...Object.keys(memoryValue), ...Object.keys(redisValue)])
    ).sort();
    keys.forEach((key) => {
      if (output.length >= limit) return;
      const nextPath = basePath ? `${basePath}.${key}` : key;
      if (!Object.prototype.hasOwnProperty.call(memoryValue, key)) {
        output.push({ path: nextPath, type: "only_in_redis" });
        return;
      }
      if (!Object.prototype.hasOwnProperty.call(redisValue, key)) {
        output.push({ path: nextPath, type: "only_in_memory" });
        return;
      }
      collectObjectDiffPaths(memoryValue[key], redisValue[key], nextPath, output, limit);
    });
    return output;
  }

  const memorySerialized = stableJsonStringify(memoryValue);
  const redisSerialized = stableJsonStringify(redisValue);
  if (memorySerialized !== redisSerialized) {
    output.push({
      path: basePath || "$",
      memory: memoryValue === undefined ? null : memoryValue,
      redis: redisValue === undefined ? null : redisValue,
    });
  }
  return output;
}

function buildMatchDetailsDiffSamples(memoryRecords, redisRecords, sampleLimit = REDIS_RECONCILIATION_SAMPLE_LIMIT) {
  const memoryIds = Object.keys(memoryRecords || {}).sort();
  const redisIds = Object.keys(redisRecords || {}).sort();
  const memorySet = new Set(memoryIds);
  const redisSet = new Set(redisIds);
  const onlyInMemory = [];
  const onlyInRedis = [];
  const changed = [];

  memoryIds.forEach((matchId) => {
    if (!redisSet.has(matchId) && onlyInMemory.length < sampleLimit) {
      const payload = memoryRecords[matchId];
      onlyInMemory.push({
        match_id: matchId,
        updated_at: payload && payload.updated_at ? payload.updated_at : null,
        score_status: payload && payload.score_status ? payload.score_status : null,
        home_score: payload && payload.home_score !== undefined ? payload.home_score : null,
        away_score: payload && payload.away_score !== undefined ? payload.away_score : null,
      });
    }
  });
  redisIds.forEach((matchId) => {
    if (!memorySet.has(matchId) && onlyInRedis.length < sampleLimit) {
      const payload = redisRecords[matchId];
      onlyInRedis.push({
        match_id: matchId,
        updated_at: payload && payload.updated_at ? payload.updated_at : null,
        score_status: payload && payload.score_status ? payload.score_status : null,
        home_score: payload && payload.home_score !== undefined ? payload.home_score : null,
        away_score: payload && payload.away_score !== undefined ? payload.away_score : null,
      });
    }
  });

  memoryIds.forEach((matchId) => {
    if (!redisSet.has(matchId) || changed.length >= sampleLimit) return;
    const memoryPayload = memoryRecords[matchId];
    const redisPayload = redisRecords[matchId];
    if (hashComparablePayload(memoryPayload) === hashComparablePayload(redisPayload)) return;
    changed.push({
      match_id: matchId,
      memory: {
        updated_at: memoryPayload && memoryPayload.updated_at ? memoryPayload.updated_at : null,
        score_status: memoryPayload && memoryPayload.score_status ? memoryPayload.score_status : null,
        home_score:
          memoryPayload && memoryPayload.home_score !== undefined ? memoryPayload.home_score : null,
        away_score:
          memoryPayload && memoryPayload.away_score !== undefined ? memoryPayload.away_score : null,
        in_progress: Boolean(memoryPayload && memoryPayload.in_progress),
      },
      redis: {
        updated_at: redisPayload && redisPayload.updated_at ? redisPayload.updated_at : null,
        score_status: redisPayload && redisPayload.score_status ? redisPayload.score_status : null,
        home_score:
          redisPayload && redisPayload.home_score !== undefined ? redisPayload.home_score : null,
        away_score:
          redisPayload && redisPayload.away_score !== undefined ? redisPayload.away_score : null,
        in_progress: Boolean(redisPayload && redisPayload.in_progress),
      },
    });
  });

  return {
    only_in_memory: onlyInMemory,
    only_in_redis: onlyInRedis,
    changed,
    summary: {
      only_in_memory: memoryIds.filter((matchId) => !redisSet.has(matchId)).length,
      only_in_redis: redisIds.filter((matchId) => !memorySet.has(matchId)).length,
      changed: memoryIds.filter((matchId) => {
        if (!redisSet.has(matchId)) return false;
        return hashComparablePayload(memoryRecords[matchId]) !== hashComparablePayload(redisRecords[matchId]);
      }).length,
    },
  };
}

function buildComparableDatasetSide(payload, updatedAt, source, nowMs) {
  const hasPayload = payload !== null && payload !== undefined;
  const count = Array.isArray(payload)
    ? payload.length
    : payload && typeof payload === "object"
      ? Object.keys(payload).length
      : 0;
  return {
    source: source || null,
    updated_at: updatedAt || null,
    age_seconds: ageSecondsFromIso(updatedAt, nowMs),
    has_payload: hasPayload,
    count,
    hash: hasPayload ? hashComparablePayload(payload) : null,
  };
}

function buildDatasetReconciliationComponent(name, memorySnapshot, redisRecord, nowMs) {
  const startedAtMs = Date.now();
  const memoryPayload =
    Object.prototype.hasOwnProperty.call(memorySnapshot || {}, "payload")
      ? memorySnapshot.payload
      : Array.isArray(memorySnapshot && memorySnapshot.items)
        ? memorySnapshot.items
        : [];
  const redisPayload =
    redisRecord && Object.prototype.hasOwnProperty.call(redisRecord, "payload")
      ? redisRecord.payload
      : null;
  const memorySide = buildComparableDatasetSide(
    cloneComparablePayload(memoryPayload),
    memorySnapshot && memorySnapshot.updated_at ? memorySnapshot.updated_at : null,
    memorySnapshot && memorySnapshot.source ? memorySnapshot.source : "memory",
    nowMs
  );
  const redisSide = buildComparableDatasetSide(
    cloneComparablePayload(redisPayload),
    redisRecord && redisRecord.updated_at ? redisRecord.updated_at : null,
    redisRecord && redisRecord.source ? redisRecord.source : "redis",
    nowMs
  );

  let status = "in_sync";
  let diff = null;
  if (!memorySide.has_payload && !redisSide.has_payload) {
    status = "empty";
  } else if (!memorySide.has_payload && redisSide.has_payload) {
    status = "memory_missing";
  } else if (memorySide.has_payload && !redisSide.has_payload) {
    status = "redis_missing";
  } else if (memorySide.hash === redisSide.hash) {
    const updatedDeltaSeconds = secondsDeltaBetweenIso(memorySide.updated_at, redisSide.updated_at);
    if (updatedDeltaSeconds !== null && updatedDeltaSeconds !== 0) {
      status = "meta_out_of_sync";
    }
  } else {
    const updatedDeltaSeconds = secondsDeltaBetweenIso(memorySide.updated_at, redisSide.updated_at);
    if (updatedDeltaSeconds !== null) {
      if (updatedDeltaSeconds > 0) {
        status = "redis_stale";
      } else if (updatedDeltaSeconds < 0) {
        status = "redis_newer";
      } else {
        status = "payload_mismatch";
      }
    } else {
      status = "payload_mismatch";
    }
  }

  if (Array.isArray(memoryPayload) || Array.isArray(redisPayload)) {
    diff = buildArrayDiffSamples(memoryPayload, redisPayload);
  } else if (memorySide.hash !== redisSide.hash) {
    diff = {
      object_paths: collectObjectDiffPaths(memoryPayload || {}, redisPayload || {}),
      summary: {
        changed_paths: collectObjectDiffPaths(memoryPayload || {}, redisPayload || {}, "", [], 1000)
          .length,
      },
    };
  }

  const freshnessConcern =
    redisSide.age_seconds !== null &&
    redisSide.age_seconds > REDIS_RECONCILIATION_FRESHNESS_WARN_SECONDS &&
    (status === "redis_stale" || status === "redis_missing" || status === "meta_out_of_sync");

  return {
    name,
    type: "dataset",
    status,
    healthy: status === "in_sync" || status === "empty",
    repair_recommended:
      status === "redis_missing" || status === "redis_stale" || status === "meta_out_of_sync",
    memory: memorySide,
    redis: redisSide,
    updated_at_delta_seconds: secondsDeltaBetweenIso(memorySide.updated_at, redisSide.updated_at),
    count_delta: memorySide.count - redisSide.count,
    diff,
    timings: {
      compare_ms: Date.now() - startedAtMs,
    },
    notes: freshnessConcern
      ? [`Redis side exceeds freshness warning threshold (${REDIS_RECONCILIATION_FRESHNESS_WARN_SECONDS}s).`]
      : [],
  };
}

function buildMatchDetailsReconciliationComponent(memorySnapshot, redisSnapshot, nowMs) {
  const startedAtMs = Date.now();
  const memoryPayload = cloneComparablePayload(memorySnapshot && memorySnapshot.records);
  const redisPayload = cloneComparablePayload(redisSnapshot && redisSnapshot.records);
  const memorySide = buildComparableDatasetSide(
    memoryPayload,
    memorySnapshot && memorySnapshot.updated_at ? memorySnapshot.updated_at : null,
    memorySnapshot && memorySnapshot.source ? memorySnapshot.source : "memory",
    nowMs
  );
  const redisSide = buildComparableDatasetSide(
    redisPayload,
    redisSnapshot && redisSnapshot.updated_at ? redisSnapshot.updated_at : null,
    redisSnapshot && redisSnapshot.source ? redisSnapshot.source : "redis",
    nowMs
  );

  let status = "in_sync";
  if (!memorySide.has_payload && !redisSide.has_payload) {
    status = "empty";
  } else if (!memorySide.has_payload && redisSide.has_payload) {
    status = "memory_missing";
  } else if (memorySide.has_payload && !redisSide.has_payload) {
    status = "redis_missing";
  } else if (memorySide.hash === redisSide.hash) {
    const updatedDeltaSeconds = secondsDeltaBetweenIso(memorySide.updated_at, redisSide.updated_at);
    if (updatedDeltaSeconds !== null && updatedDeltaSeconds !== 0) {
      status = "meta_out_of_sync";
    }
  } else {
    const updatedDeltaSeconds = secondsDeltaBetweenIso(memorySide.updated_at, redisSide.updated_at);
    if (updatedDeltaSeconds !== null) {
      if (updatedDeltaSeconds > 0) {
        status = "redis_stale";
      } else if (updatedDeltaSeconds < 0) {
        status = "redis_newer";
      } else {
        status = "payload_mismatch";
      }
    } else {
      status = "payload_mismatch";
    }
  }

  return {
    name: "match_details",
    type: "match_details",
    status,
    healthy: status === "in_sync" || status === "empty",
    repair_recommended:
      status === "redis_missing" || status === "redis_stale" || status === "meta_out_of_sync",
    memory: {
      ...memorySide,
      total: memorySnapshot && Number.isFinite(memorySnapshot.total) ? memorySnapshot.total : memorySide.count,
    },
    redis: {
      ...redisSide,
      total: redisSnapshot && Number.isFinite(redisSnapshot.total) ? redisSnapshot.total : redisSide.count,
    },
    updated_at_delta_seconds: secondsDeltaBetweenIso(memorySide.updated_at, redisSide.updated_at),
    count_delta: memorySide.count - redisSide.count,
    diff: buildMatchDetailsDiffSamples(memoryPayload || {}, redisPayload || {}),
    timings: {
      compare_ms: Date.now() - startedAtMs,
    },
    notes: [],
  };
}

async function repairRedisReconciliationComponent(component, memoryDatasetSnapshots, memoryMatchDetailsSnapshot) {
  const startedAtMs = Date.now();
  if (!component || !component.repair_recommended) {
    return {
      attempted: false,
      applied: false,
      duration_ms: 0,
    };
  }

  if (component.type === "match_details") {
    await persistOperationalMatchDetailsSafe(memoryMatchDetailsSnapshot.records, {
      replace: true,
      updated_at: component.memory.updated_at || new Date().toISOString(),
      source: "redis_reconciliation_repair",
    });
  } else {
    const snapshot = memoryDatasetSnapshots[component.name];
    const payload =
      snapshot && Object.prototype.hasOwnProperty.call(snapshot, "payload")
        ? snapshot.payload
        : snapshot && Array.isArray(snapshot.items)
          ? snapshot.items
          : [];
    await persistOperationalDatasetSafe(
      component.name,
      payload,
      operationalPersistOptionsForDataset(
        component.name,
        component.memory.updated_at || new Date().toISOString(),
        "redis_reconciliation_repair"
      )
    );
  }

  return {
    attempted: true,
    applied: true,
    duration_ms: Date.now() - startedAtMs,
  };
}

async function runRedisReconciliationCheck(options = {}) {
  if (redisReconciliationTask) {
    return redisReconciliationTask;
  }

  const trigger = options.trigger || "manual";
  const repairEnabled =
    options.repair !== undefined ? Boolean(options.repair) : REDIS_RECONCILIATION_AUTO_REPAIR;
  const startedAtIso = new Date().toISOString();
  recordRuntimeComponentStart(COMPONENT_REDIS_RECONCILIATION, {
    trigger,
    repair_enabled: repairEnabled,
  });
  ensureRedisReconciliationState();
  redisReconciliationState = buildRedisReconciliationStatePatch({
    ...redisReconciliationState,
    generated_at: startedAtIso,
    last_run_started_at: startedAtIso,
    last_trigger: trigger,
    running: true,
    auto_repair_enabled: repairEnabled,
    last_error: null,
  });

  redisReconciliationTask = (async () => {
    const runStartedAtMs = Date.now();
    const nowMs = runStartedAtMs;
    try {
      const [redisDatasets, redisMatchDetailsSnapshot] = await Promise.all([
        getOperationalDatasets(ADMIN_OPERATIONAL_DATASET_NAMES),
        getOperationalMatchDetailsSnapshotSafe(),
      ]);
      const memoryDatasetSnapshots = currentOperationalMemoryDatasetSnapshots();
      const memoryMatchDetailsSnapshot = currentOperationalMatchDetailsMemorySnapshot();

      const components = ADMIN_OPERATIONAL_DATASET_NAMES.map((name) =>
        buildDatasetReconciliationComponent(
          name,
          memoryDatasetSnapshots[name],
          redisDatasets && redisDatasets[name] ? redisDatasets[name] : null,
          nowMs
        )
      );
      components.push(
        buildMatchDetailsReconciliationComponent(
          memoryMatchDetailsSnapshot,
          redisMatchDetailsSnapshot,
          nowMs
        )
      );

      for (const component of components) {
        const canRepair = repairEnabled && component.repair_recommended && component.status !== "redis_newer";
        const repair = canRepair
          ? await repairRedisReconciliationComponent(
            component,
            memoryDatasetSnapshots,
            memoryMatchDetailsSnapshot
          )
          : { attempted: false, applied: false, duration_ms: 0 };
        component.repair = repair;
        component.timings.total_ms =
          (component.timings && component.timings.compare_ms ? component.timings.compare_ms : 0) +
          (repair.duration_ms || 0);
      }

      const repairedAny = components.some(
        (component) => component.repair && component.repair.applied
      );
      let finalizedComponents = components;
      if (repairedAny) {
        const [reloadedRedisDatasets, reloadedRedisMatchDetailsSnapshot] = await Promise.all([
          getOperationalDatasets(ADMIN_OPERATIONAL_DATASET_NAMES),
          getOperationalMatchDetailsSnapshotSafe(),
        ]);
        finalizedComponents = ADMIN_OPERATIONAL_DATASET_NAMES.map((name) => {
          const previous = components.find((component) => component.name === name);
          const rebuilt = buildDatasetReconciliationComponent(
            name,
            memoryDatasetSnapshots[name],
            reloadedRedisDatasets && reloadedRedisDatasets[name]
              ? reloadedRedisDatasets[name]
              : null,
            nowMs
          );
          rebuilt.repair = previous && previous.repair ? previous.repair : null;
          rebuilt.timings.total_ms =
            (rebuilt.timings && rebuilt.timings.compare_ms ? rebuilt.timings.compare_ms : 0) +
            (rebuilt.repair && rebuilt.repair.duration_ms ? rebuilt.repair.duration_ms : 0);
          return rebuilt;
        });
        const matchDetailsPrevious = components.find((component) => component.name === "match_details");
        const rebuiltMatchDetails = buildMatchDetailsReconciliationComponent(
          memoryMatchDetailsSnapshot,
          reloadedRedisMatchDetailsSnapshot,
          nowMs
        );
        rebuiltMatchDetails.repair =
          matchDetailsPrevious && matchDetailsPrevious.repair ? matchDetailsPrevious.repair : null;
        rebuiltMatchDetails.timings.total_ms =
          (rebuiltMatchDetails.timings && rebuiltMatchDetails.timings.compare_ms
            ? rebuiltMatchDetails.timings.compare_ms
            : 0) +
          (rebuiltMatchDetails.repair && rebuiltMatchDetails.repair.duration_ms
            ? rebuiltMatchDetails.repair.duration_ms
            : 0);
        finalizedComponents.push(rebuiltMatchDetails);
      }

      const statusCounts = {};
      finalizedComponents.forEach((component) => {
        statusCounts[component.status] = (statusCounts[component.status] || 0) + 1;
      });
      const healthyComponents = finalizedComponents.filter((component) => component.healthy).length;
      const repairedComponents = finalizedComponents.filter(
        (component) => component.repair && component.repair.applied
      ).length;
      const summary = {
        total_components: finalizedComponents.length,
        healthy_components: healthyComponents,
        unhealthy_components: finalizedComponents.length - healthyComponents,
        repaired_components: repairedComponents,
        status_counts: statusCounts,
      };
      const completedAtIso = new Date().toISOString();
      redisReconciliationState = buildRedisReconciliationStatePatch({
        generated_at: completedAtIso,
        last_run_started_at: startedAtIso,
        last_run_completed_at: completedAtIso,
        last_duration_ms: Date.now() - runStartedAtMs,
        last_trigger: trigger,
        running: false,
        healthy: summary.unhealthy_components === 0,
        auto_repair_enabled: repairEnabled,
        summary,
        components: finalizedComponents,
        notes: [
          "Redis persistence is best-effort. Memory is still the live authoritative runtime cache.",
          "Auto-repair only writes memory back to Redis when Redis is missing, older, or metadata-only stale.",
        ],
      });
      recordRuntimeComponentSuccess(COMPONENT_REDIS_RECONCILIATION, {
        trigger,
        repair_enabled: repairEnabled,
        healthy: redisReconciliationState.healthy,
        summary,
      });
      return redisReconciliationState;
    } catch (error) {
      const completedAtIso = new Date().toISOString();
      redisReconciliationState = buildRedisReconciliationStatePatch({
        generated_at: completedAtIso,
        last_run_started_at: startedAtIso,
        last_run_completed_at: completedAtIso,
        last_duration_ms: Date.now() - runStartedAtMs,
        last_trigger: trigger,
        running: false,
        healthy: false,
        auto_repair_enabled: repairEnabled,
        summary: {
          total_components: 0,
          healthy_components: 0,
          unhealthy_components: 0,
          repaired_components: 0,
          status_counts: {},
        },
        components: [],
        last_error: error.message || String(error),
        notes: [
          "Redis reconciliation failed before a full comparison could be completed.",
        ],
      });
      recordRuntimeComponentFailure(COMPONENT_REDIS_RECONCILIATION, error, {
        trigger,
        repair_enabled: repairEnabled,
      });
      return redisReconciliationState;
    } finally {
      redisReconciliationTask = null;
    }
  })();

  return redisReconciliationTask;
}

function currentRedisReconciliationSnapshot() {
  return ensureRedisReconciliationState();
}

function findInMemoryMatchRecordByMatchId(matchId) {
  const normalizedMatchId = normalizeMatchDetailsId(matchId);
  if (!normalizedMatchId) return null;

  const sources = [
    mergedMatchesForResponse(),
    Array.isArray(cachedRecentMatches) ? cachedRecentMatches : [],
    Array.isArray(cachedBbcRangeMatches) ? cachedBbcRangeMatches : [],
    Array.isArray(cachedBbcMatches) ? cachedBbcMatches : [],
    Array.isArray(cachedMatches) ? cachedMatches : [],
  ];

  for (const source of sources) {
    for (const candidate of source) {
      const detailsId =
        matchDetailsIdFromUrl(candidate && candidate.details_url) ||
        normalizeMatchDetailsId(candidate && candidate.match_details_id);
      if (detailsId !== normalizedMatchId) continue;
      const normalized = normalizeMatchRecord(candidate);
      if (normalized) return normalized;
    }
  }

  return null;
}

function buildFallbackMatchDetailsPayload(matchId, fallbackMatchRecord) {
  const normalizedMatchId = normalizeMatchDetailsId(matchId);
  if (!normalizedMatchId || !fallbackMatchRecord || typeof fallbackMatchRecord !== "object") {
    return null;
  }

  const statePayload = getMatchDetailsStatePayload({
    id: normalizedMatchId,
    ...fallbackMatchRecord,
    updated_at: matchDetailsLastUpdated || null,
  });
  if (!statePayload) return null;

  const payload = {
    ...statePayload,
    league_subcategory: fallbackMatchRecord.league_subcategory || null,
    home_goal_scorers: Array.isArray(fallbackMatchRecord.home_goal_scorers)
      ? fallbackMatchRecord.home_goal_scorers
      : [],
    away_goal_scorers: Array.isArray(fallbackMatchRecord.away_goal_scorers)
      ? fallbackMatchRecord.away_goal_scorers
      : [],
    home_assists: Array.isArray(fallbackMatchRecord.home_assists)
      ? fallbackMatchRecord.home_assists
      : [],
    away_assists: Array.isArray(fallbackMatchRecord.away_assists)
      ? fallbackMatchRecord.away_assists
      : [],
    home_yellow_cards: Array.isArray(fallbackMatchRecord.home_yellow_cards)
      ? fallbackMatchRecord.home_yellow_cards
      : [],
    away_yellow_cards: Array.isArray(fallbackMatchRecord.away_yellow_cards)
      ? fallbackMatchRecord.away_yellow_cards
      : [],
    home_red_cards: Array.isArray(fallbackMatchRecord.home_red_cards)
      ? fallbackMatchRecord.home_red_cards
      : [],
    away_red_cards: Array.isArray(fallbackMatchRecord.away_red_cards)
      ? fallbackMatchRecord.away_red_cards
      : [],
  };

  const teamLineups = normalizeTeamLineupsPayload(fallbackMatchRecord.team_lineups);
  if (teamLineups) {
    payload.team_lineups = teamLineups;
  }

  return payload;
}

async function mergeConfirmedVarDisallowedGoalsIntoPayload(payload, options = {}) {
  const matchId = normalizeMatchDetailsId(payload && payload.id);
  if (!matchId || !payload) {
    return payload;
  }

  const nowMs = Date.now();
  const loadHistory =
    options && typeof options.loadHistory === "function"
      ? options.loadHistory
      : getBbcMatchHistoryGrouped;
  const history = await loadHistory({
    match_id: matchId,
    start_ms: nowMs - 24 * 60 * 60 * 1000,
    end_ms: nowMs + 60 * 60 * 1000,
  });
  if (!history || history.error || !Array.isArray(history.matches)) {
    return payload;
  }

  const historyMatch =
    history.matches.find((entry) => normalizeMatchDetailsId(entry && entry.match_id) === matchId) || null;
  const disallowedEvents = Array.isArray(historyMatch && historyMatch.events)
    ? historyMatch.events.filter(
      (event) => event && event.event_type === "goal" && event.disallowed_by_var
    )
    : [];
  if (disallowedEvents.length === 0) {
    return payload;
  }

  const merged = {
    ...payload,
    home_goal_scorers: Array.isArray(payload.home_goal_scorers)
      ? payload.home_goal_scorers.map((entry) => ({ ...entry }))
      : [],
    away_goal_scorers: Array.isArray(payload.away_goal_scorers)
      ? payload.away_goal_scorers.map((entry) => ({ ...entry }))
      : [],
    home_assists: Array.isArray(payload.home_assists)
      ? payload.home_assists.map((entry) => ({ ...entry }))
      : [],
    away_assists: Array.isArray(payload.away_assists)
      ? payload.away_assists.map((entry) => ({ ...entry }))
      : [],
  };

  const mergeEvent = (targetList, event) => {
    const playerName = String(event && (event.scorer || event.player) ? (event.scorer || event.player) : "").trim();
    const goalTime = String(event && event.goal_time ? event.goal_time : "").trim();
    if (!playerName || !goalTime) return;

    let target = targetList.find((entry) => String(entry && entry.player ? entry.player : "").trim() === playerName);
    if (!target) {
      target = {
        player: playerName,
        goal_times: [],
        own_goal_times: [],
        disallowed_goal_times: [],
      };
      targetList.push(target);
    }
    if (!Array.isArray(target.disallowed_goal_times)) {
      target.disallowed_goal_times = [];
    }
    if (!target.disallowed_goal_times.includes(goalTime)) {
      target.disallowed_goal_times.push(goalTime);
    }
  };

  const mergeAssist = (targetList, event) => {
    const assisterName = String(event && event.assister ? event.assister : "").trim();
    const assistTime = String(event && event.goal_time ? event.goal_time : "").trim();
    if (!assisterName || !assistTime) return;

    let target = targetList.find((entry) => String(entry && entry.player ? entry.player : "").trim() === assisterName);
    if (!target) {
      target = {
        player: assisterName,
        assist_times: [],
      };
      targetList.push(target);
    }
    if (!Array.isArray(target.assist_times)) {
      target.assist_times = [];
    }
    if (!target.assist_times.includes(assistTime)) {
      target.assist_times.push(assistTime);
    }
  };

  disallowedEvents.forEach((event) => {
    if (event.team === "home") {
      mergeEvent(merged.home_goal_scorers, event);
      mergeAssist(merged.home_assists, event);
    } else if (event.team === "away") {
      mergeEvent(merged.away_goal_scorers, event);
      mergeAssist(merged.away_assists, event);
    }
  });

  return merged;
}

function scheduleMatchDetailsWarm(matchId, options = {}) {
  const normalizedMatchId = normalizeMatchDetailsId(matchId);
  if (!normalizedMatchId) return false;
  if (matchDetailsById.has(normalizedMatchId) || matchDetailsWarmTasks.has(normalizedMatchId)) {
    return false;
  }

  const trigger = options && options.trigger ? String(options.trigger) : "request";
  const fallbackMatchRecord =
    options && options.fallbackMatchRecord && typeof options.fallbackMatchRecord === "object"
      ? options.fallbackMatchRecord
      : null;

  const task = (async () => {
    try {
      const payload = await getOperationalMatchDetails(normalizedMatchId);
      if (payload && typeof payload === "object") {
        matchDetailsById.set(normalizedMatchId, payload);
        if (
          payload.updated_at &&
          (!matchDetailsLastUpdated || payload.updated_at > matchDetailsLastUpdated)
        ) {
          matchDetailsLastUpdated = payload.updated_at;
        }
        if (payload.details_url) {
          scheduleMatchDetailsBackfill(payload, { trigger: `${trigger}_warm` });
        }
        return;
      }

      if (fallbackMatchRecord && fallbackMatchRecord.details_url) {
        scheduleMatchDetailsBackfill(
          {
            id: normalizedMatchId,
            ...fallbackMatchRecord,
          },
          { trigger: `${trigger}_fallback` }
        );
      }
    } catch (error) {
      console.warn(
        `[API] Failed to warm match details for ${normalizedMatchId}:`,
        error.message || error
      );
    } finally {
      matchDetailsWarmTasks.delete(normalizedMatchId);
    }
  })();

  matchDetailsWarmTasks.set(normalizedMatchId, task);
  return true;
}

async function updateMatches(options = {}) {
  if (updating) return;
  updating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_LIVE_FOOTBALL, {
    trigger,
    url: SOURCE_URL,
    interval_ms: INTERVAL_MS,
  });
  try {
    const matches = filterMatchesByCompetition(await fetchMatches(SOURCE_URL));
    cachedMatches = matches;
    recordsFetched = matches.length;
    setSourceCacheSize(SOURCE_LIVE_FOOTBALL, matches.length);
    lastUpdated = new Date().toISOString();
    writeMatches(OUTPUT_PATH, matches);
    await persistOperationalDatasetSafe(OP_DATASET_LIVE_MATCHES, matches, {
      updated_at: lastUpdated,
      source: SOURCE_LIVE_FOOTBALL,
    });
    await updateRecentCache(SOURCE_LIVE_FOOTBALL);
    await rebuildMergedMatchesCache(SOURCE_LIVE_FOOTBALL);
    success = true;
    logPollSuccess("live_football", {
      source: SOURCE_LIVE_FOOTBALL,
      trigger,
      count: matches.length,
      updated_at: lastUpdated,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_LIVE_FOOTBALL, {
      trigger,
      url: SOURCE_URL,
      interval_ms: INTERVAL_MS,
      count: matches.length,
      updated_at: lastUpdated,
    });
  } catch (err) {
    recordRuntimeComponentFailure(COMPONENT_SOURCE_LIVE_FOOTBALL, err, {
      trigger,
      url: SOURCE_URL,
      interval_ms: INTERVAL_MS,
    });
    console.warn("Failed to update matches:", err.message || err);
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_LIVE_FOOTBALL,
      startedAtMs,
      success,
      recordsFetched,
    });
    updating = false;
  }
}

function filterStaleBbcMatches(newMatches, cachedMatches) {
  if (!cachedMatches || cachedMatches.length === 0) {
    return newMatches;
  }

  // Build a map of cached matches by team names for quick lookup
  const cachedMap = new Map();
  cachedMatches.forEach((match) => {
    const key = `${match.home_team}|${match.away_team}`.toLowerCase();
    cachedMap.set(key, match);
  });

  const filtered = [];
  let staleCount = 0;
  const staleSamples = [];
  let terminalRecoveryCount = 0;

  newMatches.forEach((newMatch) => {
    const key = `${newMatch.home_team}|${newMatch.away_team}`.toLowerCase();
    const cached = cachedMap.get(key);

    if (!cached) {
      // New match, not in cache - accept it
      filtered.push(newMatch);
      return;
    }

    // Check if the new match data is stale (match time has regressed)
    const newTime = parseMatchTimeMinutes(newMatch.match_time);
    const cachedTime = parseMatchTimeMinutes(cached.match_time);
    const cachedStatus = normalizeMatchStatusValue(cached.match_time || cached.score_status);
    const newStatus = normalizeMatchStatusValue(newMatch.match_time || newMatch.score_status);
    const cachedIsTerminal = MATCH_STATUS_COMPLETE_TOKENS.has(
      String(cachedStatus || "").toUpperCase()
    );
    const newIsInProgress = isInProgressMatchStatus(newStatus);
    const allowTerminalRecovery = cachedIsTerminal && newIsInProgress;

    if (!allowTerminalRecovery && newTime !== null && cachedTime !== null && newTime < cachedTime) {
      staleCount++;
      if (staleSamples.length < 5) {
        staleSamples.push(
          `${newMatch.home_team} vs ${newMatch.away_team}: time ${newTime}' < ${cachedTime}'`
        );
      }
      filtered.push(cached); // Keep the cached version
      return;
    }

    if (allowTerminalRecovery) {
      terminalRecoveryCount += 1;
    }

    // Check if scores have regressed
    const newHasScore =
      parseNumericScore(newMatch.home_score) !== null && parseNumericScore(newMatch.away_score) !== null;
    if (newHasScore && cached.home_score !== null && cached.away_score !== null) {
      const cachedTotal = cached.home_score + cached.away_score;
      const newTotal = (newMatch.home_score || 0) + (newMatch.away_score || 0);
      const timeNotAhead =
        newTime !== null && cachedTime !== null ? newTime <= cachedTime : true;

      if (!allowTerminalRecovery && newTotal < cachedTotal && timeNotAhead) {
        staleCount++;
        if (staleSamples.length < 5) {
          staleSamples.push(
            `${newMatch.home_team} vs ${newMatch.away_team}: score ${newMatch.home_score}-${newMatch.away_score} < ${cached.home_score}-${cached.away_score}`
          );
        }
        filtered.push(cached); // Keep the cached version
        return;
      }
    }

    // Data looks fresh - accept it
    filtered.push(newMatch);
  });

  if (staleCount > 0) {
    const sampleSuffix =
      staleSamples.length > 0 ? ` samples=${staleSamples.join(" | ")}` : "";
    console.log(`[STALE DATA] Filtered out ${staleCount} stale match(es) from BBC update${sampleSuffix}`);
  }
  if (terminalRecoveryCount > 0) {
    console.log(`[STALE DATA] Allowed terminal recovery for ${terminalRecoveryCount} match(es)`);
  }

  return filtered;
}

function parseMatchTimeMinutes(matchTime) {
  if (!matchTime || typeof matchTime !== 'string') return null;

  const trimmed = matchTime.trim();

  // Extract minute value (e.g., "45+2" -> 47, "90" -> 90)
  const match = trimmed.match(/^(\d+)(?:\+(\d+))?['']?$/);
  if (match) {
    const base = parseInt(match[1], 10);
    const added = match[2] ? parseInt(match[2], 10) : 0;
    return base + added;
  }

  // Handle "HT", "FT", "AET", etc. - assign high values so they don't regress
  if (/^(HT|Half.?Time)$/i.test(trimmed)) return 45;
  if (/^(FT|Full.?Time)$/i.test(trimmed)) return 90;
  if (/^AET$/i.test(trimmed)) return 120;
  if (/^(Pens?|Penalty|PEN\.?)$/i.test(trimmed)) return 120;

  return null;
}

async function updateBbcMatches(options = {}) {
  if (bbcUpdating) return;
  bbcUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_BBC_LIVE, {
    trigger,
    url: BBC_SOURCE_URL,
    interval_ms: BBC_INTERVAL_MS,
  });
  try {
    const matches = await fetchBbcFixtures(BBC_SOURCE_URL);
    const filteredMatches = filterStaleBbcMatches(matches, cachedBbcMatches);
    cachedBbcMatches = filteredMatches;
    recordsFetched = filteredMatches.length;
    setSourceCacheSize(SOURCE_BBC_LIVE, filteredMatches.length);
    bbcLastUpdated = new Date().toISOString();
    writeBbcFixtures(BBC_OUTPUT_PATH, filteredMatches);
    await persistOperationalDatasetSafe(OP_DATASET_BBC_LIVE_MATCHES, filteredMatches, {
      updated_at: bbcLastUpdated,
      source: SOURCE_BBC_LIVE,
    });
    await updateRecentCache(SOURCE_BBC_LIVE);
    indexMatchDetailsFromMatches(filteredMatches, bbcLastUpdated);
    const detailsSubset = collectMatchDetailsSubsetByMatches(filteredMatches);
    await persistOperationalMatchDetailsSafe(detailsSubset, {
      replace: false,
      updated_at: bbcLastUpdated,
      source: SOURCE_BBC_LIVE,
    });
    success = true;
    logPollSuccess("bbc_live_matches", {
      source: SOURCE_BBC_LIVE,
      trigger,
      count: filteredMatches.length,
      updated_at: bbcLastUpdated,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_BBC_LIVE, {
      trigger,
      url: BBC_SOURCE_URL,
      interval_ms: BBC_INTERVAL_MS,
      count: filteredMatches.length,
      updated_at: bbcLastUpdated,
    });
  } catch (err) {
    recordRuntimeComponentFailure(COMPONENT_SOURCE_BBC_LIVE, err, {
      trigger,
      url: BBC_SOURCE_URL,
      interval_ms: BBC_INTERVAL_MS,
    });
    console.warn("Failed to update BBC matches:", err.message || err);
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_BBC_LIVE,
      startedAtMs,
      success,
      recordsFetched,
    });
    bbcUpdating = false;
  }
}

async function updateBbcRangeMatches(options = {}) {
  if (bbcRangeUpdating) return;
  bbcRangeUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_BBC_RANGE, {
    trigger,
    url: BBC_RANGE_BASE_URL,
    interval_ms: BBC_RANGE_INTERVAL_MS,
    past_days: BBC_RANGE_PAST_DAYS,
    future_days: BBC_RANGE_FUTURE_DAYS,
  });
  try {
    const matches = filterMatchesByCompetition(
      await fetchBbcScoresFixturesByDateRange({
        baseUrl: BBC_RANGE_BASE_URL,
        pastDays: BBC_RANGE_PAST_DAYS,
        futureDays: BBC_RANGE_FUTURE_DAYS,
        concurrency: BBC_RANGE_CONCURRENCY,
        timeZone: BBC_RANGE_MATCH_TIMEZONE,
      })
    );
    cachedBbcRangeMatches = matches;
    recordsFetched = matches.length;
    setSourceCacheSize(SOURCE_BBC_RANGE, matches.length);
    bbcRangeLastUpdated = new Date().toISOString();
    writeBbcRangeMatches(BBC_RANGE_OUTPUT_PATH, matches);
    await persistOperationalDatasetSafe(OP_DATASET_BBC_RANGE_MATCHES, matches, {
      updated_at: bbcRangeLastUpdated,
      source: SOURCE_BBC_RANGE,
    });
    await rebuildMergedMatchesCache(SOURCE_BBC_RANGE);
    success = true;
    logPollSuccess("bbc_date_range_matches", {
      source: SOURCE_BBC_RANGE,
      trigger,
      count: matches.length,
      updated_at: bbcRangeLastUpdated,
      past_days: BBC_RANGE_PAST_DAYS,
      future_days: BBC_RANGE_FUTURE_DAYS,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_BBC_RANGE, {
      trigger,
      url: BBC_RANGE_BASE_URL,
      interval_ms: BBC_RANGE_INTERVAL_MS,
      count: matches.length,
      updated_at: bbcRangeLastUpdated,
      past_days: BBC_RANGE_PAST_DAYS,
      future_days: BBC_RANGE_FUTURE_DAYS,
    });
  } catch (err) {
    recordRuntimeComponentFailure(COMPONENT_SOURCE_BBC_RANGE, err, {
      trigger,
      url: BBC_RANGE_BASE_URL,
      interval_ms: BBC_RANGE_INTERVAL_MS,
      past_days: BBC_RANGE_PAST_DAYS,
      future_days: BBC_RANGE_FUTURE_DAYS,
    });
    console.warn("Failed to update BBC date-range matches:", err.message || err);
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_BBC_RANGE,
      startedAtMs,
      success,
      recordsFetched,
    });
    bbcRangeUpdating = false;
  }
}

async function updatePremierLeagueTeams(options = {}) {
  if (eplUpdating) return;
  eplUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_BBC_TABLES_PREMIER_TEAMS, {
    trigger,
    url: EPL_SOURCE_URL,
    interval_ms: EPL_INTERVAL_MS,
  });
  try {
    const teams = await fetchPremierLeagueTeams(EPL_SOURCE_URL);
    if (!Array.isArray(teams) || teams.length === 0) {
      recordRuntimeComponentFailure(
        COMPONENT_SOURCE_BBC_TABLES_PREMIER_TEAMS,
        new Error("Premier League table update returned no teams"),
        {
          trigger,
          url: EPL_SOURCE_URL,
          interval_ms: EPL_INTERVAL_MS,
        }
      );
      console.warn("Premier League table update returned no teams");
      return;
    }

    cachedPremierLeagueTeams = teams.map((team) => String(team || "").trim()).filter(Boolean);
    recordsFetched = cachedPremierLeagueTeams.length;
    setSourceCacheSize(SOURCE_BBC_PREMIER_LEAGUE, cachedPremierLeagueTeams.length);
    eplLastUpdated = new Date().toISOString();
    writePremierLeagueTeams(EPL_OUTPUT_PATH, cachedPremierLeagueTeams);
    await persistOperationalDatasetSafe(
      OP_DATASET_PREMIER_LEAGUE_TEAMS,
      cachedPremierLeagueTeams,
      {
        updated_at: eplLastUpdated,
        source: SOURCE_BBC_PREMIER_LEAGUE,
      }
    );
    success = true;
    logPollSuccess("bbc_premier_league_teams", {
      source: SOURCE_BBC_PREMIER_LEAGUE,
      trigger,
      count: cachedPremierLeagueTeams.length,
      updated_at: eplLastUpdated,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_BBC_TABLES_PREMIER_TEAMS, {
      trigger,
      url: EPL_SOURCE_URL,
      interval_ms: EPL_INTERVAL_MS,
      count: cachedPremierLeagueTeams.length,
      updated_at: eplLastUpdated,
    });
  } catch (err) {
    recordRuntimeComponentFailure(COMPONENT_SOURCE_BBC_TABLES_PREMIER_TEAMS, err, {
      trigger,
      url: EPL_SOURCE_URL,
      interval_ms: EPL_INTERVAL_MS,
    });
    console.warn("Failed to update Premier League teams:", err.message || err);
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_BBC_PREMIER_LEAGUE,
      startedAtMs,
      success,
      recordsFetched,
    });
    eplUpdating = false;
  }
}

async function updateLeagueTables(options = {}) {
  if (leagueTablesUpdating) return;
  leagueTablesUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_BBC_TABLES_LEAGUE_TABLES, {
    trigger,
    interval_ms: LEAGUE_TABLES_INTERVAL_MS,
    urls: LEAGUE_TABLE_SOURCES.map((source) => source.url),
  });

  try {
    const { tables, errors } = await fetchLeagueTables(LEAGUE_TABLE_SOURCES);

    if (Array.isArray(errors) && errors.length > 0) {
      errors.forEach((error) => {
        console.warn(
          `[LeagueTables] Failed ${error.league_id || "unknown"}: ${error.message || String(error)}`
        );
      });
    }

    if (!Array.isArray(tables) || tables.length === 0) {
      recordRuntimeComponentFailure(
        COMPONENT_SOURCE_BBC_TABLES_LEAGUE_TABLES,
        new Error("League tables update returned no tables"),
        {
          trigger,
          interval_ms: LEAGUE_TABLES_INTERVAL_MS,
        }
      );
      console.warn("League tables update returned no tables");
      return;
    }

    const previousTables = Array.isArray(cachedLeagueTables) ? cachedLeagueTables : [];
    const mergedById = new Map();
    previousTables.forEach((table) => {
      const id = normalizeLeagueTableId(table && table.league_id);
      if (!id) return;
      mergedById.set(id, table);
    });
    tables.forEach((table) => {
      const id = normalizeLeagueTableId(table && table.league_id);
      if (!id) return;
      mergedById.set(id, table);
    });
    const sortedTables = sortLeagueTablesForResponse(Array.from(mergedById.values()));
    const nowIso = new Date().toISOString();
    const updatedAtCandidates = sortedTables
      .map((league) => (league && league.updated_at ? String(league.updated_at) : ""))
      .filter(Boolean);
    const resolvedUpdatedAt = newestIsoTimestamp([...updatedAtCandidates, nowIso]) || nowIso;

    cachedLeagueTables = sortedTables;
    leagueTablesLastUpdated = resolvedUpdatedAt;
    recordsFetched = leagueTableRowsCount(sortedTables);
    setSourceCacheSize(SOURCE_BBC_LEAGUE_TABLES, recordsFetched);

    writeLeagueTables(LEAGUE_TABLES_OUTPUT_PATH, sortedTables);
    await persistOperationalDatasetSafe(OP_DATASET_LEAGUE_TABLES, sortedTables, {
      updated_at: leagueTablesLastUpdated,
      source: SOURCE_BBC_LEAGUE_TABLES,
    });

    // Keep EPL team filters aligned with the live table feed.
    const premierLeagueTeams = extractPremierLeagueTeamsFromTables(sortedTables);
    if (premierLeagueTeams.length > 0) {
      cachedPremierLeagueTeams = premierLeagueTeams;
      eplLastUpdated = leagueTablesLastUpdated;
      setSourceCacheSize(SOURCE_BBC_PREMIER_LEAGUE, cachedPremierLeagueTeams.length);
      await persistOperationalDatasetSafe(
        OP_DATASET_PREMIER_LEAGUE_TEAMS,
        cachedPremierLeagueTeams,
        {
          updated_at: eplLastUpdated,
          source: SOURCE_BBC_LEAGUE_TABLES,
        }
      );
    }

    success = true;
    logPollSuccess("bbc_league_tables", {
      source: SOURCE_BBC_LEAGUE_TABLES,
      trigger,
      leagues: sortedTables.length,
      rows: recordsFetched,
      updated_at: leagueTablesLastUpdated,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_BBC_TABLES_LEAGUE_TABLES, {
      trigger,
      interval_ms: LEAGUE_TABLES_INTERVAL_MS,
      leagues: sortedTables.length,
      rows: recordsFetched,
      updated_at: leagueTablesLastUpdated,
      warnings: Array.isArray(errors) ? errors.length : 0,
    });
  } catch (err) {
    recordRuntimeComponentFailure(COMPONENT_SOURCE_BBC_TABLES_LEAGUE_TABLES, err, {
      trigger,
      interval_ms: LEAGUE_TABLES_INTERVAL_MS,
    });
    console.warn("Failed to update league tables:", err.message || err);
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_BBC_LEAGUE_TABLES,
      startedAtMs,
      success,
      recordsFetched,
    });
    leagueTablesUpdating = false;
  }
}

async function updateFantasyBootstrapStatic(options = {}) {
  if (fantasyBootstrapUpdating) return;
  fantasyBootstrapUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_FPL_BOOTSTRAP, {
    trigger,
    url: FPL_BOOTSTRAP_SOURCE_URL,
    interval_ms: FPL_BOOTSTRAP_INTERVAL_MS,
  });

  console.info(
    `[FPLBootstrap] Download start source=${FPL_BOOTSTRAP_SOURCE_URL} trigger=${trigger}`
  );

  try {
    const { payload, payloadBytes } = await fetchFantasyBootstrapStaticPayload(
      FPL_BOOTSTRAP_SOURCE_URL,
      {
        timeoutMs: FPL_BOOTSTRAP_TIMEOUT_MS,
        maxBytes: FPL_BOOTSTRAP_MAX_BYTES,
      }
    );

    cachedFantasyBootstrap = payload;
    fantasyBootstrapPayloadBytes = payloadBytes;
    fantasyBootstrapLastUpdated = new Date().toISOString();
    fantasyBootstrapGameUpdating = false;
    fantasyBootstrapGameUpdatingMessage = null;
    fantasyBootstrapGameUpdatingDetectedAt = null;
    refreshFantasyBootstrapDerivedState(payload);
    recordsFetched = fantasyBootstrapEventsCount;
    fantasyBootstrapLastSuccessAt = fantasyBootstrapLastUpdated;
    fantasyBootstrapLastSuccessDurationSeconds = Math.max(
      0,
      (Date.now() - startedAtMs) / 1000
    );

    success = true;
    console.info(
      `[FPLBootstrap] Download complete source=${FPL_BOOTSTRAP_SOURCE_URL} trigger=${trigger} bytes=${fantasyBootstrapPayloadBytes} events=${fantasyBootstrapEventsCount} duration_ms=${Date.now() - startedAtMs} updated_at=${fantasyBootstrapLastUpdated}`
    );
    if (
      matchMonitor &&
      typeof matchMonitor.runFantasyDeadlineReminderEvaluationNow === "function"
    ) {
      void matchMonitor
        .runFantasyDeadlineReminderEvaluationNow({
          reason: `fpl_bootstrap_refresh:${trigger}`,
        })
        .catch((error) => {
          console.warn(
            "[FPLBootstrap] Fantasy deadline reminder refresh after bootstrap failed:",
            error && error.message ? error.message : error
          );
        });
    }
    logPollSuccess("fpl_bootstrap_static", {
      source: SOURCE_FPL_BOOTSTRAP,
      trigger,
      bytes: fantasyBootstrapPayloadBytes,
      events: fantasyBootstrapEventsCount,
      current_event_id: fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id,
      next_event_id: fantasyBootstrapNextEvent && fantasyBootstrapNextEvent.id,
      updated_at: fantasyBootstrapLastUpdated,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_FPL_BOOTSTRAP, {
      trigger,
      url: FPL_BOOTSTRAP_SOURCE_URL,
      interval_ms: FPL_BOOTSTRAP_INTERVAL_MS,
      updated_at: fantasyBootstrapLastUpdated,
      events: fantasyBootstrapEventsCount,
      bytes: fantasyBootstrapPayloadBytes,
    });
  } catch (err) {
    const gameUpdatingMessage = extractFplGameUpdatingMessageFromError(err);
    if (gameUpdatingMessage) {
      fantasyBootstrapGameUpdating = true;
      fantasyBootstrapGameUpdatingMessage = gameUpdatingMessage;
      fantasyBootstrapGameUpdatingDetectedAt = new Date().toISOString();
      console.warn(
        `[FPLBootstrap] Upstream reported game update in progress message="${gameUpdatingMessage}" trigger=${trigger}`
      );
    }
    fantasyBootstrapLastFailureAt = new Date().toISOString();
    fantasyBootstrapLastFailureDurationSeconds = Math.max(
      0,
      (Date.now() - startedAtMs) / 1000
    );
    console.warn(
      "Failed to update FPL bootstrap-static dataset:",
      err.message || err
    );
    recordRuntimeComponentFailure(COMPONENT_SOURCE_FPL_BOOTSTRAP, err, {
      trigger,
      url: FPL_BOOTSTRAP_SOURCE_URL,
      interval_ms: FPL_BOOTSTRAP_INTERVAL_MS,
      game_updating: fantasyBootstrapGameUpdating,
    });
  } finally {
    const durationMs = Date.now() - startedAtMs;
    console.info(
      `[FPLBootstrap] Download end source=${FPL_BOOTSTRAP_SOURCE_URL} trigger=${trigger} status=${success ? "success" : "failure"} duration_ms=${durationMs}`
    );
    trackSourceUpdateMetrics({
      source: SOURCE_FPL_BOOTSTRAP,
      startedAtMs,
      success,
      recordsFetched,
    });
    fantasyBootstrapUpdating = false;
  }
}

async function updateFantasyFixtures(options = {}) {
  if (fantasyFixturesUpdating) return;
  fantasyFixturesUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_FPL_FIXTURES, {
    trigger,
    url: FPL_FIXTURES_SOURCE_URL,
    interval_ms: FPL_FIXTURES_INTERVAL_MS,
  });

  console.info(
    `[FPLFixtures] Download start source=${FPL_FIXTURES_SOURCE_URL} trigger=${trigger}`
  );

  try {
    const { payload, payloadBytes } = await fetchFantasyFixturesPayload(
      FPL_FIXTURES_SOURCE_URL,
      {
        timeoutMs: FPL_FIXTURES_TIMEOUT_MS,
        maxBytes: FPL_FIXTURES_MAX_BYTES,
      }
    );
    cachedFantasyFixtures = payload;
    fantasyFixturesPayloadBytes = payloadBytes;
    fantasyFixturesLastUpdated = new Date().toISOString();
    recordsFetched = payload.length;
    fantasyFixturesLastSuccessAt = fantasyFixturesLastUpdated;
    fantasyFixturesLastSuccessDurationSeconds = Math.max(
      0,
      (Date.now() - startedAtMs) / 1000
    );
    setSourceCacheSize(SOURCE_FPL_FIXTURES, recordsFetched);
    refreshFantasyScoreContextCache();

    success = true;
    console.info(
      `[FPLFixtures] Download complete source=${FPL_FIXTURES_SOURCE_URL} trigger=${trigger} bytes=${fantasyFixturesPayloadBytes} fixtures=${recordsFetched} duration_ms=${Date.now() - startedAtMs} updated_at=${fantasyFixturesLastUpdated}`
    );
    logPollSuccess("fpl_fixtures", {
      source: SOURCE_FPL_FIXTURES,
      trigger,
      bytes: fantasyFixturesPayloadBytes,
      fixtures: recordsFetched,
      updated_at: fantasyFixturesLastUpdated,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_FPL_FIXTURES, {
      trigger,
      url: FPL_FIXTURES_SOURCE_URL,
      interval_ms: FPL_FIXTURES_INTERVAL_MS,
      updated_at: fantasyFixturesLastUpdated,
      fixtures: recordsFetched,
      bytes: fantasyFixturesPayloadBytes,
    });
  } catch (err) {
    fantasyFixturesLastFailureAt = new Date().toISOString();
    fantasyFixturesLastFailureDurationSeconds = Math.max(
      0,
      (Date.now() - startedAtMs) / 1000
    );
    console.warn(
      "Failed to update FPL fixtures dataset:",
      err.message || err
    );
    recordRuntimeComponentFailure(COMPONENT_SOURCE_FPL_FIXTURES, err, {
      trigger,
      url: FPL_FIXTURES_SOURCE_URL,
      interval_ms: FPL_FIXTURES_INTERVAL_MS,
    });
  } finally {
    const durationMs = Date.now() - startedAtMs;
    console.info(
      `[FPLFixtures] Download end source=${FPL_FIXTURES_SOURCE_URL} trigger=${trigger} status=${success ? "success" : "failure"} duration_ms=${durationMs}`
    );
    trackSourceUpdateMetrics({
      source: SOURCE_FPL_FIXTURES,
      startedAtMs,
      success,
      recordsFetched,
    });
    fantasyFixturesUpdating = false;
  }
}

async function updateFantasyEventLive(options = {}) {
  if (fantasyEventLiveUpdating) return;
  if (!currentEventHasMutableFantasyFixtures()) return;

  const sourceURL = currentFantasyEventLiveSourceURL();
  if (!sourceURL) return;

  fantasyEventLiveUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_FPL_EVENT_LIVE, {
    trigger,
    url: sourceURL,
    interval_ms: FPL_EVENT_LIVE_INTERVAL_MS,
  });

  console.info(
    `[FPLEventLive] Download start source=${sourceURL} trigger=${trigger}`
  );

  try {
    const { payload, payloadBytes } = await fetchFantasyEventLivePayload(
      sourceURL,
      {
        timeoutMs: FPL_EVENT_LIVE_TIMEOUT_MS,
        maxBytes: FPL_EVENT_LIVE_MAX_BYTES,
      }
    );
    cachedFantasyEventLive = payload;
    fantasyEventLivePayloadBytes = payloadBytes;
    fantasyEventLiveLastUpdated = new Date().toISOString();
    recordsFetched = Array.isArray(payload && payload.elements) ? payload.elements.length : 0;
    fantasyEventLiveLastSuccessAt = fantasyEventLiveLastUpdated;
    fantasyEventLiveLastSuccessDurationSeconds = Math.max(
      0,
      (Date.now() - startedAtMs) / 1000
    );
    setSourceCacheSize(SOURCE_FPL_EVENT_LIVE, recordsFetched);
    refreshFantasyScoreContextCache();

    success = true;
    console.info(
      `[FPLEventLive] Download complete source=${sourceURL} trigger=${trigger} bytes=${fantasyEventLivePayloadBytes} elements=${recordsFetched} duration_ms=${Date.now() - startedAtMs} updated_at=${fantasyEventLiveLastUpdated}`
    );
    logPollSuccess("fpl_event_live", {
      source: SOURCE_FPL_EVENT_LIVE,
      trigger,
      bytes: fantasyEventLivePayloadBytes,
      elements: recordsFetched,
      current_event_id: fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id,
      updated_at: fantasyEventLiveLastUpdated,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_FPL_EVENT_LIVE, {
      trigger,
      url: sourceURL,
      interval_ms: FPL_EVENT_LIVE_INTERVAL_MS,
      updated_at: fantasyEventLiveLastUpdated,
      elements: recordsFetched,
      bytes: fantasyEventLivePayloadBytes,
    });
  } catch (err) {
    fantasyEventLiveLastFailureAt = new Date().toISOString();
    fantasyEventLiveLastFailureDurationSeconds = Math.max(
      0,
      (Date.now() - startedAtMs) / 1000
    );
    console.warn(
      "Failed to update FPL event live dataset:",
      err.message || err
    );
    recordRuntimeComponentFailure(COMPONENT_SOURCE_FPL_EVENT_LIVE, err, {
      trigger,
      url: sourceURL,
      interval_ms: FPL_EVENT_LIVE_INTERVAL_MS,
    });
  } finally {
    const durationMs = Date.now() - startedAtMs;
    console.info(
      `[FPLEventLive] Download end source=${sourceURL} trigger=${trigger} status=${success ? "success" : "failure"} duration_ms=${durationMs}`
    );
    trackSourceUpdateMetrics({
      source: SOURCE_FPL_EVENT_LIVE,
      startedAtMs,
      success,
      recordsFetched,
    });
    fantasyEventLiveUpdating = false;
  }
}

async function updateClubEloFixtures(options = {}) {
  if (clubEloFixturesUpdating) {
    return {
      success: false,
      skipped: true,
      reason: "update_in_progress",
    };
  }

  clubEloFixturesUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_CLUB_ELO_FIXTURES, {
    trigger,
    url: CLUB_ELO_FIXTURES_URL,
    interval_ms: CLUB_ELO_FIXTURES_INTERVAL_MS,
  });

  try {
    const result = await fetchClubEloFixtures({
      url: CLUB_ELO_FIXTURES_URL,
      minRows: CLUB_ELO_FIXTURES_MIN_ROWS,
      minBytes: CLUB_ELO_FIXTURES_MIN_BYTES,
    });
    const fixtures = Array.isArray(result.fixtures) ? result.fixtures : [];
    if (fixtures.length === 0) {
      throw new Error("Club Elo fixtures update returned no fixtures");
    }

    const nowIso = new Date().toISOString();
    const candidatesByDate = buildClubEloFixturesCandidatesByDate(matchDetailsById);
    const updatedSubset = {};
    let matchedCount = 0;
    let unmatchedCount = 0;

    fixtures.forEach((fixture) => {
      const bestMatch = findBestMatchDetailsForClubEloFixture(fixture, candidatesByDate);
      if (!bestMatch) {
        unmatchedCount += 1;
        return;
      }

      const existingPayload = matchDetailsById.get(bestMatch.details_id);
      if (!existingPayload || typeof existingPayload !== "object") {
        unmatchedCount += 1;
        return;
      }

      const mergedPayload = mergeClubEloFixtureMetadata(
        existingPayload,
        fixture,
        bestMatch,
        nowIso,
        result.url
      );
      matchDetailsById.set(bestMatch.details_id, mergedPayload);
      updatedSubset[bestMatch.details_id] = mergedPayload;
      matchedCount += 1;
    });

    cachedClubEloFixtures = fixtures;
    recordsFetched = fixtures.length;
    clubEloFixturesLastUpdated = nowIso;
    clubEloFixturesLastMatchedCount = matchedCount;
    clubEloFixturesLastUnmatchedCount = unmatchedCount;
    setSourceCacheSize(SOURCE_CLUB_ELO_FIXTURES, fixtures.length);
    writeClubEloFixturesData(CLUB_ELO_FIXTURES_OUTPUT_PATH, fixtures);

    if (Object.keys(updatedSubset).length > 0) {
      await persistOperationalMatchDetailsSafe(updatedSubset, {
        replace: false,
        updated_at: nowIso,
        source: SOURCE_CLUB_ELO_FIXTURES,
      });
      matchDetailsLastUpdated = nowIso;
    }

    success = true;
    logPollSuccess("club_elo_fixtures", {
      source: SOURCE_CLUB_ELO_FIXTURES,
      trigger,
      rows: fixtures.length,
      matched: matchedCount,
      unmatched: unmatchedCount,
      updated_at: nowIso,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_CLUB_ELO_FIXTURES, {
      trigger,
      url: CLUB_ELO_FIXTURES_URL,
      interval_ms: CLUB_ELO_FIXTURES_INTERVAL_MS,
      rows: fixtures.length,
      matched: matchedCount,
      unmatched: unmatchedCount,
      updated_at: nowIso,
    });
    return {
      success: true,
      trigger,
      url: result.url,
      count: fixtures.length,
      matched_count: matchedCount,
      unmatched_count: unmatchedCount,
      content_type: result.contentType,
      bytes: result.byteLength,
      min_rows: CLUB_ELO_FIXTURES_MIN_ROWS,
      min_bytes: CLUB_ELO_FIXTURES_MIN_BYTES,
      updated_at: nowIso,
    };
  } catch (err) {
    recordRuntimeComponentFailure(COMPONENT_SOURCE_CLUB_ELO_FIXTURES, err, {
      trigger,
      url: CLUB_ELO_FIXTURES_URL,
      interval_ms: CLUB_ELO_FIXTURES_INTERVAL_MS,
    });
    console.warn("Failed to update Club Elo fixtures:", err.message || err);
    return {
      success: false,
      trigger,
      error: err.message || String(err),
      updated_at: clubEloFixturesLastUpdated,
      cached_count: Array.isArray(cachedClubEloFixtures) ? cachedClubEloFixtures.length : 0,
      cached_matched_count: clubEloFixturesLastMatchedCount,
      cached_unmatched_count: clubEloFixturesLastUnmatchedCount,
    };
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_CLUB_ELO_FIXTURES,
      startedAtMs,
      success,
      recordsFetched,
    });
    clubEloFixturesUpdating = false;
  }
}

async function updateClubEloTeams(options = {}) {
  if (clubEloUpdating) {
    return {
      success: false,
      skipped: true,
      reason: "update_in_progress",
    };
  }

  clubEloUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_CLUB_ELO, {
    trigger,
    url: CLUB_ELO_BASE_URL,
    interval_ms: CLUB_ELO_INTERVAL_MS,
  });

  try {
    const result = await fetchClubEloRankings({
      baseUrl: CLUB_ELO_BASE_URL,
      date: options && options.date ? String(options.date).trim() : undefined,
      timeZone: CLUB_ELO_TIMEZONE,
      minRows: CLUB_ELO_MIN_ROWS,
      minBytes: CLUB_ELO_MIN_BYTES,
    });
    const teams = normalizeClubEloTeamsPayload(result.teams);
    if (!Array.isArray(teams) || teams.length === 0) {
      throw new Error("Club Elo update returned no teams");
    }

    cachedClubEloTeams = teams;
    recordsFetched = teams.length;
    setSourceCacheSize(SOURCE_CLUB_ELO, teams.length);
    clubEloLastUpdated = new Date().toISOString();
    const durationSeconds = Math.max(0, (Date.now() - startedAtMs) / 1000);
    markClubEloSuccess(clubEloLastUpdated, teams, durationSeconds);
    writeClubEloTeams(CLUB_ELO_OUTPUT_PATH, teams);
    await persistOperationalDatasetSafe(OP_DATASET_CLUB_ELO_TEAMS, teams, {
      updated_at: clubEloLastUpdated,
      source: SOURCE_CLUB_ELO,
      ttl_seconds: CLUB_ELO_REDIS_TTL_SECONDS,
    });
    success = true;
    logPollSuccess("club_elo_rankings", {
      source: SOURCE_CLUB_ELO,
      trigger,
      count: teams.length,
      date: result.date,
      updated_at: clubEloLastUpdated,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_CLUB_ELO, {
      trigger,
      url: CLUB_ELO_BASE_URL,
      interval_ms: CLUB_ELO_INTERVAL_MS,
      count: teams.length,
      updated_at: clubEloLastUpdated,
      date: result.date,
    });
    return {
      success: true,
      trigger,
      date: result.date,
      url: result.url,
      count: teams.length,
      content_type: result.contentType,
      bytes: result.byteLength,
      min_rows: CLUB_ELO_MIN_ROWS,
      min_bytes: CLUB_ELO_MIN_BYTES,
      updated_at: clubEloLastUpdated,
    };
  } catch (err) {
    const durationSeconds = Math.max(0, (Date.now() - startedAtMs) / 1000);
    markClubEloFailure(new Date().toISOString(), durationSeconds);
    recordRuntimeComponentFailure(COMPONENT_SOURCE_CLUB_ELO, err, {
      trigger,
      url: CLUB_ELO_BASE_URL,
      interval_ms: CLUB_ELO_INTERVAL_MS,
    });
    console.warn("Failed to update Club Elo teams:", err.message || err);
    return {
      success: false,
      trigger,
      error: err.message || String(err),
      updated_at: clubEloLastUpdated,
      cached_count: Array.isArray(cachedClubEloTeams) ? cachedClubEloTeams.length : 0,
    };
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_CLUB_ELO,
      startedAtMs,
      success,
      recordsFetched,
    });
    clubEloUpdating = false;
  }
}

async function updateFootballDatabaseTeams(options = {}) {
  if (footballDatabaseUpdating) {
    return {
      success: false,
      skipped: true,
      reason: "update_in_progress",
    };
  }

  footballDatabaseUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_FOOTBALL_DATABASE, {
    trigger,
    url: FOOTBALL_DATABASE_BASE_URL,
    interval_ms: FOOTBALL_DATABASE_INTERVAL_MS,
  });

  try {
    const result = await fetchFootballDatabaseRankings({
      baseUrl: FOOTBALL_DATABASE_BASE_URL,
      concurrency: FOOTBALL_DATABASE_CONCURRENCY,
      minRows: FOOTBALL_DATABASE_MIN_ROWS,
      maxPages: FOOTBALL_DATABASE_MAX_PAGES,
      retryAttempts: FOOTBALL_DATABASE_RETRY_ATTEMPTS,
      retryBackoffBaseMs: FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS,
      retryBackoffMaxMs: FOOTBALL_DATABASE_RETRY_BACKOFF_MAX_MS,
      retryBackoffFactor: FOOTBALL_DATABASE_RETRY_BACKOFF_FACTOR,
      retryJitterMs: FOOTBALL_DATABASE_RETRY_JITTER_MS,
      adaptiveConcurrencyEnabled: FOOTBALL_DATABASE_ADAPTIVE_CONCURRENCY_ENABLED,
      adaptiveMinConcurrency: FOOTBALL_DATABASE_ADAPTIVE_MIN_CONCURRENCY,
    });
    const teams = normalizeFootballDatabaseTeamsPayload(result.teams);
    if (!Array.isArray(teams) || teams.length === 0) {
      throw new Error("FootballDatabase update returned no teams");
    }

    cachedFootballDatabaseTeams = teams;
    recordsFetched = teams.length;
    setSourceCacheSize(SOURCE_FOOTBALL_DATABASE, teams.length);
    footballDatabaseLastUpdated = new Date().toISOString();
    const durationSeconds = Math.max(0, (Date.now() - startedAtMs) / 1000);
    markFootballDatabaseSuccess(
      footballDatabaseLastUpdated,
      teams,
      durationSeconds,
      result.dateModified
    );
    writeFootballDatabaseTeams(FOOTBALL_DATABASE_OUTPUT_PATH, teams);
    await persistOperationalDatasetSafe(OP_DATASET_FOOTBALL_DATABASE_TEAMS, teams, {
      updated_at: footballDatabaseLastUpdated,
      source: SOURCE_FOOTBALL_DATABASE,
      ttl_seconds: FOOTBALL_DATABASE_REDIS_TTL_SECONDS,
    });
    success = true;
    logPollSuccess("football_database_rankings", {
      source: SOURCE_FOOTBALL_DATABASE,
      trigger,
      count: teams.length,
      pages: `${result.fetchedPages}/${result.totalPages}`,
      retries: result && result.retry ? result.retry.retries_performed : 0,
      adaptive_reductions:
        result && result.adaptive_concurrency ? result.adaptive_concurrency.reductions : 0,
      final_concurrency:
        result && result.adaptive_concurrency
          ? result.adaptive_concurrency.final_concurrency
          : FOOTBALL_DATABASE_CONCURRENCY,
      updated_at: footballDatabaseLastUpdated,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_FOOTBALL_DATABASE, {
      trigger,
      url: FOOTBALL_DATABASE_BASE_URL,
      interval_ms: FOOTBALL_DATABASE_INTERVAL_MS,
      count: teams.length,
      updated_at: footballDatabaseLastUpdated,
      pages_fetched: result.fetchedPages,
      pages_total: result.totalPages,
      retries: result && result.retry ? result.retry.retries_performed : 0,
    });
    return {
      success: true,
      trigger,
      url: result.url,
      count: teams.length,
      pages_total: result.totalPages,
      pages_fetched: result.fetchedPages,
      concurrency: FOOTBALL_DATABASE_CONCURRENCY,
      min_rows: FOOTBALL_DATABASE_MIN_ROWS,
      max_pages: FOOTBALL_DATABASE_MAX_PAGES,
      retry_attempts: FOOTBALL_DATABASE_RETRY_ATTEMPTS,
      retry_backoff_base_ms: FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS,
      retry_backoff_max_ms: FOOTBALL_DATABASE_RETRY_BACKOFF_MAX_MS,
      retry_backoff_factor: FOOTBALL_DATABASE_RETRY_BACKOFF_FACTOR,
      retry_jitter_ms: FOOTBALL_DATABASE_RETRY_JITTER_MS,
      retry: result && result.retry ? result.retry : null,
      adaptive_concurrency_enabled: FOOTBALL_DATABASE_ADAPTIVE_CONCURRENCY_ENABLED,
      adaptive_min_concurrency: FOOTBALL_DATABASE_ADAPTIVE_MIN_CONCURRENCY,
      adaptive_concurrency:
        result && result.adaptive_concurrency ? result.adaptive_concurrency : null,
      date_modified: result.dateModified || null,
      content_type: result.contentType,
      bytes: result.byteLength,
      updated_at: footballDatabaseLastUpdated,
    };
  } catch (err) {
    const durationSeconds = Math.max(0, (Date.now() - startedAtMs) / 1000);
    markFootballDatabaseFailure(new Date().toISOString(), durationSeconds);
    recordRuntimeComponentFailure(COMPONENT_SOURCE_FOOTBALL_DATABASE, err, {
      trigger,
      url: FOOTBALL_DATABASE_BASE_URL,
      interval_ms: FOOTBALL_DATABASE_INTERVAL_MS,
    });
    console.warn("Failed to update FootballDatabase teams:", err.message || err);
    return {
      success: false,
      trigger,
      error: err.message || String(err),
      updated_at: footballDatabaseLastUpdated,
      cached_count: Array.isArray(cachedFootballDatabaseTeams)
        ? cachedFootballDatabaseTeams.length
        : 0,
    };
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_FOOTBALL_DATABASE,
      startedAtMs,
      success,
      recordsFetched,
    });
    footballDatabaseUpdating = false;
  }
}

async function updateNationalEloTeams(options = {}) {
  if (nationalEloUpdating) {
    return {
      success: false,
      skipped: true,
      reason: "update_in_progress",
    };
  }

  nationalEloUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  const trigger = options && options.trigger ? String(options.trigger) : "scheduled";
  recordRuntimeComponentStart(COMPONENT_SOURCE_NATIONAL_ELO, {
    trigger,
    url: NATIONAL_ELO_BASE_URL,
    interval_ms: NATIONAL_ELO_INTERVAL_MS,
  });

  try {
    const result = await fetchNationalEloRankings({
      baseUrl: NATIONAL_ELO_BASE_URL,
      page: NATIONAL_ELO_PAGE,
      minRows: NATIONAL_ELO_MIN_ROWS,
      minBytes: NATIONAL_ELO_MIN_BYTES,
      fallbackTeams: cachedNationalEloTeams,
      retryAttempts: NATIONAL_ELO_RETRY_ATTEMPTS,
      retryBackoffBaseMs: NATIONAL_ELO_RETRY_BACKOFF_BASE_MS,
      retryBackoffMaxMs: NATIONAL_ELO_RETRY_BACKOFF_MAX_MS,
      retryBackoffFactor: NATIONAL_ELO_RETRY_BACKOFF_FACTOR,
      retryJitterMs: NATIONAL_ELO_RETRY_JITTER_MS,
      preferIpv4: NATIONAL_ELO_PREFER_IPV4,
      userAgent: NATIONAL_ELO_USER_AGENT,
    });
    const teams = normalizeNationalEloTeamsPayload(result.teams);
    if (!Array.isArray(teams) || teams.length === 0) {
      throw new Error("National Elo update returned no teams");
    }

    cachedNationalEloTeams = teams;
    recordsFetched = teams.length;
    setSourceCacheSize(SOURCE_NATIONAL_ELO, teams.length);
    nationalEloLastUpdated = new Date().toISOString();
    const durationSeconds = Math.max(0, (Date.now() - startedAtMs) / 1000);
    markNationalEloSuccess(
      nationalEloLastUpdated,
      teams,
      durationSeconds,
      result.dateModified || (result.lastModified ? String(result.lastModified).slice(0, 10) : null)
    );
    writeNationalEloTeams(NATIONAL_ELO_OUTPUT_PATH, teams);
    await persistOperationalDatasetSafe(OP_DATASET_NATIONAL_ELO_TEAMS, teams, {
      updated_at: nationalEloLastUpdated,
      source: SOURCE_NATIONAL_ELO,
      ttl_seconds: NATIONAL_ELO_REDIS_TTL_SECONDS,
    });
    success = true;
    logPollSuccess("national_elo_rankings", {
      source: SOURCE_NATIONAL_ELO,
      trigger,
      count: teams.length,
      page: result.page,
      retries: result && result.retry ? result.retry.retries_performed : 0,
      partial_success:
        result && result.partial_fetch
          ? !result.partial_fetch.successors_loaded || !result.partial_fetch.team_dictionary_loaded
          : false,
      updated_at: nationalEloLastUpdated,
      duration_ms: Date.now() - startedAtMs,
    });
    recordRuntimeComponentSuccess(COMPONENT_SOURCE_NATIONAL_ELO, {
      trigger,
      url: NATIONAL_ELO_BASE_URL,
      interval_ms: NATIONAL_ELO_INTERVAL_MS,
      count: teams.length,
      updated_at: nationalEloLastUpdated,
      retries: result && result.retry ? result.retry.retries_performed : 0,
    });
    if (Array.isArray(result.warnings) && result.warnings.length > 0) {
      console.warn(
        `National Elo update completed with warnings (${result.warnings.length}): ${result.warnings.join(" | ")}`
      );
    }
    return {
      success: true,
      trigger,
      page: result.page,
      url: result.url,
      count: teams.length,
      min_rows: NATIONAL_ELO_MIN_ROWS,
      min_bytes: NATIONAL_ELO_MIN_BYTES,
      retry_attempts: NATIONAL_ELO_RETRY_ATTEMPTS,
      retry_backoff_base_ms: NATIONAL_ELO_RETRY_BACKOFF_BASE_MS,
      retry_backoff_max_ms: NATIONAL_ELO_RETRY_BACKOFF_MAX_MS,
      retry_backoff_factor: NATIONAL_ELO_RETRY_BACKOFF_FACTOR,
      retry_jitter_ms: NATIONAL_ELO_RETRY_JITTER_MS,
      prefer_ipv4: NATIONAL_ELO_PREFER_IPV4,
      retry: result && result.retry ? result.retry : null,
      partial_fetch: result && result.partial_fetch ? result.partial_fetch : null,
      warnings: Array.isArray(result && result.warnings) ? result.warnings : [],
      request: result && result.request ? result.request : null,
      date_modified: result.dateModified || null,
      last_modified: result.lastModified || null,
      content_type: result.contentType,
      bytes: result.byteLength,
      updated_at: nationalEloLastUpdated,
    };
  } catch (err) {
    const durationSeconds = Math.max(0, (Date.now() - startedAtMs) / 1000);
    markNationalEloFailure(new Date().toISOString(), durationSeconds);
    recordRuntimeComponentFailure(COMPONENT_SOURCE_NATIONAL_ELO, err, {
      trigger,
      url: NATIONAL_ELO_BASE_URL,
      interval_ms: NATIONAL_ELO_INTERVAL_MS,
    });
    console.warn("Failed to update National Elo teams:", err.message || err);
    if (Array.isArray(err && err.attemptErrors) && err.attemptErrors.length > 0) {
      console.warn(
        `National Elo retry attempts (${err.attemptErrors.length}) for ${err.url || "unknown url"}: ` +
        `${JSON.stringify(err.attemptErrors)}`
      );
    }
    return {
      success: false,
      trigger,
      error: err.message || String(err),
      attempt_errors: Array.isArray(err && err.attemptErrors) ? err.attemptErrors : [],
      updated_at: nationalEloLastUpdated,
      cached_count: Array.isArray(cachedNationalEloTeams) ? cachedNationalEloTeams.length : 0,
    };
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_NATIONAL_ELO,
      startedAtMs,
      success,
      recordsFetched,
    });
    nationalEloUpdating = false;
  }
}

function parseRequiredDateRange(query) {
  const start = query.start ? String(query.start).trim() : "";
  const end = query.end ? String(query.end).trim() : "";
  if (!start || !end) {
    return { error: "Missing required query params: start and end (YYYY-MM-DD)" };
  }
  if (!isDateOnly(start) || !isDateOnly(end)) {
    return { error: "Invalid date range. Expected YYYY-MM-DD for start and end." };
  }
  if (start > end) {
    return { error: "Invalid date range. start must be on or before end." };
  }
  return { start, end };
}

function parsePositiveInt(value, fallback, min = 1, max = Number.MAX_SAFE_INTEGER) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  const normalized = Math.floor(parsed);
  if (normalized < min) return fallback;
  return Math.min(max, normalized);
}

const MAX_BBC_HISTORY_QUERY_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_BBC_HISTORY_QUERY_HOURS = Math.max(1, Math.floor(MAX_BBC_HISTORY_QUERY_MS / (60 * 60 * 1000)));

function parseBbcHistoryWindow(query) {
  const rawStart = query.start ? String(query.start).trim() : "";
  const rawEnd = query.end ? String(query.end).trim() : "";
  const nowMs = Date.now();

  if (rawStart || rawEnd) {
    if (!rawStart || !rawEnd) {
      return {
        error: "When using absolute range, both start and end are required (ISO datetime).",
      };
    }
    const startMs = Date.parse(rawStart);
    const endMs = Date.parse(rawEnd);
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs)) {
      return {
        error: "Invalid start/end datetime. Use ISO format, e.g. 2026-02-21T10:00:00Z.",
      };
    }
    if (endMs < startMs) {
      return { error: "Invalid date range. end must be greater than or equal to start." };
    }
    if (endMs - startMs > MAX_BBC_HISTORY_QUERY_MS) {
      return {
        error: `Maximum query range is ${MAX_BBC_HISTORY_QUERY_HOURS} hours (7 days).`,
      };
    }
    return {
      startMs: Math.floor(startMs),
      endMs: Math.floor(endMs),
      mode: "absolute",
    };
  }

  const hours = parsePositiveInt(query.hours, 24, 1, MAX_BBC_HISTORY_QUERY_HOURS);
  return {
    startMs: nowMs - hours * 60 * 60 * 1000,
    endMs: nowMs,
    mode: "relative",
    hours,
  };
}

function parseStatusMinuteValue(status) {
  return parseMatchStatusMinute(status);
}

function isFinishedMatchStatus(status) {
  const normalized = String(status || "").trim();
  if (!normalized) return false;
  return MATCH_STATUS_COMPLETE_TOKENS.has(normalized.toUpperCase());
}

function displayMatchStatusForAdmin(status) {
  const normalized = String(status || "").trim();
  if (!normalized) return null;
  if (MATCH_STATUS_MINUTE_PATTERN.test(normalized)) {
    return `${normalized.replace(/'/g, "")}'`;
  }
  return normalized;
}

function kickoffTimestampMs(match) {
  const kickoff = parseKickoff(match);
  return kickoff ? kickoff.getTime() : null;
}

function startOfTodayLocal(now = new Date()) {
  return new Date(now.getFullYear(), now.getMonth(), now.getDate());
}

function parseMatchDayLocal(dateValue) {
  const value = String(dateValue || "").trim();
  if (!isDateOnly(value)) return null;
  const [year, month, day] = value.split("-").map((part) => Number(part));
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)) {
    return null;
  }
  return new Date(year, month - 1, day);
}

function sortAdminMatchesByKickoff(lhs, rhs, direction = "asc") {
  const lhsKickoffMs = Number(lhs && lhs.kickoff_ts_ms);
  const rhsKickoffMs = Number(rhs && rhs.kickoff_ts_ms);
  const lhsHasKickoff = Number.isFinite(lhsKickoffMs);
  const rhsHasKickoff = Number.isFinite(rhsKickoffMs);

  if (lhsHasKickoff || rhsHasKickoff) {
    if (!lhsHasKickoff) return direction === "asc" ? 1 : -1;
    if (!rhsHasKickoff) return direction === "asc" ? -1 : 1;
    if (lhsKickoffMs !== rhsKickoffMs) {
      return direction === "asc" ? lhsKickoffMs - rhsKickoffMs : rhsKickoffMs - lhsKickoffMs;
    }
  }

  const dateCompare = String(lhs && lhs.date ? lhs.date : "").localeCompare(
    String(rhs && rhs.date ? rhs.date : "")
  );
  if (dateCompare !== 0) {
    return direction === "asc" ? dateCompare : -dateCompare;
  }

  const timeCompare = normalizeTimeValue(lhs && lhs.time).localeCompare(
    normalizeTimeValue(rhs && rhs.time)
  );
  if (timeCompare !== 0) {
    return direction === "asc" ? timeCompare : -timeCompare;
  }

  const leagueCompare = compareInsensitive(lhs && lhs.league ? lhs.league : "", rhs && rhs.league ? rhs.league : "");
  if (leagueCompare !== 0) return leagueCompare;
  const homeCompare = compareInsensitive(
    lhs && lhs.home_team ? lhs.home_team : "",
    rhs && rhs.home_team ? rhs.home_team : ""
  );
  if (homeCompare !== 0) return homeCompare;
  return compareInsensitive(
    lhs && lhs.away_team ? lhs.away_team : "",
    rhs && rhs.away_team ? rhs.away_team : ""
  );
}

function toAdminListMatchPayload(match, options = {}) {
  const payload = toMatchListPayload(match, options);
  if (!payload) return null;
  const normalized = normalizeMatchRecord(match);
  let statePayload = null;

  if (payload.match_details_id && options && options.matchDetailsLookup) {
    const matchDetailsLookup = options.matchDetailsLookup;
    const matchDetails =
      matchDetailsLookup instanceof Map
        ? matchDetailsLookup.get(payload.match_details_id)
        : matchDetailsLookup[payload.match_details_id];
    statePayload = getMatchDetailsStatePayload(matchDetails);
  }

  if (!statePayload && normalized) {
    statePayload = {
      home_score: parseNumericScore(normalized.home_score),
      away_score: parseNumericScore(normalized.away_score),
      aggregate_home_score: parseNumericScore(normalized.aggregate_home_score),
      aggregate_away_score: parseNumericScore(normalized.aggregate_away_score),
      score_status: resolveMatchScoreStatus(normalized),
      penalty_result: normalized.penalty_result || null,
    };
  }

  const kickoffMs = kickoffTimestampMs(payload);
  const inProgress = isInProgressMatchStatus(statePayload && statePayload.score_status);
  const finished = isFinishedMatchStatus(statePayload && statePayload.score_status);
  const hasScore =
    statePayload &&
    statePayload.home_score !== undefined &&
    statePayload.home_score !== null &&
    statePayload.away_score !== undefined &&
    statePayload.away_score !== null;

  return {
    ...payload,
    ...(statePayload || {}),
    id: payload.match_details_id || matchKey(payload),
    kickoff_ts_ms: Number.isFinite(kickoffMs) ? kickoffMs : null,
    in_progress: inProgress,
    finished,
    has_score: hasScore,
    display_score_status: displayMatchStatusForAdmin(statePayload && statePayload.score_status),
  };
}

function isFixtureMatchForAdmin(match, now = new Date()) {
  const nowMs = now.getTime();
  if (match.in_progress || match.finished) return false;

  const kickoffMs = Number(match.kickoff_ts_ms);
  if (Number.isFinite(kickoffMs)) {
    return kickoffMs >= nowMs;
  }

  const day = parseMatchDayLocal(match.date);
  if (!day) return false;
  return day.getTime() >= startOfTodayLocal(now).getTime();
}

function isResultMatchForAdmin(match, now = new Date()) {
  const day = parseMatchDayLocal(match.date);
  const todayStartMs = startOfTodayLocal(now).getTime();

  if (!day) {
    return Boolean(match.in_progress || match.finished);
  }

  const dayMs = day.getTime();
  if (dayMs < todayStartMs) return true;
  if (dayMs > todayStartMs) return false;
  return Boolean(match.in_progress || match.finished);
}

function filterAdminMatches(rawMatches, options = {}) {
  const mode = options.mode === "results" ? "results" : "fixtures";
  const now = options.now instanceof Date ? options.now : new Date();
  const matchDetailsLookup = options.matchDetailsLookup || {};

  const mapped = (Array.isArray(rawMatches) ? rawMatches : [])
    .map((match) => toAdminListMatchPayload(match, { matchDetailsLookup }))
    .filter(Boolean);

  const filtered = mapped.filter((match) => (
    mode === "fixtures" ? isFixtureMatchForAdmin(match, now) : isResultMatchForAdmin(match, now)
  ));

  return filtered.sort((lhs, rhs) =>
    sortAdminMatchesByKickoff(lhs, rhs, mode === "fixtures" ? "asc" : "desc")
  );
}

function extractDeviceNameFromPreferenceRecord(record) {
  if (!record || typeof record !== "object") return null;
  const preferences =
    record.preferences && typeof record.preferences === "object" ? record.preferences : {};
  const candidates = [
    record.deviceName,
    record.device_name,
    record.name,
    preferences.deviceName,
    preferences.device_name,
    preferences.deviceLabel,
    preferences.device_label,
    preferences.displayName,
    preferences.display_name,
    preferences.nickname,
    preferences.name,
  ];

  const selected = candidates.find(
    (value) => typeof value === "string" && value.trim().length > 0
  );
  return selected ? selected.trim().slice(0, 120) : null;
}

function buildDeviceTokenNameLookup(preferenceRecords) {
  const lookup = new Map();
  (Array.isArray(preferenceRecords) ? preferenceRecords : []).forEach((record) => {
    const token = normalizeDeviceToken(record && record.deviceToken);
    if (!token) return;
    const name = extractDeviceNameFromPreferenceRecord(record);
    if (!name) return;
    lookup.set(token, name);
  });
  return lookup;
}

function shortDeviceTokenForAdmin(deviceToken, prefix = 8, suffix = 6) {
  const value = String(deviceToken || "").trim();
  if (!value) return "unknown-device";
  if (value.length <= prefix + suffix + 3) return value;
  return `${value.slice(0, prefix)}...${value.slice(-suffix)}`;
}

function adminHistoryTimestampMs(value) {
  const parsed = Number(value);
  if (Number.isFinite(parsed) && parsed > 0) return Math.floor(parsed);
  return 0;
}

function sortHistoryRecordsByTimestampAsc(lhs, rhs) {
  const left = adminHistoryTimestampMs(lhs && lhs.timestamp_ms);
  const right = adminHistoryTimestampMs(rhs && rhs.timestamp_ms);
  if (left !== right) return left - right;
  return String(lhs && lhs.event_type ? lhs.event_type : "").localeCompare(
    String(rhs && rhs.event_type ? rhs.event_type : "")
  );
}

function normalizeNotificationStatusForAdmin(status) {
  const normalized = String(status || "").trim().toLowerCase();
  if (!normalized) return "unknown";
  if (normalized === "sent") return "sent";
  if (normalized === "failed") return "failed";
  if (normalized === "dedupe_skipped") return "dedupe_skipped";
  return normalized;
}

function normalizeFantasyReminderStatusForAdmin(status) {
  const normalized = String(status || "").trim().toLowerCase();
  if (!normalized) return "unknown";
  return normalized;
}

function fantasyReminderTimestampMsForAdmin(value) {
  const direct = Number(value);
  if (Number.isFinite(direct) && direct > 0) return Math.floor(direct);
  const parsed = Date.parse(String(value || "").trim());
  return Number.isFinite(parsed) ? parsed : 0;
}

function effectiveFantasyReminderStatusForAdmin(record, nowMs = Date.now()) {
  const rawStatus = normalizeFantasyReminderStatusForAdmin(record && record.status);
  const deadlineTimeMs = fantasyReminderTimestampMsForAdmin(
    record && (record.deadline_time_ms || record.deadline_time)
  );
  const scheduledForMs = fantasyReminderTimestampMsForAdmin(
    record && (record.scheduled_for_ms || record.scheduled_for)
  );

  if (rawStatus === "scheduled") {
    if (Number.isFinite(deadlineTimeMs) && deadlineTimeMs > 0 && deadlineTimeMs <= nowMs) {
      return "expired";
    }
    if (Number.isFinite(scheduledForMs) && scheduledForMs > 0 && scheduledForMs <= nowMs) {
      return "due";
    }
  }

  return rawStatus;
}

function buildAdminFantasyReminderEntry(record, nowMs = Date.now()) {
  const scheduledForMs = fantasyReminderTimestampMsForAdmin(
    record && (record.scheduled_for_ms || record.scheduled_for)
  );
  const deadlineTimeMs = fantasyReminderTimestampMsForAdmin(
    record && (record.deadline_time_ms || record.deadline_time)
  );
  const sentAtMs = fantasyReminderTimestampMsForAdmin(
    record && (record.sent_at_ms || record.sent_at)
  );
  const effectiveStatus = effectiveFantasyReminderStatusForAdmin(record, nowMs);
  const isPast = Number.isFinite(scheduledForMs) && scheduledForMs > 0 ? scheduledForMs < nowMs : false;

  return {
    reminder_id: record && record.reminder_id ? String(record.reminder_id) : null,
    kind: record && record.kind ? String(record.kind) : "fantasy_deadline",
    source: record && record.source ? String(record.source) : null,
    status: normalizeFantasyReminderStatusForAdmin(record && record.status),
    effective_status: effectiveStatus,
    is_past: isPast,
    can_test_send:
      effectiveStatus === "scheduled" &&
      Boolean(record && record.apns_token) &&
      Number.isFinite(deadlineTimeMs) &&
      deadlineTimeMs > nowMs,
    gameweek_id:
      record && record.gameweek_id !== undefined && record.gameweek_id !== null
        ? Number(record.gameweek_id)
        : null,
    gameweek_name: record && record.gameweek_name ? String(record.gameweek_name) : null,
    title: record && record.title ? String(record.title) : null,
    body: record && record.body ? String(record.body) : null,
    device_token: record && record.device_token ? String(record.device_token) : null,
    device_token_short: shortDeviceTokenForAdmin(record && record.device_token),
    apns_token_present: Boolean(record && record.apns_token),
    dedupe_basis: record && record.dedupe_basis ? String(record.dedupe_basis) : null,
    target_key: record && record.target_key ? String(record.target_key) : null,
    scheduled_for_ms: scheduledForMs || null,
    scheduled_for:
      Number.isFinite(scheduledForMs) && scheduledForMs > 0
        ? new Date(scheduledForMs).toISOString()
        : record && record.scheduled_for
          ? String(record.scheduled_for)
          : null,
    deadline_time_ms: deadlineTimeMs || null,
    deadline_time:
      Number.isFinite(deadlineTimeMs) && deadlineTimeMs > 0
        ? new Date(deadlineTimeMs).toISOString()
        : record && record.deadline_time
          ? String(record.deadline_time)
          : null,
    sent_at_ms: sentAtMs || null,
    sent_at:
      Number.isFinite(sentAtMs) && sentAtMs > 0
        ? new Date(sentAtMs).toISOString()
        : record && record.sent_at
          ? String(record.sent_at)
          : null,
    updated_at: record && record.updated_at ? String(record.updated_at) : null,
    environment: record && record.environment ? String(record.environment) : null,
    last_error: record && record.last_error ? String(record.last_error) : null,
    is_development_build: Boolean(record && record.is_development_build),
    device_time_zone: record && record.device_time_zone ? String(record.device_time_zone) : null,
    device_locale: record && record.device_locale ? String(record.device_locale) : null,
    last_test_status:
      record && record.last_test_status ? String(record.last_test_status) : null,
    last_test_error:
      record && record.last_test_error ? String(record.last_test_error) : null,
    last_test_sent_at:
      record && record.last_test_sent_at ? String(record.last_test_sent_at) : null,
    payload: record && record.payload ? record.payload : null,
  };
}

function buildAdminFantasyReminderStatusCounts(records, nowMs = Date.now()) {
  return (Array.isArray(records) ? records : []).reduce((acc, record) => {
    const key = effectiveFantasyReminderStatusForAdmin(record, nowMs);
    acc[key] = (acc[key] || 0) + 1;
    return acc;
  }, {});
}

function buildNextFantasyReminderSummary(nextGameweek, nowMs = Date.now()) {
  if (!nextGameweek || typeof nextGameweek !== "object") return null;
  const deadlineTime = String(nextGameweek.deadline_time || "").trim();
  const deadlineTimeMs = Date.parse(deadlineTime);
  const scheduledForMs = Number.isFinite(deadlineTimeMs)
    ? deadlineTimeMs - 24 * 60 * 60 * 1000
    : null;
  return {
    gameweek_id:
      nextGameweek.id !== undefined && nextGameweek.id !== null ? Number(nextGameweek.id) : null,
    gameweek_name: nextGameweek.name ? String(nextGameweek.name) : null,
    deadline_time: deadlineTime || null,
    deadline_time_ms: Number.isFinite(deadlineTimeMs) ? deadlineTimeMs : null,
    scheduled_for:
      Number.isFinite(scheduledForMs) ? new Date(scheduledForMs).toISOString() : null,
    scheduled_for_ms: Number.isFinite(scheduledForMs) ? scheduledForMs : null,
    is_due:
      Number.isFinite(scheduledForMs) &&
      Number.isFinite(deadlineTimeMs) &&
      scheduledForMs <= nowMs &&
      deadlineTimeMs > nowMs,
  };
}

function notificationGroupKeyForAdmin(record) {
  const eventType = String(record && record.event_type ? record.event_type : "unknown").trim();
  const eventKey = String(record && record.event_key ? record.event_key : "").trim();
  const title = String(record && record.title ? record.title : "").trim();
  const body = String(record && record.body ? record.body : "").trim();
  const dispatchMode = String(record && record.dispatch_mode ? record.dispatch_mode : "").trim();
  const delay = Number.isFinite(Number(record && record.delay_minutes))
    ? Math.floor(Number(record.delay_minutes))
    : 0;

  if (eventKey) {
    return `event:${eventType}|${eventKey}|${title}|${body}|${dispatchMode}|${delay}`;
  }

  const timestampBucket = Math.floor(adminHistoryTimestampMs(record && record.timestamp_ms) / 60_000);
  return `fallback:${eventType}|${title}|${body}|${dispatchMode}|${delay}|${timestampBucket}`;
}

function buildNotificationDispatches(records, deviceTokenNameLookup = new Map()) {
  const sorted = (Array.isArray(records) ? records : [])
    .slice()
    .sort(sortHistoryRecordsByTimestampAsc);
  const grouped = new Map();

  sorted.forEach((record) => {
    const key = notificationGroupKeyForAdmin(record);
    if (!grouped.has(key)) {
      grouped.set(key, {
        dispatch_key: key,
        event_type: String(record && record.event_type ? record.event_type : "unknown"),
        event_key: String(record && record.event_key ? record.event_key : "").trim() || null,
        title: record && record.title ? String(record.title) : null,
        body: record && record.body ? String(record.body) : null,
        delay_minutes: Number.isFinite(Number(record && record.delay_minutes))
          ? Number(record.delay_minutes)
          : 0,
        dispatch_mode: record && record.dispatch_mode ? String(record.dispatch_mode) : null,
        first_timestamp_ms: null,
        last_timestamp_ms: null,
        statuses: {},
        count_notifications: 0,
        _device_tokens_set: new Set(),
      });
    }

    const group = grouped.get(key);
    const timestampMs = adminHistoryTimestampMs(record && record.timestamp_ms);
    if (!group.first_timestamp_ms || timestampMs < group.first_timestamp_ms) {
      group.first_timestamp_ms = timestampMs;
    }
    if (!group.last_timestamp_ms || timestampMs > group.last_timestamp_ms) {
      group.last_timestamp_ms = timestampMs;
    }

    const statusKey = normalizeNotificationStatusForAdmin(record && record.status);
    group.statuses[statusKey] = (group.statuses[statusKey] || 0) + 1;
    group.count_notifications += 1;

    const deviceToken = normalizeDeviceToken(record && record.device_token);
    if (deviceToken) {
      group._device_tokens_set.add(deviceToken);
    }
  });

  return Array.from(grouped.values())
    .map((group) => {
      const deviceTokens = Array.from(group._device_tokens_set).sort(compareInsensitive);
      const devices = deviceTokens.map((token) => {
        const configuredName = deviceTokenNameLookup.get(token) || null;
        const shortToken = shortDeviceTokenForAdmin(token);
        return {
          token,
          short_token: shortToken,
          name: configuredName,
          label: configuredName ? `${configuredName} (${shortToken})` : shortToken,
        };
      });

      return {
        dispatch_key: group.dispatch_key,
        event_type: group.event_type,
        event_key: group.event_key,
        title: group.title,
        body: group.body,
        delay_minutes: group.delay_minutes,
        dispatch_mode: group.dispatch_mode,
        first_timestamp_ms: group.first_timestamp_ms,
        last_timestamp_ms: group.last_timestamp_ms,
        count_notifications: group.count_notifications,
        count_device_tokens: devices.length,
        statuses: group.statuses,
        devices,
      };
    })
    .sort((lhs, rhs) => {
      const left = adminHistoryTimestampMs(lhs && lhs.last_timestamp_ms);
      const right = adminHistoryTimestampMs(rhs && rhs.last_timestamp_ms);
      if (left !== right) return right - left;
      return String(lhs && lhs.event_type ? lhs.event_type : "").localeCompare(
        String(rhs && rhs.event_type ? rhs.event_type : "")
      );
    });
}

function goalEventAssisterForAdmin(goalTimeLabel, assists) {
  if (!goalTimeLabel) return null;
  if (!Array.isArray(assists)) return null;
  for (const assister of assists) {
    const assistTimes = Array.isArray(assister && assister.assist_times)
      ? assister.assist_times
      : [];
    if (assistTimes.includes(goalTimeLabel)) {
      const player = String(assister && assister.player ? assister.player : "").trim();
      if (player) return player;
    }
  }
  return null;
}

function flattenGoalTimelineEventsForAdmin(goalScorers, assists, side, teamName) {
  const events = [];
  let sourceOrder = 0;

  (Array.isArray(goalScorers) ? goalScorers : []).forEach((scorer) => {
    const player = String(scorer && scorer.player ? scorer.player : "").trim() || null;

    (Array.isArray(scorer && scorer.goal_times) ? scorer.goal_times : []).forEach((rawTime) => {
      const timeLabel = String(rawTime || "").trim() || null;
      events.push({
        event_type: "goal",
        team_side: side,
        team_name: teamName || null,
        player,
        assister: goalEventAssisterForAdmin(timeLabel, assists),
        time_label: timeLabel,
        minute: parseStatusMinuteValue(timeLabel),
        own_goal: false,
        source_order: sourceOrder++,
      });
    });

    (Array.isArray(scorer && scorer.own_goal_times) ? scorer.own_goal_times : []).forEach(
      (rawTime) => {
        const timeLabel = String(rawTime || "").trim() || null;
        events.push({
          event_type: "goal",
          team_side: side,
          team_name: teamName || null,
          player,
          assister: null,
          time_label: timeLabel,
          minute: parseStatusMinuteValue(timeLabel),
          own_goal: true,
          source_order: sourceOrder++,
        });
      }
    );
  });

  return events;
}

function flattenRedCardTimelineEventsForAdmin(redCards, side, teamName) {
  const events = [];
  let sourceOrder = 0;
  (Array.isArray(redCards) ? redCards : []).forEach((redCard) => {
    const player = String(redCard && redCard.player ? redCard.player : "").trim() || null;
    (Array.isArray(redCard && redCard.red_card_times) ? redCard.red_card_times : []).forEach(
      (rawTime) => {
        const timeLabel = String(rawTime || "").trim() || null;
        events.push({
          event_type: "red_card",
          team_side: side,
          team_name: teamName || null,
          player,
          assister: null,
          time_label: timeLabel,
          minute: parseStatusMinuteValue(timeLabel),
          own_goal: false,
          source_order: sourceOrder++,
        });
      }
    );
  });
  return events;
}

function buildMatchEventTimeline(matchPayload) {
  if (!matchPayload || typeof matchPayload !== "object") return [];

  const homeGoals = flattenGoalTimelineEventsForAdmin(
    matchPayload.home_goal_scorers,
    matchPayload.home_assists,
    "home",
    matchPayload.home_team
  );
  const awayGoals = flattenGoalTimelineEventsForAdmin(
    matchPayload.away_goal_scorers,
    matchPayload.away_assists,
    "away",
    matchPayload.away_team
  );
  const homeRedCards = flattenRedCardTimelineEventsForAdmin(
    matchPayload.home_red_cards,
    "home",
    matchPayload.home_team
  );
  const awayRedCards = flattenRedCardTimelineEventsForAdmin(
    matchPayload.away_red_cards,
    "away",
    matchPayload.away_team
  );

  return [...homeGoals, ...awayGoals, ...homeRedCards, ...awayRedCards]
    .sort((lhs, rhs) => {
      const leftMinute = Number(lhs && lhs.minute);
      const rightMinute = Number(rhs && rhs.minute);
      const leftHasMinute = Number.isFinite(leftMinute);
      const rightHasMinute = Number.isFinite(rightMinute);

      if (leftHasMinute || rightHasMinute) {
        if (!leftHasMinute) return 1;
        if (!rightHasMinute) return -1;
        if (leftMinute !== rightMinute) return leftMinute - rightMinute;
      }

      const leftLabel = String(lhs && lhs.time_label ? lhs.time_label : "");
      const rightLabel = String(rhs && rhs.time_label ? rhs.time_label : "");
      const labelCompare = leftLabel.localeCompare(rightLabel);
      if (labelCompare !== 0) return labelCompare;

      return Number(lhs && lhs.source_order ? lhs.source_order : 0) -
        Number(rhs && rhs.source_order ? rhs.source_order : 0);
    })
    .map((event, index) => ({
      ...event,
      timeline_id: `${event.event_type}:${event.team_side}:${event.time_label || "na"}:${index}`,
    }));
}

function toAdminResultMatchPayload(detailsPayload, fallbackMatchRecord = null, fallbackListPayload = null) {
  const detailId = normalizeMatchDetailsId(detailsPayload && detailsPayload.id);
  const fallbackId =
    normalizeMatchDetailsId(fallbackListPayload && fallbackListPayload.match_details_id) ||
    normalizeMatchDetailsId(fallbackMatchRecord && fallbackMatchRecord.match_details_id) ||
    matchDetailsIdFromUrl(fallbackMatchRecord && fallbackMatchRecord.details_url);
  const matchId = detailId || fallbackId;
  if (!matchId) return null;

  const baseDate = String(
    (detailsPayload && detailsPayload.date) ||
    (fallbackListPayload && fallbackListPayload.date) ||
    (fallbackMatchRecord && fallbackMatchRecord.date) ||
    ""
  ).trim();
  const baseTime = String(
    (detailsPayload && detailsPayload.time) ||
    (fallbackListPayload && fallbackListPayload.time) ||
    (fallbackMatchRecord && fallbackMatchRecord.time) ||
    ""
  ).trim();

  const scoreStatus = String(
    (detailsPayload && detailsPayload.score_status) ||
    (fallbackListPayload && fallbackListPayload.score_status) ||
    (fallbackMatchRecord && fallbackMatchRecord.score_status) ||
    ""
  ).trim() || null;

  const homeScore = parseNumericScore(
    detailsPayload && detailsPayload.home_score !== undefined
      ? detailsPayload.home_score
      : fallbackListPayload && fallbackListPayload.home_score !== undefined
        ? fallbackListPayload.home_score
        : fallbackMatchRecord && fallbackMatchRecord.home_score
  );
  const awayScore = parseNumericScore(
    detailsPayload && detailsPayload.away_score !== undefined
      ? detailsPayload.away_score
      : fallbackListPayload && fallbackListPayload.away_score !== undefined
        ? fallbackListPayload.away_score
        : fallbackMatchRecord && fallbackMatchRecord.away_score
  );
  const aggregateHomeScore = parseNumericScore(
    detailsPayload && detailsPayload.aggregate_home_score !== undefined
      ? detailsPayload.aggregate_home_score
      : fallbackListPayload && fallbackListPayload.aggregate_home_score !== undefined
        ? fallbackListPayload.aggregate_home_score
        : fallbackMatchRecord && fallbackMatchRecord.aggregate_home_score
  );
  const aggregateAwayScore = parseNumericScore(
    detailsPayload && detailsPayload.aggregate_away_score !== undefined
      ? detailsPayload.aggregate_away_score
      : fallbackListPayload && fallbackListPayload.aggregate_away_score !== undefined
        ? fallbackListPayload.aggregate_away_score
        : fallbackMatchRecord && fallbackMatchRecord.aggregate_away_score
  );

  const payload = {
    match_details_id: matchId,
    date: baseDate || null,
    time: baseTime || null,
    league: String(
      (detailsPayload && detailsPayload.league) ||
      (fallbackListPayload && fallbackListPayload.league) ||
      (fallbackMatchRecord && fallbackMatchRecord.league) ||
      ""
    ).trim() || null,
    home_team: String(
      (detailsPayload && detailsPayload.home_team) ||
      (fallbackListPayload && fallbackListPayload.home_team) ||
      (fallbackMatchRecord && fallbackMatchRecord.home_team) ||
      ""
    ).trim() || null,
    away_team: String(
      (detailsPayload && detailsPayload.away_team) ||
      (fallbackListPayload && fallbackListPayload.away_team) ||
      (fallbackMatchRecord && fallbackMatchRecord.away_team) ||
      ""
    ).trim() || null,
    home_score: homeScore,
    away_score: awayScore,
    aggregate_home_score: aggregateHomeScore,
    aggregate_away_score: aggregateAwayScore,
    score_status: scoreStatus,
    display_score_status: displayMatchStatusForAdmin(scoreStatus),
    in_progress: isInProgressMatchStatus(scoreStatus),
    finished: isFinishedMatchStatus(scoreStatus),
    has_score: homeScore !== null && awayScore !== null,
    penalty_result: String(
      (detailsPayload && detailsPayload.penalty_result) ||
      (fallbackListPayload && fallbackListPayload.penalty_result) ||
      (fallbackMatchRecord && fallbackMatchRecord.penalty_result) ||
      ""
    ).trim() || null,
    details_url: String(
      (detailsPayload && detailsPayload.details_url) ||
      (fallbackMatchRecord && fallbackMatchRecord.details_url) ||
      ""
    ).trim() || null,
    updated_at: String(detailsPayload && detailsPayload.updated_at ? detailsPayload.updated_at : "").trim() || null,
    tv_channels: uniqueChannels(
      (fallbackListPayload && fallbackListPayload.tv_channels) ||
      (fallbackMatchRecord && fallbackMatchRecord.tv_channels) ||
      []
    ),
    home_goal_scorers: Array.isArray(detailsPayload && detailsPayload.home_goal_scorers)
      ? detailsPayload.home_goal_scorers
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.home_goal_scorers)
        ? fallbackMatchRecord.home_goal_scorers
        : [],
    away_goal_scorers: Array.isArray(detailsPayload && detailsPayload.away_goal_scorers)
      ? detailsPayload.away_goal_scorers
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.away_goal_scorers)
        ? fallbackMatchRecord.away_goal_scorers
        : [],
    home_assists: Array.isArray(detailsPayload && detailsPayload.home_assists)
      ? detailsPayload.home_assists
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.home_assists)
        ? fallbackMatchRecord.home_assists
        : [],
    away_assists: Array.isArray(detailsPayload && detailsPayload.away_assists)
      ? detailsPayload.away_assists
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.away_assists)
        ? fallbackMatchRecord.away_assists
        : [],
    home_yellow_cards: Array.isArray(detailsPayload && detailsPayload.home_yellow_cards)
      ? detailsPayload.home_yellow_cards
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.home_yellow_cards)
        ? fallbackMatchRecord.home_yellow_cards
        : [],
    away_yellow_cards: Array.isArray(detailsPayload && detailsPayload.away_yellow_cards)
      ? detailsPayload.away_yellow_cards
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.away_yellow_cards)
        ? fallbackMatchRecord.away_yellow_cards
        : [],
    home_red_cards: Array.isArray(detailsPayload && detailsPayload.home_red_cards)
      ? detailsPayload.home_red_cards
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.home_red_cards)
        ? fallbackMatchRecord.home_red_cards
        : [],
    away_red_cards: Array.isArray(detailsPayload && detailsPayload.away_red_cards)
      ? detailsPayload.away_red_cards
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.away_red_cards)
        ? fallbackMatchRecord.away_red_cards
        : [],
    team_lineups: normalizeTeamLineupsPayload(
      (detailsPayload && detailsPayload.team_lineups) ||
      (fallbackMatchRecord && fallbackMatchRecord.team_lineups) ||
      null
    ),
  };

  const kickoffMs = kickoffTimestampMs(payload);
  payload.kickoff_ts_ms = Number.isFinite(kickoffMs) ? kickoffMs : null;

  return payload;
}

function setCacheOnlyHeaders(res) {
  res.set("X-Data-Source", APP_DATA_SOURCE);
  res.set("X-External-Dependency", "none");
  setOperationalCacheStateHeaders(res);
}

const ADMIN_ARCH_COMPONENT_DEFS = Object.freeze([
  { id: "source_live_football", label: "LiveFootballOnTV", short_label: "LiveFootballOnTV", group: "sources", kind: "source" },
  { id: "source_bbc_live", label: "BBC Live Scores", short_label: "BBC Live", group: "sources", kind: "source" },
  { id: "source_bbc_range", label: "BBC Scores + Fixtures Range", short_label: "BBC Range", group: "sources", kind: "source" },
  { id: "source_bbc_match_details", label: "BBC Match Details", short_label: "BBC Details", group: "sources", kind: "source" },
  { id: "source_bbc_tables", label: "BBC Tables", short_label: "BBC Tables", group: "sources", kind: "source" },
  { id: "source_club_elo_rankings", label: "Club Elo Rankings", short_label: "Club Elo", group: "sources", kind: "source" },
  { id: "source_club_elo_fixtures", label: "Club Elo Fixtures", short_label: "Club Elo Fx", group: "sources", kind: "source" },
  { id: "source_football_database", label: "FootballDatabase Rankings", short_label: "FootballDB", group: "sources", kind: "source" },
  { id: "source_national_elo", label: "National Elo Rankings", short_label: "National Elo", group: "sources", kind: "source" },
  { id: "source_fpl_api", label: "Fantasy Premier League API", short_label: "FPL API", group: "sources", kind: "source" },
  { id: "operational_memory", label: "In-Memory Runtime Cache", short_label: "Memory Cache", group: "runtime", kind: "cache" },
  { id: "operational_redis", label: "Operational Redis", short_label: "Redis", group: "runtime", kind: "cache" },
  { id: "redis_reconciliation", label: "Redis Reconciliation", short_label: "Redis Recon", group: "runtime", kind: "service" },
  { id: "matches_api", label: "Matches + Match Details APIs", short_label: "Matches API", group: "consumers", kind: "consumer" },
  { id: "metadata_api", label: "Metadata + Rankings APIs", short_label: "Metadata APIs", group: "consumers", kind: "consumer" },
  { id: "tables_api", label: "League Tables API", short_label: "Tables API", group: "consumers", kind: "consumer" },
  { id: "fantasy_api", label: "Fantasy API", short_label: "Fantasy API", group: "consumers", kind: "consumer" },
  { id: "match_monitor", label: "Match Monitor + Push Flows", short_label: "Match Monitor", group: "consumers", kind: "consumer" },
]);
const ADMIN_ARCH_COMPONENT_BY_ID = new Map(
  ADMIN_ARCH_COMPONENT_DEFS.map((component) => [component.id, component])
);
const ADMIN_ARCH_FLOW_EDGES = Object.freeze([
  { from: "source_live_football", to: "operational_memory" },
  { from: "source_bbc_live", to: "operational_memory" },
  { from: "source_bbc_range", to: "operational_memory" },
  { from: "source_bbc_match_details", to: "operational_memory" },
  { from: "source_bbc_tables", to: "operational_memory" },
  { from: "source_club_elo_rankings", to: "metadata_api" },
  { from: "source_club_elo_fixtures", to: "operational_memory" },
  { from: "source_football_database", to: "metadata_api" },
  { from: "source_national_elo", to: "metadata_api" },
  { from: "source_fpl_api", to: "fantasy_api" },
  { from: "operational_memory", to: "operational_redis" },
  { from: "operational_redis", to: "operational_memory" },
  { from: "operational_memory", to: "matches_api" },
  { from: "operational_memory", to: "metadata_api" },
  { from: "operational_redis", to: "metadata_api" },
  { from: "operational_redis", to: "tables_api" },
  { from: "operational_redis", to: "match_monitor" },
  { from: "operational_memory", to: "redis_reconciliation" },
  { from: "operational_redis", to: "redis_reconciliation" },
]);
const ADMIN_STATUS_LEVEL_RANK = Object.freeze({
  ok: 0,
  warn: 1,
  fail: 2,
});

function sourceLastSuccessAtIso(source) {
  const seconds = sourceLastSuccessAtSeconds.get(source);
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  return new Date(seconds * 1000).toISOString();
}

function componentLevelRank(level) {
  return ADMIN_STATUS_LEVEL_RANK[level] ?? ADMIN_STATUS_LEVEL_RANK.ok;
}

function combineAdminHealth(...items) {
  return items.reduce(
    (acc, item) => {
      if (!item) return acc;
      const nextLevel = item.level || "ok";
      if (componentLevelRank(nextLevel) > componentLevelRank(acc.level)) {
        return {
          level: nextLevel,
          status: item.status || acc.status,
        };
      }
      return acc;
    },
    { level: "ok", status: "healthy" }
  );
}

function buildAgeHealth(updatedAt, intervalMs, options = {}) {
  const nowMs = Number.isFinite(options.nowMs) ? options.nowMs : Date.now();
  const ageSeconds = ageSecondsFromIso(updatedAt, nowMs);
  const running = Boolean(options.running);
  const lastFailureAt = options.lastFailureAt || null;
  const lastSuccessAt = options.lastSuccessAt || null;
  const lastError = options.lastError || null;
  const inactive =
    options.inactive && typeof options.inactive === "object" ? options.inactive : null;

  if (inactive && inactive.active === false) {
    return {
      level: inactive.level || "ok",
      status: inactive.status || "inactive",
      age_seconds: null,
    };
  }

  if (!updatedAt) {
    if (running) {
      return { level: "warn", status: "starting", age_seconds: null };
    }
    if (lastError) {
      return { level: "fail", status: "error", age_seconds: null };
    }
    return {
      level: options.allowMissing ? "warn" : "fail",
      status: options.allowMissing ? "missing" : "uninitialized",
      age_seconds: null,
    };
  }

  const safeIntervalMs = Number.isFinite(intervalMs) && intervalMs > 0 ? intervalMs : 0;
  const warnMs = safeIntervalMs > 0 ? Math.max(Math.floor(safeIntervalMs * 1.5), 60 * 1000) : 5 * 60 * 1000;
  const failMs = safeIntervalMs > 0 ? Math.max(Math.floor(safeIntervalMs * 3), 5 * 60 * 1000) : 15 * 60 * 1000;
  const ageMs = Number.isFinite(ageSeconds) ? ageSeconds * 1000 : 0;

  if (ageMs > failMs) {
    return { level: "fail", status: "stale", age_seconds: ageSeconds };
  }
  if (ageMs > warnMs) {
    return {
      level: "warn",
      status: running ? "updating_late" : "lagging",
      age_seconds: ageSeconds,
    };
  }
  if (lastFailureAt) {
    const failedAtMs = Date.parse(String(lastFailureAt || ""));
    const succeededAtMs = Date.parse(String(lastSuccessAt || ""));
    if (Number.isFinite(failedAtMs) && (!Number.isFinite(succeededAtMs) || failedAtMs > succeededAtMs)) {
      return { level: "warn", status: "recent_failures", age_seconds: ageSeconds };
    }
  }
  return {
    level: "ok",
    status: running ? "updating" : "healthy",
    age_seconds: ageSeconds,
  };
}

function mergeRuntimeDiagnostics(componentIds) {
  const ids = Array.isArray(componentIds) ? componentIds : [componentIds];
  const merged = {
    running: false,
    last_started_at: null,
    last_success_at: null,
    last_failure_at: null,
    last_error: null,
    recent_errors: [],
  };

  ids.forEach((componentId) => {
    const diagnostics = currentRuntimeComponentDiagnostics(componentId);
    if (!diagnostics) return;
    if (diagnostics.running) merged.running = true;
    if (diagnostics.last_started_at && (!merged.last_started_at || diagnostics.last_started_at > merged.last_started_at)) {
      merged.last_started_at = diagnostics.last_started_at;
    }
    if (diagnostics.last_success_at && (!merged.last_success_at || diagnostics.last_success_at > merged.last_success_at)) {
      merged.last_success_at = diagnostics.last_success_at;
    }
    if (diagnostics.last_failure_at && (!merged.last_failure_at || diagnostics.last_failure_at > merged.last_failure_at)) {
      merged.last_failure_at = diagnostics.last_failure_at;
      merged.last_error = diagnostics.last_error || merged.last_error;
    }
    if (Array.isArray(diagnostics.recent_errors)) {
      merged.recent_errors.push(...diagnostics.recent_errors);
    }
  });

  merged.recent_errors.sort((left, right) => {
    const leftMs = Date.parse(String(left && left.at ? left.at : ""));
    const rightMs = Date.parse(String(right && right.at ? right.at : ""));
    return (Number.isFinite(rightMs) ? rightMs : 0) - (Number.isFinite(leftMs) ? leftMs : 0);
  });
  if (merged.recent_errors.length > RUNTIME_COMPONENT_ERROR_LIMIT) {
    merged.recent_errors = merged.recent_errors.slice(0, RUNTIME_COMPONENT_ERROR_LIMIT);
  }
  return merged;
}

function buildUpstreamFeedSnapshot(options = {}) {
  const diagnostics = mergeRuntimeDiagnostics(options.runtimeIds || options.runtimeId || []);
  const updatedAt = options.updated_at || null;
  const health = buildAgeHealth(updatedAt, options.interval_ms, {
    running: options.running !== undefined ? options.running : diagnostics.running,
    lastFailureAt: options.last_failure_at || diagnostics.last_failure_at,
    lastSuccessAt: options.last_success_at || diagnostics.last_success_at,
    lastError: diagnostics.last_error,
    allowMissing: Boolean(options.allow_missing),
    inactive: options.inactive,
  });

  return {
    id: options.id || null,
    title: options.title || options.label || null,
    url: options.url || null,
    interval_ms: Number.isFinite(options.interval_ms) ? options.interval_ms : null,
    updated_at: updatedAt,
    age_seconds: health.age_seconds,
    count: Number.isFinite(options.count) ? options.count : null,
    running:
      options.running !== undefined ? Boolean(options.running) : Boolean(diagnostics.running),
    last_success_at: options.last_success_at || diagnostics.last_success_at || null,
    last_failure_at: options.last_failure_at || diagnostics.last_failure_at || null,
    last_error: diagnostics.last_error || null,
    recent_errors: diagnostics.recent_errors,
    retry: options.retry || { mode: "none" },
    inactive_reason:
      options.inactive && options.inactive.active === false
        ? options.inactive.reason || null
        : null,
    level: health.level,
    status: health.status,
  };
}

function findReconciliationComponentByName(snapshot, name) {
  if (!snapshot || !Array.isArray(snapshot.components)) return null;
  return snapshot.components.find((component) => component && component.name === name) || null;
}

async function probeRedisConnectivitySnapshot(timeoutMs = 1500) {
  const startedAtMs = Date.now();
  try {
    const client = await Promise.race([
      getClient(),
      new Promise((_, reject) => {
        setTimeout(() => reject(new Error("Redis probe timed out")), timeoutMs);
      }),
    ]);
    return {
      level: client && client.isReady ? "ok" : "warn",
      status: client && client.isReady ? "connected" : "connecting",
      is_ready: Boolean(client && client.isReady),
      is_open: Boolean(client && client.isOpen),
      duration_ms: Date.now() - startedAtMs,
      error: null,
    };
  } catch (error) {
    return {
      level: "fail",
      status: "unavailable",
      is_ready: false,
      is_open: false,
      duration_ms: Date.now() - startedAtMs,
      error: error && error.message ? error.message : String(error),
    };
  }
}

function buildAdminComponentSummary(definition, options = {}) {
  return {
    id: definition.id,
    label: definition.label,
    short_label: definition.short_label,
    group: definition.group,
    kind: definition.kind,
    level: options.level || "ok",
    status: options.status || "healthy",
    summary: options.summary || "",
    updated_at: options.updated_at || null,
    age_seconds: options.age_seconds ?? null,
    detail_path: `/admin/status/${definition.id}`,
    dependencies: Array.isArray(options.dependencies) ? options.dependencies : [],
  };
}

async function buildAdminArchitectureOverviewPayload() {
  const nowMs = Date.now();
  const reconciliation = currentRedisReconciliationSnapshot();
  const redisConnectivity = await probeRedisConnectivitySnapshot();
  const memoryDatasets = currentOperationalMemoryDatasetSnapshots();
  const memoryMatchDetails = currentOperationalMatchDetailsMemorySnapshot();
  const mergedReconciliation = findReconciliationComponentByName(reconciliation, OP_DATASET_MERGED_MATCHES);
  const recentReconciliation = findReconciliationComponentByName(reconciliation, OP_DATASET_RECENT_MATCHES);
  const tablesReconciliation = findReconciliationComponentByName(reconciliation, OP_DATASET_LEAGUE_TABLES);
  const detailsReconciliation = findReconciliationComponentByName(reconciliation, "match_details");

  const liveFootballFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_LIVE_FOOTBALL,
    title: "LiveFootballOnTV",
    runtimeId: COMPONENT_SOURCE_LIVE_FOOTBALL,
    url: SOURCE_URL,
    interval_ms: INTERVAL_MS,
    updated_at: lastUpdated,
    count: cachedMatches.length,
    last_success_at: sourceLastSuccessAtIso(SOURCE_LIVE_FOOTBALL),
    running: updating,
  });
  const bbcLiveFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_BBC_LIVE,
    title: "BBC Live Scores",
    runtimeId: COMPONENT_SOURCE_BBC_LIVE,
    url: BBC_SOURCE_URL,
    interval_ms: BBC_INTERVAL_MS,
    updated_at: bbcLastUpdated,
    count: cachedBbcMatches.length,
    last_success_at: sourceLastSuccessAtIso(SOURCE_BBC_LIVE),
    running: bbcUpdating,
  });
  const bbcRangeFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_BBC_RANGE,
    title: "BBC Range Scores + Fixtures",
    runtimeId: COMPONENT_SOURCE_BBC_RANGE,
    url: BBC_RANGE_BASE_URL,
    interval_ms: BBC_RANGE_INTERVAL_MS,
    updated_at: bbcRangeLastUpdated,
    count: cachedBbcRangeMatches.length,
    last_success_at: sourceLastSuccessAtIso(SOURCE_BBC_RANGE),
    running: bbcRangeUpdating,
  });
  const bbcDetailsFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_BBC_MATCH_DETAILS,
    title: "BBC Match Details",
    runtimeId: COMPONENT_SOURCE_BBC_MATCH_DETAILS,
    url: "bbc_details_urls",
    interval_ms: MATCH_DETAILS_POLL_INTERVAL_MS,
    updated_at: matchDetailsLastUpdated,
    count: memoryMatchDetails.total,
    last_success_at: sourceLastSuccessAtIso(SOURCE_BBC_MATCH_DETAILS),
    running: matchDetailsUpdating,
  });
  const bbcPremierFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_BBC_TABLES_PREMIER_TEAMS,
    title: "BBC Premier League Teams",
    runtimeId: COMPONENT_SOURCE_BBC_TABLES_PREMIER_TEAMS,
    url: EPL_SOURCE_URL,
    interval_ms: EPL_INTERVAL_MS,
    updated_at: eplLastUpdated,
    count: cachedPremierLeagueTeams.length,
    last_success_at: sourceLastSuccessAtIso(SOURCE_BBC_PREMIER_LEAGUE),
    running: eplUpdating,
    allow_missing: true,
  });
  const bbcLeagueTablesFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_BBC_TABLES_LEAGUE_TABLES,
    title: "BBC League Tables",
    runtimeId: COMPONENT_SOURCE_BBC_TABLES_LEAGUE_TABLES,
    url: LEAGUE_TABLE_SOURCES[0] && LEAGUE_TABLE_SOURCES[0].url,
    interval_ms: LEAGUE_TABLES_INTERVAL_MS,
    updated_at: leagueTablesLastUpdated,
    count: leagueTableRowsCount(cachedLeagueTables),
    last_success_at: sourceLastSuccessAtIso(SOURCE_BBC_LEAGUE_TABLES),
    running: leagueTablesUpdating,
  });
  const bbcTablesHealth = combineAdminHealth(bbcPremierFeed, bbcLeagueTablesFeed);
  const clubEloFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_CLUB_ELO,
    title: "Club Elo Rankings",
    runtimeId: COMPONENT_SOURCE_CLUB_ELO,
    url: CLUB_ELO_BASE_URL,
    interval_ms: CLUB_ELO_INTERVAL_MS,
    updated_at: clubEloLastUpdated,
    count: cachedClubEloTeams.length,
    last_success_at: clubEloLastSuccessAt || sourceLastSuccessAtIso(SOURCE_CLUB_ELO),
    last_failure_at: clubEloLastFailureAt,
    running: clubEloUpdating,
  });
  const clubEloFixturesFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_CLUB_ELO_FIXTURES,
    title: "Club Elo Fixtures",
    runtimeId: COMPONENT_SOURCE_CLUB_ELO_FIXTURES,
    url: CLUB_ELO_FIXTURES_URL,
    interval_ms: CLUB_ELO_FIXTURES_INTERVAL_MS,
    updated_at: clubEloFixturesLastUpdated,
    count: cachedClubEloFixtures.length,
    last_success_at: sourceLastSuccessAtIso(SOURCE_CLUB_ELO_FIXTURES),
    running: clubEloFixturesUpdating,
  });
  const footballDatabaseFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_FOOTBALL_DATABASE,
    title: "FootballDatabase Rankings",
    runtimeId: COMPONENT_SOURCE_FOOTBALL_DATABASE,
    url: FOOTBALL_DATABASE_BASE_URL,
    interval_ms: FOOTBALL_DATABASE_INTERVAL_MS,
    updated_at: footballDatabaseLastUpdated,
    count: cachedFootballDatabaseTeams.length,
    last_success_at: footballDatabaseLastSuccessAt || sourceLastSuccessAtIso(SOURCE_FOOTBALL_DATABASE),
    last_failure_at: footballDatabaseLastFailureAt,
    running: footballDatabaseUpdating,
  });
  const nationalEloFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_NATIONAL_ELO,
    title: "National Elo Rankings",
    runtimeId: COMPONENT_SOURCE_NATIONAL_ELO,
    url: NATIONAL_ELO_BASE_URL,
    interval_ms: NATIONAL_ELO_INTERVAL_MS,
    updated_at: nationalEloLastUpdated,
    count: cachedNationalEloTeams.length,
    last_success_at: nationalEloLastSuccessAt || sourceLastSuccessAtIso(SOURCE_NATIONAL_ELO),
    last_failure_at: nationalEloLastFailureAt,
    running: nationalEloUpdating,
  });
  const fplBootstrapFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_FPL_BOOTSTRAP,
    title: "FPL Bootstrap",
    runtimeId: COMPONENT_SOURCE_FPL_BOOTSTRAP,
    url: FPL_BOOTSTRAP_SOURCE_URL,
    interval_ms: FPL_BOOTSTRAP_INTERVAL_MS,
    updated_at: fantasyBootstrapLastUpdated,
    count: fantasyBootstrapEventsCount,
    last_success_at: fantasyBootstrapLastSuccessAt || sourceLastSuccessAtIso(SOURCE_FPL_BOOTSTRAP),
    last_failure_at: fantasyBootstrapLastFailureAt,
    running: fantasyBootstrapUpdating,
  });
  const fplFixturesFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_FPL_FIXTURES,
    title: "FPL Fixtures",
    runtimeId: COMPONENT_SOURCE_FPL_FIXTURES,
    url: FPL_FIXTURES_SOURCE_URL,
    interval_ms: FPL_FIXTURES_INTERVAL_MS,
    updated_at: fantasyFixturesLastUpdated,
    count: cachedFantasyFixtures.length,
    last_success_at: fantasyFixturesLastSuccessAt || sourceLastSuccessAtIso(SOURCE_FPL_FIXTURES),
    last_failure_at: fantasyFixturesLastFailureAt,
    running: fantasyFixturesUpdating,
  });
  const fplEventLiveAvailability = currentFantasyEventLiveAvailability();
  const fplEventLiveFeed = buildUpstreamFeedSnapshot({
    id: COMPONENT_SOURCE_FPL_EVENT_LIVE,
    title: "FPL Event Live",
    runtimeId: COMPONENT_SOURCE_FPL_EVENT_LIVE,
    url: fplEventLiveAvailability.source_url,
    interval_ms: FPL_EVENT_LIVE_INTERVAL_MS,
    updated_at: fantasyEventLiveLastUpdated,
    count: cachedFantasyEventLive && Array.isArray(cachedFantasyEventLive.elements)
      ? cachedFantasyEventLive.elements.length
      : 0,
    last_success_at: fantasyEventLiveLastSuccessAt || sourceLastSuccessAtIso(SOURCE_FPL_EVENT_LIVE),
    last_failure_at: fantasyEventLiveLastFailureAt,
    running: fantasyEventLiveUpdating,
    allow_missing: true,
    inactive: fplEventLiveAvailability.active
      ? null
      : {
        active: false,
        status: "inactive",
        level: "ok",
        reason: fplEventLiveAvailability.reason,
      },
  });
  const fplHealth = combineAdminHealth(fplBootstrapFeed, fplFixturesFeed, fplEventLiveFeed);

  const operationalMemoryHealth = combineAdminHealth(
    mergedReconciliation && { level: mergedReconciliation.healthy ? "ok" : "warn", status: mergedReconciliation.status },
    recentReconciliation && { level: recentReconciliation.healthy ? "ok" : "warn", status: recentReconciliation.status },
    tablesReconciliation && { level: tablesReconciliation.healthy ? "ok" : "warn", status: tablesReconciliation.status },
    detailsReconciliation && { level: detailsReconciliation.healthy ? "ok" : "warn", status: detailsReconciliation.status }
  );

  const redisDiagnostics = currentRuntimeComponentDiagnostics(COMPONENT_OPERATIONAL_REDIS);
  const redisHealth = combineAdminHealth(
    { level: redisConnectivity.level, status: redisConnectivity.status },
    reconciliation && { level: reconciliation.healthy ? "ok" : "warn", status: reconciliation.healthy ? "healthy" : "drift_detected" },
    redisDiagnostics.last_error ? { level: redisConnectivity.level === "ok" ? "warn" : "fail", status: "recent_persist_errors" } : null
  );
  const reconHealth =
    reconciliation && reconciliation.healthy
      ? { level: reconciliation.running ? "warn" : "ok", status: reconciliation.running ? "running" : "healthy" }
      : { level: reconciliation.running ? "warn" : "fail", status: reconciliation && reconciliation.running ? "running" : "drift_detected" };

  const matchesApiHealth = combineAdminHealth(
    { level: operationalMemoryHealth.level, status: operationalMemoryHealth.status },
    { level: bbcDetailsFeed.level, status: bbcDetailsFeed.status }
  );
  const metadataApiHealth = combineAdminHealth(
    { level: redisHealth.level === "fail" ? "warn" : redisHealth.level, status: redisHealth.status },
    { level: clubEloFeed.level, status: clubEloFeed.status },
    { level: footballDatabaseFeed.level, status: footballDatabaseFeed.status },
    { level: nationalEloFeed.level, status: nationalEloFeed.status }
  );
  const tablesApiHealth = combineAdminHealth(
    { level: redisHealth.level === "fail" ? "warn" : redisHealth.level, status: redisHealth.status },
    { level: bbcTablesHealth.level, status: bbcTablesHealth.status }
  );
  const fantasyApiHealth = combineAdminHealth({ level: fplHealth.level, status: fplHealth.status });
  const monitorStatus = matchMonitor.getStatus({ limitRecent: 10 });
  const matchMonitorHealth = combineAdminHealth(
    { level: redisHealth.level, status: redisHealth.status },
    monitorStatus && monitorStatus.diagnostics && monitorStatus.diagnostics.last_error
      ? { level: "warn", status: "runtime_errors" }
      : { level: "ok", status: "healthy" }
  );

  const components = [
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("source_live_football"), {
      level: liveFootballFeed.level,
      status: liveFootballFeed.status,
      summary: `${liveFootballFeed.count || 0} live TV fixtures`,
      updated_at: liveFootballFeed.updated_at,
      age_seconds: liveFootballFeed.age_seconds,
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("source_bbc_live"), {
      level: bbcLiveFeed.level,
      status: bbcLiveFeed.status,
      summary: `${bbcLiveFeed.count || 0} BBC live matches`,
      updated_at: bbcLiveFeed.updated_at,
      age_seconds: bbcLiveFeed.age_seconds,
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("source_bbc_range"), {
      level: bbcRangeFeed.level,
      status: bbcRangeFeed.status,
      summary: `${bbcRangeFeed.count || 0} range matches`,
      updated_at: bbcRangeFeed.updated_at,
      age_seconds: bbcRangeFeed.age_seconds,
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("source_bbc_match_details"), {
      level: bbcDetailsFeed.level,
      status: bbcDetailsFeed.status,
      summary: `${bbcDetailsFeed.count || 0} match-detail records`,
      updated_at: bbcDetailsFeed.updated_at,
      age_seconds: bbcDetailsFeed.age_seconds,
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("source_bbc_tables"), {
      level: bbcTablesHealth.level,
      status: bbcTablesHealth.status,
      summary: `${cachedLeagueTables.length} leagues / ${cachedPremierLeagueTeams.length} EPL teams`,
      updated_at: newestIsoTimestamp([bbcPremierFeed.updated_at, bbcLeagueTablesFeed.updated_at]),
      age_seconds: ageSecondsFromIso(newestIsoTimestamp([bbcPremierFeed.updated_at, bbcLeagueTablesFeed.updated_at]), nowMs),
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("source_club_elo_rankings"), {
      level: clubEloFeed.level,
      status: clubEloFeed.status,
      summary: `${clubEloFeed.count || 0} club teams`,
      updated_at: clubEloFeed.updated_at,
      age_seconds: clubEloFeed.age_seconds,
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("source_club_elo_fixtures"), {
      level: clubEloFixturesFeed.level,
      status: clubEloFixturesFeed.status,
      summary: `${clubEloFixturesFeed.count || 0} fixture rows`,
      updated_at: clubEloFixturesFeed.updated_at,
      age_seconds: clubEloFixturesFeed.age_seconds,
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("source_football_database"), {
      level: footballDatabaseFeed.level,
      status: footballDatabaseFeed.status,
      summary: `${footballDatabaseFeed.count || 0} ranked clubs`,
      updated_at: footballDatabaseFeed.updated_at,
      age_seconds: footballDatabaseFeed.age_seconds,
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("source_national_elo"), {
      level: nationalEloFeed.level,
      status: nationalEloFeed.status,
      summary: `${nationalEloFeed.count || 0} ranked countries`,
      updated_at: nationalEloFeed.updated_at,
      age_seconds: nationalEloFeed.age_seconds,
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("source_fpl_api"), {
      level: fplHealth.level,
      status: fplHealth.status,
      summary: `${fantasyBootstrapEventsCount || 0} bootstrap events / ${cachedFantasyFixtures.length || 0} fixtures`,
      updated_at: newestIsoTimestamp([fplBootstrapFeed.updated_at, fplFixturesFeed.updated_at, fplEventLiveFeed.updated_at]),
      age_seconds: ageSecondsFromIso(newestIsoTimestamp([fplBootstrapFeed.updated_at, fplFixturesFeed.updated_at, fplEventLiveFeed.updated_at]), nowMs),
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("operational_memory"), {
      level: operationalMemoryHealth.level,
      status: operationalMemoryHealth.status,
      summary: `${cachedMergedMatches.length} merged / ${memoryMatchDetails.total} details / ${cachedRecentMatches.length} recent`,
      updated_at: newestIsoTimestamp([memoryDatasets[OP_DATASET_MERGED_MATCHES].updated_at, memoryMatchDetails.updated_at]),
      age_seconds: ageSecondsFromIso(newestIsoTimestamp([memoryDatasets[OP_DATASET_MERGED_MATCHES].updated_at, memoryMatchDetails.updated_at]), nowMs),
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("operational_redis"), {
      level: redisHealth.level,
      status: redisHealth.status,
      summary: `${ADMIN_OPERATIONAL_DATASET_NAMES.length + 1} operational stores`,
      updated_at: reconciliation.generated_at || operationalCacheState.updated_at,
      age_seconds: ageSecondsFromIso(reconciliation.generated_at || operationalCacheState.updated_at, nowMs),
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("redis_reconciliation"), {
      level: reconHealth.level,
      status: reconHealth.status,
      summary: `${reconciliation.summary && reconciliation.summary.healthy_components ? reconciliation.summary.healthy_components : 0}/${reconciliation.summary && reconciliation.summary.total_components ? reconciliation.summary.total_components : 0} healthy`,
      updated_at: reconciliation.generated_at,
      age_seconds: ageSecondsFromIso(reconciliation.generated_at, nowMs),
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("matches_api"), {
      level: matchesApiHealth.level,
      status: matchesApiHealth.status,
      summary: "/api/v1/matches and /api/v1/matches/:id",
      updated_at: newestIsoTimestamp([memoryDatasets[OP_DATASET_MERGED_MATCHES].updated_at, memoryMatchDetails.updated_at]),
      age_seconds: ageSecondsFromIso(newestIsoTimestamp([memoryDatasets[OP_DATASET_MERGED_MATCHES].updated_at, memoryMatchDetails.updated_at]), nowMs),
      dependencies: ["operational_memory", "source_bbc_match_details"],
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("metadata_api"), {
      level: metadataApiHealth.level,
      status: metadataApiHealth.status,
      summary: "/api/v1/teams, /channels, /competitions",
      updated_at: newestIsoTimestamp([clubEloLastUpdated, footballDatabaseLastUpdated, nationalEloLastUpdated, operationalCacheState.updated_at]),
      age_seconds: ageSecondsFromIso(newestIsoTimestamp([clubEloLastUpdated, footballDatabaseLastUpdated, nationalEloLastUpdated, operationalCacheState.updated_at]), nowMs),
      dependencies: ["operational_redis", "source_club_elo_rankings", "source_football_database", "source_national_elo"],
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("tables_api"), {
      level: tablesApiHealth.level,
      status: tablesApiHealth.status,
      summary: "/api/v1/tables",
      updated_at: leagueTablesLastUpdated,
      age_seconds: ageSecondsFromIso(leagueTablesLastUpdated, nowMs),
      dependencies: ["operational_redis", "source_bbc_tables"],
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("fantasy_api"), {
      level: fantasyApiHealth.level,
      status: fantasyApiHealth.status,
      summary: "Fantasy bootstrap, fixtures, gameweek, score helpers",
      updated_at: newestIsoTimestamp([fantasyBootstrapLastUpdated, fantasyFixturesLastUpdated, fantasyEventLiveLastUpdated]),
      age_seconds: ageSecondsFromIso(newestIsoTimestamp([fantasyBootstrapLastUpdated, fantasyFixturesLastUpdated, fantasyEventLiveLastUpdated]), nowMs),
      dependencies: ["source_fpl_api"],
    }),
    buildAdminComponentSummary(ADMIN_ARCH_COMPONENT_BY_ID.get("match_monitor"), {
      level: matchMonitorHealth.level,
      status: matchMonitorHealth.status,
      summary: `${monitorStatus.monitoredMatchCount || 0} monitored / ${monitorStatus.scheduledNotificationCount || 0} scheduled`,
      updated_at: monitorStatus && monitorStatus.diagnostics && monitorStatus.diagnostics.last_check
        ? monitorStatus.diagnostics.last_check.timestamp || null
        : null,
      age_seconds: ageSecondsFromIso(
        monitorStatus && monitorStatus.diagnostics && monitorStatus.diagnostics.last_check
          ? monitorStatus.diagnostics.last_check.timestamp || null
          : null,
        nowMs
      ),
      dependencies: ["operational_redis", "source_bbc_match_details"],
    }),
  ];

  const summary = components.reduce(
    (acc, component) => {
      acc.total += 1;
      acc[component.level] = (acc[component.level] || 0) + 1;
      return acc;
    },
    { total: 0, ok: 0, warn: 0, fail: 0 }
  );

  return {
    generated_at: new Date(nowMs).toISOString(),
    summary,
    notes: [
      "Matches and match-details APIs read the in-memory runtime cache directly.",
      "Tables, channels, competitions, and rankings endpoints use Redis-preferred operational datasets with in-memory fallback.",
      "The match monitor and push flows depend on Redis operational state plus Redis user preference records.",
      "Redis reconciliation compares memory against Redis and can repair Redis from memory when Redis is missing or stale.",
    ],
    edges: ADMIN_ARCH_FLOW_EDGES,
    components,
    feed_snapshots: {
      live_football: liveFootballFeed,
      bbc_live: bbcLiveFeed,
      bbc_range: bbcRangeFeed,
      bbc_match_details: bbcDetailsFeed,
      bbc_premier_teams: bbcPremierFeed,
      bbc_league_tables: bbcLeagueTablesFeed,
      club_elo: clubEloFeed,
      club_elo_fixtures: clubEloFixturesFeed,
      football_database: footballDatabaseFeed,
      national_elo: nationalEloFeed,
      fpl_bootstrap: fplBootstrapFeed,
      fpl_fixtures: fplFixturesFeed,
      fpl_event_live: fplEventLiveFeed,
    },
    redis: {
      connectivity: redisConnectivity,
      reconciliation,
    },
  };
}

async function buildAdminArchitectureComponentDetail(componentId) {
  const definition = ADMIN_ARCH_COMPONENT_BY_ID.get(componentId);
  if (!definition) return null;
  const overview = await buildAdminArchitectureOverviewPayload();
  const component = overview.components.find((entry) => entry.id === componentId) || null;
  const feedSnapshots = overview.feed_snapshots || {};
  const reconciliation = overview.redis && overview.redis.reconciliation
    ? overview.redis.reconciliation
    : currentRedisReconciliationSnapshot();
  const memoryDatasets = currentOperationalMemoryDatasetSnapshots();
  const memoryMatchDetails = currentOperationalMatchDetailsMemorySnapshot();

  if (componentId === "operational_memory") {
    const datasetCards = [
      { name: OP_DATASET_LIVE_MATCHES, snapshot: memoryDatasets[OP_DATASET_LIVE_MATCHES], reconciliation: findReconciliationComponentByName(reconciliation, OP_DATASET_LIVE_MATCHES) },
      { name: OP_DATASET_BBC_LIVE_MATCHES, snapshot: memoryDatasets[OP_DATASET_BBC_LIVE_MATCHES], reconciliation: findReconciliationComponentByName(reconciliation, OP_DATASET_BBC_LIVE_MATCHES) },
      { name: OP_DATASET_BBC_RANGE_MATCHES, snapshot: memoryDatasets[OP_DATASET_BBC_RANGE_MATCHES], reconciliation: findReconciliationComponentByName(reconciliation, OP_DATASET_BBC_RANGE_MATCHES) },
      { name: OP_DATASET_RECENT_MATCHES, snapshot: memoryDatasets[OP_DATASET_RECENT_MATCHES], reconciliation: findReconciliationComponentByName(reconciliation, OP_DATASET_RECENT_MATCHES) },
      { name: OP_DATASET_MERGED_MATCHES, snapshot: memoryDatasets[OP_DATASET_MERGED_MATCHES], reconciliation: findReconciliationComponentByName(reconciliation, OP_DATASET_MERGED_MATCHES) },
      { name: OP_DATASET_LEAGUE_TABLES, snapshot: memoryDatasets[OP_DATASET_LEAGUE_TABLES], reconciliation: findReconciliationComponentByName(reconciliation, OP_DATASET_LEAGUE_TABLES) },
      { name: "match_details", snapshot: memoryMatchDetails, reconciliation: findReconciliationComponentByName(reconciliation, "match_details") },
    ].map((entry) => ({
      title: entry.name,
      updated_at: entry.snapshot && entry.snapshot.updated_at ? entry.snapshot.updated_at : null,
      count:
        entry.name === "match_details"
          ? entry.snapshot.total
          : Array.isArray(entry.snapshot && entry.snapshot.items)
            ? entry.snapshot.items.length
            : null,
      source: entry.snapshot && entry.snapshot.source ? entry.snapshot.source : "memory",
      reconciliation_status: entry.reconciliation ? entry.reconciliation.status : "n/a",
      reconciliation_healthy: entry.reconciliation ? entry.reconciliation.healthy : null,
    }));
    return {
      component,
      detail: {
        description: "The live runtime cache held inside the Node process. Source updaters write here first. `/api/v1/matches` and `/api/v1/matches/:id` read directly from this layer.",
        stats: [
          { label: "Merged Matches", value: cachedMergedMatches.length },
          { label: "Recent Matches", value: cachedRecentMatches.length },
          { label: "Match Details", value: memoryMatchDetails.total },
          { label: "League Tables", value: cachedLeagueTables.length },
        ],
        data_flow: {
          reads_from: ["All upstream fetchers", "Redis bootstrap on process start"],
          writes_to: ["operational_redis", "matches_api"],
          used_by: ["matches_api", "metadata_api fallback", "redis_reconciliation"],
        },
        failure_impact: [
          "If this layer is empty or stale, the matches and match-details APIs are directly affected.",
          "Redis can still help on restart, but live runtime freshness depends on the process memory state.",
        ],
        subcomponents: datasetCards,
      },
    };
  }

  if (componentId === "operational_redis") {
    const [datasetRecords, matchDetailsSummary] = await Promise.all([
      getOperationalDatasets(ADMIN_OPERATIONAL_DATASET_NAMES),
      getOperationalMatchDetailsSummary(),
    ]);
    const datasetCards = ADMIN_OPERATIONAL_DATASET_NAMES.map((name) => {
      const record = datasetRecords && datasetRecords[name] ? datasetRecords[name] : null;
      return {
        title: name,
        updated_at: record && record.updated_at ? record.updated_at : null,
        count: Array.isArray(record && record.payload)
          ? record.payload.length
          : record && record.payload && typeof record.payload === "object"
            ? Object.keys(record.payload).length
            : null,
        source: record && record.source ? record.source : null,
      };
    });
    datasetCards.push({
      title: "match_details",
      updated_at: matchDetailsSummary && matchDetailsSummary.updated_at ? matchDetailsSummary.updated_at : null,
      count: matchDetailsSummary && Number.isFinite(matchDetailsSummary.total) ? matchDetailsSummary.total : 0,
      source: "redis",
    });
    return {
      component,
      detail: {
        description: "Durable operational snapshot store. Used for bootstrap, Redis-preferred metadata endpoints, admin diagnostics, and the match monitor/user-preference flows.",
        stats: [
          { label: "Connectivity", value: overview.redis && overview.redis.connectivity ? overview.redis.connectivity.status : "n/a" },
          { label: "Is Ready", value: overview.redis && overview.redis.connectivity ? String(overview.redis.connectivity.is_ready) : "false" },
          { label: "Last Probe Error", value: overview.redis && overview.redis.connectivity && overview.redis.connectivity.error ? overview.redis.connectivity.error : "n/a" },
          { label: "Recent Persist Error", value: currentRuntimeComponentDiagnostics(COMPONENT_OPERATIONAL_REDIS).last_error || "n/a" },
        ],
        data_flow: {
          reads_from: ["operational_memory persistence writes", "bootstrap reconciliation"],
          writes_to: ["operational_memory on startup hydrate", "metadata_api", "tables_api", "match_monitor"],
          used_by: ["operational_bootstrap", "metadata_api", "tables_api", "match_monitor"],
        },
        failure_impact: [
          "Startup hydration loses its durable snapshot source.",
          "Metadata/table/admin endpoints fall back to memory or fail to serve Redis-backed diagnostics.",
          "Match monitor and user-preference driven push flows lose a required dependency.",
        ],
        recent_errors: currentRuntimeComponentDiagnostics(COMPONENT_OPERATIONAL_REDIS).recent_errors,
        subcomponents: datasetCards,
      },
    };
  }

  if (componentId === "redis_reconciliation") {
    return {
      component,
      detail: {
        description: "Periodic compare-and-repair job that checks every operational dataset and the match-details store for memory/Redis drift.",
        stats: [
          { label: "Auto Repair Enabled", value: String(reconciliation.auto_repair_enabled) },
          { label: "Last Trigger", value: reconciliation.last_trigger || "n/a" },
          { label: "Last Started", value: reconciliation.last_run_started_at || "n/a" },
          { label: "Last Completed", value: reconciliation.last_run_completed_at || "n/a" },
          { label: "Last Duration (ms)", value: reconciliation.last_duration_ms },
          { label: "Last Error", value: reconciliation.last_error || "n/a" },
        ],
        data_flow: {
          reads_from: ["operational_memory", "operational_redis"],
          writes_to: ["operational_redis when repair is needed"],
          used_by: ["operational_redis", "operational_memory"],
        },
        failure_impact: ["Redis drift remains unresolved until a later successful run."],
        recent_errors: currentRuntimeComponentDiagnostics(COMPONENT_REDIS_RECONCILIATION).recent_errors,
        subcomponents: Array.isArray(reconciliation.components) ? reconciliation.components : [],
      },
    };
  }

  if (componentId === "matches_api") {
    return {
      component,
      detail: {
        description: "The matches list and match-details endpoints serve directly from in-memory merged matches and match-detail caches.",
        stats: [
          { label: "Endpoints", value: "/api/v1/matches, /api/v1/matches/:matchId, /api/v1/matches/states, /api/v1/bbc/details" },
          { label: "Merged Matches In Memory", value: cachedMergedMatches.length },
          { label: "Match Details In Memory", value: memoryMatchDetails.total },
        ],
        data_flow: {
          reads_from: ["operational_memory.merged_matches", "operational_memory.match_details"],
          fallback_to: ["/api/v1/matches/states can hydrate misses from Redis", "detail requests can warm/backfill asynchronously"],
          used_by: ["iOS matches screen", "web matches screen", "watch/widget bridge"],
        },
        failure_impact: [
          "If merged matches are stale, fixtures/results lists go stale immediately.",
          "If match_details are stale, detailed scorers/cards/lineups/aggregate scores degrade or 404 until warm/backfill succeeds.",
        ],
      },
    };
  }

  if (componentId === "metadata_api") {
    return {
      component,
      detail: {
        description: "Metadata-oriented APIs use Redis-preferred operational datasets, with in-memory fallback if Redis reads fail or are empty.",
        stats: [
          { label: "Endpoints", value: "/api/v1/teams, /api/v1/teams/:teamName, /api/v1/channels, /api/v1/competitions, /api/v1/teams/premier-league" },
          { label: "Default Team Ranking Source", value: TEAM_RANKING_DEFAULT_SOURCE },
          { label: "Club Elo Rows", value: cachedClubEloTeams.length },
          { label: "FootballDatabase Rows", value: cachedFootballDatabaseTeams.length },
          { label: "National Elo Rows", value: cachedNationalEloTeams.length },
        ],
        data_flow: {
          reads_from: ["operational_redis merged/ranking datasets", "operational_memory as fallback"],
          used_by: ["iOS/web rankings views", "filters and metadata UIs"],
        },
        failure_impact: [
          "Ranking overlays, channel lists, competition lists, and team metadata can become stale or inconsistent if Redis lags memory.",
          "If upstream ranking feeds fail, the APIs still work but serve older ranking data.",
        ],
      },
    };
  }

  if (componentId === "tables_api") {
    return {
      component,
      detail: {
        description: "League table endpoints read the Redis-preferred league_tables dataset with in-memory fallback.",
        stats: [
          { label: "Endpoints", value: "/api/v1/tables, /api/v1/tables/:leagueId" },
          { label: "Leagues", value: cachedLeagueTables.length },
          { label: "Rows", value: leagueTableRowsCount(cachedLeagueTables) },
        ],
        data_flow: {
          reads_from: ["operational_redis.league_tables", "operational_memory.league_tables as fallback"],
          used_by: ["iOS tables screen", "web tables screen"],
        },
        failure_impact: ["Tables pages become stale if BBC tables ingestion or Redis persistence fails."],
      },
    };
  }

  if (componentId === "fantasy_api") {
    const fantasyRecentErrors = mergeRuntimeDiagnostics([
      COMPONENT_SOURCE_FPL_BOOTSTRAP,
      COMPONENT_SOURCE_FPL_FIXTURES,
      COMPONENT_SOURCE_FPL_EVENT_LIVE,
    ]).recent_errors;
    const eventLiveAvailability = currentFantasyEventLiveAvailability();
    return {
      component,
      detail: {
        description: "Fantasy endpoints are backed by in-memory FPL caches plus filesystem config for phrases/messages/team colors.",
        stats: [
          { label: "Endpoints", value: "/api/v1/fantasy/*, /api/v1/team-colors" },
          { label: "Bootstrap Updated", value: fantasyBootstrapLastUpdated || "n/a" },
          { label: "Fixtures Updated", value: fantasyFixturesLastUpdated || "n/a" },
          { label: "Event Live Updated", value: fantasyEventLiveLastUpdated || "n/a" },
          { label: "Event Live Status", value: feedSnapshots.fpl_event_live && feedSnapshots.fpl_event_live.status ? feedSnapshots.fpl_event_live.status : "n/a" },
          { label: "Event Live Reason", value: (feedSnapshots.fpl_event_live && feedSnapshots.fpl_event_live.inactive_reason) || "actively polling or recently updated" },
          { label: "Current Event ID", value: eventLiveAvailability.current_event_id || "n/a" },
          { label: "Next Event ID", value: fantasyBootstrapNextEvent && fantasyBootstrapNextEvent.id ? fantasyBootstrapNextEvent.id : "n/a" },
        ],
        data_flow: {
          reads_from: ["FPL API memory caches", "filesystem config JSON files"],
          used_by: ["iOS fantasy views"],
        },
        failure_impact: [
          "Fantasy gameweek/bootstrap/score/recommendation flows can return stale or unavailable data.",
          "This path is independent of the operational Redis reconciliation flow.",
        ],
        recent_errors: fantasyRecentErrors,
        subcomponents: [
          {
            ...feedSnapshots.fpl_bootstrap,
            note: fantasyBootstrapGameUpdating
              ? `Upstream game update in progress: ${fantasyBootstrapGameUpdatingMessage || "reported by FPL API"}`
              : "Bootstrap data powers current/next gameweek context and player/team lookup endpoints.",
          },
          {
            ...feedSnapshots.fpl_fixtures,
            note: "Fixtures drive fantasy score context and upcoming fixture calculations.",
          },
          {
            ...feedSnapshots.fpl_event_live,
            note:
              (feedSnapshots.fpl_event_live && feedSnapshots.fpl_event_live.inactive_reason) ||
              "Event-live polling only runs while the current gameweek has started mutable fixtures.",
          },
        ],
      },
    };
  }

  if (componentId === "match_monitor") {
    const status = matchMonitor.getStatus({ limitRecent: 20 });
    return {
      component,
      detail: {
        description: "Background service that monitors live matches, reads user preferences from Redis, and drives notifications and Live Activity updates.",
        stats: [
          { label: "Poll Interval", value: "10s for monitored matches" },
          { label: "Monitored Match Count", value: status.monitoredMatchCount || 0 },
          { label: "Scheduled Notifications", value: status.scheduledNotificationCount || 0 },
          { label: "Last Error", value: status.diagnostics && status.diagnostics.last_error ? status.diagnostics.last_error : "n/a" },
        ],
        data_flow: {
          reads_from: ["operational_redis merged_matches/recent_matches/match_details", "Redis user preferences", "BBC match details fetcher for live text"],
          used_by: ["push notifications", "live activities", "fantasy reminders"],
        },
        failure_impact: [
          "If Redis user preferences or operational datasets are unavailable, push/live-activity decisions degrade or stop.",
          "If BBC match-detail freshness degrades, event detection loses detail and timing confidence.",
        ],
        recent_errors: status.diagnostics && status.diagnostics.last_error
          ? [{ at: new Date().toISOString(), error: status.diagnostics.last_error }]
          : [],
        raw: status,
      },
    };
  }

  const simpleSourceMap = {
    source_live_football: {
      snapshot: feedSnapshots.live_football,
      description: "Pulls TV fixture listings from LiveFootballOnTV and seeds the live_matches dataset.",
      writes_to: ["operational_memory.live_matches", "operational_memory.recent_matches", "operational_memory.merged_matches", "operational_redis.live_matches"],
      used_by: ["matches_api", "metadata_api"],
      failure_impact: [
        "TV channel and fixture listing freshness degrades for /api/v1/matches.",
        "Recent cache and merged matches stop incorporating new LiveFootballOnTV entries until the next success.",
      ],
    },
    source_bbc_live: {
      snapshot: feedSnapshots.bbc_live,
      description: "Polls BBC live scores every 30 seconds, overlays fresher score/status data, and seeds match details.",
      writes_to: ["operational_memory.recent_matches", "operational_memory.match_details", "operational_redis.bbc_live_matches", "operational_redis.match_details"],
      used_by: ["matches_api", "match_monitor"],
      failure_impact: [
        "Live score/status freshness regresses to whatever is already in memory.",
        "Recent matches and match-detail seeds stop receiving BBC live overlays.",
      ],
    },
    source_bbc_range: {
      snapshot: feedSnapshots.bbc_range,
      description: "Fetches BBC scores/fixtures across a rolling date window and is the main structural source for merged fixtures/results coverage.",
      writes_to: ["operational_memory.merged_matches", "operational_redis.bbc_range_matches", "operational_redis.merged_matches"],
      used_by: ["matches_api", "metadata_api"],
      failure_impact: [
        "Fixture/result coverage for /api/v1/matches becomes stale and new fixtures may not appear.",
        "Merged matches stop receiving broad BBC schedule/result refreshes until the next success.",
      ],
    },
    source_bbc_match_details: {
      snapshot: feedSnapshots.bbc_match_details,
      description: "Polls in-progress BBC match detail pages every 10 seconds for tracked matches and maintains the high-detail match_details cache.",
      writes_to: ["operational_memory.match_details", "operational_redis.match_details"],
      used_by: ["matches_api", "match_monitor"],
      failure_impact: [
        "Detailed match pages lose freshness for scorers, cards, lineups, aggregates, and live status normalization.",
        "Live Activity and push-notification decisions have less detailed state to work from.",
      ],
    },
    source_club_elo_rankings: {
      snapshot: feedSnapshots.club_elo,
      description: "Club Elo rankings feed used to enrich /api/v1/teams responses.",
      writes_to: ["operational_redis.club_elo_teams"],
      used_by: ["metadata_api"],
      failure_impact: [
        "Club-ranking overlays become stale in /api/v1/teams and clients that display them.",
        "Team matching diagnostics drift until the next successful sync.",
      ],
    },
    source_club_elo_fixtures: {
      snapshot: feedSnapshots.club_elo_fixtures,
      description: "Club Elo fixtures feed used to enrich match-detail records with probability metadata.",
      writes_to: ["operational_memory.match_details", "operational_redis.match_details"],
      used_by: ["matches_api"],
      failure_impact: [
        "Club Elo fixture metadata inside match details stops refreshing.",
        "Only the enrichment layer fails; core fixtures/results still work from BBC/LiveFootballOnTV data.",
      ],
    },
    source_football_database: {
      snapshot: feedSnapshots.football_database,
      description: "FootballDatabase world club rankings feed with retry/backoff and adaptive concurrency.",
      writes_to: ["operational_redis.football_database_teams"],
      used_by: ["metadata_api"],
      failure_impact: [
        "Club-ranking overlays sourced from FootballDatabase become stale.",
        "Team matching diagnostics for FootballDatabase stop improving until the next success.",
      ],
    },
    source_national_elo: {
      snapshot: feedSnapshots.national_elo,
      description: "National Elo TSV feed with retry/backoff for international team rankings.",
      writes_to: ["operational_redis.national_elo_teams"],
      used_by: ["metadata_api"],
      failure_impact: [
        "International ranking overlays become stale.",
        "National-team matching diagnostics drift until the next success.",
      ],
    },
    source_fpl_api: {
      snapshot: [feedSnapshots.fpl_bootstrap, feedSnapshots.fpl_fixtures, feedSnapshots.fpl_event_live],
      description: "Aggregates the three official Fantasy Premier League feeds cached in memory only.",
      writes_to: ["fantasy_api in-memory caches"],
      used_by: ["fantasy_api"],
      failure_impact: [
        "Fantasy gameweek/bootstrap endpoints can return 503 or stale data.",
        "Fantasy score, transfer recommendations, and fixture context lose freshness.",
      ],
    },
  };

  if (componentId === "source_bbc_tables") {
    return {
      component,
      detail: {
        description: "Combines the BBC Premier League team-list puller and the multi-league BBC tables puller.",
        subcomponents: [feedSnapshots.bbc_premier_teams, feedSnapshots.bbc_league_tables],
        data_flow: {
          writes_to: ["operational_memory.league_tables", "operational_redis.league_tables", "operational_redis.premier_league_teams"],
          used_by: ["tables_api", "metadata_api"],
        },
        failure_impact: [
          "Tables screens and /api/v1/tables become stale.",
          "Premier League team-only filters can drift if the dedicated team list stops refreshing.",
        ],
        recent_errors: mergeRuntimeDiagnostics([
          COMPONENT_SOURCE_BBC_TABLES_PREMIER_TEAMS,
          COMPONENT_SOURCE_BBC_TABLES_LEAGUE_TABLES,
        ]).recent_errors,
      },
    };
  }

  const simpleSource = simpleSourceMap[componentId];
  if (simpleSource) {
    const subcomponents = Array.isArray(simpleSource.snapshot)
      ? simpleSource.snapshot
      : [simpleSource.snapshot];
    const recentErrors = Array.isArray(simpleSource.snapshot)
      ? mergeRuntimeDiagnostics(
        simpleSource.snapshot
          .map((entry) => entry && entry.id)
          .filter(Boolean)
      ).recent_errors
      : (simpleSource.snapshot && simpleSource.snapshot.recent_errors) || [];
    return {
      component,
      detail: {
        description: simpleSource.description,
        subcomponents,
        data_flow: {
          writes_to: simpleSource.writes_to,
          used_by: simpleSource.used_by,
        },
        failure_impact: simpleSource.failure_impact,
        recent_errors: recentErrors,
      },
    };
  }

  return {
    component,
    detail: {
      description: definition.label,
    },
  };
}

app.get("/", (_req, res) => {
  res
    .type("text/plain")
    .send("Football on TV API. Try /api/v1/matches?start=YYYY-MM-DD&end=YYYY-MM-DD");
});

app.get("/admin/bbc-history", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_bbc_history_ui.html"));
});

app.get("/admin/status", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_status_ui.html"));
});

app.get("/admin/status/:componentId", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_status_ui.html"));
});

app.get("/admin/preferences", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_preferences_ui.html"));
});

app.get("/admin/redis", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_redis_ui.html"));
});

app.get("/admin/devices", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_devices_ui.html"));
});

app.get("/admin/devices/:deviceSuffix", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_devices_ui.html"));
});

app.get("/admin/fantasy-reminders", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_fantasy_reminders_ui.html"));
});

app.get("/admin/harness", (_req, res) => {
  res.sendFile(path.join(__dirname, "test_harness_ui.html"));
});

app.get("/admin/fixtures", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_matches_ui.html"));
});

app.get("/admin/results", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_matches_ui.html"));
});

app.get("/admin/results/:matchId", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_match_details_ui.html"));
});

app.get("/test-harness", (_req, res) => {
  res.redirect("/admin/harness");
});

app.get(["/healthcheck", `${API_PREFIX}/healthcheck`], (_req, res) => {
  res.json({ status: "ok" });
});

app.get(`${API_PREFIX}/cache-state`, (_req, res) => {
  setCacheOnlyHeaders(res);
  res.json(currentCacheStateSnapshot());
});

app.get(`${API_PREFIX}/admin/status/overview`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  try {
    const payload = await buildAdminArchitectureOverviewPayload();
    res.status(200).json({
      success: true,
      ...payload,
    });
  } catch (error) {
    res.status(500).json({
      error: "Failed to build admin architecture overview.",
      message: error.message || String(error),
    });
  }
});

app.get(`${API_PREFIX}/admin/status/components/:componentId`, async (req, res) => {
  setCacheOnlyHeaders(res);
  try {
    const componentId = String(req.params.componentId || "").trim();
    const payload = await buildAdminArchitectureComponentDetail(componentId);
    if (!payload) {
      res.status(404).json({
        error: "Unknown admin status component.",
        component_id: componentId,
      });
      return;
    }
    res.status(200).json({
      success: true,
      ...payload,
    });
  } catch (error) {
    res.status(500).json({
      error: "Failed to build admin component detail.",
      message: error.message || String(error),
    });
  }
});

app.get(`${API_PREFIX}/admin/redis/reconciliation`, async (req, res) => {
  setCacheOnlyHeaders(res);
  try {
    const refreshRaw = String(req.query.refresh || "").trim().toLowerCase();
    const repairRaw = String(req.query.repair || "").trim().toLowerCase();
    const refresh = refreshRaw === "1" || refreshRaw === "true" || refreshRaw === "yes";
    const repair = repairRaw === "1" || repairRaw === "true" || repairRaw === "yes";
    const snapshot = refresh
      ? await runRedisReconciliationCheck({
        trigger: "admin_api_refresh",
        repair,
      })
      : currentRedisReconciliationSnapshot();
    res.status(200).json({
      success: true,
      refreshed: refresh,
      repair_requested: repair,
      ...snapshot,
    });
  } catch (error) {
    res.status(500).json({
      error: "Failed to build Redis reconciliation snapshot.",
      message: error.message || String(error),
    });
  }
});

app.post(`${API_PREFIX}/admin/redis/reconciliation/run`, async (req, res) => {
  setCacheOnlyHeaders(res);
  try {
    const repairRaw = String(req.query.repair || req.body?.repair || "").trim().toLowerCase();
    const repair = repairRaw === "1" || repairRaw === "true" || repairRaw === "yes";
    const snapshot = await runRedisReconciliationCheck({
      trigger: "admin_api_run",
      repair,
    });
    res.status(202).json({
      success: true,
      repair_requested: repair,
      ...snapshot,
    });
  } catch (error) {
    res.status(500).json({
      error: "Failed to run Redis reconciliation.",
      message: error.message || String(error),
    });
  }
});

app.post(`${API_PREFIX}/admin/cache-state/invalidate`, (req, res) => {
  setCacheOnlyHeaders(res);

  const normalized = normalizeCacheStateDomains(req.body && req.body.domains);
  if (normalized.invalid.length > 0) {
    res.status(400).json({
      error: "Invalid cache domains.",
      invalid_domains: normalized.invalid,
      allowed_domains: CACHE_STATE_DOMAINS,
    });
    return;
  }

  if (req.body && req.body.domains !== undefined && normalized.domains.length === 0) {
    res.status(400).json({
      error: "Expected at least one cache domain when domains is provided.",
      allowed_domains: CACHE_STATE_DOMAINS,
    });
    return;
  }

  const nextState = invalidateCacheDomains(normalized.domains, {
    reason: req.body && req.body.reason ? req.body.reason : "manual_invalidation",
    source: "admin_api",
  });

  res.status(202).json({
    success: true,
    invalidated_domains:
      normalized.domains.length > 0 ? normalized.domains : CACHE_STATE_DOMAINS,
    cache_state: nextState,
  });
});

app.post(`${API_PREFIX}/app-metrics`, (req, res) => {
  setCacheOnlyHeaders(res);

  if (!req.body || typeof req.body !== "object" || Array.isArray(req.body)) {
    appUsageMetrics.appMetricEventsRejectedTotal += 1;
    res.status(400).json({ error: "Invalid JSON payload." });
    return;
  }

  const payload = req.body;
  const event = normalizeMetricLabel(payload.event || "app_open", "app_open");
  const labels = {
    event,
    screen: normalizeMetricLabel(payload.screen || payload.view, "unknown"),
    build_type: normalizeMetricLabel(payload.buildType || payload.build_type, "unknown"),
    platform: normalizeMetricLabel(payload.platform || "ios", "ios"),
    os_version: normalizeMetricLabel(payload.osVersion || payload.systemVersion, "unknown"),
    device_type: normalizeMetricLabel(
      payload.deviceType || payload.userInterfaceIdiom || payload.idiom,
      "unknown"
    ),
    device_model: normalizeMetricLabel(payload.deviceModel || payload.model, "unknown"),
    app_version: normalizeMetricLabel(payload.appVersion, "unknown"),
    build_number: normalizeMetricLabel(payload.buildNumber, "unknown"),
  };

  const deviceToken = req.deviceToken || normalizeDeviceToken(payload.deviceToken);
  if (deviceToken) {
    trackSeenDeviceToken(deviceToken);
  }

  const key = appMetricEventKey(labels);
  const existing = appMetricEventsByDimension.get(key);
  if (existing) {
    existing.count += 1;
  } else {
    appMetricEventsByDimension.set(key, { labels, count: 1 });
  }

  appUsageMetrics.appMetricEventsTotal += 1;
  appMetricEventsLastUpdated = new Date().toISOString();

  res.status(202).json({
    success: true,
    recorded: true,
    event,
    has_device_token: Boolean(deviceToken),
    received_at: appMetricEventsLastUpdated,
  });
});

app.get("/metrics", (_req, res) => {
  res.set("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
  res.send(buildPrometheusMetricsText());
});

app.get(`${API_PREFIX}/matches`, async (req, res) => {
  setCacheOnlyHeaders(res);
  try {
    const range = parseRequiredDateRange(req.query);
    if (range.error) {
      res.status(400).json({ error: range.error });
      return;
    }

    const mergedDataset = currentMergedMatchesDatasetSnapshot();
    const premierLeagueDataset = currentPremierLeagueTeamsDatasetSnapshot();
    const matchDetailsSnapshot = currentFastMatchDetailsLookupSnapshot("matches_list_request");

    const latestUpdated = newestIsoTimestamp([
      mergedDataset.updated_at,
      bbcRangeLastUpdated,
      lastUpdated,
      bbcLastUpdated,
    ]);
    if (latestUpdated) {
      res.set("X-Last-Updated", latestUpdated);
    }
    res.set("X-Operational-Source", mergedDataset.source || "unknown");
    res.set(
      "X-Operational-Match-Details-Source",
      matchDetailsSnapshot.source || "unknown"
    );

    const mergedMatches = Array.isArray(mergedDataset.items) ? mergedDataset.items : [];
    const leagues = normalizeListParam(req.query.league).map(normalizeLeagueName);
    const teams = normalizeListParam(req.query.team);
    const channels = normalizeListParam(req.query.channel);
    const manualMappings = loadClubEloManualMappings();
    const filterMode = req.query.filter_mode ? String(req.query.filter_mode) : "union";
    const sortOrder = String(req.query.sort || "asc").toLowerCase() === "desc" ? "desc" : "asc";
    const pageSize = parsePositiveInt(req.query.page_size, 100, 1, 500);
    const page = parsePositiveInt(req.query.page, 1, 1, Number.MAX_SAFE_INTEGER);
    const dateFrom = range.start;
    const dateTo = range.end;
    const eplOnly = isTruthyParam(req.query.epl_only);
    const homeNations = isTruthyParam(req.query.home_nations);
    const majorTournaments = isTruthyParam(req.query.major_tournaments);

    let filtered = mergedMatches.filter((match) =>
      matchesFilters(match, {
        leagues,
        teams,
        channels,
        filterMode,
        dateFrom,
        dateTo,
        manualMappings,
      })
    );

    if (eplOnly || homeNations || majorTournaments) {
      filtered = filtered.filter((match) =>
        matchPassesCategoryFilters(match, {
          eplOnly,
          homeNations,
          majorTournaments,
          premierLeagueTeams: premierLeagueDataset.items,
        })
      );
    }

    // Inject all test matches if they match filters
    const allTestMatches = testMatchState.getAllMatches();
    for (const testMatch of allTestMatches) {
      if (testMatch && testMatch.is_test_match) {
        const testMatchDate = testMatch.date;
        if (testMatchDate >= dateFrom && testMatchDate <= dateTo) {
          // Check if test match matches other filters
          const matchesLeagueFilter =
          leagues.length === 0 ||
          leagues.some((league) =>
            normalizeLeagueName(testMatch.league) === league
          );
        const matchesTeamFilter =
          teams.length === 0 ||
          teams.some(
            (team) =>
              teamMatchesSelectionAliasAware(testMatch.home_team, team, manualMappings) ||
              teamMatchesSelectionAliasAware(testMatch.away_team, team, manualMappings) ||
              testMatch.home_team.toLowerCase().includes(team.toLowerCase()) ||
              testMatch.away_team.toLowerCase().includes(team.toLowerCase())
          );

          if (matchesLeagueFilter && matchesTeamFilter) {
            // Insert test match at the appropriate position based on date/time
            filtered.push(testMatch);
            // Re-sort by kickoff time (date + time)
            filtered.sort((a, b) => {
              const aTime = `${a.date} ${a.time}`;
              const bTime = `${b.date} ${b.time}`;
              return aTime.localeCompare(bTime);
            });
          }
        }
      }
    }

    // mergedMatchesForResponse() is stored in ascending kickoff order already.
    // Filtering preserves order, so only reverse for descending responses.
    if (sortOrder === "desc") {
      filtered = filtered.slice().reverse();
    }

    const totalCount = filtered.length;
    const totalPages = totalCount > 0 ? Math.ceil(totalCount / pageSize) : 0;
    const pageStart = (page - 1) * pageSize;
    const pageEnd = pageStart + pageSize;
    const paged = pageStart >= totalCount ? [] : filtered.slice(pageStart, pageEnd);
    const hasMore = page < totalPages;

    res.set("X-Total-Count", String(totalCount));
    res.set("X-Page", String(page));
    res.set("X-Page-Size", String(pageSize));
    res.set("X-Total-Pages", String(totalPages));
    res.set("X-Has-More", hasMore ? "true" : "false");
    res.set("X-Sort-Order", sortOrder);

    let matchDetailsLookup = matchDetailsSnapshot.lookup || {};
    const aggregateEnrichment = await enrichKnockoutAggregatesForListMatches(
      paged,
      matchDetailsLookup
    );
    matchDetailsLookup = aggregateEnrichment.lookup || matchDetailsLookup;
    const matchDetailsIdentityIndex = buildMatchDetailsIdentityIndex(matchDetailsLookup);

    const payload = paged
      .map((match) =>
        toMatchListPayload(match, {
          matchDetailsLookup,
          matchDetailsIdentityIndex,
        })
      )
      .filter(Boolean);
    res.json(payload);
  } catch (err) {
    console.warn("Failed to serve /matches from cache:", err.message || err);
    res.status(500).json({ error: "Failed to serve matches from cache" });
  }
});

app.post(`${API_PREFIX}/matches/states`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const ids = Array.isArray(req.body && req.body.ids) ? req.body.ids : [];
  const uniqueIds = [];
  const seen = new Set();
  ids.forEach((value) => {
    const normalized = normalizeMatchDetailsId(value);
    if (!normalized || seen.has(normalized)) return;
    seen.add(normalized);
    uniqueIds.push(normalized);
  });

  if (uniqueIds.length === 0) {
    res.status(400).json({ error: "Expected non-empty ids array of BBC match detail ids." });
    return;
  }

  if (uniqueIds.length > 500) {
    res.status(400).json({ error: "Too many ids. Maximum 500 per request." });
    return;
  }

  uniqueIds.forEach((matchId) => {
    markMatchDetailsActive(matchId);
  });

  const lookup = await getOperationalMatchDetailsBatchSafe(uniqueIds);
  res.set("X-Operational-Source", lookup.source || "unknown");

  const payload = uniqueIds
    .map((matchId) => {
      const detailsPayload = lookup.payloadsById.get(matchId) || null;
      if (!detailsPayload) return null;
      scheduleMatchDetailsBackfill(detailsPayload, { trigger: "batch_states" });
      return getMatchDetailsStatePayload(detailsPayload);
    })
    .filter(Boolean);

  const latestUpdated = newestIsoTimestamp(
    payload.map((item) => (item && item.updated_at ? item.updated_at : null))
  );
  if (latestUpdated) {
    res.set("X-Last-Updated", latestUpdated);
  }

  res.json(payload);
});

app.get(`${API_PREFIX}/matches/:matchId`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const matchId = normalizeMatchDetailsId(req.params.matchId);
  if (!matchId) {
    res.status(400).json({ error: "Invalid match id. Expected BBC details id (e.g. c043pne0q3kt)." });
    return;
  }
  markMatchDetailsActive(matchId);

  // Check if this is a test match (search all test matches by their ID)
  const allTestMatches = testMatchState.getAllMatches();
  const testMatch = allTestMatches.find(m => m.match_details_id === matchId);
  if (testMatch) {
    const testMatchDetails = {
      id: testMatch.match_details_id,
      details_url: null,
      date: testMatch.date,
      time: testMatch.time,
      league: testMatch.league,
      home_team: testMatch.home_team,
      away_team: testMatch.away_team,
      home_score: testMatch.home_score,
      away_score: testMatch.away_score,
      aggregate_home_score: testMatch.aggregate_home_score,
      aggregate_away_score: testMatch.aggregate_away_score,
      score_status: testMatch.score_status,
      home_goal_scorers: testMatch.home_goal_scorers || [],
      away_goal_scorers: testMatch.away_goal_scorers || [],
      home_assists: testMatch.home_assists || [],
      away_assists: testMatch.away_assists || [],
      home_yellow_cards: testMatch.home_yellow_cards || [],
      away_yellow_cards: testMatch.away_yellow_cards || [],
      home_red_cards: testMatch.home_red_cards || [],
      away_red_cards: testMatch.away_red_cards || [],
      live_text_entries: testMatch.live_text_entries || [],
      penalty_result: testMatch.penalty_result,
      in_progress: testMatch.in_progress,
      updated_at: testMatch.updated_at,
    };
    res.json(testMatchDetails);
    return;
  }

  const payload = matchDetailsById.get(matchId) || null;
  const fallbackMatchRecord = findInMemoryMatchRecordByMatchId(matchId);
  const responsePayload = await enrichMatchDetailsAggregateImmediately(
    payload || buildFallbackMatchDetailsPayload(matchId, fallbackMatchRecord),
    {
      persistSource: "match_details_request_knockout_aggregate_enrichment",
    }
  );
  if (!responsePayload) {
    scheduleMatchDetailsWarm(matchId, {
      trigger: "match_details_request",
      fallbackMatchRecord,
    });
    res.status(404).json({ error: "No cached match details found for match id." });
    return;
  }
  const stableResponsePayload = withStableMatchDetailsState(responsePayload) || responsePayload;
  const enrichedResponsePayload = await mergeConfirmedVarDisallowedGoalsIntoPayload(stableResponsePayload);

  if (payload) {
    scheduleMatchDetailsBackfill(payload, { trigger: "match_details_request" });
  } else {
    scheduleMatchDetailsWarm(matchId, {
      trigger: "match_details_request",
      fallbackMatchRecord,
    });
  }

  res.set("X-Operational-Source", payload ? "memory" : "memory_fallback");
  if (stableResponsePayload.updated_at) {
    res.set("X-Last-Updated", stableResponsePayload.updated_at);
  } else if (matchDetailsLastUpdated) {
    res.set("X-Last-Updated", matchDetailsLastUpdated);
  }
  res.json(enrichedResponsePayload);
});

app.get(`${API_PREFIX}/monitor/candidates`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const date = req.query.date
    ? String(req.query.date).trim()
    : new Date().toISOString().split("T")[0];
  if (!isDateOnly(date)) {
    res.status(400).json({
      error: "Invalid date. Expected YYYY-MM-DD.",
    });
    return;
  }

  try {
    const mergedDataset = currentMergedMatchesDatasetSnapshot();
    const matchDetailsSnapshot = currentFastMatchDetailsLookupSnapshot("monitor_candidates_request");
    const matchDetailsLookup = matchDetailsSnapshot.lookup || {};
    const mergedItems = Array.isArray(mergedDataset.items) ? mergedDataset.items : [];
    const candidates = buildMonitorCandidatesForDate(date, mergedItems, matchDetailsLookup);
    const existingCandidateIds = new Set(
      candidates.map((candidate) => normalizeMatchDetailsId(candidate && candidate.match_details_id))
    );
    const testCandidates = testMatchState
      .getAllMatches()
      .filter((match) => match && match.date === date)
      .map((match) => ({
        match_details_id: String(match.match_details_id || match.id || "").trim() || null,
        details_url: match.details_url || null,
        date: match.date || null,
        time: match.time || null,
        league: match.league || null,
        league_subcategory: match.league_subcategory || null,
        home_team: match.home_team || null,
        away_team: match.away_team || null,
        home_score: match.home_score,
        away_score: match.away_score,
        score_status: match.score_status || null,
        tv_channels: Array.isArray(match.tv_channels) ? match.tv_channels : [],
        source: "test_harness",
      }))
      .filter((candidate) => {
        const candidateId = normalizeMatchDetailsId(candidate && candidate.match_details_id);
        return candidateId && !existingCandidateIds.has(candidateId);
      });
    const allCandidates = [...candidates, ...testCandidates];

    res.status(200).json({
      success: true,
      date,
      count: allCandidates.length,
      source: {
        merged_matches: mergedDataset && mergedDataset.source ? mergedDataset.source : "unknown",
        merged_matches_updated_at: mergedDataset && mergedDataset.updated_at ? mergedDataset.updated_at : null,
        match_details: matchDetailsSnapshot && matchDetailsSnapshot.source ? matchDetailsSnapshot.source : "unknown",
        match_details_updated_at:
          matchDetailsSnapshot && matchDetailsSnapshot.updated_at ? matchDetailsSnapshot.updated_at : null,
      },
      candidates: allCandidates,
    });
  } catch (error) {
    console.error("[API] Error retrieving monitor candidates:", error);
    res.status(500).json({
      error: "Failed to retrieve monitor candidates",
      message: error.message || String(error),
    });
  }
});

app.get(`${API_PREFIX}/competitions`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const dataset = await getOperationalArrayDataset(
    OP_DATASET_MERGED_MATCHES,
    mergedMatchesForResponse()
  );
  res.set("X-Operational-Source", dataset.source || "unknown");
  res.json(buildLeagueList(dataset.items));
});

app.get(`${API_PREFIX}/teams`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const leagueFilter = req.query.league ? String(req.query.league) : null;
  const sourceSelection = resolveTeamRankingSource(req.query.source);
  const typeSelection = resolveTeamTypeFilter(req.query.type);
  if (!sourceSelection.valid) {
    res.status(400).json({
      error: `Invalid source. Expected one of: ${SUPPORTED_TEAM_RANKING_SOURCES.join(", ")}.`,
      supported_sources: SUPPORTED_TEAM_RANKING_SOURCES,
      default_source: TEAM_RANKING_DEFAULT_SOURCE,
    });
    return;
  }
  if (!typeSelection.valid) {
    res.status(400).json({
      error: `Invalid type. Expected one of: ${SUPPORTED_TEAM_TYPES.join(", ")}.`,
      supported_types: SUPPORTED_TEAM_TYPES,
    });
    return;
  }
  const [mergedDataset, clubEloDataset, footballDatabaseDataset, nationalEloDataset] = await Promise.all([
    getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, mergedMatchesForResponse()),
    getOperationalArrayDataset(OP_DATASET_CLUB_ELO_TEAMS, cachedClubEloTeams),
    getOperationalArrayDataset(
      OP_DATASET_FOOTBALL_DATABASE_TEAMS,
      cachedFootballDatabaseTeams
    ),
    getOperationalArrayDataset(OP_DATASET_NATIONAL_ELO_TEAMS, cachedNationalEloTeams),
  ]);
  const rankedRows = buildRankedTeamsForSource(
    mergedDataset.items,
    clubEloDataset.items,
    footballDatabaseDataset.items,
    nationalEloDataset.items,
    sourceSelection.source,
    leagueFilter
  );
  const filteredRows = filterRankedRowsByTeamType(rankedRows, typeSelection.type);
  const updatedAt = newestIsoTimestamp([
    mergedDataset.updated_at,
    clubEloDataset.updated_at,
    footballDatabaseDataset.updated_at,
    nationalEloDataset.updated_at,
    clubEloLastUpdated,
    footballDatabaseLastUpdated,
    nationalEloLastUpdated,
  ]);
  if (updatedAt) {
    res.set("X-Last-Updated", updatedAt);
  }
  res.set("X-Team-Metadata-Source", sourceSelection.source);
  res.set("X-Team-Metadata-Default-Source", TEAM_RANKING_DEFAULT_SOURCE);
  res.set("X-Team-Type-Filter", typeSelection.type || "all");
  res.set(
    "X-Operational-Source",
    `merged=${mergedDataset.source || "unknown"};` +
      `club_elo=${clubEloDataset.source || "unknown"};` +
      `footballdatabase=${footballDatabaseDataset.source || "unknown"};` +
      `national_elo=${nationalEloDataset.source || "unknown"}`
  );
  res.json(toTeamsApiTeamPayload(filteredRows));
});

app.get(`${API_PREFIX}/teams/config`, (_req, res) => {
  setCacheOnlyHeaders(res);
  const updatedAt = new Date().toISOString();
  res.set("X-Last-Updated", updatedAt);
  res.set("X-Operational-Source", "server_config");
  res.status(200).json({
    default_elo: TEAM_RANKING_DEFAULT_ELO,
    updated_at: updatedAt,
  });
});

app.post(`${API_PREFIX}/teams/club-elo/sync`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const result = await updateClubEloTeams({ trigger: "api_on_demand" });
  if (result && result.skipped && result.reason === "update_in_progress") {
    res.status(409).json({
      success: false,
      error: "Club Elo sync already in progress.",
      ...result,
    });
    return;
  }
  if (!result || !result.success) {
    res.status(502).json({
      success: false,
      error: "Failed to sync Club Elo teams.",
      ...result,
    });
    return;
  }
  res.status(200).json(result);
});

app.post(`${API_PREFIX}/teams/footballdatabase/sync`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const result = await updateFootballDatabaseTeams({ trigger: "api_on_demand" });
  if (result && result.skipped && result.reason === "update_in_progress") {
    res.status(409).json({
      success: false,
      error: "FootballDatabase sync already in progress.",
      ...result,
    });
    return;
  }
  if (!result || !result.success) {
    res.status(502).json({
      success: false,
      error: "Failed to sync FootballDatabase teams.",
      ...result,
    });
    return;
  }
  res.status(200).json(result);
});

app.post(`${API_PREFIX}/teams/national-elo/sync`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const result = await updateNationalEloTeams({ trigger: "api_on_demand" });
  if (result && result.skipped && result.reason === "update_in_progress") {
    res.status(409).json({
      success: false,
      error: "National Elo sync already in progress.",
      ...result,
    });
    return;
  }
  if (!result || !result.success) {
    res.status(502).json({
      success: false,
      error: "Failed to sync National Elo teams.",
      ...result,
    });
    return;
  }
  res.status(200).json(result);
});

async function serveTeamsUnmatched(req, res, forcedSource = null) {
  setCacheOnlyHeaders(res);
  const leagueFilter = req.query.league ? String(req.query.league) : null;
  const sourceSelection = resolveTeamRankingSource(forcedSource || req.query.source);
  if (!sourceSelection.valid) {
    res.status(400).json({
      error: `Invalid source. Expected one of: ${SUPPORTED_TEAM_RANKING_SOURCES.join(", ")}.`,
      supported_sources: SUPPORTED_TEAM_RANKING_SOURCES,
      default_source: TEAM_RANKING_DEFAULT_SOURCE,
    });
    return;
  }
  const [mergedDataset, clubEloDataset, footballDatabaseDataset, nationalEloDataset] = await Promise.all([
    getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, mergedMatchesForResponse()),
    getOperationalArrayDataset(OP_DATASET_CLUB_ELO_TEAMS, cachedClubEloTeams),
    getOperationalArrayDataset(
      OP_DATASET_FOOTBALL_DATABASE_TEAMS,
      cachedFootballDatabaseTeams
    ),
    getOperationalArrayDataset(OP_DATASET_NATIONAL_ELO_TEAMS, cachedNationalEloTeams),
  ]);
  const rankedRows = buildRankedTeamsForSource(
    mergedDataset.items,
    clubEloDataset.items,
    footballDatabaseDataset.items,
    nationalEloDataset.items,
    sourceSelection.source,
    leagueFilter
  );
  const unmatched = buildUnmatchedTeamPayloadFromUnifiedRows(rankedRows);
  const updatedAt = newestIsoTimestamp([
    mergedDataset.updated_at,
    clubEloDataset.updated_at,
    footballDatabaseDataset.updated_at,
    nationalEloDataset.updated_at,
    clubEloLastUpdated,
    footballDatabaseLastUpdated,
    nationalEloLastUpdated,
  ]);
  if (updatedAt) {
    res.set("X-Last-Updated", updatedAt);
  }
  res.set("X-Team-Metadata-Source", sourceSelection.source);
  res.set("X-Team-Metadata-Default-Source", TEAM_RANKING_DEFAULT_SOURCE);
  res.set(
    "X-Operational-Source",
    `merged=${mergedDataset.source || "unknown"};` +
      `club_elo=${clubEloDataset.source || "unknown"};` +
      `footballdatabase=${footballDatabaseDataset.source || "unknown"};` +
      `national_elo=${nationalEloDataset.source || "unknown"}`
  );
  res.status(200).json({
    count: unmatched.length,
    league: leagueFilter ? normalizeLeagueName(leagueFilter) : null,
    source: sourceSelection.source,
    default_source: TEAM_RANKING_DEFAULT_SOURCE,
    match_confidence_threshold: teamSourceConfidenceThreshold(sourceSelection.source),
    teams: unmatched,
  });
}

app.get(`${API_PREFIX}/teams/unmatched`, async (req, res) => {
  await serveTeamsUnmatched(req, res);
});

app.get(`${API_PREFIX}/teams/club-elo/unmatched`, async (req, res) => {
  await serveTeamsUnmatched(req, res, TEAM_RANKING_SOURCE_CLUBELO);
});

app.get(`${API_PREFIX}/teams/footballdatabase/unmatched`, async (req, res) => {
  await serveTeamsUnmatched(req, res, TEAM_RANKING_SOURCE_FOOTBALLDATABASE);
});

app.get(`${API_PREFIX}/teams/national-elo/unmatched`, async (req, res) => {
  await serveTeamsUnmatched(req, res, TEAM_RANKING_SOURCE_NATIONAL_ELO);
});

app.get(`${API_PREFIX}/teams/premier-league`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const dataset = await getOperationalArrayDataset(
    OP_DATASET_PREMIER_LEAGUE_TEAMS,
    cachedPremierLeagueTeams
  );
  const updatedAt = dataset.updated_at || eplLastUpdated;
  if (updatedAt) {
    res.set("X-Last-Updated", updatedAt);
  }
  res.set("X-Operational-Source", dataset.source || "unknown");
  res.json(dataset.items);
});

app.get(`${API_PREFIX}/teams/:teamName`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const teamName = String(req.params.teamName || "").replace(/\s+/g, " ").trim();
  if (!teamName) {
    res.status(400).json({ error: "Team name is required." });
    return;
  }

  const leagueFilter = req.query.league ? String(req.query.league) : null;
  const sourceSelection = resolveTeamRankingSource(req.query.source);
  const typeSelection = resolveTeamTypeFilter(req.query.type);
  if (!sourceSelection.valid) {
    res.status(400).json({
      error: `Invalid source. Expected one of: ${SUPPORTED_TEAM_RANKING_SOURCES.join(", ")}.`,
      supported_sources: SUPPORTED_TEAM_RANKING_SOURCES,
      default_source: TEAM_RANKING_DEFAULT_SOURCE,
    });
    return;
  }
  if (!typeSelection.valid) {
    res.status(400).json({
      error: `Invalid type. Expected one of: ${SUPPORTED_TEAM_TYPES.join(", ")}.`,
      supported_types: SUPPORTED_TEAM_TYPES,
    });
    return;
  }

  const [mergedDataset, clubEloDataset, footballDatabaseDataset, nationalEloDataset] = await Promise.all([
    getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, mergedMatchesForResponse()),
    getOperationalArrayDataset(OP_DATASET_CLUB_ELO_TEAMS, cachedClubEloTeams),
    getOperationalArrayDataset(
      OP_DATASET_FOOTBALL_DATABASE_TEAMS,
      cachedFootballDatabaseTeams
    ),
    getOperationalArrayDataset(OP_DATASET_NATIONAL_ELO_TEAMS, cachedNationalEloTeams),
  ]);
  const rankedRows = buildRankedTeamsForSource(
    mergedDataset.items,
    clubEloDataset.items,
    footballDatabaseDataset.items,
    nationalEloDataset.items,
    sourceSelection.source,
    leagueFilter
  );
  const filteredRows = filterRankedRowsByTeamType(rankedRows, typeSelection.type);
  const match = findBestRankedTeamRowMatch(teamName, filteredRows, {
    minConfidence: req.query.min_confidence,
  });
  if (!match) {
    res.status(404).json({
      error: "Team not found for provided name.",
      query: teamName,
      source: sourceSelection.source,
      type: typeSelection.type || "all",
    });
    return;
  }

  const updatedAt = newestIsoTimestamp([
    mergedDataset.updated_at,
    clubEloDataset.updated_at,
    footballDatabaseDataset.updated_at,
    nationalEloDataset.updated_at,
    clubEloLastUpdated,
    footballDatabaseLastUpdated,
    nationalEloLastUpdated,
  ]);
  if (updatedAt) {
    res.set("X-Last-Updated", updatedAt);
  }
  res.set("X-Team-Metadata-Source", sourceSelection.source);
  res.set("X-Team-Metadata-Default-Source", TEAM_RANKING_DEFAULT_SOURCE);
  res.set("X-Team-Type-Filter", typeSelection.type || "all");
  res.set("X-Team-Match-Method", match.method);
  res.set("X-Team-Match-Confidence", String(Number(match.confidence).toFixed(4)));
  res.set(
    "X-Operational-Source",
    `merged=${mergedDataset.source || "unknown"};` +
      `club_elo=${clubEloDataset.source || "unknown"};` +
      `footballdatabase=${footballDatabaseDataset.source || "unknown"};` +
      `national_elo=${nationalEloDataset.source || "unknown"}`
  );

  const payload = toTeamsApiTeamPayload([match.row])[0] || null;
  if (!payload) {
    res.status(404).json({
      error: "Team found but payload could not be generated.",
      query: teamName,
      source: sourceSelection.source,
      type: typeSelection.type || "all",
    });
    return;
  }
  res.status(200).json({
    ...payload,
    query: teamName,
    match_name: match.matched_name,
    match_alias: match.matched_alias,
    match_method: match.method,
    match_confidence: Number(match.confidence.toFixed(4)),
  });
});

app.get(`${API_PREFIX}/tables`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const dataset = await getOperationalArrayDataset(OP_DATASET_LEAGUE_TABLES, cachedLeagueTables);
  const leagues = sortLeagueTablesForResponse(dataset.items);
  const updatedAt =
    dataset.updated_at ||
    leagueTablesLastUpdated ||
    newestIsoTimestamp(
      leagues
        .map((league) => String((league && league.updated_at) || "").trim())
        .filter(Boolean)
    );
  if (updatedAt) {
    res.set("X-Last-Updated", updatedAt);
  }
  res.set("X-Operational-Source", dataset.source || "unknown");
  res.json({
    updated_at: updatedAt || null,
    count: leagues.length,
    leagues,
  });
});

app.get(`${API_PREFIX}/tables/:leagueId`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const dataset = await getOperationalArrayDataset(OP_DATASET_LEAGUE_TABLES, cachedLeagueTables);
  const leagues = sortLeagueTablesForResponse(dataset.items);
  const league = findLeagueTableById(leagues, req.params.leagueId);
  if (!league) {
    res.status(404).json({
      error: "League table not found",
      league_id: normalizeLeagueTableId(req.params.leagueId),
      available_leagues: leagues.map((item) => item.league_id).filter(Boolean),
    });
    return;
  }
  if (league.updated_at) {
    res.set("X-Last-Updated", league.updated_at);
  } else if (dataset.updated_at) {
    res.set("X-Last-Updated", dataset.updated_at);
  }
  res.set("X-Operational-Source", dataset.source || "unknown");
  res.json(league);
});

app.get(`${API_PREFIX}/channels`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const dataset = await getOperationalArrayDataset(
    OP_DATASET_MERGED_MATCHES,
    mergedMatchesForResponse()
  );
  res.set("X-Operational-Source", dataset.source || "unknown");
  res.json(buildChannelList(dataset.items));
});

app.get(`${API_PREFIX}/fantasy/team-short-name-mappings`, (_req, res) => {
  setCacheOnlyHeaders(res);
  const mappings = loadFantasyTeamShortNameMappings();
  if (fantasyTeamShortNameMappingsLoadedAt) {
    res.set("X-Last-Updated", fantasyTeamShortNameMappingsLoadedAt);
  }
  res.set("X-Operational-Source", "filesystem_config");
  res.json({
    updated_at: fantasyTeamShortNameMappingsLoadedAt,
    mappings,
  });
});

app.get(`${API_PREFIX}/fantasy/loading-messages`, (_req, res) => {
  setCacheOnlyHeaders(res);
  const messages = loadFantasyLoadingMessages();
  if (fantasyLoadingMessagesLoadedAt) {
    res.set("X-Last-Updated", fantasyLoadingMessagesLoadedAt);
  }
  res.set("X-Operational-Source", "filesystem_config");
  res.json({
    updated_at: fantasyLoadingMessagesLoadedAt,
    messages,
  });
});

app.get(`${API_PREFIX}/fantasy/assistant-manager/phrases`, (_req, res) => {
  setCacheOnlyHeaders(res);
  const phrases = loadFantasyAssistantManagerPhrases();
  if (fantasyAssistantManagerPhrasesLoadedAt) {
    res.set("X-Last-Updated", fantasyAssistantManagerPhrasesLoadedAt);
  }
  res.set("X-Operational-Source", "filesystem_config");
  res.json({
    updated_at: fantasyAssistantManagerPhrasesLoadedAt,
    phrases,
  });
});

app.get(`${API_PREFIX}/team-colors`, (_req, res) => {
  setCacheOnlyHeaders(res);
  const payload = loadTeamColorsConfig();
  if (teamColorsLoadedAt) {
    res.set("X-Last-Updated", teamColorsLoadedAt);
  }
  res.set("X-Operational-Source", "filesystem_config");
  res.json(payload);
});

app.get(`${API_PREFIX}/fantasy/gameweek/current`, (_req, res) => {
  setFantasyBootstrapHeaders(res);

  if (!cachedFantasyBootstrap) {
    if (fantasyBootstrapGameUpdating) {
      res.set("Retry-After", "120");
      res.status(503).json({
        error: FPL_GAME_UPDATING_USER_MESSAGE,
        code: "fantasy_game_updating",
        upstream_message: fantasyBootstrapGameUpdatingMessage,
        detected_at: fantasyBootstrapGameUpdatingDetectedAt,
      });
      return;
    }
    res.status(503).json({ error: "Fantasy bootstrap-static dataset not loaded yet." });
    return;
  }

  if (!fantasyBootstrapCurrentEvent) {
    res.status(404).json({
      error: "No current gameweek found in fantasy bootstrap-static dataset.",
    });
    return;
  }

  res.json(fantasyBootstrapCurrentEvent);
});

app.get(`${API_PREFIX}/fantasy/gameweek/next`, (_req, res) => {
  setFantasyBootstrapHeaders(res);

  if (!cachedFantasyBootstrap) {
    if (fantasyBootstrapGameUpdating) {
      res.set("Retry-After", "120");
      res.status(503).json({
        error: FPL_GAME_UPDATING_USER_MESSAGE,
        code: "fantasy_game_updating",
        upstream_message: fantasyBootstrapGameUpdatingMessage,
        detected_at: fantasyBootstrapGameUpdatingDetectedAt,
      });
      return;
    }
    res.status(503).json({ error: "Fantasy bootstrap-static dataset not loaded yet." });
    return;
  }

  if (!fantasyBootstrapNextEvent) {
    res.status(404).json({
      error: "No next gameweek found in fantasy bootstrap-static dataset.",
    });
    return;
  }

  res.json(fantasyBootstrapNextEvent);
});

app.get(`${API_PREFIX}/fantasy/score`, async (req, res) => {
  setCacheOnlyHeaders(res);
  if (fantasyBootstrapLastUpdated) {
    res.set("X-Fantasy-Bootstrap-Last-Updated", fantasyBootstrapLastUpdated);
  }
  if (fantasyFixturesLastUpdated) {
    res.set("X-Fantasy-Fixtures-Last-Updated", fantasyFixturesLastUpdated);
  }
  if (fantasyEventLiveLastUpdated) {
    res.set("X-Fantasy-Event-Live-Last-Updated", fantasyEventLiveLastUpdated);
  }

  const explicitDeviceToken =
    typeof req.query.deviceToken === "string"
      ? req.query.deviceToken
      : typeof req.query.userDeviceToken === "string"
        ? req.query.userDeviceToken
        : "";
  const resolvedDeviceToken = req.deviceToken || normalizeDeviceToken(explicitDeviceToken);

  if (!resolvedDeviceToken) {
    res.status(400).json({
      error: "Missing device token (X-Device-Token header or deviceToken query parameter).",
    });
    return;
  }

  try {
    const record = await getUserPreferences(resolvedDeviceToken);
    if (!record || !record.fantasy || !record.fantasy.squad) {
      res.status(404).json({
        error: "No synced fantasy squad found for this device.",
        userDeviceToken: resolvedDeviceToken,
      });
      return;
    }

    const breakdown = fantasyScore.calculateFantasyScore(record.fantasy);
    if (!breakdown) {
      res.status(422).json({
        error: "Fantasy score could not be calculated from the synced squad.",
        userDeviceToken: resolvedDeviceToken,
      });
      return;
    }

    res.status(200).json({
      success: true,
      userDeviceToken: resolvedDeviceToken,
      managerEntryID: record.fantasy.managerEntryID || record.fantasy.squad.managerEntryID || null,
      gameweekID: record.fantasy.squad.gameweekID || null,
      gameweekTitle: record.fantasy.squad.gameweekTitle || null,
      currentScore: breakdown.currentScore,
      effectiveContributions: breakdown.effectiveContributions,
      scoreCalculationRulesApplied: breakdown.scoreCalculationRulesApplied,
      usedServerLiveData: breakdown.usedServerLiveData,
      playerCount: breakdown.playerCount,
      context: fantasyScore.fantasyScoreContextSummary(),
    });
  } catch (error) {
    console.error("[API] Error calculating fantasy score:", error);
    res.status(500).json({
      error: "Failed to calculate fantasy score",
      message: error.message,
    });
  }
});

function fantasyBootstrapLookupPayload() {
  const payload = cachedFantasyBootstrap && typeof cachedFantasyBootstrap === "object"
    ? cachedFantasyBootstrap
    : {};

  const elements = Array.isArray(payload.elements)
    ? payload.elements
      .map((item) => ({
        id: Number(item && item.id) || 0,
        web_name: String((item && item.web_name) || "").trim(),
        first_name: String((item && item.first_name) || "").trim(),
        second_name: String((item && item.second_name) || "").trim(),
        team: Number(item && item.team) || 0,
        element_type: Number(item && item.element_type) || 0,
        photo: String((item && item.photo) || "").trim(),
        status: String((item && item.status) || "").trim(),
        news: String((item && item.news) || "").trim(),
        now_cost: Number(item && item.now_cost) || 0,
      }))
      .filter((item) => Number.isFinite(item.id) && item.id > 0)
    : [];

  const teams = Array.isArray(payload.teams)
    ? payload.teams
      .map((item) => ({
        id: Number(item && item.id) || 0,
        name: String((item && item.name) || "").trim(),
        short_name: String((item && item.short_name) || "").trim(),
        code: Number(item && item.code) || 0,
      }))
      .filter((item) => Number.isFinite(item.id) && item.id > 0)
    : [];

  const elementTypes = Array.isArray(payload.element_types)
    ? payload.element_types
      .map((item) => ({
        id: Number(item && item.id) || 0,
        singular_name: String((item && item.singular_name) || "").trim(),
        singular_name_short: String((item && item.singular_name_short) || "").trim(),
        plural_name: String((item && item.plural_name) || "").trim(),
        plural_name_short: String((item && item.plural_name_short) || "").trim(),
      }))
      .filter((item) => Number.isFinite(item.id) && item.id > 0)
    : [];

  const events = Array.isArray(payload.events)
    ? payload.events
      .map((item) => ({
        id: Number(item && item.id) || 0,
        name: String((item && item.name) || "").trim(),
        is_current: Boolean(item && item.is_current === true),
        is_next: Boolean(item && item.is_next === true),
        deadline_time: String((item && item.deadline_time) || "").trim() || null,
      }))
      .filter((item) => Number.isFinite(item.id) && item.id > 0)
    : [];

  return {
    updated_at: fantasyBootstrapLastUpdated,
    elements,
    teams,
    element_types: elementTypes,
    events,
  };
}

function setFantasyBootstrapHeaders(res) {
  setCacheOnlyHeaders(res);
  if (fantasyBootstrapLastUpdated) {
    res.set("X-Last-Updated", fantasyBootstrapLastUpdated);
  }
  res.set("X-Fantasy-Upstream-Status", fantasyBootstrapGameUpdating ? "game-updating" : "ok");
  const ageSeconds = fantasyBootstrapAgeSeconds();
  if (Number.isFinite(ageSeconds)) {
    res.set("X-Fantasy-Cache-Age-Seconds", String(Math.floor(ageSeconds)));
  }
  res.set("X-Fantasy-Cache-Stale", isFantasyBootstrapStale() ? "true" : "false");
  res.set("X-Operational-Source", "memory_cache");
}

app.get(`${API_PREFIX}/fantasy/bootstrap/lookup`, (_req, res) => {
  setFantasyBootstrapHeaders(res);
  if (!cachedFantasyBootstrap) {
    if (fantasyBootstrapGameUpdating) {
      res.set("Retry-After", "120");
      res.status(503).json({
        error: FPL_GAME_UPDATING_USER_MESSAGE,
        code: "fantasy_game_updating",
        upstream_message: fantasyBootstrapGameUpdatingMessage,
        detected_at: fantasyBootstrapGameUpdatingDetectedAt,
      });
      return;
    }
    res.status(503).json({ error: "Fantasy bootstrap-static dataset not loaded yet." });
    return;
  }
  res.json(fantasyBootstrapLookupPayload());
});

app.get(`${API_PREFIX}/fantasy/bootstrap/elements`, (_req, res) => {
  setFantasyBootstrapHeaders(res);
  if (!cachedFantasyBootstrap) {
    if (fantasyBootstrapGameUpdating) {
      res.set("Retry-After", "120");
      res.status(503).json({
        error: FPL_GAME_UPDATING_USER_MESSAGE,
        code: "fantasy_game_updating",
        upstream_message: fantasyBootstrapGameUpdatingMessage,
        detected_at: fantasyBootstrapGameUpdatingDetectedAt,
      });
      return;
    }
    res.status(503).json({ error: "Fantasy bootstrap-static dataset not loaded yet." });
    return;
  }
  res.json(fantasyBootstrapLookupPayload().elements);
});

app.get(`${API_PREFIX}/fantasy/bootstrap/teams`, (_req, res) => {
  setFantasyBootstrapHeaders(res);
  if (!cachedFantasyBootstrap) {
    if (fantasyBootstrapGameUpdating) {
      res.set("Retry-After", "120");
      res.status(503).json({
        error: FPL_GAME_UPDATING_USER_MESSAGE,
        code: "fantasy_game_updating",
        upstream_message: fantasyBootstrapGameUpdatingMessage,
        detected_at: fantasyBootstrapGameUpdatingDetectedAt,
      });
      return;
    }
    res.status(503).json({ error: "Fantasy bootstrap-static dataset not loaded yet." });
    return;
  }
  res.json(fantasyBootstrapLookupPayload().teams);
});

app.get(`${API_PREFIX}/fantasy/bootstrap/element-types`, (_req, res) => {
  setFantasyBootstrapHeaders(res);
  if (!cachedFantasyBootstrap) {
    if (fantasyBootstrapGameUpdating) {
      res.set("Retry-After", "120");
      res.status(503).json({
        error: FPL_GAME_UPDATING_USER_MESSAGE,
        code: "fantasy_game_updating",
        upstream_message: fantasyBootstrapGameUpdatingMessage,
        detected_at: fantasyBootstrapGameUpdatingDetectedAt,
      });
      return;
    }
    res.status(503).json({ error: "Fantasy bootstrap-static dataset not loaded yet." });
    return;
  }
  res.json(fantasyBootstrapLookupPayload().element_types);
});

app.get(`${API_PREFIX}/fantasy/transfers/recommendations/:elementId`, (req, res) => {
  const startedAtMs = Date.now();
  fantasyTransferRecommendationRequestsTotal += 1;

  try {
    setFantasyBootstrapHeaders(res);

    if (!cachedFantasyBootstrap) {
      if (fantasyBootstrapGameUpdating) {
        res.set("Retry-After", "120");
        res.status(503).json({
          error: FPL_GAME_UPDATING_USER_MESSAGE,
          code: "fantasy_game_updating",
          upstream_message: fantasyBootstrapGameUpdatingMessage,
          detected_at: fantasyBootstrapGameUpdatingDetectedAt,
        });
        return;
      }
      res.status(503).json({ error: "Fantasy bootstrap-static dataset not loaded yet." });
      return;
    }

    const targetElementID = parseFiniteNumber(req.params.elementId, 0);
    if (!Number.isFinite(targetElementID) || targetElementID <= 0) {
      res.status(400).json({
        error: "Invalid element ID. Use a positive integer player ID.",
      });
      return;
    }

    const payload = cachedFantasyBootstrap && typeof cachedFantasyBootstrap === "object"
      ? cachedFantasyBootstrap
      : {};
    const elements = Array.isArray(payload.elements) ? payload.elements : [];
    const teams = Array.isArray(payload.teams) ? payload.teams : [];
    const elementTypes = Array.isArray(payload.element_types) ? payload.element_types : [];
    const targetElement = elements.find(
      (item) => parseFiniteNumber(item && item.id, 0) === targetElementID
    );

    if (!targetElement) {
      res.status(404).json({
        error: "Player not found in bootstrap-static dataset.",
        element_id: targetElementID,
      });
      return;
    }

    const targetPositionID = parseFiniteNumber(targetElement && targetElement.element_type, 0);
    const targetNowCost = parseFiniteNumber(targetElement && targetElement.now_cost, 0);
    if (targetPositionID <= 0 || targetNowCost <= 0) {
      res.status(422).json({
        error: "Target player has incomplete data for recommendation scoring.",
        element_id: targetElementID,
      });
      return;
    }

    const rawValueWindowMillions = Number(req.query.value_window_millions);
    const valueWindowMillions = Number.isFinite(rawValueWindowMillions)
      ? clamp(rawValueWindowMillions, 0.1, 5)
      : FPL_TRANSFER_DEFAULT_VALUE_WINDOW_MILLIONS;
    const valueWindowCostUnits = valueWindowMillions * 10;

    const rawBudgetDiscount = Number(req.query.budget_discount_fraction);
    const budgetDiscountFraction = Number.isFinite(rawBudgetDiscount)
      ? clamp(rawBudgetDiscount, 0.1, 0.8)
      : FPL_TRANSFER_DEFAULT_BUDGET_DISCOUNT_FRACTION;

    const rawLimit = Number(req.query.limit);
    const limit = Number.isFinite(rawLimit)
      ? Math.max(1, Math.min(FPL_TRANSFER_MAX_LIMIT, Math.floor(rawLimit)))
      : FPL_TRANSFER_DEFAULT_LIMIT;

    const maxBudgetCost = Math.floor(targetNowCost * (1 - budgetDiscountFraction));
    const positionNameByID = new Map(
      elementTypes
        .map((item) => [
          parseFiniteNumber(item && item.id, 0),
          String((item && item.singular_name) || "").trim() || "Player",
        ])
        .filter(([id]) => id > 0)
    );
    const teamContext = teamStrengthContext(teams);
    const currentEventID = parseFiniteNumber(
      fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id,
      0
    );
    const nextEventID = parseFiniteNumber(
      fantasyBootstrapNextEvent && fantasyBootstrapNextEvent.id,
      0
    );
    const baselineEvent = nextEventID > 0
      ? nextEventID
      : Math.max(1, currentEventID);
    const upcomingFixturesByTeam = buildUpcomingFixturesByTeam(
      cachedFantasyFixtures,
      teamContext,
      baselineEvent
    );

    const recommendations = elements
      .filter((item) => {
        const elementID = parseFiniteNumber(item && item.id, 0);
        if (elementID <= 0 || elementID === targetElementID) return false;
        const elementType = parseFiniteNumber(item && item.element_type, 0);
        if (elementType !== targetPositionID) return false;
        const nowCost = parseFiniteNumber(item && item.now_cost, 0);
        return nowCost > 0;
      })
      .map((item) =>
        buildTransferRecommendation(
          item,
          targetElement,
          teamContext,
          positionNameByID,
          upcomingFixturesByTeam,
          baselineEvent
        )
      )
      .sort((left, right) => {
        if (right.recommendation_score !== left.recommendation_score) {
          return right.recommendation_score - left.recommendation_score;
        }
        if (right.total_points !== left.total_points) {
          return right.total_points - left.total_points;
        }
        return left.now_cost_millions - right.now_cost_millions;
      });

    const similarValue = recommendations
      .filter((item) =>
        Math.abs(item.value_delta_millions) <= valueWindowMillions + 0.001
      )
      .slice(0, limit);

    const budget = recommendations
      .filter((item) => parseFiniteNumber(item.now_cost_millions, 0) * 10 <= maxBudgetCost)
      .slice(0, limit);

    res.json({
      source: "memory_cache",
      updated_at: fantasyBootstrapLastUpdated,
      age_seconds: Math.floor(
        Number.isFinite(fantasyBootstrapAgeSeconds()) ? fantasyBootstrapAgeSeconds() : 0
      ),
      stale: isFantasyBootstrapStale(),
      criteria: {
        element_id: targetElementID,
        player_name: normalizedPlayerName(targetElement),
        position_id: targetPositionID,
        position: positionNameByID.get(targetPositionID) || "Player",
        value_millions: roundTo(targetNowCost / 10, 1),
        value_window_millions: valueWindowMillions,
        budget_discount_fraction: roundTo(budgetDiscountFraction, 3),
        budget_max_value_millions: roundTo(maxBudgetCost / 10, 1),
        limit,
      },
      algorithm: {
        summary:
          "Score combines last-5 form proxy, projected next-5 fixture ease proxy, points-per-game, value efficiency, availability penalties, and blank-gameweek penalties (xP=0 for blank weeks).",
        components: {
          form_last5_proxy_weight: 0.52,
          next5_fixture_ease_proxy_weight: 0.28,
          points_per_game_weight: 0.12,
          value_efficiency_weight: 0.08,
          availability_penalty_multiplier: 24,
          blank_gameweek_penalty_points_each: 5,
        },
        notes: [
          "Past form is approximated with bootstrap 'form' scaled to a 5-match equivalent.",
          "Upcoming fixture labels/difficulty come from the in-memory fixtures cache.",
          "Recommendations penalize injury/suspension/doubt and chance-of-playing fields.",
        ],
      },
      similar_value: similarValue,
      budget,
    });
  } catch (error) {
    console.warn(
      "[FPLTransferRecommendations] failed:",
      error && error.message ? error.message : error
    );
    res.status(500).json({
      error: "Failed to build transfer recommendations.",
    });
  } finally {
    const durationSeconds = Math.max(0, (Date.now() - startedAtMs) / 1000);
    const success = res.statusCode >= 200 && res.statusCode < 300;
    if (!success) {
      fantasyTransferRecommendationFailuresTotal += 1;
    }
    recordHistogramSample(
      fantasyTransferRecommendationMetrics,
      {
        status: success ? "success" : "failure",
      },
      durationSeconds,
      FPL_TRANSFER_RECOMMENDATION_DURATION_BUCKETS
    );
  }
});

app.post(`${API_PREFIX}/fantasy/assistant-manager/:entryId/sync`, async (req, res) => {
  setFantasyBootstrapHeaders(res);

  const entryID = parseFiniteNumber(req.params.entryId, 0);
  if (!Number.isFinite(entryID) || entryID <= 0) {
    res.status(400).json({
      error: "Invalid entry ID. Use a positive integer manager entry ID.",
    });
    return;
  }

  touchFantasyAssistantEntry(entryID);
  try {
    await refreshFantasyAssistantManagerEntry(entryID, { trigger: "sync" });
  } catch (error) {
    console.warn(
      `[FantasyAssistantManager] sync failed entry_id=${entryID}:`,
      error && error.message ? error.message : error
    );
  }

  const response = buildFantasyAssistantManagerResponse(entryID);
  res.status(response.ready ? 200 : 202).json(response);
});

app.get(`${API_PREFIX}/fantasy/assistant-manager/:entryId`, (req, res) => {
  setFantasyBootstrapHeaders(res);

  const entryID = parseFiniteNumber(req.params.entryId, 0);
  if (!Number.isFinite(entryID) || entryID <= 0) {
    res.status(400).json({
      error: "Invalid entry ID. Use a positive integer manager entry ID.",
    });
    return;
  }

  touchFantasyAssistantEntry(entryID);
  const response = buildFantasyAssistantManagerResponse(entryID);
  if (!response.ready || response.stale) {
    void refreshFantasyAssistantManagerEntry(entryID, {
      trigger: response.ready ? "read_stale" : "read_warm",
      force: !response.ready,
    }).catch((error) => {
      console.warn(
        `[FantasyAssistantManager] read refresh failed entry_id=${entryID}:`,
        error && error.message ? error.message : error
      );
    });
  }

  res.status(response.ready ? 200 : 202).json(response);
});

app.post(`${API_PREFIX}/audit/missing-team-logos`, (req, res) => {
  setCacheOnlyHeaders(res);

  const payload = req.body;
  const teamNames = missingTeamLogoNamesFromPayload(payload);

  if (!teamNames) {
    res.status(400).json({
      error: "Invalid payload. Send a JSON array of team names or {\"team_names\":[...]}",
    });
    return;
  }

  const result = ingestMissingTeamLogoNames(teamNames);
  if (result.acceptedCount === 0) {
    res.status(400).json({
      error: "No valid team names were provided.",
      total_count: result.totalCount,
      last_updated: missingTeamLogosLastUpdated,
    });
    return;
  }

  if (missingTeamLogosLastUpdated) {
    res.set("X-Last-Updated", missingTeamLogosLastUpdated);
  }
  res.json({
    accepted_count: result.acceptedCount,
    added_count: result.addedCount,
    added: result.added,
    total_count: result.totalCount,
    last_updated: missingTeamLogosLastUpdated,
  });
});

app.post(`${API_PREFIX}/audit/missing-team-logos/cleanup`, (req, res) => {
  setCacheOnlyHeaders(res);

  const payload = req.body;
  const teamNames = missingTeamLogoNamesFromPayload(payload);
  const clearAll =
    isTruthyParam(req.query.all) ||
    (payload && typeof payload === "object" && isTruthyParam(payload.clear_all));

  if (!clearAll && !teamNames) {
    res.status(400).json({
      error:
        "Invalid cleanup payload. Send a JSON array, {\"team_names\":[...]}, or set all=true/clear_all=true.",
    });
    return;
  }

  const result = clearAll ? clearMissingTeamLogos() : removeMissingTeamLogoNames(teamNames);

  if (missingTeamLogosLastUpdated) {
    res.set("X-Last-Updated", missingTeamLogosLastUpdated);
  }

  res.json({
    accepted_count: clearAll ? result.removedCount : result.acceptedCount,
    removed_count: result.removedCount,
    removed: result.removed,
    total_count: result.totalCount,
    last_updated: missingTeamLogosLastUpdated,
    cleared_all: clearAll,
  });
});

app.get(`${API_PREFIX}/audit/missing-team-logos`, (_req, res) => {
  setCacheOnlyHeaders(res);
  if (missingTeamLogosLastUpdated) {
    res.set("X-Last-Updated", missingTeamLogosLastUpdated);
  }
  res.json(sortedMissingTeamLogoNames());
});

app.get(`${API_PREFIX}/bbc/live`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const [bbcLiveDataset, matchDetailsSnapshot] = await Promise.all([
    getOperationalArrayDataset(OP_DATASET_BBC_LIVE_MATCHES, cachedBbcMatches),
    getOperationalMatchDetailsSnapshotSafe(),
  ]);

  const updatedAt = bbcLiveDataset.updated_at || bbcLastUpdated;
  if (updatedAt) {
    res.set("X-Last-Updated", updatedAt);
  }
  res.set("X-Operational-Source", bbcLiveDataset.source || "unknown");

  // Transform "Pens" to "AET" for completed penalty shootouts in BBC Live matches
  const transformedMatches = bbcLiveDataset.items.map((match) => {
    // If match has Pens status and we have match details with penalty_result, change to AET
    if (match.match_time === "Pens" || match.match_time === "PEN" || match.match_time === "PEN.") {
      const detailsId = matchDetailsIdFromUrl(match.details_url);
      if (detailsId) {
        const matchDetails =
          matchDetailsSnapshot && matchDetailsSnapshot.records
            ? matchDetailsSnapshot.records[detailsId]
            : null;
        if (matchDetails && matchDetails.penalty_result) {
          return { ...match, match_time: "AET" };
        }
      }
    }
    return match;
  });

  res.json(transformedMatches);
});

app.get(`${API_PREFIX}/bbc/details`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const detailsUrl = req.query.url ? String(req.query.url).trim() : "";
  if (!detailsUrl) {
    res.status(400).json({ error: "Missing required query parameter: url" });
    return;
  }

  const detailsId = matchDetailsIdFromUrl(detailsUrl);
  if (!detailsId) {
    res.status(400).json({ error: "Invalid BBC football details URL" });
    return;
  }
  markMatchDetailsActive(detailsId);

  const payload = matchDetailsById.get(detailsId) || null;
  const fallbackMatchRecord = findInMemoryMatchRecordByMatchId(detailsId);
  const responsePayload = await enrichMatchDetailsAggregateImmediately(
    payload || buildFallbackMatchDetailsPayload(detailsId, fallbackMatchRecord),
    {
      persistSource: "bbc_details_request_knockout_aggregate_enrichment",
    }
  );
  if (!responsePayload) {
    scheduleMatchDetailsWarm(detailsId, {
      trigger: "bbc_details_request",
      fallbackMatchRecord,
    });
    res.status(404).json({ error: "No cached match details found for provided details URL" });
    return;
  }
  const stableResponsePayload = withStableMatchDetailsState(responsePayload) || responsePayload;
  const enrichedResponsePayload = await mergeConfirmedVarDisallowedGoalsIntoPayload(stableResponsePayload);

  if (payload) {
    scheduleMatchDetailsBackfill(payload, { trigger: "bbc_details_request" });
  } else {
    scheduleMatchDetailsWarm(detailsId, {
      trigger: "bbc_details_request",
      fallbackMatchRecord,
    });
  }

  res.set("X-Operational-Source", payload ? "memory" : "memory_fallback");
  if (stableResponsePayload.updated_at) {
    res.set("X-Last-Updated", stableResponsePayload.updated_at);
  } else if (matchDetailsLastUpdated) {
    res.set("X-Last-Updated", matchDetailsLastUpdated);
  }
  res.json(enrichedResponsePayload);
});

app.post(`${API_PREFIX}/matches/backfill`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const batchSize = parsePositiveInt(
    req.query.batch_size,
    MATCH_DETAILS_BACKFILL_BATCH_SIZE,
    1,
    500
  );

  const detailsSnapshot = await getOperationalMatchDetailsSnapshotSafe();
  res.set("X-Operational-Source", detailsSnapshot.source || "unknown");

  const candidates = [];
  Object.entries(detailsSnapshot.records || {}).forEach(([matchId, payload]) => {
    if (matchDetailsNeedsBackfill(payload) && payload.details_url) {
      candidates.push({ matchId, payload });
    }
  });

  const toEnrich = candidates.slice(0, batchSize);
  const enriched = [];
  const failed = [];
  const skipped = candidates.length - toEnrich.length;
  const nowIso = new Date().toISOString();

  await mapWithConcurrency(
    toEnrich,
    MATCH_DETAILS_POLL_CONCURRENCY,
    async (candidate) => {
      try {
        const fetched = await fetchBbcMatchByDetailsUrl(candidate.payload.details_url);
        if (fetched) {
          const combined = buildMergedMatchDetailsCandidate(
            candidate.payload,
            fetched,
            candidate.payload.details_url
          );
          const upsertedMatchId = upsertMatchDetailsFromMatch(combined, nowIso);
          if (upsertedMatchId) {
            enriched.push(upsertedMatchId);
          } else {
            failed.push(candidate.matchId);
          }
        } else {
          failed.push(candidate.matchId);
        }
      } catch (err) {
        console.warn(
          `Failed to backfill match ${candidate.matchId}:`,
          err.message || err
        );
        failed.push(candidate.matchId);
      }
    }
  );

  console.log(
    `Batch backfilled ${enriched.length} matches, ${failed.length} failed, ${skipped} skipped at ${nowIso}`
  );

  if (enriched.length > 0) {
    const updatedSubset = {};
    enriched.forEach((matchId) => {
      const payload = matchDetailsById.get(matchId);
      if (payload && typeof payload === "object") {
        updatedSubset[matchId] = payload;
      }
    });
    if (Object.keys(updatedSubset).length > 0) {
      await persistOperationalMatchDetailsSafe(updatedSubset, {
        replace: false,
        updated_at: nowIso,
        source: "admin_backfill_matches",
      });
    }
  }

  res.json({
    enriched_count: enriched.length,
    enriched_ids: enriched,
    failed_count: failed.length,
    failed_ids: failed,
    skipped_count: skipped,
    total_candidates: candidates.length,
    batch_size: batchSize,
    timestamp: nowIso,
  });
});

app.get(`${API_PREFIX}/status`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const [
    mergedDataset,
    liveDataset,
    bbcLiveDataset,
    bbcRangeDataset,
    recentDataset,
    teamsDataset,
    leagueTablesDataset,
    clubEloDataset,
    footballDatabaseDataset,
    nationalEloDataset,
    matchDetailsSummary,
    matchDetailsSnapshot,
  ] = await Promise.all([
    getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, cachedMergedMatches),
    getOperationalArrayDataset(OP_DATASET_LIVE_MATCHES, cachedMatches),
    getOperationalArrayDataset(OP_DATASET_BBC_LIVE_MATCHES, cachedBbcMatches),
    getOperationalArrayDataset(OP_DATASET_BBC_RANGE_MATCHES, cachedBbcRangeMatches),
    getOperationalArrayDataset(OP_DATASET_RECENT_MATCHES, cachedRecentMatches),
    getOperationalArrayDataset(OP_DATASET_PREMIER_LEAGUE_TEAMS, cachedPremierLeagueTeams),
    getOperationalArrayDataset(OP_DATASET_LEAGUE_TABLES, cachedLeagueTables),
    getOperationalArrayDataset(OP_DATASET_CLUB_ELO_TEAMS, cachedClubEloTeams),
    getOperationalArrayDataset(
      OP_DATASET_FOOTBALL_DATABASE_TEAMS,
      cachedFootballDatabaseTeams
    ),
    getOperationalArrayDataset(OP_DATASET_NATIONAL_ELO_TEAMS, cachedNationalEloTeams),
    getOperationalMatchDetailsSummary(),
    getOperationalMatchDetailsSnapshotSafe(),
  ]);

  const mergedLastUpdated = newestIsoTimestamp([
    mergedDataset.updated_at,
    bbcRangeDataset.updated_at,
    liveDataset.updated_at,
    bbcLiveDataset.updated_at,
    bbcRangeLastUpdated,
    lastUpdated,
    bbcLastUpdated,
  ]);

  let needsEnrichmentCount = 0;
  let needsStatusRefreshCount = 0;
  let needsBackfillCount = 0;
  const detailsRecords = matchDetailsSnapshot.records || {};
  const manualClubEloMappings = loadClubEloManualMappings();
  Object.values(detailsRecords).forEach((payload) => {
    if (matchDetailsNeedsEnrichment(payload) && payload.details_url) {
      needsEnrichmentCount += 1;
    }
    if (matchDetailsHasStaleInProgressStatus(payload)) {
      needsStatusRefreshCount += 1;
    }
    if (matchDetailsNeedsBackfill(payload)) {
      needsBackfillCount += 1;
    }
  });

  res.json({
    count: mergedDataset.items.length,
    last_updated: mergedLastUpdated,
    live_count: liveDataset.items.length,
    live_last_updated: liveDataset.updated_at || lastUpdated,
    source_url: SOURCE_URL,
    output_path: path.resolve(OUTPUT_PATH),
    interval_ms: INTERVAL_MS,
    bbc_count: bbcLiveDataset.items.length,
    bbc_last_updated: bbcLiveDataset.updated_at || bbcLastUpdated,
    bbc_source_url: BBC_SOURCE_URL,
    bbc_output_path: path.resolve(BBC_OUTPUT_PATH),
    bbc_interval_ms: BBC_INTERVAL_MS,
    bbc_range_count: bbcRangeDataset.items.length,
    bbc_range_last_updated: bbcRangeDataset.updated_at || bbcRangeLastUpdated,
    bbc_range_base_url: BBC_RANGE_BASE_URL,
    bbc_range_output_path: path.resolve(BBC_RANGE_OUTPUT_PATH),
    bbc_range_interval_ms: BBC_RANGE_INTERVAL_MS,
    bbc_range_past_days: BBC_RANGE_PAST_DAYS,
    bbc_range_future_days: BBC_RANGE_FUTURE_DAYS,
    bbc_range_concurrency: BBC_RANGE_CONCURRENCY,
    bbc_range_match_timezone: BBC_RANGE_MATCH_TIMEZONE,
    epl_count: teamsDataset.items.length,
    epl_last_updated: teamsDataset.updated_at || eplLastUpdated,
    epl_source_url: EPL_SOURCE_URL,
    epl_output_path: path.resolve(EPL_OUTPUT_PATH),
    epl_interval_ms: EPL_INTERVAL_MS,
    epl_team_min_confidence: EPL_TEAM_MIN_CONFIDENCE,
    fpl_bootstrap_source_url: FPL_BOOTSTRAP_SOURCE_URL,
    fpl_bootstrap_interval_ms: FPL_BOOTSTRAP_INTERVAL_MS,
    fpl_bootstrap_timeout_ms: FPL_BOOTSTRAP_TIMEOUT_MS,
    fpl_bootstrap_max_bytes: FPL_BOOTSTRAP_MAX_BYTES,
    fpl_bootstrap_max_age_ms: FPL_BOOTSTRAP_MAX_AGE_MS,
    fpl_bootstrap_daily_refresh_hour_uk: FPL_BOOTSTRAP_DAILY_REFRESH_HOUR_UK,
    fpl_bootstrap_daily_refresh_minute_uk: FPL_BOOTSTRAP_DAILY_REFRESH_MINUTE_UK,
    fpl_bootstrap_next_daily_refresh_at: fantasyBootstrapNextDailyRefreshAt,
    fpl_bootstrap_last_updated: fantasyBootstrapLastUpdated,
    fpl_bootstrap_age_seconds: Number.isFinite(fantasyBootstrapAgeSeconds())
      ? Math.floor(fantasyBootstrapAgeSeconds())
      : null,
    fpl_bootstrap_stale: isFantasyBootstrapStale(),
    fpl_bootstrap_payload_bytes: fantasyBootstrapPayloadBytes,
    fpl_bootstrap_events_count: fantasyBootstrapEventsCount,
    fpl_bootstrap_current_event_id:
      fantasyBootstrapCurrentEvent && fantasyBootstrapCurrentEvent.id
        ? fantasyBootstrapCurrentEvent.id
        : null,
    fpl_bootstrap_next_event_id:
      fantasyBootstrapNextEvent && fantasyBootstrapNextEvent.id
        ? fantasyBootstrapNextEvent.id
        : null,
    fpl_bootstrap_updating: fantasyBootstrapUpdating,
    fpl_bootstrap_game_updating: fantasyBootstrapGameUpdating,
    fpl_bootstrap_game_updating_message: fantasyBootstrapGameUpdatingMessage,
    fpl_bootstrap_game_updating_detected_at: fantasyBootstrapGameUpdatingDetectedAt,
    fpl_fixtures_source_url: FPL_FIXTURES_SOURCE_URL,
    fpl_fixtures_interval_ms: FPL_FIXTURES_INTERVAL_MS,
    fpl_fixtures_timeout_ms: FPL_FIXTURES_TIMEOUT_MS,
    fpl_fixtures_max_bytes: FPL_FIXTURES_MAX_BYTES,
    fpl_fixtures_count: cachedFantasyFixtures.length,
    fpl_fixtures_payload_bytes: fantasyFixturesPayloadBytes,
    fpl_fixtures_last_updated: fantasyFixturesLastUpdated,
    fpl_fixtures_updating: fantasyFixturesUpdating,
    fpl_fixtures_last_success_at: fantasyFixturesLastSuccessAt,
    fpl_fixtures_last_failure_at: fantasyFixturesLastFailureAt,
    fpl_transfer_recommendation_requests_total: fantasyTransferRecommendationRequestsTotal,
    fpl_transfer_recommendation_failures_total: fantasyTransferRecommendationFailuresTotal,
    league_tables_count: leagueTablesDataset.items.length,
    league_tables_rows_count: leagueTableRowsCount(leagueTablesDataset.items),
    league_tables_last_updated: leagueTablesDataset.updated_at || leagueTablesLastUpdated,
    league_tables_output_path: path.resolve(LEAGUE_TABLES_OUTPUT_PATH),
    league_tables_interval_ms: LEAGUE_TABLES_INTERVAL_MS,
    club_elo_count: clubEloDataset.items.length,
    club_elo_last_updated: clubEloDataset.updated_at || clubEloLastUpdated,
    club_elo_base_url: CLUB_ELO_BASE_URL,
    club_elo_output_path: path.resolve(CLUB_ELO_OUTPUT_PATH),
    club_elo_timezone: CLUB_ELO_TIMEZONE,
    club_elo_interval_ms: CLUB_ELO_INTERVAL_MS,
    club_elo_min_rows: CLUB_ELO_MIN_ROWS,
    club_elo_min_bytes: CLUB_ELO_MIN_BYTES,
    club_elo_match_min_confidence: CLUB_ELO_MATCH_MIN_CONFIDENCE,
    club_elo_manual_mappings_path: path.resolve(CLUB_ELO_MANUAL_MAPPINGS_PATH),
    club_elo_manual_mappings_count: manualClubEloMappings.size,
    club_elo_updating: clubEloUpdating,
    club_elo_redis_ttl_seconds: CLUB_ELO_REDIS_TTL_SECONDS,
    club_elo_fixtures_count: cachedClubEloFixtures.length,
    club_elo_fixtures_last_updated: clubEloFixturesLastUpdated,
    club_elo_fixtures_base_url: CLUB_ELO_FIXTURES_URL,
    club_elo_fixtures_output_path: path.resolve(CLUB_ELO_FIXTURES_OUTPUT_PATH),
    club_elo_fixtures_interval_ms: CLUB_ELO_FIXTURES_INTERVAL_MS,
    club_elo_fixtures_min_rows: CLUB_ELO_FIXTURES_MIN_ROWS,
    club_elo_fixtures_min_bytes: CLUB_ELO_FIXTURES_MIN_BYTES,
    club_elo_fixtures_updating: clubEloFixturesUpdating,
    club_elo_fixtures_last_matched_count: clubEloFixturesLastMatchedCount,
    club_elo_fixtures_last_unmatched_count: clubEloFixturesLastUnmatchedCount,
    club_elo_fixtures_match_min_confidence: CLUB_ELO_FIXTURES_MATCH_MIN_CONFIDENCE,
    club_elo_fixtures_match_min_team_confidence: CLUB_ELO_FIXTURES_MATCH_MIN_TEAM_CONFIDENCE,
    football_database_count: footballDatabaseDataset.items.length,
    football_database_last_updated:
      footballDatabaseDataset.updated_at || footballDatabaseLastUpdated,
    football_database_base_url: FOOTBALL_DATABASE_BASE_URL,
    football_database_output_path: path.resolve(FOOTBALL_DATABASE_OUTPUT_PATH),
    football_database_interval_ms: FOOTBALL_DATABASE_INTERVAL_MS,
    football_database_concurrency: FOOTBALL_DATABASE_CONCURRENCY,
    football_database_min_rows: FOOTBALL_DATABASE_MIN_ROWS,
    football_database_max_pages: FOOTBALL_DATABASE_MAX_PAGES,
    football_database_retry_attempts: FOOTBALL_DATABASE_RETRY_ATTEMPTS,
    football_database_retry_backoff_base_ms: FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS,
    football_database_retry_backoff_max_ms: FOOTBALL_DATABASE_RETRY_BACKOFF_MAX_MS,
    football_database_retry_backoff_factor: FOOTBALL_DATABASE_RETRY_BACKOFF_FACTOR,
    football_database_retry_jitter_ms: FOOTBALL_DATABASE_RETRY_JITTER_MS,
    football_database_adaptive_concurrency_enabled:
      FOOTBALL_DATABASE_ADAPTIVE_CONCURRENCY_ENABLED,
    football_database_adaptive_min_concurrency: FOOTBALL_DATABASE_ADAPTIVE_MIN_CONCURRENCY,
    football_database_match_min_confidence: FOOTBALL_DATABASE_MATCH_MIN_CONFIDENCE,
    football_database_manual_target_min_confidence:
      FOOTBALL_DATABASE_MANUAL_TARGET_MIN_CONFIDENCE,
    football_database_updating: footballDatabaseUpdating,
    football_database_redis_ttl_seconds: FOOTBALL_DATABASE_REDIS_TTL_SECONDS,
    national_elo_count: nationalEloDataset.items.length,
    national_elo_last_updated: nationalEloDataset.updated_at || nationalEloLastUpdated,
    national_elo_base_url: NATIONAL_ELO_BASE_URL,
    national_elo_page: NATIONAL_ELO_PAGE,
    national_elo_output_path: path.resolve(NATIONAL_ELO_OUTPUT_PATH),
    national_elo_interval_ms: NATIONAL_ELO_INTERVAL_MS,
    national_elo_min_rows: NATIONAL_ELO_MIN_ROWS,
    national_elo_min_bytes: NATIONAL_ELO_MIN_BYTES,
    national_elo_retry_attempts: NATIONAL_ELO_RETRY_ATTEMPTS,
    national_elo_retry_backoff_base_ms: NATIONAL_ELO_RETRY_BACKOFF_BASE_MS,
    national_elo_retry_backoff_max_ms: NATIONAL_ELO_RETRY_BACKOFF_MAX_MS,
    national_elo_retry_backoff_factor: NATIONAL_ELO_RETRY_BACKOFF_FACTOR,
    national_elo_retry_jitter_ms: NATIONAL_ELO_RETRY_JITTER_MS,
    national_elo_prefer_ipv4: NATIONAL_ELO_PREFER_IPV4,
    national_elo_user_agent: NATIONAL_ELO_USER_AGENT,
    national_elo_match_min_confidence: NATIONAL_ELO_MATCH_MIN_CONFIDENCE,
    national_elo_updating: nationalEloUpdating,
    national_elo_redis_ttl_seconds: NATIONAL_ELO_REDIS_TTL_SECONDS,
    team_ranking_default_source: TEAM_RANKING_DEFAULT_SOURCE,
    team_ranking_default_elo: TEAM_RANKING_DEFAULT_ELO,
    recent_count: recentDataset.items.length,
    recent_last_updated: recentDataset.updated_at || recentLastUpdated,
    recent_output_path: path.resolve(RECENT_OUTPUT_PATH),
    recent_cache_hours: RECENT_CACHE_HOURS,
    match_details_count:
      Number.isFinite(matchDetailsSummary.total) && matchDetailsSummary.total > 0
        ? matchDetailsSummary.total
        : matchDetailsSnapshot.total,
    match_details_last_updated:
      matchDetailsSummary.updated_at || matchDetailsSnapshot.updated_at || matchDetailsLastUpdated,
    match_details_poll_interval_ms: MATCH_DETAILS_POLL_INTERVAL_MS,
    match_details_poll_concurrency: MATCH_DETAILS_POLL_CONCURRENCY,
    match_details_stale_in_progress_ms: MATCH_DETAILS_STALE_IN_PROGRESS_MS,
    match_details_stale_minute_threshold: MATCH_DETAILS_STALE_MINUTE_THRESHOLD,
    match_details_updating: matchDetailsUpdating,
    match_details_needs_enrichment_count: needsEnrichmentCount,
    match_details_needs_status_refresh_count: needsStatusRefreshCount,
    match_details_backfill_candidates_count: needsBackfillCount,
    match_details_backfill_batch_size: MATCH_DETAILS_BACKFILL_BATCH_SIZE,
    missing_team_logos_count: missingTeamLogosByKey.size,
    missing_team_logos_last_updated: missingTeamLogosLastUpdated,
    missing_team_logos_output_path: path.resolve(MISSING_TEAM_LOGOS_OUTPUT_PATH),
    app_api_data_source: APP_DATA_SOURCE,
    app_api_cache_only: true,
    app_metrics_last_updated: appMetricEventsLastUpdated,
    app_metrics_events_total: appUsageMetrics.appMetricEventsTotal,
    app_metrics_events_rejected_total: appUsageMetrics.appMetricEventsRejectedTotal,
    app_metrics_unique_devices_total: seenDeviceTokens.size,
    app_metrics_active_devices_total: activeDeviceCount(),
    app_metrics_active_window_ms: APP_METRICS_ACTIVE_DEVICE_WINDOW_MS,
    api_requests_total: appUsageMetrics.apiRequestsTotal,
    api_requests_with_device_token_total: appUsageMetrics.apiRequestsWithDeviceTokenTotal,
    api_requests_without_device_token_total: appUsageMetrics.apiRequestsWithoutDeviceTokenTotal,
    competition_allowlist: SERVER_CONFIG.competitionAllowlist,
    operational_state_source: {
      merged_matches: mergedDataset.source,
      live_matches: liveDataset.source,
      bbc_live_matches: bbcLiveDataset.source,
      bbc_range_matches: bbcRangeDataset.source,
      recent_matches: recentDataset.source,
      premier_league_teams: teamsDataset.source,
      league_tables: leagueTablesDataset.source,
      club_elo_teams: clubEloDataset.source,
      club_elo_fixtures:
        clubEloFixturesLastUpdated ? SOURCE_CLUB_ELO_FIXTURES : null,
      football_database_teams: footballDatabaseDataset.source,
      national_elo_teams: nationalEloDataset.source,
      match_details: matchDetailsSnapshot.source,
      fpl_bootstrap: "memory_cache",
    },
  });
});

loadFromDisk();
loadBbcFromDisk();
loadBbcRangeFromDisk();
loadRecentFromDisk();
loadPremierLeagueFromDisk();
loadLeagueTablesFromDisk();
loadClubEloFromDisk();
loadClubEloFixturesFromDisk();
loadFootballDatabaseFromDisk();
loadNationalEloFromDisk();
// ===== User Preferences Redis Endpoints =====
const {
  getClient,
  saveUserPreferences,
  updateUserLiveActivityState,
  getUserPreferences,
  deleteUserPreferences,
  getAllUserPreferences,
  getFantasyReminderRecord,
  getFantasyReminderRecords,
  getBbcMatchHistoryGrouped,
  getLiveActivityDebugRecords,
  getBbcRealtimeSnapshot,
  cleanupBbcHistory,
  saveOperationalDataset,
  getOperationalDataset,
  getOperationalDatasets,
  saveLiveActivityMatchTimelineSnapshots,
  saveOperationalMatchDetailsRecords,
  getOperationalMatchDetails,
  getAllOperationalMatchDetails,
  getOperationalMatchDetailsSummary,
  __historyConfig: bbcHistoryConfig,
} = require("./redis_client");

// Save user preferences
app.post(`${API_PREFIX}/preferences`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken, preferences, apnsToken, isDevelopmentBuild, liveActivity, fantasy } = req.body;
  const resolvedDeviceToken = req.deviceToken || normalizeDeviceToken(deviceToken);

  if (!resolvedDeviceToken) {
    res.status(400).json({
      error: "Missing device token (X-Device-Token header or deviceToken body field).",
    });
    return;
  }

  try {
    const hasFantasyPatch = Object.prototype.hasOwnProperty.call(req.body || {}, "fantasy");
    const clearsFantasyState = hasFantasyPatch && fantasy === null;
    const saved = await saveUserPreferences(
      resolvedDeviceToken,
      preferences,
      apnsToken,
      typeof isDevelopmentBuild === "boolean" ? isDevelopmentBuild : false,
      {
        fantasy,
        liveActivity:
          {
            ...(liveActivity && typeof liveActivity === "object" ? liveActivity : {}),
            ...(clearsFantasyState
              ? {
                  lastPayloadHash: null,
                  lastScoreHash: null,
                }
              : {}),
          },
      }
    );
    if (hasFantasyPatch) {
      void matchMonitor.runLiveActivityEvaluationNow({
        userDeviceToken: resolvedDeviceToken,
        trigger: "preferences_fantasy_sync",
        forceDispatch: true,
      }).catch((error) => {
        console.warn("[API] Fantasy preference sync reconcile failed:", error.message || error);
      });
    }
    res.status(200).json({
      success: true,
      data: saved,
    });
  } catch (error) {
    console.error("[API] Error saving preferences:", error);
    res.status(500).json({
      error: "Failed to save preferences",
      message: error.message,
    });
  }
});

// Save push-to-start token used to server-trigger Live Activities.
app.post(`${API_PREFIX}/live-activity/push-to-start-token`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken, pushToStartToken, isDevelopmentBuild } = req.body || {};
  const resolvedDeviceToken = req.deviceToken || normalizeDeviceToken(deviceToken);
  const normalizedToken = normalizeLiveActivityToken(pushToStartToken);

  if (!resolvedDeviceToken) {
    res.status(400).json({
      error: "Missing device token (X-Device-Token header or deviceToken body field).",
    });
    return;
  }
  if (!normalizedToken) {
    res.status(400).json({
      error: "Missing or invalid pushToStartToken.",
    });
    return;
  }

  try {
    const nowIso = new Date().toISOString();
    const saved = await updateUserLiveActivityState(
      resolvedDeviceToken,
      {
        pushToStartToken: normalizedToken,
        pushToStartTokenUpdatedAt: nowIso,
      },
      {
        isDevelopmentBuild: typeof isDevelopmentBuild === "boolean" ? isDevelopmentBuild : undefined,
      }
    );
    res.status(200).json({
      success: true,
      data: saved,
    });
  } catch (error) {
    console.error("[API] Error saving push-to-start token:", error);
    res.status(500).json({
      error: "Failed to save push-to-start token",
      message: error.message,
    });
  }
});

// Save active Live Activity push token so server can send update/end events.
app.post(`${API_PREFIX}/live-activity/activity-token`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken, activityId, activityPushToken, isDevelopmentBuild } = req.body || {};
  const resolvedDeviceToken = req.deviceToken || normalizeDeviceToken(deviceToken);
  const normalizedActivityId = normalizeDeviceToken(activityId);
  const normalizedActivityPushToken = normalizeLiveActivityToken(activityPushToken);

  if (!resolvedDeviceToken) {
    res.status(400).json({
      error: "Missing device token (X-Device-Token header or deviceToken body field).",
    });
    return;
  }
  if (!normalizedActivityId || !normalizedActivityPushToken) {
    res.status(400).json({
      error: "Missing or invalid activityId/activityPushToken.",
    });
    return;
  }

  try {
    const existingRecord = await getUserPreferences(resolvedDeviceToken);
    const resolvedIsDevelopmentBuild =
      typeof isDevelopmentBuild === "boolean"
        ? isDevelopmentBuild
        : Boolean(existingRecord && existingRecord.isDevelopmentBuild);
    const duplicateResolution = await endSupersededLiveActivityIfNeeded({
      existingRecord,
      deviceToken: resolvedDeviceToken,
      activityId: normalizedActivityId,
      activityPushToken: normalizedActivityPushToken,
      isDevelopmentBuild: resolvedIsDevelopmentBuild,
    });
    if (
      duplicateResolution.reason === "end_failed" &&
      duplicateResolution.result &&
      duplicateResolution.result.success === false
    ) {
      res.status(502).json({
        error: "Failed to end superseded live activity",
        message:
          duplicateResolution.result.error || "Server could not enforce a single live activity.",
        previousActivityId: duplicateResolution.previousActivityId || null,
      });
      return;
    }

    const nowIso = new Date().toISOString();
    const saved = await updateUserLiveActivityState(
      resolvedDeviceToken,
      {
        currentActivityId: normalizedActivityId,
        currentActivityPushToken: normalizedActivityPushToken,
        currentActivityTokenUpdatedAt: nowIso,
        pendingStartAt: null,
      },
      {
        isDevelopmentBuild:
          typeof isDevelopmentBuild === "boolean" ? isDevelopmentBuild : undefined,
      }
    );
    const activeResult = liveActivityMetrics.markActivityActive({
      deviceToken: resolvedDeviceToken,
      activityId: normalizedActivityId,
      isDevelopmentBuild: resolvedIsDevelopmentBuild,
    });
    if (activeResult.changed) {
      liveActivityMetrics.recordPush({
        event: "arrival_confirmation",
        status: "success",
        isDevelopmentBuild: resolvedIsDevelopmentBuild,
      });
    }
    res.status(200).json({
      success: true,
      duplicateResolution,
      data: saved,
    });
  } catch (error) {
    console.error("[API] Error saving activity push token:", error);
    res.status(500).json({
      error: "Failed to save activity push token",
      message: error.message,
    });
  }
});

// Mark the current Live Activity as ended for this device.
app.post(`${API_PREFIX}/live-activity/activity-ended`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken, activityId, isDevelopmentBuild, reason } = req.body || {};
  const resolvedDeviceToken = req.deviceToken || normalizeDeviceToken(deviceToken);
  const normalizedActivityId = normalizeDeviceToken(activityId);

  if (!resolvedDeviceToken) {
    res.status(400).json({
      error: "Missing device token (X-Device-Token header or deviceToken body field).",
    });
    return;
  }

  try {
    const nowIso = new Date().toISOString();
    const patch = {
      currentActivityPushToken: null,
      pendingStartAt: null,
      lastPayloadHash: null,
      lastScoreHash: null,
      lastMode: null,
      lastEndedAt: nowIso,
      testHoldUntil: null,
    };
    if (normalizedActivityId) {
      patch.currentActivityId = normalizedActivityId;
    } else {
      patch.currentActivityId = null;
    }
    const saved = await updateUserLiveActivityState(
      resolvedDeviceToken,
      patch,
      {
        isDevelopmentBuild: typeof isDevelopmentBuild === "boolean" ? isDevelopmentBuild : undefined,
      }
    );
    const removedActivity = liveActivityMetrics.markActivityInactive({ deviceToken: resolvedDeviceToken });
    if (removedActivity) {
      liveActivityMetrics.recordEnd({
        isDevelopmentBuild:
          typeof isDevelopmentBuild === "boolean"
            ? isDevelopmentBuild
            : removedActivity.buildType === "development",
        reason: String(reason || "user"),
      });
    }
    res.status(200).json({
      success: true,
      data: saved,
    });
  } catch (error) {
    console.error("[API] Error marking live activity as ended:", error);
    res.status(500).json({
      error: "Failed to mark live activity as ended",
      message: error.message,
    });
  }
});

// Clear the stored current Live Activity token/id for a device so the next reconcile
// can push-to-start a fresh activity from the saved push-to-start token.
app.post(`${API_PREFIX}/live-activity/restart`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const explicitDeviceToken =
    typeof req.body?.userDeviceToken === "string" ? req.body.userDeviceToken : req.body?.deviceToken;
  const resolvedDeviceToken = req.deviceToken || normalizeDeviceToken(explicitDeviceToken);

  if (!resolvedDeviceToken) {
    res.status(400).json({
      error: "Missing user device token. Provide X-Device-Token header or userDeviceToken/deviceToken body field.",
    });
    return;
  }

  try {
    const record = await getUserPreferences(resolvedDeviceToken);
    if (!record) {
      res.status(404).json({
        error: "No preferences found for user device token.",
        userDeviceToken: resolvedDeviceToken,
      });
      return;
    }

    const liveActivityState =
      record.liveActivity && typeof record.liveActivity === "object" ? record.liveActivity : {};
    const pushToStartToken = normalizeLiveActivityToken(liveActivityState.pushToStartToken);
    if (!pushToStartToken) {
      res.status(400).json({
        error: "No push-to-start token is stored for this device, so the activity cannot be restarted from the server.",
        userDeviceToken: resolvedDeviceToken,
      });
      return;
    }

    await updateUserLiveActivityState(
      resolvedDeviceToken,
      {
        currentActivityPushToken: null,
        currentActivityId: null,
        pendingStartAt: null,
        lastPayloadHash: null,
        lastScoreHash: null,
        lastMode: null,
      },
      {
        isDevelopmentBuild:
          typeof record.isDevelopmentBuild === "boolean" ? record.isDevelopmentBuild : undefined,
      }
    );
    if (liveActivityMetrics.markActivityInactive({ deviceToken: resolvedDeviceToken })) {
      liveActivityMetrics.recordEnd({
        isDevelopmentBuild: Boolean(record.isDevelopmentBuild),
        reason: "restart",
      });
    }

    const reconcileResult = await matchMonitor.runLiveActivityEvaluationNow({
      forceDispatch: true,
      preserveExistingOnEmpty: false,
    });

    res.status(200).json({
      success: true,
      restarted: true,
      userDeviceToken: resolvedDeviceToken,
      reconcile: reconcileResult,
    });
  } catch (error) {
    console.error("[API] Error restarting live activity:", error);
    res.status(500).json({
      error: "Failed to restart live activity",
      message: error.message,
    });
  }
});

// Get user preferences
app.get(`${API_PREFIX}/preferences/:deviceToken`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken } = req.params;

  if (!deviceToken) {
    res.status(400).json({
      error: "Missing deviceToken parameter",
    });
    return;
  }

  try {
    const data = await getUserPreferences(deviceToken);

    if (!data) {
      res.status(404).json({
        error: "Preferences not found for this device",
      });
      return;
    }

    res.status(200).json({
      success: true,
      data,
    });
  } catch (error) {
    console.error("[API] Error retrieving preferences:", error);
    res.status(500).json({
      error: "Failed to retrieve preferences",
      message: error.message,
    });
  }
});

// Delete user preferences
app.delete(`${API_PREFIX}/preferences/:deviceToken`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken } = req.params;

  if (!deviceToken) {
    res.status(400).json({
      error: "Missing deviceToken parameter",
    });
    return;
  }

  try {
    const deleted = await deleteUserPreferences(deviceToken);

    if (!deleted) {
      res.status(404).json({
        error: "Preferences not found for this device",
      });
      return;
    }

    res.status(200).json({
      success: true,
      message: "Preferences deleted successfully",
    });
  } catch (error) {
    console.error("[API] Error deleting preferences:", error);
    res.status(500).json({
      error: "Failed to delete preferences",
      message: error.message,
    });
  }
});

// Get all user preferences (admin endpoint)
app.get(`${API_PREFIX}/preferences`, async (_req, res) => {
  setCacheOnlyHeaders(res);

  try {
    const allPreferences = await getAllUserPreferences();

    res.status(200).json({
      success: true,
      count: allPreferences.length,
      data: allPreferences,
    });
  } catch (error) {
    console.error("[API] Error retrieving all preferences:", error);
    res.status(500).json({
      error: "Failed to retrieve all preferences",
      message: error.message,
    });
  }
});

function normalizePreferenceFilterText(value) {
  if (typeof value !== "string") return "";
  return value.trim().toLowerCase().slice(0, 200);
}

function sortPreferencesByUpdatedAtDescending(records) {
  return records.slice().sort((lhs, rhs) => {
    const lhsTs = Date.parse(lhs && lhs.updatedAt ? lhs.updatedAt : "");
    const rhsTs = Date.parse(rhs && rhs.updatedAt ? rhs.updatedAt : "");
    const safeLhsTs = Number.isFinite(lhsTs) ? lhsTs : 0;
    const safeRhsTs = Number.isFinite(rhsTs) ? rhsTs : 0;
    return safeRhsTs - safeLhsTs;
  });
}

function preferenceObjectToSearchText(preferences) {
  if (!preferences || typeof preferences !== "object") return "";
  try {
    return JSON.stringify(preferences).toLowerCase();
  } catch (_error) {
    return "";
  }
}

const ADMIN_DEVICE_SUFFIX_LENGTH = 8;
const ADMIN_DEVICE_NOTIFICATIONS_LIMIT = 100;
const ADMIN_DEVICE_LIST_PAGE_SIZE_MAX = 50;
const ADMIN_DEVICE_HISTORY_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

function normalizeAdminDeviceSuffix(value) {
  const normalized = String(value || "").trim().toLowerCase();
  if (!normalized) return "";
  if (!/^[a-z0-9]+$/.test(normalized)) return "";
  return normalized;
}

function deviceSuffixForAdmin(deviceToken) {
  const normalized = normalizeDeviceToken(deviceToken);
  if (!normalized) return "";
  return normalized.slice(-ADMIN_DEVICE_SUFFIX_LENGTH).toLowerCase();
}

function devicePreferenceRecordSearchText(record) {
  if (!record || typeof record !== "object") return "";
  const preferencesText = preferenceObjectToSearchText(record.preferences);
  const deviceToken = normalizeDeviceToken(record.deviceToken) || "";
  const apnsToken = normalizeDeviceToken(record.apnsToken) || "";
  const deviceName = extractDeviceNameFromPreferenceRecord(record) || "";
  const updatedAt = String(record.updatedAt || "").trim();
  const suffix = deviceSuffixForAdmin(deviceToken);
  return `${deviceToken} ${suffix} ${apnsToken} ${deviceName} ${updatedAt} ${preferencesText}`
    .trim()
    .toLowerCase();
}

function buildDeviceSuffixCounts(records) {
  const counts = new Map();
  (Array.isArray(records) ? records : []).forEach((record) => {
    const suffix = deviceSuffixForAdmin(record && record.deviceToken);
    if (!suffix) return;
    counts.set(suffix, (counts.get(suffix) || 0) + 1);
  });
  return counts;
}

function summarizeAdminDeviceRecord(record, suffixCounts = new Map()) {
  const deviceToken = normalizeDeviceToken(record && record.deviceToken);
  const apnsToken = normalizeDeviceToken(record && record.apnsToken);
  const preferences =
    record && record.preferences && typeof record.preferences === "object" ? record.preferences : {};
  const suffix = deviceSuffixForAdmin(deviceToken);
  const deviceName = extractDeviceNameFromPreferenceRecord(record);

  return {
    device_token: deviceToken,
    device_token_short: shortDeviceTokenForAdmin(deviceToken),
    device_token_suffix: suffix || null,
    suffix_collision_count: suffix ? suffixCounts.get(suffix) || 0 : 0,
    admin_path: suffix ? `/admin/devices/${suffix}` : null,
    admin_resolved_path:
      suffix && deviceToken
        ? `/admin/devices/${suffix}?device_token=${encodeURIComponent(deviceToken)}`
        : null,
    apns_token_present: Boolean(apnsToken),
    apns_token_short: apnsToken ? shortDeviceTokenForAdmin(apnsToken, 10, 8) : null,
    is_development_build: Boolean(record && record.isDevelopmentBuild),
    updated_at: record && record.updatedAt ? record.updatedAt : null,
    device_name: deviceName,
    notifications_enabled: preferences.notificationsEnabled === true,
    english_premier_league_teams_only: preferences.englishPremierLeagueTeamsOnly === true,
    competition_filter_enabled: preferences.competitionFilterEnabled === true,
    notification_use_viewing_filter: preferences.notificationUseViewingFilter !== false,
    selected_leagues_count: Array.isArray(preferences.selectedLeagues)
      ? preferences.selectedLeagues.length
      : 0,
    notification_selected_leagues_count: Array.isArray(preferences.notificationSelectedLeagues)
      ? preferences.notificationSelectedLeagues.length
      : 0,
  };
}

function buildAdminDeviceNotificationEntry(record) {
  const matchContext = record && record.match && typeof record.match === "object" ? record.match : {};
  return {
    notification_id: record && record.notification_id ? String(record.notification_id) : null,
    timestamp_ms: adminHistoryTimestampMs(record && record.timestamp_ms),
    timestamp: record && record.timestamp ? record.timestamp : null,
    status: normalizeNotificationStatusForAdmin(record && record.status),
    event_type: record && record.event_type ? String(record.event_type) : "unknown",
    event_key: record && record.event_key ? String(record.event_key) : null,
    title: record && record.title ? String(record.title) : null,
    body: record && record.body ? String(record.body) : null,
    delay_minutes: Number.isFinite(Number(record && record.delay_minutes))
      ? Number(record.delay_minutes)
      : 0,
    dispatch_mode: record && record.dispatch_mode ? String(record.dispatch_mode) : null,
    environment: record && record.environment ? String(record.environment) : null,
    error: record && record.error ? String(record.error) : null,
    apns_result_success: Boolean(record && record.apns_result_success),
    match_id: record && record.match_id ? String(record.match_id) : null,
    match_label:
      matchContext.home_team && matchContext.away_team
        ? `${matchContext.home_team} vs ${matchContext.away_team}`
        : null,
    match: {
      league: matchContext.league || null,
      home_team: matchContext.home_team || null,
      away_team: matchContext.away_team || null,
      date: matchContext.date || null,
      time: matchContext.time || null,
    },
    payload: record,
  };
}

function buildAdminDeviceNotificationStatusCounts(records) {
  return (Array.isArray(records) ? records : []).reduce((acc, record) => {
    const key = normalizeNotificationStatusForAdmin(record && record.status);
    acc[key] = (acc[key] || 0) + 1;
    return acc;
  }, {});
}

function adminAgeSeconds(isoValue, nowMs = Date.now()) {
  const parsed = Date.parse(String(isoValue || "").trim());
  if (!Number.isFinite(parsed)) return null;
  return Math.max(0, Math.round((nowMs - parsed) / 1000));
}

function buildAdminLiveActivityDebugEntry(record, nowMs = Date.now()) {
  const contentState =
    record && record.content_state && typeof record.content_state === "object"
      ? record.content_state
      : null;
  const matches = Array.isArray(contentState && contentState.matches) ? contentState.matches : [];
  return {
    record_id: record && record.record_id ? String(record.record_id) : null,
    timestamp_ms: adminHistoryTimestampMs(record && record.timestamp_ms),
    timestamp: record && record.timestamp ? String(record.timestamp) : null,
    age_seconds: adminAgeSeconds(record && record.timestamp, nowMs),
    record_type: record && record.record_type ? String(record.record_type) : "unknown",
    dispatch_kind: record && record.dispatch_kind ? String(record.dispatch_kind) : null,
    decision_type: record && record.decision_type ? String(record.decision_type) : null,
    decision_reason: record && record.decision_reason ? String(record.decision_reason) : null,
    status: record && record.status ? String(record.status) : null,
    mode: record && record.mode ? String(record.mode) : null,
    trigger: record && record.trigger ? String(record.trigger) : null,
    environment: record && record.environment ? String(record.environment) : null,
    elapsed_ms:
      record && Number.isFinite(Number(record.elapsed_ms)) ? Number(record.elapsed_ms) : null,
    dispatch_started_at:
      record && record.dispatch_started_at ? String(record.dispatch_started_at) : null,
    dispatch_completed_at:
      record && record.dispatch_completed_at ? String(record.dispatch_completed_at) : null,
    payload_hash: record && record.payload_hash ? String(record.payload_hash) : null,
    score_hash: record && record.score_hash ? String(record.score_hash) : null,
    last_mode: record && record.last_mode ? String(record.last_mode) : null,
    last_payload_hash: record && record.last_payload_hash ? String(record.last_payload_hash) : null,
    last_score_hash: record && record.last_score_hash ? String(record.last_score_hash) : null,
    last_dispatch_at: record && record.last_dispatch_at ? String(record.last_dispatch_at) : null,
    current_activity_id:
      record && record.current_activity_id ? String(record.current_activity_id) : null,
    push_token_kind: record && record.push_token_kind ? String(record.push_token_kind) : null,
    pending_start_at: record && record.pending_start_at ? String(record.pending_start_at) : null,
    pending_age_seconds:
      record && Number.isFinite(Number(record.pending_age_seconds))
        ? Number(record.pending_age_seconds)
        : null,
    pending_max_seconds:
      record && Number.isFinite(Number(record.pending_max_seconds))
        ? Number(record.pending_max_seconds)
        : null,
    hold_until: record && record.hold_until ? String(record.hold_until) : null,
    error: record && record.error ? String(record.error) : null,
    is_terminal: Boolean(record && record.is_terminal),
    match_count: matches.length,
    match_ids: matches
      .map((match) => String(match && match.matchId ? match.matchId : "").trim())
      .filter(Boolean),
    payload: record && record.raw_payload ? record.raw_payload : null,
    content_state: contentState,
    raw_record: record,
  };
}

function buildAdminLiveActivityDebugSummary(records) {
  return (Array.isArray(records) ? records : []).reduce((acc, record) => {
    const key = String(
      record && record.record_type === "push"
        ? `push:${record.dispatch_kind || "unknown"}:${record.status || "unknown"}`
        : `${record && record.record_type ? record.record_type : "unknown"}:${record && record.decision_type ? record.decision_type : "unknown"}`
    );
    acc[key] = (acc[key] || 0) + 1;
    return acc;
  }, {});
}

function summarizeAdminLiveActivityState(record, nowMs = Date.now()) {
  const liveActivity =
    record && record.liveActivity && typeof record.liveActivity === "object" ? record.liveActivity : {};
  return {
    push_to_start_token_present: Boolean(
      liveActivity.pushToStartToken && String(liveActivity.pushToStartToken).trim()
    ),
    push_to_start_token_updated_at: liveActivity.pushToStartTokenUpdatedAt || null,
    push_to_start_token_age_seconds: adminAgeSeconds(
      liveActivity.pushToStartTokenUpdatedAt,
      nowMs
    ),
    current_activity_id: liveActivity.currentActivityId || null,
    current_activity_push_token_present: Boolean(
      liveActivity.currentActivityPushToken && String(liveActivity.currentActivityPushToken).trim()
    ),
    current_activity_token_updated_at: liveActivity.currentActivityTokenUpdatedAt || null,
    current_activity_token_age_seconds: adminAgeSeconds(
      liveActivity.currentActivityTokenUpdatedAt,
      nowMs
    ),
    pending_start_at: liveActivity.pendingStartAt || null,
    pending_start_age_seconds: adminAgeSeconds(liveActivity.pendingStartAt, nowMs),
    last_payload_hash: liveActivity.lastPayloadHash || null,
    last_score_hash: liveActivity.lastScoreHash || null,
    last_mode: liveActivity.lastMode || null,
    last_dispatch_at: liveActivity.lastDispatchAt || null,
    last_dispatch_age_seconds: adminAgeSeconds(liveActivity.lastDispatchAt, nowMs),
    last_start_at: liveActivity.lastStartAt || null,
    last_start_age_seconds: adminAgeSeconds(liveActivity.lastStartAt, nowMs),
    last_ended_at: liveActivity.lastEndedAt || null,
    last_ended_age_seconds: adminAgeSeconds(liveActivity.lastEndedAt, nowMs),
    test_hold_until: liveActivity.testHoldUntil || null,
    test_hold_active:
      adminAgeSeconds(liveActivity.testHoldUntil, nowMs) !== null &&
      Date.parse(String(liveActivity.testHoldUntil || "").trim()) > nowMs,
    raw_state: liveActivity,
  };
}

async function buildAdminLiveActivityPreview(record, nowMs = Date.now()) {
  const hooks = matchMonitor && matchMonitor.__testHooks ? matchMonitor.__testHooks : null;
  if (
    !hooks ||
    typeof hooks.monitoredMatchStatesSnapshot !== "function" ||
    typeof hooks.buildLiveActivityEntriesForUser !== "function" ||
    typeof hooks.buildLiveActivityPresentationForUser !== "function" ||
    typeof hooks.buildLiveActivityContentState !== "function" ||
    typeof hooks.combineLiveActivityOperationalMatches !== "function" ||
    typeof hooks.enrichLiveActivityOperationalMatches !== "function"
  ) {
    return null;
  }

  const [mergedDataset, recentDataset] = await Promise.all([
    getOperationalDataset("merged_matches"),
    getOperationalDataset("recent_matches"),
  ]);
  const matchDetailsSnapshot = currentFastMatchDetailsLookupSnapshot("admin_live_activity_preview");
  const detailsRecords = matchDetailsSnapshot && matchDetailsSnapshot.lookup
    ? matchDetailsSnapshot.lookup
    : {};
  const operationalMatches = hooks.combineLiveActivityOperationalMatches(
    hooks.enrichLiveActivityOperationalMatches(
      mergedDataset && Array.isArray(mergedDataset.payload) ? mergedDataset.payload : [],
      detailsRecords
    ),
    hooks.enrichLiveActivityOperationalMatches(
      recentDataset && Array.isArray(recentDataset.payload) ? recentDataset.payload : [],
      detailsRecords
    )
  );
  const monitoredEntries = hooks.monitoredMatchStatesSnapshot(nowMs);
  const entries = hooks.buildLiveActivityEntriesForUser(
    record,
    monitoredEntries,
    operationalMatches,
    nowMs
  );
  const presentation = hooks.buildLiveActivityPresentationForUser(record, entries, nowMs);
  const contentState =
    presentation && presentation.mode
      ? hooks.buildLiveActivityContentState(
        presentation.mode,
        presentation.matches,
        presentation.delayMinutes,
        nowMs,
        presentation.fantasyCurrentScore
      )
      : null;

  return {
    generated_at: new Date(nowMs).toISOString(),
    monitored_entry_count: Array.isArray(monitoredEntries) ? monitoredEntries.length : 0,
    operational_match_count: Array.isArray(operationalMatches) ? operationalMatches.length : 0,
    built_entry_count: Array.isArray(entries) ? entries.length : 0,
    presentation,
    content_state: contentState,
  };
}

// Admin preferences query endpoint
app.get(`${API_PREFIX}/admin/preferences`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const deviceTokenFilter = normalizePreferenceFilterText(req.query.device_token);
  const preferenceFilter = normalizePreferenceFilterText(req.query.preference_text);
  const searchFilter = normalizePreferenceFilterText(req.query.q);
  const limit = parsePositiveInt(req.query.limit, 500, 1, 2000);

  try {
    const allPreferences = await getAllUserPreferences();
    const sorted = sortPreferencesByUpdatedAtDescending(allPreferences);

    const filtered = sorted.filter((record) => {
      const deviceToken = String(record && record.deviceToken ? record.deviceToken : "").toLowerCase();
      const apnsToken = String(record && record.apnsToken ? record.apnsToken : "").toLowerCase();
      const updatedAt = String(record && record.updatedAt ? record.updatedAt : "").toLowerCase();
      const preferencesText = preferenceObjectToSearchText(record && record.preferences);
      const searchable = `${deviceToken} ${apnsToken} ${updatedAt} ${preferencesText}`;

      if (deviceTokenFilter && !deviceToken.includes(deviceTokenFilter)) return false;
      if (preferenceFilter && !preferencesText.includes(preferenceFilter)) return false;
      if (searchFilter && !searchable.includes(searchFilter)) return false;
      return true;
    });

    const limited = filtered.slice(0, limit);

    res.status(200).json({
      success: true,
      count: limited.length,
      totalMatched: filtered.length,
      totalAvailable: sorted.length,
      limit,
      filters: {
        device_token: deviceTokenFilter || null,
        preference_text: preferenceFilter || null,
        q: searchFilter || null,
      },
      data: limited,
    });
  } catch (error) {
    console.error("[API] Error retrieving admin preferences:", error);
    res.status(500).json({
      error: "Failed to retrieve admin preferences",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/admin/devices`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const searchFilter = normalizePreferenceFilterText(req.query.q);
  const pageSize = parsePositiveInt(
    req.query.page_size,
    ADMIN_DEVICE_LIST_PAGE_SIZE_MAX,
    1,
    ADMIN_DEVICE_LIST_PAGE_SIZE_MAX
  );
  const requestedPage = parsePositiveInt(req.query.page, 1, 1, 100000);

  try {
    const allPreferences = await getAllUserPreferences();
    const sorted = sortPreferencesByUpdatedAtDescending(allPreferences);
    const filtered = sorted.filter((record) => {
      if (!searchFilter) return true;
      return devicePreferenceRecordSearchText(record).includes(searchFilter);
    });
    const suffixCounts = buildDeviceSuffixCounts(filtered);
    const totalPages = Math.max(1, Math.ceil(filtered.length / pageSize));
    const page = Math.min(requestedPage, totalPages);
    const startIndex = (page - 1) * pageSize;
    const pageRecords = filtered.slice(startIndex, startIndex + pageSize);

    res.status(200).json({
      success: true,
      generated_at: new Date().toISOString(),
      page,
      page_size: pageSize,
      total_pages: totalPages,
      total_matched: filtered.length,
      total_available: sorted.length,
      q: searchFilter || null,
      data: pageRecords.map((record) => summarizeAdminDeviceRecord(record, suffixCounts)),
    });
  } catch (error) {
    console.error("[API] Error retrieving admin devices:", error);
    res.status(500).json({
      error: "Failed to retrieve admin devices",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/admin/devices/:deviceSuffix`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const deviceSuffix = normalizeAdminDeviceSuffix(req.params.deviceSuffix);
  const explicitDeviceToken = normalizeDeviceToken(req.query.device_token);
  if (!deviceSuffix || deviceSuffix.length !== ADMIN_DEVICE_SUFFIX_LENGTH) {
    res.status(400).json({
      error: `Invalid device suffix. Expected the last ${ADMIN_DEVICE_SUFFIX_LENGTH} characters of the device token.`,
    });
    return;
  }

  try {
    const allPreferences = await getAllUserPreferences();
    const suffixCounts = buildDeviceSuffixCounts(allPreferences);
    const matches = allPreferences.filter((record) => deviceSuffixForAdmin(record && record.deviceToken) === deviceSuffix);
    const exactMatch = explicitDeviceToken
      ? matches.find((record) => normalizeDeviceToken(record && record.deviceToken) === explicitDeviceToken) || null
      : null;

    if (matches.length === 0 || (explicitDeviceToken && !exactMatch)) {
      res.status(404).json({
        error: "No device found for that suffix.",
        device_suffix: deviceSuffix,
        device_token: explicitDeviceToken || null,
      });
      return;
    }

    if (matches.length > 1 && !exactMatch) {
      res.status(409).json({
        error: "Device suffix is ambiguous.",
        device_suffix: deviceSuffix,
        matches: matches.map((record) => summarizeAdminDeviceRecord(record, suffixCounts)),
      });
      return;
    }

    const record = exactMatch || matches[0];
    const deviceToken = normalizeDeviceToken(record && record.deviceToken);
    const historySnapshot = await getBbcMatchHistoryGrouped({
      start_ms: Date.now() - ADMIN_DEVICE_HISTORY_WINDOW_MS,
      end_ms: Date.now(),
      device_token: deviceToken,
    });
    const historyMatches = Array.isArray(historySnapshot && historySnapshot.matches)
      ? historySnapshot.matches
      : [];
    const notificationRecords = historyMatches
      .flatMap((entry) => (Array.isArray(entry && entry.notifications) ? entry.notifications : []))
      .slice()
      .sort((lhs, rhs) => adminHistoryTimestampMs(rhs && rhs.timestamp_ms) - adminHistoryTimestampMs(lhs && lhs.timestamp_ms));
    const limitedNotifications = notificationRecords
      .slice(0, ADMIN_DEVICE_NOTIFICATIONS_LIMIT)
      .map(buildAdminDeviceNotificationEntry);
    const nowMs = Date.now();
    const liveActivityDebugRecords = await getLiveActivityDebugRecords({
      device_token: deviceToken,
      limit: 40,
      order: "desc",
    });
    const normalizedLiveActivityDebug = liveActivityDebugRecords.map((entry) =>
      buildAdminLiveActivityDebugEntry(entry, nowMs)
    );
    const liveActivityPushes = normalizedLiveActivityDebug
      .filter((entry) => entry.record_type === "push")
      .slice(0, 10);
    const liveActivityDecisions = normalizedLiveActivityDebug
      .filter((entry) => entry.record_type !== "push")
      .slice(0, 10);
    const liveActivityPreview = await buildAdminLiveActivityPreview(record, nowMs).catch(
      (error) => ({
        error: error.message || String(error),
      })
    );

    res.status(200).json({
      success: true,
      generated_at: new Date().toISOString(),
      device: summarizeAdminDeviceRecord(record, suffixCounts),
      preferences_record: record,
      history: {
        source: historySnapshot && historySnapshot.error ? "error" : "redis",
        error: historySnapshot && historySnapshot.error ? historySnapshot.error : null,
        window_start_ms: historySnapshot && historySnapshot.start_ms ? historySnapshot.start_ms : null,
        window_end_ms: historySnapshot && historySnapshot.end_ms ? historySnapshot.end_ms : null,
        total_notifications: notificationRecords.length,
        returned_notifications: limitedNotifications.length,
        status_counts: buildAdminDeviceNotificationStatusCounts(notificationRecords),
      },
      live_activity: {
        state: summarizeAdminLiveActivityState(record, nowMs),
        preview: liveActivityPreview,
        debug: {
          total_records_considered: normalizedLiveActivityDebug.length,
          pushes_returned: liveActivityPushes.length,
          decisions_returned: liveActivityDecisions.length,
          summary_counts: buildAdminLiveActivityDebugSummary(normalizedLiveActivityDebug),
          pushes: liveActivityPushes,
          decisions: liveActivityDecisions,
        },
      },
      notifications: limitedNotifications,
    });
  } catch (error) {
    console.error("[API] Error retrieving admin device details:", error);
    res.status(500).json({
      error: "Failed to retrieve admin device details",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/admin/fantasy-reminders`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const deviceTokenFilter = normalizeDeviceToken(req.query.device_token);
  const statusFilter =
    typeof req.query.status === "string" ? String(req.query.status).trim().toLowerCase() : "";
  const limitUpcoming = parsePositiveInt(req.query.limit_upcoming, 100, 1, 1000);
  const limitPast = parsePositiveInt(req.query.limit_past, 200, 1, 2000);
  const nowMs = Date.now();

  try {
    const records = await getFantasyReminderRecords({
      device_token: deviceTokenFilter || undefined,
      status: statusFilter || undefined,
      order: "desc",
    });
    const normalized = records.map((record) => buildAdminFantasyReminderEntry(record, nowMs));
    const upcoming = normalized
      .filter((record) => !record.is_past)
      .sort((lhs, rhs) => (lhs.scheduled_for_ms || 0) - (rhs.scheduled_for_ms || 0))
      .slice(0, limitUpcoming);
    const past = normalized
      .filter((record) => record.is_past)
      .sort((lhs, rhs) => (rhs.scheduled_for_ms || 0) - (lhs.scheduled_for_ms || 0))
      .slice(0, limitPast);
    const nextGameweek = buildNextFantasyReminderSummary(fantasyBootstrapNextEvent, nowMs);

    res.status(200).json({
      success: true,
      generated_at: new Date(nowMs).toISOString(),
      filters: {
        device_token: deviceTokenFilter || null,
        status: statusFilter || null,
        limit_upcoming: limitUpcoming,
        limit_past: limitPast,
      },
      next_gameweek: nextGameweek,
      summary: {
        total: normalized.length,
        upcoming: normalized.filter((record) => !record.is_past).length,
        past: normalized.filter((record) => record.is_past).length,
        status_counts: buildAdminFantasyReminderStatusCounts(records, nowMs),
      },
      upcoming,
      past,
    });
  } catch (error) {
    console.error("[API] Error retrieving fantasy reminder admin data:", error);
    res.status(500).json({
      error: "Failed to retrieve fantasy reminder admin data",
      message: error.message,
    });
  }
});

app.post(`${API_PREFIX}/admin/fantasy-reminders/:reminderId/test-send`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const reminderId = String(req.params.reminderId || "").trim();
  if (!reminderId) {
    res.status(400).json({ error: "Missing reminder id." });
    return;
  }

  try {
    const record = await getFantasyReminderRecord(reminderId);
    if (!record) {
      res.status(404).json({ error: "Reminder not found.", reminder_id: reminderId });
      return;
    }

    const result = await matchMonitor.sendFantasyDeadlineReminderNow(reminderId, {
      reason: "admin_test_send",
    });
    if (!result || !result.success) {
      res.status(409).json({
        error: result && result.error ? result.error : "Failed to send reminder test push.",
        reminder_id: reminderId,
        ...result,
      });
      return;
    }

    res.status(200).json({
      success: true,
      reminder_id: reminderId,
      ...result,
    });
  } catch (error) {
    console.error("[API] Error test-sending fantasy reminder:", error);
    res.status(500).json({
      error: "Failed to send fantasy reminder test push",
      message: error.message,
      reminder_id: reminderId,
    });
  }
});

app.get(`${API_PREFIX}/admin/fixtures`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const limit = parsePositiveInt(req.query.limit, 500, 1, 5000);

  try {
    const [mergedDataset, matchDetailsSnapshot] = await Promise.all([
      getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, mergedMatchesForResponse()),
      getOperationalMatchDetailsSnapshotSafe(),
    ]);

    const matches = filterAdminMatches(mergedDataset.items, {
      mode: "fixtures",
      matchDetailsLookup: matchDetailsSnapshot.records || {},
    });
    const limited = matches.slice(0, limit);

    res.status(200).json({
      success: true,
      mode: "fixtures",
      generated_at: new Date().toISOString(),
      count: limited.length,
      total_available: matches.length,
      limit,
      source: mergedDataset.source || "unknown",
      updated_at: mergedDataset.updated_at || null,
      matches: limited,
    });
  } catch (error) {
    console.error("[API] Error retrieving admin fixtures:", error);
    res.status(500).json({
      error: "Failed to retrieve admin fixtures",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/admin/results`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const limit = parsePositiveInt(req.query.limit, 500, 1, 5000);

  try {
    const [mergedDataset, matchDetailsSnapshot] = await Promise.all([
      getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, mergedMatchesForResponse()),
      getOperationalMatchDetailsSnapshotSafe(),
    ]);

    const matches = filterAdminMatches(mergedDataset.items, {
      mode: "results",
      matchDetailsLookup: matchDetailsSnapshot.records || {},
    });
    const limited = matches.slice(0, limit);

    res.status(200).json({
      success: true,
      mode: "results",
      generated_at: new Date().toISOString(),
      count: limited.length,
      total_available: matches.length,
      limit,
      source: mergedDataset.source || "unknown",
      updated_at: mergedDataset.updated_at || null,
      matches: limited,
    });
  } catch (error) {
    console.error("[API] Error retrieving admin results:", error);
    res.status(500).json({
      error: "Failed to retrieve admin results",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/admin/results/:matchId`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const matchId = normalizeMatchDetailsId(req.params.matchId);
  if (!matchId) {
    res.status(400).json({
      error: "Invalid match id. Expected BBC details id (e.g. c043pne0q3kt).",
    });
    return;
  }

  try {
    const [detailsLookup, mergedDataset, historySnapshot, allPreferences] = await Promise.all([
      getOperationalMatchDetailsByIdSafe(matchId),
      getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, mergedMatchesForResponse()),
      getBbcRealtimeSnapshot({ match_id: matchId, limit_matches: 1 }),
      getAllUserPreferences(),
    ]);

    const mergedItems = Array.isArray(mergedDataset.items) ? mergedDataset.items : [];
    const fallbackRawMatch = mergedItems.find((candidate) => {
      const detailsId =
        matchDetailsIdFromUrl(candidate && candidate.details_url) ||
        normalizeMatchDetailsId(candidate && candidate.match_details_id);
      return detailsId === matchId;
    });
    const fallbackMatchRecord = fallbackRawMatch ? normalizeMatchRecord(fallbackRawMatch) : null;
    const fallbackListPayload = fallbackRawMatch ? toAdminListMatchPayload(fallbackRawMatch) : null;

    const matchPayload = toAdminResultMatchPayload(
      detailsLookup.payload,
      fallbackMatchRecord,
      fallbackListPayload
    );
    if (!matchPayload) {
      res.status(404).json({
        error: "No cached match details found for match id.",
      });
      return;
    }

    const historyMatch = Array.isArray(historySnapshot && historySnapshot.matches)
      ? historySnapshot.matches.find((entry) => String(entry && entry.match_id) === matchId) || null
      : null;
    const eventRecords = Array.isArray(historyMatch && historyMatch.events)
      ? historyMatch.events.slice().sort(sortHistoryRecordsByTimestampAsc)
      : [];
    const notificationRecords = Array.isArray(historyMatch && historyMatch.notifications)
      ? historyMatch.notifications.slice().sort(sortHistoryRecordsByTimestampAsc)
      : [];

    const deviceTokenNameLookup = buildDeviceTokenNameLookup(allPreferences);
    const notificationDispatches = buildNotificationDispatches(
      notificationRecords,
      deviceTokenNameLookup
    );

    res.status(200).json({
      success: true,
      generated_at: new Date().toISOString(),
      match_id: matchId,
      match: matchPayload,
      match_timeline: buildMatchEventTimeline(matchPayload),
      match_source: {
        details: detailsLookup && detailsLookup.source ? detailsLookup.source : "unknown",
        merged_matches: mergedDataset && mergedDataset.source ? mergedDataset.source : "unknown",
      },
      history: {
        source: historySnapshot && historySnapshot.error ? "error" : "redis",
        error: historySnapshot && historySnapshot.error ? historySnapshot.error : null,
        count_events: eventRecords.length,
        count_notifications: notificationRecords.length,
        events: eventRecords,
        notifications: notificationRecords,
        notification_dispatches: notificationDispatches,
      },
      device_tokens_named_count: deviceTokenNameLookup.size,
    });
  } catch (error) {
    console.error("[API] Error retrieving admin result details:", error);
    res.status(500).json({
      error: "Failed to retrieve admin result details",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/admin/bbc-history`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const historyWindow = parseBbcHistoryWindow(req.query || {});
  if (historyWindow.error) {
    res.status(400).json({ error: historyWindow.error });
    return;
  }

  const rawMatchId = req.query.match_id ? String(req.query.match_id).trim() : "";
  const normalizedMatchId = rawMatchId ? normalizeMatchDetailsId(rawMatchId) : null;
  if (rawMatchId && !normalizedMatchId) {
    res.status(400).json({
      error: "Invalid match_id. Expected BBC details id (e.g. c043pne0q3kt).",
    });
    return;
  }

  const rawDeviceToken = req.query.device_token ? String(req.query.device_token).trim() : "";
  const normalizedDeviceToken = rawDeviceToken ? normalizeDeviceToken(rawDeviceToken) : "";
  if (rawDeviceToken && !normalizedDeviceToken) {
    res.status(400).json({
      error: "Invalid device_token filter.",
    });
    return;
  }

  try {
    const groupedHistory = await getBbcMatchHistoryGrouped({
      start_ms: historyWindow.startMs,
      end_ms: historyWindow.endMs,
      match_id: normalizedMatchId || undefined,
      device_token: normalizedDeviceToken || undefined,
    });

    const statusCode = groupedHistory.error ? 500 : 200;
    res.status(statusCode).json({
      success: !groupedHistory.error,
      window: {
        mode: historyWindow.mode,
        start_ms: historyWindow.startMs,
        end_ms: historyWindow.endMs,
        start: new Date(historyWindow.startMs).toISOString(),
        end: new Date(historyWindow.endMs).toISOString(),
        hours: historyWindow.hours || null,
        max_hours: MAX_BBC_HISTORY_QUERY_HOURS,
      },
      filters: {
        match_id: normalizedMatchId || null,
        device_token: normalizedDeviceToken || null,
      },
      history_config: {
        event_ttl_seconds: bbcHistoryConfig.event_ttl_seconds,
        notification_ttl_seconds: bbcHistoryConfig.notification_ttl_seconds,
        notification_idempotency_ttl_seconds:
          bbcHistoryConfig.notification_idempotency_ttl_seconds,
        user_preferences_ttl_seconds: bbcHistoryConfig.user_preferences_ttl_seconds,
      },
      ...groupedHistory,
    });
  } catch (error) {
    console.error("[API] Error retrieving BBC history:", error);
    res.status(500).json({
      error: "Failed to retrieve BBC history",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/admin/bbc-history/realtime`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const rawMatchId = req.query.match_id ? String(req.query.match_id).trim() : "";
  const normalizedMatchId = rawMatchId ? normalizeMatchDetailsId(rawMatchId) : null;
  if (rawMatchId && !normalizedMatchId) {
    res.status(400).json({
      error: "Invalid match_id. Expected BBC details id (e.g. c043pne0q3kt).",
    });
    return;
  }

  const rawDeviceToken = req.query.device_token ? String(req.query.device_token).trim() : "";
  const normalizedDeviceToken = rawDeviceToken ? normalizeDeviceToken(rawDeviceToken) : "";
  if (rawDeviceToken && !normalizedDeviceToken) {
    res.status(400).json({
      error: "Invalid device_token filter.",
    });
    return;
  }

  const limitMatches = parsePositiveInt(req.query.limit_matches, 0, 0, 1000);

  try {
    const [snapshot, operationalSnapshot] = await Promise.all([
      getBbcRealtimeSnapshot({
        match_id: normalizedMatchId || undefined,
        device_token: normalizedDeviceToken || undefined,
        limit_matches: limitMatches || undefined,
      }),
      getOperationalRealtimeSnapshot({
        match_id: normalizedMatchId || undefined,
        limit_matches: limitMatches || undefined,
      }),
    ]);

    const hasError = Boolean(
      (snapshot && snapshot.error) ||
      (operationalSnapshot && operationalSnapshot.error)
    );
    const statusCode = hasError ? 500 : 200;
    res.status(statusCode).json({
      success: !hasError,
      realtime: true,
      ...snapshot,
      operational: operationalSnapshot,
    });
  } catch (error) {
    console.error("[API] Error retrieving BBC realtime snapshot:", error);
    res.status(500).json({
      error: "Failed to retrieve BBC realtime snapshot",
      message: error.message,
    });
  }
});

app.post(`${API_PREFIX}/admin/bbc-history/cleanup`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const payload =
    req.body && typeof req.body === "object" && !Array.isArray(req.body)
      ? req.body
      : {};

  const parseBoolean = (value, fallback = false) => {
    if (value === undefined || value === null) return fallback;
    if (typeof value === "boolean") return value;
    const normalized = String(value).trim().toLowerCase();
    if (["1", "true", "yes", "on"].includes(normalized)) return true;
    if (["0", "false", "no", "off"].includes(normalized)) return false;
    return fallback;
  };

  const rawMatchIds = [];
  if (payload.match_id !== undefined && payload.match_id !== null) {
    rawMatchIds.push(payload.match_id);
  }
  if (Array.isArray(payload.match_ids)) {
    payload.match_ids.forEach((value) => rawMatchIds.push(value));
  } else if (typeof payload.match_ids === "string") {
    payload.match_ids
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean)
      .forEach((value) => rawMatchIds.push(value));
  }

  const normalizedMatchIds = [];
  const invalidMatchIds = [];
  rawMatchIds
    .map((value) => String(value || "").trim())
    .filter(Boolean)
    .forEach((value) => {
      const normalized = normalizeMatchDetailsId(value);
      if (!normalized) {
        invalidMatchIds.push(value);
        return;
      }
      if (!normalizedMatchIds.includes(normalized)) normalizedMatchIds.push(normalized);
    });

  if (invalidMatchIds.length > 0) {
    res.status(400).json({
      error: "Invalid match_ids. Expected BBC details ids (e.g. c043pne0q3kt).",
      invalid_match_ids: invalidMatchIds,
    });
    return;
  }

  const rawDeviceToken =
    payload.device_token !== undefined && payload.device_token !== null
      ? String(payload.device_token).trim()
      : "";
  const normalizedDeviceToken = rawDeviceToken ? normalizeDeviceToken(rawDeviceToken) : "";
  if (rawDeviceToken && !normalizedDeviceToken) {
    res.status(400).json({
      error: "Invalid device_token filter.",
    });
    return;
  }

  const rawStart = payload.start ? String(payload.start).trim() : "";
  const rawEnd = payload.end ? String(payload.end).trim() : "";
  let startMs = null;
  let endMs = null;
  if (rawStart || rawEnd) {
    if (!rawStart || !rawEnd) {
      res.status(400).json({
        error: "When using absolute range cleanup, both start and end are required (ISO datetime).",
      });
      return;
    }
    startMs = Date.parse(rawStart);
    endMs = Date.parse(rawEnd);
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs)) {
      res.status(400).json({
        error: "Invalid cleanup start/end datetime. Use ISO format.",
      });
      return;
    }
    if (endMs < startMs) {
      res.status(400).json({
        error: "Invalid cleanup date range. end must be greater than or equal to start.",
      });
      return;
    }
    if (endMs - startMs > MAX_BBC_HISTORY_QUERY_MS) {
      res.status(400).json({
        error: `Maximum cleanup query range is ${MAX_BBC_HISTORY_QUERY_HOURS} hours (7 days).`,
      });
      return;
    }
  }

  const dryRun = parseBoolean(payload.dry_run, true);
  const allowAll = parseBoolean(payload.allow_all, false);
  const hasAnyFilter = normalizedMatchIds.length > 0 || Boolean(normalizedDeviceToken) || rawStart || rawEnd;
  if (!hasAnyFilter && !allowAll) {
    res.status(400).json({
      error:
        "Cleanup requires at least one filter (match_id(s), device_token, or start/end) unless allow_all=true.",
    });
    return;
  }

  try {
    const cleanupResult = await cleanupBbcHistory({
      match_ids: normalizedMatchIds,
      device_token: normalizedDeviceToken || undefined,
      start_ms: Number.isFinite(startMs) ? startMs : undefined,
      end_ms: Number.isFinite(endMs) ? endMs : undefined,
      dry_run: dryRun,
    });

    const statusCode = cleanupResult.error ? 500 : 200;
    res.status(statusCode).json({
      success: !cleanupResult.error,
      cleanup: cleanupResult,
      history_config: bbcHistoryConfig,
    });
  } catch (error) {
    console.error("[API] Error cleaning BBC history:", error);
    res.status(500).json({
      error: "Failed to cleanup BBC history",
      message: error.message,
    });
  }
});

app.post(`${API_PREFIX}/admin/bbc-state/backfill-range`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const payload =
    req.body && typeof req.body === "object" && !Array.isArray(req.body)
      ? req.body
      : {};

  const parseBoolean = (value, fallback = false) => {
    if (value === undefined || value === null) return fallback;
    if (typeof value === "boolean") return value;
    const normalized = String(value).trim().toLowerCase();
    if (["1", "true", "yes", "on"].includes(normalized)) return true;
    if (["0", "false", "no", "off"].includes(normalized)) return false;
    return fallback;
  };

  const startDate = String(payload.start_date || payload.start || "").trim();
  const endDate = String(payload.end_date || payload.end || "").trim();
  if (!startDate || !endDate) {
    res.status(400).json({
      error: "Missing required fields: start_date and end_date (YYYY-MM-DD).",
    });
    return;
  }
  if (!isDateOnly(startDate) || !isDateOnly(endDate)) {
    res.status(400).json({
      error: "Invalid date format. Expected YYYY-MM-DD for start_date and end_date.",
    });
    return;
  }
  if (startDate > endDate) {
    res.status(400).json({
      error: "Invalid date range. start_date must be on or before end_date.",
    });
    return;
  }

  const startMs = Date.parse(`${startDate}T00:00:00.000Z`);
  const endMs = Date.parse(`${endDate}T23:59:59.999Z`);
  const spanDays = Math.floor((endMs - startMs) / (24 * 60 * 60 * 1000)) + 1;
  const maxSpanDays = 366;
  if (spanDays > maxSpanDays) {
    res.status(400).json({
      error: `Date range too large. Maximum span is ${maxSpanDays} days.`,
    });
    return;
  }

  const concurrency = parsePositiveInt(
    payload.concurrency,
    BBC_RANGE_CONCURRENCY,
    1,
    50
  );
  const applyToRangeCache = parseBoolean(payload.apply_to_range_cache, true);
  const startedAtMs = Date.now();

  try {
    const fetchedMatches = filterMatchesByCompetition(
      await fetchBbcScoresFixturesByDateRange({
        baseUrl: BBC_RANGE_BASE_URL,
        startDate,
        endDate,
        concurrency,
        timeZone: BBC_RANGE_MATCH_TIMEZONE,
      })
    );

    let nextRangeMatches = fetchedMatches;
    let existingRangeCount = cachedBbcRangeMatches.length;
    if (applyToRangeCache) {
      const rangeDataset = await getOperationalArrayDataset(
        OP_DATASET_BBC_RANGE_MATCHES,
        cachedBbcRangeMatches
      );
      const existingRangeMatches = Array.isArray(rangeDataset.items) ? rangeDataset.items : [];
      existingRangeCount = existingRangeMatches.length;
      const outsideRequestedWindow = existingRangeMatches.filter((match) => {
        const date = String(match && match.date ? match.date : "").trim();
        if (!date || !isDateOnly(date)) return true;
        return date < startDate || date > endDate;
      });
      nextRangeMatches = mergeBbcAndLive(
        [...outsideRequestedWindow, ...fetchedMatches],
        []
      );
      nextRangeMatches = filterMatchesByCompetition(nextRangeMatches);

      cachedBbcRangeMatches = nextRangeMatches;
      bbcRangeLastUpdated = new Date().toISOString();
      setSourceCacheSize(SOURCE_BBC_RANGE, nextRangeMatches.length);
      writeBbcRangeMatches(BBC_RANGE_OUTPUT_PATH, nextRangeMatches);
      await persistOperationalDatasetSafe(OP_DATASET_BBC_RANGE_MATCHES, nextRangeMatches, {
        updated_at: bbcRangeLastUpdated,
        source: "admin_bbc_range_backfill",
      });
      await rebuildMergedMatchesCache("admin_bbc_range_backfill");
    }

    res.status(200).json({
      success: true,
      backfill: {
        start_date: startDate,
        end_date: endDate,
        span_days: spanDays,
        concurrency,
        apply_to_range_cache: applyToRangeCache,
        fetched_matches: fetchedMatches.length,
        existing_range_matches: existingRangeCount,
        updated_range_matches: nextRangeMatches.length,
        duration_ms: Date.now() - startedAtMs,
      },
      state: {
        bbc_range_last_updated: bbcRangeLastUpdated,
        bbc_range_count: cachedBbcRangeMatches.length,
      },
    });
  } catch (error) {
    console.error("[API] Error backfilling BBC range state:", error);
    res.status(500).json({
      error: "Failed to backfill BBC range state",
      message: error.message,
    });
  }
});

// ===== Push Notification & Live Activity Testing Endpoints =====
const { sendNotification, sendLiveActivityPush } = require("./apns_client");

const LIVE_ACTIVITY_TEST_MODES = new Set([
  "single_upcoming",
  "single_live",
  "single_finished",
  "multi_upcoming",
  "multi_live",
  "multi_finished",
  "ended",
]);
const LIVE_ACTIVITY_TEST_PENDING_START_MAX_SECONDS = 2 * 60;

function normalizeLiveActivityTestMode(value, fallback = "single_live") {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  if (LIVE_ACTIVITY_TEST_MODES.has(normalized)) return normalized;
  return fallback;
}

function normalizeLiveActivityTestDelay(value, fallback = 0) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(0, Math.min(10, Math.floor(parsed)));
}

function normalizeLiveActivityTestHoldSeconds(value, fallback = 300) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(30, Math.min(1800, Math.floor(parsed)));
}

function liveActivityNowTimeLabel(now = new Date()) {
  return now.toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

function normalizeLiveActivityTestMatch(rawMatch, index = 0, now = new Date()) {
  const match = rawMatch && typeof rawMatch === "object" ? rawMatch : {};
  const fallbackKickoff = liveActivityNowTimeLabel(now);
  const fallbackHome = index % 2 === 0 ? "Atalanta" : "Norwich City";
  const fallbackAway = index % 2 === 0 ? "Borussia Dortmund" : "Sheffield Wednesday";
  const homeTeamScore = Number(match.homeTeamScore ?? match.home_team_score);
  const awayTeamScore = Number(match.awayTeamScore ?? match.away_team_score);
  const explicitTotalTeamScore = Number(match.totalTeamScore ?? match.total_team_score);
  const totalTeamScore = Number.isFinite(explicitTotalTeamScore)
    ? explicitTotalTeamScore
    : (Number.isFinite(homeTeamScore) ? homeTeamScore : 0) +
      (Number.isFinite(awayTeamScore) ? awayTeamScore : 0);

  return {
    matchId: String(match.matchId || match.match_id || `test_match_${index + 1}`).trim(),
    date: String(match.date || now.toISOString().split("T")[0]).trim(),
    time: String(match.time || fallbackKickoff).trim(),
    league: String(match.league || "UEFA Champions League").trim(),
    leagueSubcategory:
      match.leagueSubcategory !== undefined && match.leagueSubcategory !== null
        ? String(match.leagueSubcategory).trim()
        : match.league_subcategory !== undefined && match.league_subcategory !== null
          ? String(match.league_subcategory).trim()
          : null,
    homeTeam: String(match.homeTeam || match.home_team || fallbackHome).trim(),
    awayTeam: String(match.awayTeam || match.away_team || fallbackAway).trim(),
    homeScore: Number.isFinite(Number(match.homeScore)) ? Number(match.homeScore) : null,
    awayScore: Number.isFinite(Number(match.awayScore)) ? Number(match.awayScore) : null,
    aggregateHomeScore: Number.isFinite(Number(match.aggregateHomeScore))
      ? Number(match.aggregateHomeScore)
      : Number.isFinite(Number(match.aggregate_home_score))
        ? Number(match.aggregate_home_score)
        : null,
    aggregateAwayScore: Number.isFinite(Number(match.aggregateAwayScore))
      ? Number(match.aggregateAwayScore)
      : Number.isFinite(Number(match.aggregate_away_score))
        ? Number(match.aggregate_away_score)
        : null,
    homeTeamScore: Number.isFinite(homeTeamScore) ? homeTeamScore : null,
    awayTeamScore: Number.isFinite(awayTeamScore) ? awayTeamScore : null,
    totalTeamScore: Number.isFinite(totalTeamScore) ? totalTeamScore : null,
    matchTime:
      match.matchTime !== undefined && match.matchTime !== null
        ? String(match.matchTime).trim()
        : null,
    tvChannels: Array.isArray(match.tvChannels || match.tv_channels)
      ? (match.tvChannels || match.tv_channels)
          .map((channel) => String(channel || "").trim())
          .filter(Boolean)
          .slice(0, 3)
      : ["TNT Sports 1"],
  };
}

function defaultLiveActivityTestMatches(mode, now = new Date()) {
  const timeLabel = liveActivityNowTimeLabel(now);
  if (mode === "single_upcoming") {
    return [
      normalizeLiveActivityTestMatch(
        {
          matchId: "test_upcoming_1",
          date: now.toISOString().split("T")[0],
          time: timeLabel,
          league: "UEFA Champions League",
          leagueSubcategory: "Round of 16",
          homeTeam: "Atalanta",
          awayTeam: "Borussia Dortmund",
          homeTeamScore: 1780,
          awayTeamScore: 1768,
          homeScore: null,
          awayScore: null,
          aggregateHomeScore: 2,
          aggregateAwayScore: 2,
          matchTime: null,
          tvChannels: ["TNT Sports 1"],
        },
        0,
        now
      ),
    ];
  }
  if (mode === "single_live") {
    return [
      normalizeLiveActivityTestMatch(
        {
          matchId: "test_live_1",
          date: now.toISOString().split("T")[0],
          time: timeLabel,
          league: "UEFA Champions League",
          leagueSubcategory: "Round of 16",
          homeTeam: "Atalanta",
          awayTeam: "Borussia Dortmund",
          homeTeamScore: 1780,
          awayTeamScore: 1768,
          homeScore: 1,
          awayScore: 0,
          aggregateHomeScore: 3,
          aggregateAwayScore: 2,
          matchTime: "7'",
          tvChannels: ["TNT Sports 1"],
        },
        0,
        now
      ),
    ];
  }
  if (mode === "single_finished") {
    return [
      normalizeLiveActivityTestMatch(
        {
          matchId: "test_finished_1",
          date: now.toISOString().split("T")[0],
          time: timeLabel,
          league: "UEFA Champions League",
          leagueSubcategory: "Round of 16",
          homeTeam: "Atalanta",
          awayTeam: "Borussia Dortmund",
          homeTeamScore: 1780,
          awayTeamScore: 1768,
          homeScore: 2,
          awayScore: 1,
          aggregateHomeScore: 4,
          aggregateAwayScore: 3,
          matchTime: "FT",
          tvChannels: ["TNT Sports 1"],
        },
        0,
        now
      ),
    ];
  }
  if (mode === "multi_upcoming") {
    return [
      normalizeLiveActivityTestMatch(
        {
          matchId: "test_multi_upcoming_1",
          date: now.toISOString().split("T")[0],
          time: "19:45",
          league: "Premier League",
          homeTeam: "Norwich City",
          awayTeam: "Sheffield Wednesday",
          homeTeamScore: 1442,
          awayTeamScore: 1413,
          tvChannels: ["Sky Sports Main Event"],
        },
        0,
        now
      ),
      normalizeLiveActivityTestMatch(
        {
          matchId: "test_multi_upcoming_2",
          date: now.toISOString().split("T")[0],
          time: "20:00",
          league: "UEFA Champions League",
          homeTeam: "Atalanta",
          awayTeam: "Borussia Dortmund",
          homeTeamScore: 1780,
          awayTeamScore: 1768,
          tvChannels: ["TNT Sports 1"],
        },
        1,
        now
      ),
    ];
  }
  if (mode === "ended") {
    return [];
  }
  if (mode === "multi_finished") {
    return defaultLiveActivityTestMatches("multi_live", now).map((match, index) => ({
      ...match,
      matchId: `test_multi_finished_${index + 1}`,
      matchTime: index === 2 ? "AET" : "FT",
    }));
  }
  return [
    normalizeLiveActivityTestMatch(
      {
        matchId: "test_multi_live_1",
        date: now.toISOString().split("T")[0],
        time: "19:45",
        league: "UEFA Champions League",
        leagueSubcategory: "Round of 16",
        homeTeam: "Atalanta",
        awayTeam: "Borussia Dortmund",
        homeTeamScore: 1780,
        awayTeamScore: 1768,
        homeScore: 2,
        awayScore: 0,
        aggregateHomeScore: 4,
        aggregateAwayScore: 2,
        matchTime: "45+2'",
        tvChannels: ["TNT Sports 1"],
      },
      0,
      now
    ),
    normalizeLiveActivityTestMatch(
      {
        matchId: "test_multi_live_2",
        date: now.toISOString().split("T")[0],
        time: "20:00",
        league: "Premier League",
        homeTeam: "Norwich City",
        awayTeam: "Sheffield Wednesday",
        homeTeamScore: 1442,
        awayTeamScore: 1413,
        homeScore: 1,
        awayScore: 1,
        matchTime: "55'",
        tvChannels: ["Sky Sports Main Event"],
      },
      1,
      now
    ),
    normalizeLiveActivityTestMatch(
      {
        matchId: "test_multi_live_3",
        date: now.toISOString().split("T")[0],
        time: "20:00",
        league: "UEFA Champions League",
        leagueSubcategory: "Round of 16",
        homeTeam: "Inter Milan",
        awayTeam: "Benfica",
        homeTeamScore: 1822,
        awayTeamScore: 1771,
        homeScore: 2,
        awayScore: 1,
        aggregateHomeScore: 3,
        aggregateAwayScore: 3,
        matchTime: "110'",
        tvChannels: ["TNT Sports 1"],
      },
      2,
      now
    ),
    normalizeLiveActivityTestMatch(
      {
        matchId: "test_multi_live_4",
        date: now.toISOString().split("T")[0],
        time: "20:00",
        league: "Premier League",
        homeTeam: "Arsenal",
        awayTeam: "Chelsea",
        homeTeamScore: 1911,
        awayTeamScore: 1823,
        homeScore: 3,
        awayScore: 2,
        matchTime: "78'",
        tvChannels: ["Sky Sports Main Event"],
      },
      3,
      now
    ),
    normalizeLiveActivityTestMatch(
      {
        matchId: "test_multi_live_5",
        date: now.toISOString().split("T")[0],
        time: "20:15",
        league: "UEFA Europa League",
        homeTeam: "Roma",
        awayTeam: "Leverkusen",
        homeTeamScore: 1795,
        awayTeamScore: 1912,
        homeScore: 1,
        awayScore: 1,
        matchTime: "67'",
        tvChannels: ["TNT Sports 1"],
      },
      4,
      now
    ),
    normalizeLiveActivityTestMatch(
      {
        matchId: "test_multi_live_6",
        date: now.toISOString().split("T")[0],
        time: "20:15",
        league: "FA Cup",
        homeTeam: "Liverpool",
        awayTeam: "Everton",
        homeTeamScore: 1961,
        awayTeamScore: 1704,
        homeScore: 0,
        awayScore: 1,
        matchTime: "52'",
        tvChannels: ["ITV1"],
      },
      5,
      now
    ),
    normalizeLiveActivityTestMatch(
      {
        matchId: "test_multi_live_7",
        date: now.toISOString().split("T")[0],
        time: "20:30",
        league: "UEFA Conference League",
        homeTeam: "Fiorentina",
        awayTeam: "Lille",
        homeTeamScore: 1750,
        awayTeamScore: 1754,
        homeScore: 1,
        awayScore: 0,
        matchTime: "61'",
        tvChannels: ["TNT Sports 2"],
      },
      6,
      now
    ),
    normalizeLiveActivityTestMatch(
      {
        matchId: "test_multi_live_8",
        date: now.toISOString().split("T")[0],
        time: "20:30",
        league: "EFL Cup",
        homeTeam: "Newcastle United",
        awayTeam: "Man City",
        homeTeamScore: 1848,
        awayTeamScore: 2001,
        homeScore: 2,
        awayScore: 2,
        matchTime: "84'",
        tvChannels: ["Sky Sports Football"],
      },
      7,
      now
    ),
    normalizeLiveActivityTestMatch(
      {
        matchId: "test_multi_live_9",
        date: now.toISOString().split("T")[0],
        time: "20:45",
        league: "Premier League",
        homeTeam: "Spurs",
        awayTeam: "West Ham",
        homeTeamScore: 1835,
        awayTeamScore: 1718,
        homeScore: 1,
        awayScore: 1,
        matchTime: "73'",
        tvChannels: ["Sky Sports Premier League"],
      },
      8,
      now
    ),
    normalizeLiveActivityTestMatch(
      {
        matchId: "test_multi_live_10",
        date: now.toISOString().split("T")[0],
        time: "20:45",
        league: "UEFA Champions League",
        homeTeam: "Real Madrid",
        awayTeam: "Bayern Munich",
        homeTeamScore: 1986,
        awayTeamScore: 1936,
        homeScore: 0,
        awayScore: 0,
        matchTime: "33'",
        tvChannels: ["TNT Sports 1"],
      },
      9,
      now
    ),
  ];
}

function cloneLiveActivityTestMatches(matches = []) {
  return matches.map((match) => ({
    ...match,
    tvChannels: Array.isArray(match.tvChannels) ? [...match.tvChannels] : [],
  }));
}

function makeUpcomingLiveActivityTestMatches(matches = []) {
  return cloneLiveActivityTestMatches(matches).map((match, index) => ({
    ...match,
    matchId: `${match.matchId || `test_upcoming_${index + 1}`}_upcoming`,
    homeScore: null,
    awayScore: null,
    matchTime: null,
  }));
}

function buildLiveActivityTestPresets(now = new Date()) {
  const singleUpcoming = cloneLiveActivityTestMatches(
    defaultLiveActivityTestMatches("single_upcoming", now)
  );
  const singleLive = cloneLiveActivityTestMatches(
    defaultLiveActivityTestMatches("single_live", now)
  );
  const singleFinished = cloneLiveActivityTestMatches(
    defaultLiveActivityTestMatches("single_finished", now)
  );
  const multiLive = cloneLiveActivityTestMatches(
    defaultLiveActivityTestMatches("multi_live", now)
  );
  const trailingUpcoming = makeUpcomingLiveActivityTestMatches(multiLive.slice(0, 4));
  const multiUpcoming = makeUpcomingLiveActivityTestMatches(multiLive.slice(0, 4));
  const multiFinished = cloneLiveActivityTestMatches(
    defaultLiveActivityTestMatches("multi_finished", now)
  );

  return [
    {
      id: "single_upcoming",
      label: "Single Upcoming",
      description: "One upcoming fixture with aggregate score and TV badge.",
      payload: {
        mode: "single_upcoming",
        matches: singleUpcoming,
      },
    },
    {
      id: "single_live",
      label: "Single Live",
      description: "One live match with no footer or trailing fixtures.",
      payload: {
        mode: "single_live",
        matches: singleLive,
      },
    },
    {
      id: "single_live_trailing",
      label: "Single Live + Trailing Fixtures",
      description: "Primary live match plus four upcoming fixtures beneath it.",
      payload: {
        mode: "single_live",
        matches: [...singleLive, ...trailingUpcoming],
      },
    },
    {
      id: "single_live_trailing_footer",
      label: "Single Live + Footer Stress",
      description:
        "Primary live match, four trailing upcoming fixtures, a delay banner, and a fantasy score.",
      payload: {
        mode: "single_live",
        delayMinutes: 8,
        fantasyCurrentScore: 63,
        matches: [...singleLive, ...trailingUpcoming],
      },
    },
    {
      id: "single_finished_trailing",
      label: "Single Finished + Trailing Fixtures",
      description: "A finished match with the upcoming-fixtures rail still visible underneath.",
      payload: {
        mode: "single_finished",
        matches: [...singleFinished, ...trailingUpcoming],
      },
    },
    {
      id: "multi_upcoming",
      label: "Multi Upcoming",
      description: "Four upcoming fixtures in the two-column multi-match layout.",
      payload: {
        mode: "multi_upcoming",
        matches: multiUpcoming,
      },
    },
    {
      id: "multi_live",
      label: "Multi Live",
      description: "Four simultaneous live fixtures in the standard multi-match layout.",
      payload: {
        mode: "multi_live",
        matches: multiLive.slice(0, 4),
      },
    },
    {
      id: "multi_live_dense",
      label: "Multi Live Dense",
      description: "Eight live fixtures with both delay and fantasy footer content.",
      payload: {
        mode: "multi_live",
        delayMinutes: 4,
        fantasyCurrentScore: 72,
        matches: multiLive.slice(0, 8),
      },
    },
    {
      id: "multi_finished",
      label: "Multi Finished",
      description: "Finished fixtures using the completed-match styling and opacity.",
      payload: {
        mode: "multi_finished",
        matches: multiFinished.slice(0, 6),
      },
    },
    {
      id: "ended",
      label: "Ended",
      description: "The empty ended state that the server sends when dismissing the Live Activity.",
      payload: {
        mode: "ended",
        matches: [],
      },
    },
  ];
}

function resolveLiveActivityTestPreset(presetId, now = new Date()) {
  const normalizedPresetId = String(presetId || "")
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  if (!normalizedPresetId) return null;
  return buildLiveActivityTestPresets(now).find((preset) => preset.id === normalizedPresetId) || null;
}

function buildLiveActivityTestContentState(payload = {}, now = new Date()) {
  const preset = resolveLiveActivityTestPreset(
    payload.presetId || payload.preset || payload.layoutPreset,
    now
  );
  const presetPayload = preset && preset.payload ? preset.payload : {};
  const rawMode =
    payload.mode !== undefined && payload.mode !== null ? payload.mode : presetPayload.mode;
  const mode = normalizeLiveActivityTestMode(rawMode, "single_live");
  const rawDelayMinutes =
    payload.delayMinutes !== undefined ? payload.delayMinutes : presetPayload.delayMinutes;
  const delayMinutes = normalizeLiveActivityTestDelay(rawDelayMinutes, 0);
  const providedMatches = Array.isArray(payload.matches)
    ? payload.matches
    : Array.isArray(presetPayload.matches)
      ? presetPayload.matches
      : [];
  const matchesSource =
    providedMatches.length > 0 ? providedMatches : defaultLiveActivityTestMatches(mode, now);
  const matches = matchesSource
    .map((match, index) => normalizeLiveActivityTestMatch(match, index, now))
    .slice(0, 10);
  const delayLabel =
    delayMinutes > 0 && mode.includes("live") ? `Delayed ${delayMinutes} m` : null;

  return {
    mode,
    generatedAtEpochSeconds: Math.floor(now.getTime() / 1000),
    delayMinutes,
    delayLabel,
    fantasyCurrentScore: Number.isFinite(
      Number(
        payload.fantasyCurrentScore !== undefined
          ? payload.fantasyCurrentScore
          : presetPayload.fantasyCurrentScore
      )
    )
      ? Number(
        payload.fantasyCurrentScore !== undefined
          ? payload.fantasyCurrentScore
          : presetPayload.fantasyCurrentScore
      )
      : null,
    matches,
  };
}

function resolveLiveActivityTestUserDeviceToken(req, body = {}) {
  const headerToken = req.deviceToken ? normalizeDeviceToken(req.deviceToken) : "";
  if (headerToken) return headerToken;
  const fromUserField = normalizeDeviceToken(body.userDeviceToken);
  if (fromUserField) return fromUserField;
  return normalizeDeviceToken(body.deviceToken);
}

async function endSupersededLiveActivityIfNeeded({
  existingRecord,
  deviceToken,
  activityId,
  activityPushToken,
  isDevelopmentBuild,
}) {
  const liveActivityState =
    existingRecord &&
    existingRecord.liveActivity &&
    typeof existingRecord.liveActivity === "object"
      ? existingRecord.liveActivity
      : {};
  const existingActivityId = normalizeDeviceToken(liveActivityState.currentActivityId);
  const existingActivityPushToken = normalizeLiveActivityToken(
    liveActivityState.currentActivityPushToken
  );

  if (!existingActivityPushToken) {
    return { endedExisting: false, reason: "no_existing_activity" };
  }
  if (
    existingActivityPushToken === activityPushToken &&
    (!existingActivityId || !activityId || existingActivityId === activityId)
  ) {
    return { endedExisting: false, reason: "same_activity" };
  }

  const timestamp = Math.floor(Date.now() / 1000);
  const result = await sendLiveActivityPush({
    token: existingActivityPushToken,
    event: "end",
    contentState: {
      mode: "ended",
      generatedAtEpochSeconds: timestamp,
      delayMinutes: 0,
      delayLabel: null,
      fantasyCurrentScore: null,
      matches: [],
    },
    dismissalDate: timestamp,
    isDevelopmentBuild,
  });

  if (result.success) {
    liveActivityMetrics.markActivityInactive({ deviceToken });
    liveActivityMetrics.recordEnd({
      isDevelopmentBuild,
      reason: "superseded",
    });
    return {
      endedExisting: true,
      reason: "superseded",
      previousActivityId: existingActivityId,
      result,
    };
  }

  if (isLiveActivityTerminalResult(result)) {
    liveActivityMetrics.markActivityInactive({ deviceToken });
    return {
      endedExisting: false,
      reason: "previous_activity_already_gone",
      previousActivityId: existingActivityId,
      result,
    };
  }

  return {
    endedExisting: false,
    reason: "end_failed",
    previousActivityId: existingActivityId,
    result,
  };
}

function isLiveActivityTerminalResult(result) {
  const message = String(result && result.error ? result.error : "").toLowerCase();
  if (!message) return false;
  return (
    message.includes("baddevicetoken") ||
    message.includes("unregistered") ||
    message.includes("device token not for topic")
  );
}

app.get(`${API_PREFIX}/live-activity/test/state`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const resolvedDeviceToken = resolveLiveActivityTestUserDeviceToken(req, req.query || {});
  if (!resolvedDeviceToken) {
    res.status(400).json({
      error: "Missing user device token. Provide X-Device-Token header or userDeviceToken query field.",
    });
    return;
  }

  try {
    const record = await getUserPreferences(resolvedDeviceToken);
    if (!record) {
      res.status(404).json({
        error: "No preferences found for user device token.",
        userDeviceToken: resolvedDeviceToken,
      });
      return;
    }

    let serverPresentation = null;
    try {
      const nowMs = Date.now();
      const [mergedDataset, recentDataset] = await Promise.all([
        getOperationalDataset("merged_matches"),
        getOperationalDataset("recent_matches"),
      ]);
      const hooks = matchMonitor && matchMonitor.__testHooks ? matchMonitor.__testHooks : null;
      if (
        hooks &&
        typeof hooks.monitoredMatchStatesSnapshot === "function" &&
        typeof hooks.buildLiveActivityEntriesForUser === "function" &&
        typeof hooks.buildLiveActivityPresentationForUser === "function" &&
        typeof hooks.combineLiveActivityOperationalMatches === "function" &&
        typeof hooks.enrichLiveActivityOperationalMatches === "function"
      ) {
        const matchDetailsSnapshot = currentFastMatchDetailsLookupSnapshot("live_activity_test_state");
        const detailsRecords = matchDetailsSnapshot && matchDetailsSnapshot.lookup
          ? matchDetailsSnapshot.lookup
          : {};
        const operationalMatches = hooks.combineLiveActivityOperationalMatches(
          hooks.enrichLiveActivityOperationalMatches(
            mergedDataset && Array.isArray(mergedDataset.payload) ? mergedDataset.payload : [],
            detailsRecords
          ),
          hooks.enrichLiveActivityOperationalMatches(
            recentDataset && Array.isArray(recentDataset.payload) ? recentDataset.payload : [],
            detailsRecords
          )
        );
        const monitoredEntries = hooks.monitoredMatchStatesSnapshot(nowMs);
        const entries = hooks.buildLiveActivityEntriesForUser(
          record,
          monitoredEntries,
          operationalMatches,
          nowMs
        );
        const presentation = hooks.buildLiveActivityPresentationForUser(record, entries, nowMs);
        serverPresentation = {
          mode: presentation && presentation.mode ? presentation.mode : null,
          delayMinutes:
            presentation && Number.isFinite(Number(presentation.delayMinutes))
              ? Number(presentation.delayMinutes)
              : 0,
          fantasyCurrentScore:
            presentation && Number.isFinite(Number(presentation.fantasyCurrentScore))
              ? Number(presentation.fantasyCurrentScore)
              : null,
          matches: Array.isArray(presentation && presentation.matches)
            ? presentation.matches.map((match) => ({
              matchId: match && match.match_details_id ? String(match.match_details_id) : "",
              homeTeam: match && match.home_team ? String(match.home_team) : "",
              awayTeam: match && match.away_team ? String(match.away_team) : "",
              homeScore:
                match && match.home_score !== undefined && match.home_score !== null
                  ? Number(match.home_score)
                  : null,
              awayScore:
                match && match.away_score !== undefined && match.away_score !== null
                  ? Number(match.away_score)
                  : null,
              matchTime: match && match.score_status ? String(match.score_status) : null,
            }))
            : [],
        };
      }
    } catch (presentationError) {
      serverPresentation = {
        error:
          presentationError && presentationError.message
            ? presentationError.message
            : String(presentationError || "unknown error"),
      };
    }

    res.status(200).json({
      success: true,
      userDeviceToken: resolvedDeviceToken,
      apnsTokenPresent: Boolean(record.apnsToken),
      isDevelopmentBuild: Boolean(record.isDevelopmentBuild),
      liveActivity: record.liveActivity || null,
      serverPresentation,
    });
  } catch (error) {
    res.status(500).json({
      error: "Failed to fetch live activity test state",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/live-activity/test/presets`, (_req, res) => {
  setCacheOnlyHeaders(res);

  const presets = buildLiveActivityTestPresets().map((preset) => {
    const payload = preset && preset.payload ? preset.payload : {};
    return {
      id: preset.id,
      label: preset.label,
      description: preset.description,
      mode: payload.mode || null,
      delayMinutes: Number.isFinite(Number(payload.delayMinutes))
        ? Number(payload.delayMinutes)
        : 0,
      fantasyCurrentScore: Number.isFinite(Number(payload.fantasyCurrentScore))
        ? Number(payload.fantasyCurrentScore)
        : null,
      matchCount: Array.isArray(payload.matches) ? payload.matches.length : 0,
    };
  });

  res.status(200).json({
    success: true,
    presets,
  });
});

app.post(`${API_PREFIX}/live-activity/test/start`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const payload =
    req.body && typeof req.body === "object" && !Array.isArray(req.body) ? req.body : {};
  const userDeviceToken = resolveLiveActivityTestUserDeviceToken(req, payload);
  if (!userDeviceToken) {
    res.status(400).json({
      error: "Missing user device token. Provide X-Device-Token header or userDeviceToken/deviceToken body field.",
    });
    return;
  }

  try {
    const record = await getUserPreferences(userDeviceToken);
    const liveActivityState =
      record && record.liveActivity && typeof record.liveActivity === "object"
        ? record.liveActivity
        : {};
    const explicitActivityPushToken = normalizeLiveActivityToken(payload.activityPushToken);
    const storedActivityPushToken = normalizeLiveActivityToken(
      liveActivityState.currentActivityPushToken
    );
    const activityPushToken = explicitActivityPushToken || storedActivityPushToken;
    const explicitPushToStartToken = normalizeLiveActivityToken(payload.pushToStartToken);
    const storedPushToStartToken = normalizeLiveActivityToken(
      liveActivityState.pushToStartToken
    );
    const pushToStartToken = explicitPushToStartToken || storedPushToStartToken;
    const forceStart = payload.forceStart === true;
    const contentState = buildLiveActivityTestContentState(payload);
    if (!pushToStartToken) {
      res.status(400).json({
        error:
          "No push-to-start token available. Ensure the app uploaded it or provide pushToStartToken in request body.",
      });
      return;
    }

    const isDevelopmentBuild =
      typeof payload.isDevelopmentBuild === "boolean"
        ? payload.isDevelopmentBuild
        : Boolean(record && record.isDevelopmentBuild);
    const title = String(payload.title || "Top Scores Test").trim();
    const body = String(payload.body || "Live Activity test start").trim();
    const timestamp = Math.floor(Date.now() / 1000);
    const fallbackStartOnUpdateFailure = payload.fallbackStartOnUpdateFailure === true;
    const testHoldSeconds = normalizeLiveActivityTestHoldSeconds(payload.testHoldSeconds, 300);
    const testHoldUntil = new Date((timestamp + testHoldSeconds) * 1000).toISOString();
    const pendingStartAtMs = Date.parse(String(liveActivityState.pendingStartAt || ""));
    const hasPendingStart = Number.isFinite(pendingStartAtMs);
    const pendingStartAgeSeconds = hasPendingStart
      ? Math.max(0, Math.floor(Date.now() / 1000 - pendingStartAtMs / 1000))
      : null;
    const pendingStartIsFresh =
      hasPendingStart &&
      pendingStartAgeSeconds !== null &&
      pendingStartAgeSeconds < LIVE_ACTIVITY_TEST_PENDING_START_MAX_SECONDS;

    if (hasPendingStart && !pendingStartIsFresh) {
      await updateUserLiveActivityState(
        userDeviceToken,
        {
          pendingStartAt: null,
          lastPayloadHash: null,
          lastScoreHash: null,
          lastMode: null,
          testHoldUntil: null,
        },
        {
          isDevelopmentBuild,
        }
      );
    }

    if (!activityPushToken && pendingStartIsFresh && !forceStart) {
      res.status(200).json({
        success: true,
        userDeviceToken,
        dispatch: "pending_start_in_progress",
        forceStart,
        testHoldSeconds,
        message:
          "A previous start is still pending activity token callback; skipping duplicate start to enforce a single active Live Activity.",
        pendingStartAgeSeconds,
        contentState,
      });
      return;
    }

    if (activityPushToken && !forceStart) {
      const updateResult = await sendLiveActivityPush({
        token: activityPushToken,
        event: "update",
        contentState,
        staleDate: timestamp + 30 * 60,
        isDevelopmentBuild,
      });

      if (updateResult.success) {
        await updateUserLiveActivityState(
          userDeviceToken,
          {
            pendingStartAt: null,
            lastMode: contentState.mode,
            lastDispatchAt: new Date().toISOString(),
            testHoldUntil,
          },
          {
            isDevelopmentBuild,
          }
        );
        res.status(200).json({
          success: true,
          userDeviceToken,
          dispatch: "update_existing",
          forceStart,
          testHoldSeconds,
          result: updateResult,
          contentState,
        });
        return;
      }

      const terminalUpdateFailure =
        Boolean(updateResult && updateResult.isTerminal) || isLiveActivityTerminalResult(updateResult);
      if (terminalUpdateFailure) {
        await updateUserLiveActivityState(
          userDeviceToken,
          {
            currentActivityPushToken: null,
            currentActivityId: null,
            pendingStartAt: null,
            lastMode: null,
            lastDispatchAt: new Date().toISOString(),
            testHoldUntil: null,
          },
          {
            isDevelopmentBuild,
          }
        );
      }

      if ((terminalUpdateFailure || fallbackStartOnUpdateFailure) && pushToStartToken) {
        const fallbackStartResult = await sendLiveActivityPush({
          token: pushToStartToken,
          event: "start",
          attributesType: "TopScoresLiveActivityAttributes",
          attributes: { appScope: "topscores" },
          contentState,
          staleDate: timestamp + 30 * 60,
          alert: {
            title,
            body,
          },
          isDevelopmentBuild,
        });

        if (fallbackStartResult.success) {
          await updateUserLiveActivityState(
            userDeviceToken,
            {
              pendingStartAt: new Date().toISOString(),
              lastStartAt: new Date().toISOString(),
              lastMode: contentState.mode,
              lastDispatchAt: new Date().toISOString(),
              testHoldUntil,
            },
            {
              isDevelopmentBuild,
            }
          );
        } else {
          const terminalFallbackStartFailure =
            Boolean(fallbackStartResult && fallbackStartResult.isTerminal) ||
            isLiveActivityTerminalResult(fallbackStartResult);
          if (terminalFallbackStartFailure) {
            await updateUserLiveActivityState(
              userDeviceToken,
              {
                pushToStartToken: null,
                pushToStartTokenUpdatedAt: null,
                pendingStartAt: null,
                lastPayloadHash: null,
                lastScoreHash: null,
                lastMode: null,
                lastDispatchAt: new Date().toISOString(),
                testHoldUntil: null,
              },
              {
                isDevelopmentBuild,
              }
            );
          }
        }

        res.status(fallbackStartResult.success ? 200 : 502).json({
          success: Boolean(fallbackStartResult.success),
          userDeviceToken,
          dispatch: "fallback_start_after_update_failure",
          forceStart,
          testHoldSeconds,
          updateResult,
          result: fallbackStartResult,
          contentState,
        });
        return;
      }

      res.status(502).json({
        success: false,
        userDeviceToken,
        dispatch: "update_existing_failed",
        forceStart,
        result: updateResult,
        contentState,
      });
      return;
    }

    if (activityPushToken && forceStart) {
      const endExistingResult = await sendLiveActivityPush({
        token: activityPushToken,
        event: "end",
        contentState: {
          mode: "ended",
          generatedAtEpochSeconds: timestamp,
          delayMinutes: 0,
          delayLabel: null,
          matches: [],
        },
        dismissalDate: timestamp,
        isDevelopmentBuild,
      });

      const terminalEndFailure =
        Boolean(endExistingResult && endExistingResult.isTerminal) ||
        isLiveActivityTerminalResult(endExistingResult);
      if (!endExistingResult.success && !terminalEndFailure) {
        res.status(502).json({
          success: false,
          userDeviceToken,
          dispatch: "force_start_failed_to_end_existing",
          forceStart,
          testHoldSeconds,
          result: endExistingResult,
          contentState,
        });
        return;
      }

      await updateUserLiveActivityState(
        userDeviceToken,
        {
          currentActivityPushToken: null,
          currentActivityId: null,
          pendingStartAt: null,
          lastPayloadHash: null,
          lastScoreHash: null,
          lastMode: null,
          lastDispatchAt: new Date().toISOString(),
          lastEndedAt: new Date().toISOString(),
          testHoldUntil: null,
        },
        {
          isDevelopmentBuild,
        }
      );
    }

    const result = await sendLiveActivityPush({
      token: pushToStartToken,
      event: "start",
      attributesType: "TopScoresLiveActivityAttributes",
      attributes: { appScope: "topscores" },
      contentState,
      staleDate: timestamp + 30 * 60,
      alert: {
        title,
        body,
      },
      isDevelopmentBuild,
    });

    if (result.success) {
      await updateUserLiveActivityState(
        userDeviceToken,
        {
          pendingStartAt: new Date().toISOString(),
          lastStartAt: new Date().toISOString(),
          lastMode: contentState.mode,
          lastDispatchAt: new Date().toISOString(),
          testHoldUntil,
        },
        {
          isDevelopmentBuild,
        }
      );
    } else {
      const terminalStartFailure =
        Boolean(result && result.isTerminal) || isLiveActivityTerminalResult(result);
      if (terminalStartFailure) {
        await updateUserLiveActivityState(
          userDeviceToken,
          {
            pushToStartToken: null,
            pushToStartTokenUpdatedAt: null,
            pendingStartAt: null,
            lastPayloadHash: null,
            lastScoreHash: null,
            lastMode: null,
            lastDispatchAt: new Date().toISOString(),
            testHoldUntil: null,
          },
          {
            isDevelopmentBuild,
          }
        );
      }
    }

    res.status(result.success ? 200 : 502).json({
      success: Boolean(result.success),
      userDeviceToken,
      dispatch: "start_new",
      forceStart,
      testHoldSeconds,
      result,
      contentState,
    });
  } catch (error) {
    res.status(500).json({
      error: "Failed to send live activity test start push",
      message: error.message,
    });
  }
});

app.post(`${API_PREFIX}/live-activity/test/update`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const payload =
    req.body && typeof req.body === "object" && !Array.isArray(req.body) ? req.body : {};
  const userDeviceToken = resolveLiveActivityTestUserDeviceToken(req, payload);
  if (!userDeviceToken) {
    res.status(400).json({
      error: "Missing user device token. Provide X-Device-Token header or userDeviceToken/deviceToken body field.",
    });
    return;
  }

  try {
    const record = await getUserPreferences(userDeviceToken);
    const explicitActivityPushToken = normalizeLiveActivityToken(payload.activityPushToken);
    const storedActivityPushToken = normalizeLiveActivityToken(
      record && record.liveActivity ? record.liveActivity.currentActivityPushToken : ""
    );
    const activityPushToken = explicitActivityPushToken || storedActivityPushToken;
    if (!activityPushToken) {
      res.status(400).json({
        error:
          "No activity push token available. Wait for app callback after start, or provide activityPushToken in request body.",
      });
      return;
    }

    const isDevelopmentBuild =
      typeof payload.isDevelopmentBuild === "boolean"
        ? payload.isDevelopmentBuild
        : Boolean(record && record.isDevelopmentBuild);
    const contentState = buildLiveActivityTestContentState(payload);
    const timestamp = Math.floor(Date.now() / 1000);

    const result = await sendLiveActivityPush({
      token: activityPushToken,
      event: "update",
      contentState,
      staleDate: timestamp + 30 * 60,
      isDevelopmentBuild,
    });

    if (result.success) {
      await updateUserLiveActivityState(
        userDeviceToken,
        {
          lastMode: contentState.mode,
          lastDispatchAt: new Date().toISOString(),
        },
        {
          isDevelopmentBuild,
        }
      );
    }

    res.status(result.success ? 200 : 502).json({
      success: Boolean(result.success),
      userDeviceToken,
      result,
      contentState,
    });
  } catch (error) {
    res.status(500).json({
      error: "Failed to send live activity test update push",
      message: error.message,
    });
  }
});

app.post(`${API_PREFIX}/live-activity/test/end`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const payload =
    req.body && typeof req.body === "object" && !Array.isArray(req.body) ? req.body : {};
  const userDeviceToken = resolveLiveActivityTestUserDeviceToken(req, payload);
  if (!userDeviceToken) {
    res.status(400).json({
      error: "Missing user device token. Provide X-Device-Token header or userDeviceToken/deviceToken body field.",
    });
    return;
  }

  try {
    const record = await getUserPreferences(userDeviceToken);
    const explicitActivityPushToken = normalizeLiveActivityToken(payload.activityPushToken);
    const storedActivityPushToken = normalizeLiveActivityToken(
      record && record.liveActivity ? record.liveActivity.currentActivityPushToken : ""
    );
    const activityPushToken = explicitActivityPushToken || storedActivityPushToken;
    const isDevelopmentBuild =
      typeof payload.isDevelopmentBuild === "boolean"
        ? payload.isDevelopmentBuild
        : Boolean(record && record.isDevelopmentBuild);

    if (!activityPushToken) {
      await updateUserLiveActivityState(
        userDeviceToken,
        {
          currentActivityPushToken: null,
          currentActivityId: null,
          pendingStartAt: null,
          lastMode: null,
          lastPayloadHash: null,
          lastScoreHash: null,
          lastEndedAt: new Date().toISOString(),
          testHoldUntil: null,
        },
        {
          isDevelopmentBuild,
        }
      );
      res.status(200).json({
        success: true,
        userDeviceToken,
        message: "No activity token found; state cleared.",
      });
      return;
    }

    const timestamp = Math.floor(Date.now() / 1000);
    const result = await sendLiveActivityPush({
      token: activityPushToken,
      event: "end",
      contentState: {
        mode: "ended",
        generatedAtEpochSeconds: timestamp,
        delayMinutes: 0,
        delayLabel: null,
        matches: [],
      },
      dismissalDate: timestamp,
      isDevelopmentBuild,
    });

    if (result.success) {
      await updateUserLiveActivityState(
        userDeviceToken,
        {
          currentActivityPushToken: null,
          currentActivityId: null,
          pendingStartAt: null,
          lastMode: null,
          lastPayloadHash: null,
          lastScoreHash: null,
          lastEndedAt: new Date().toISOString(),
          testHoldUntil: null,
        },
        {
          isDevelopmentBuild,
        }
      );
    }

    res.status(result.success ? 200 : 502).json({
      success: Boolean(result.success),
      userDeviceToken,
      result,
    });
  } catch (error) {
    res.status(500).json({
      error: "Failed to send live activity test end push",
      message: error.message,
    });
  }
});

// Send a test notification to a specific device
app.post(`${API_PREFIX}/notifications/test`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken, userDeviceToken, apnsToken, title, body, isDevelopmentBuild } = req.body || {};

  const normalizedLegacyDeviceToken =
    typeof deviceToken === "string" ? deviceToken.trim() : "";
  const normalizedUserDeviceToken =
    typeof userDeviceToken === "string" ? userDeviceToken.trim() : "";
  const normalizedProvidedAPNSToken =
    typeof apnsToken === "string" ? apnsToken.trim() : "";

  const looksLikeAPNSToken = (value) => /^[a-f0-9]{64,}$/i.test(value);

  let resolvedAPNSToken = normalizedProvidedAPNSToken;
  let resolvedIsDevelopmentBuild =
    typeof isDevelopmentBuild === "boolean" ? isDevelopmentBuild : false;
  let usedStoredAPNSToken = false;

  // Backward compatibility: legacy clients sent APNS token in `deviceToken`.
  if (!resolvedAPNSToken && normalizedLegacyDeviceToken && looksLikeAPNSToken(normalizedLegacyDeviceToken)) {
    resolvedAPNSToken = normalizedLegacyDeviceToken;
  }

  const lookupDeviceToken =
    normalizedUserDeviceToken ||
    (!looksLikeAPNSToken(normalizedLegacyDeviceToken) ? normalizedLegacyDeviceToken : "");

  if (!resolvedAPNSToken && lookupDeviceToken) {
    try {
      const stored = await getUserPreferences(lookupDeviceToken);
      if (stored && typeof stored.apnsToken === "string" && stored.apnsToken.trim()) {
        resolvedAPNSToken = stored.apnsToken.trim();
        usedStoredAPNSToken = true;
        if (
          typeof isDevelopmentBuild !== "boolean" &&
          typeof stored.isDevelopmentBuild === "boolean"
        ) {
          resolvedIsDevelopmentBuild = stored.isDevelopmentBuild;
        }
      }
    } catch (lookupError) {
      console.warn("[API] Failed to resolve APNS token from stored preferences:", lookupError);
    }
  }

  if (!resolvedAPNSToken) {
    res.status(400).json({
      error:
        "Missing APNS token. Provide `apnsToken` (or legacy APNS `deviceToken`) or a known `userDeviceToken` with synced preferences.",
    });
    return;
  }

  try {
    const result = await sendNotification(
      resolvedAPNSToken,
      title || "Test Notification",
      body || "This is a test notification from Top Scores API",
      {
        test: true,
        source: "manual_test",
        requested_at: new Date().toISOString(),
      },
      resolvedIsDevelopmentBuild
    );

    res.status(200).json({
      success: result.success,
      usedStoredAPNSToken,
      ...result,
    });
  } catch (error) {
    console.error("[API] Error sending test notification:", error);
    res.status(500).json({
      error: "Failed to send test notification",
      message: error.message,
    });
  }
});

// ===== End User Preferences Endpoints =====

async function seedOperationalStateFromDiskIfNeeded() {
  const [
    mergedDataset,
    clubEloDataset,
    footballDatabaseDataset,
    nationalEloDataset,
    cacheStateDataset,
    matchDetailsSummary,
  ] = await Promise.all([
    loadOperationalDatasetSafe(OP_DATASET_MERGED_MATCHES),
    loadOperationalDatasetSafe(OP_DATASET_CLUB_ELO_TEAMS),
    loadOperationalDatasetSafe(OP_DATASET_FOOTBALL_DATABASE_TEAMS),
    loadOperationalDatasetSafe(OP_DATASET_NATIONAL_ELO_TEAMS),
    loadOperationalDatasetSafe(OP_DATASET_CACHE_STATE),
    getOperationalMatchDetailsSummary(),
  ]);
  const hasMergedState =
    mergedDataset && Array.isArray(mergedDataset.payload) && mergedDataset.payload.length > 0;
  const hasMatchDetails = Number(matchDetailsSummary && matchDetailsSummary.total) > 0;
  const hasCacheState = Boolean(
    cacheStateDataset &&
      cacheStateDataset.payload &&
      typeof cacheStateDataset.payload === "object"
  );
  const hasClubEloState =
    clubEloDataset && Array.isArray(clubEloDataset.payload) && clubEloDataset.payload.length > 0;
  const hasClubEloSeedData = Array.isArray(cachedClubEloTeams) && cachedClubEloTeams.length > 0;
  const hasFootballDatabaseState =
    footballDatabaseDataset &&
    Array.isArray(footballDatabaseDataset.payload) &&
    footballDatabaseDataset.payload.length > 0;
  const hasFootballDatabaseSeedData =
    Array.isArray(cachedFootballDatabaseTeams) && cachedFootballDatabaseTeams.length > 0;
  const hasNationalEloState =
    nationalEloDataset && Array.isArray(nationalEloDataset.payload) && nationalEloDataset.payload.length > 0;
  const hasNationalEloSeedData =
    Array.isArray(cachedNationalEloTeams) && cachedNationalEloTeams.length > 0;
  const clubEloReady = hasClubEloState || !hasClubEloSeedData;
  const footballDatabaseReady =
    hasFootballDatabaseState || !hasFootballDatabaseSeedData;
  const nationalEloReady = hasNationalEloState || !hasNationalEloSeedData;
  if (
    hasMergedState &&
    hasMatchDetails &&
    hasCacheState &&
    clubEloReady &&
    footballDatabaseReady &&
    nationalEloReady
  ) {
    return { seeded: false, reason: "redis_has_state" };
  }

  await persistStartupOperationalStateFromDisk();
  return { seeded: true, reason: "redis_was_empty_or_partial" };
}

async function bootstrapOperationalState() {
  recordRuntimeComponentStart(COMPONENT_BOOTSTRAP, {
    operation: "bootstrap_operational_state",
  });
  loadMissingTeamLogosFromDisk();

  await hydrateOperationalStateFromRedis();
  const seedResult = await seedOperationalStateFromDiskIfNeeded();
  if (seedResult.seeded) {
    await hydrateOperationalStateFromRedis();
  }

  await updateRecentCache("startup_bootstrap");
  await rebuildMergedMatchesCache("startup_bootstrap");
  await rebuildMatchDetailsCache("startup_bootstrap");

  // Run network refresh tasks in background after bootstrapping cached state.
  void refreshInProgressMatchDetails({ trigger: "startup_bootstrap" });
  void updateMatches({ trigger: "startup_bootstrap" });
  void updateBbcMatches({ trigger: "startup_bootstrap" });
  void updateBbcRangeMatches({ trigger: "startup_bootstrap" });
  void updatePremierLeagueTeams({ trigger: "startup_bootstrap" });
  void updateLeagueTables({ trigger: "startup_bootstrap" });
  void updateClubEloTeams({ trigger: "startup_bootstrap" });
  void updateClubEloFixtures({ trigger: "startup_bootstrap" });
  void updateFootballDatabaseTeams({ trigger: "startup_bootstrap" });
  void updateNationalEloTeams({ trigger: "startup_bootstrap" });
  void updateFantasyBootstrapStatic({ trigger: "startup_bootstrap" });
  void updateFantasyFixtures({ trigger: "startup_bootstrap" });
  void updateFantasyEventLive({ trigger: "startup_bootstrap" });
  recordRuntimeComponentSuccess(COMPONENT_BOOTSTRAP, {
    operation: "bootstrap_operational_state",
    seed_result: seedResult,
    merged_matches: cachedMergedMatches.length,
    match_details: matchDetailsById.size,
  });
}

const shouldRunRuntime = require.main === module;
const operationalBootstrapPromise = shouldRunRuntime
  ? bootstrapOperationalState().catch((error) => {
    recordRuntimeComponentFailure(COMPONENT_BOOTSTRAP, error, {
      operation: "bootstrap_operational_state",
    });
    console.warn("[Startup] Operational bootstrap failed:", error.message || error);
  })
  : Promise.resolve();

if (shouldRunRuntime) {
  const interval = Number.isFinite(INTERVAL_MS) && INTERVAL_MS > 0 ? INTERVAL_MS : 30 * 60 * 1000;
  setInterval(() => {
    void updateMatches({ trigger: "interval" });
  }, interval);
  const bbcInterval = Number.isFinite(BBC_INTERVAL_MS) && BBC_INTERVAL_MS > 0 ? BBC_INTERVAL_MS : 30 * 1000;
  setInterval(() => {
    void updateBbcMatches({ trigger: "interval" });
  }, bbcInterval);
  const bbcRangeInterval =
    Number.isFinite(BBC_RANGE_INTERVAL_MS) && BBC_RANGE_INTERVAL_MS > 0
      ? BBC_RANGE_INTERVAL_MS
      : 60 * 60 * 1000;
  setInterval(() => {
    void updateBbcRangeMatches({ trigger: "interval" });
  }, bbcRangeInterval);
  const eplInterval =
    Number.isFinite(EPL_INTERVAL_MS) && EPL_INTERVAL_MS > 0 ? EPL_INTERVAL_MS : 24 * 60 * 60 * 1000;
  setInterval(() => {
    void updatePremierLeagueTeams({ trigger: "interval" });
  }, eplInterval);
  const leagueTablesInterval =
    Number.isFinite(LEAGUE_TABLES_INTERVAL_MS) && LEAGUE_TABLES_INTERVAL_MS > 0
      ? LEAGUE_TABLES_INTERVAL_MS
      : 2 * 60 * 1000;
  setInterval(() => {
    void updateLeagueTables({ trigger: "interval" });
  }, leagueTablesInterval);
  const clubEloInterval =
    Number.isFinite(CLUB_ELO_INTERVAL_MS) && CLUB_ELO_INTERVAL_MS > 0
      ? CLUB_ELO_INTERVAL_MS
      : 12 * 60 * 60 * 1000;
  setInterval(() => {
    void updateClubEloTeams({ trigger: "interval" });
  }, clubEloInterval);
  const clubEloFixturesInterval =
    Number.isFinite(CLUB_ELO_FIXTURES_INTERVAL_MS) && CLUB_ELO_FIXTURES_INTERVAL_MS > 0
      ? CLUB_ELO_FIXTURES_INTERVAL_MS
      : 12 * 60 * 60 * 1000;
  setInterval(() => {
    void updateClubEloFixtures({ trigger: "interval" });
  }, clubEloFixturesInterval);
  const footballDatabaseInterval =
    Number.isFinite(FOOTBALL_DATABASE_INTERVAL_MS) && FOOTBALL_DATABASE_INTERVAL_MS > 0
      ? FOOTBALL_DATABASE_INTERVAL_MS
      : 12 * 60 * 60 * 1000;
  setInterval(() => {
    void updateFootballDatabaseTeams({ trigger: "interval" });
  }, footballDatabaseInterval);
  const nationalEloInterval =
    Number.isFinite(NATIONAL_ELO_INTERVAL_MS) && NATIONAL_ELO_INTERVAL_MS > 0
      ? NATIONAL_ELO_INTERVAL_MS
      : 12 * 60 * 60 * 1000;
  setInterval(() => {
    void updateNationalEloTeams({ trigger: "interval" });
  }, nationalEloInterval);
  const fantasyBootstrapInterval =
    Number.isFinite(FPL_BOOTSTRAP_INTERVAL_MS) && FPL_BOOTSTRAP_INTERVAL_MS > 0
      ? FPL_BOOTSTRAP_INTERVAL_MS
      : 12 * 60 * 60 * 1000;
  setInterval(() => {
    void updateFantasyBootstrapStatic({ trigger: "interval" });
  }, fantasyBootstrapInterval);
  scheduleFantasyBootstrapDailyRefresh();
  const fantasyFixturesInterval =
    Number.isFinite(FPL_FIXTURES_INTERVAL_MS) && FPL_FIXTURES_INTERVAL_MS > 0
      ? FPL_FIXTURES_INTERVAL_MS
      : 6 * 60 * 60 * 1000;
  setInterval(() => {
    void updateFantasyFixtures({ trigger: "interval" });
  }, fantasyFixturesInterval);
  const fantasyEventLiveInterval =
    Number.isFinite(FPL_EVENT_LIVE_INTERVAL_MS) && FPL_EVENT_LIVE_INTERVAL_MS > 0
      ? FPL_EVENT_LIVE_INTERVAL_MS
      : 15 * 1000;
  setInterval(() => {
    void updateFantasyEventLive({ trigger: "interval" });
  }, fantasyEventLiveInterval);
  setInterval(() => {
    pollFantasyAssistantManagerEntries();
  }, FANTASY_ASSISTANT_MANAGER_POLL_INTERVAL_MS);
  const matchDetailsPollInterval =
    Number.isFinite(MATCH_DETAILS_POLL_INTERVAL_MS) && MATCH_DETAILS_POLL_INTERVAL_MS > 0
      ? MATCH_DETAILS_POLL_INTERVAL_MS
      : 10 * 1000;
  setInterval(() => {
    void refreshInProgressMatchDetails({ trigger: "interval" });
  }, matchDetailsPollInterval);
  operationalBootstrapPromise
    .then(() =>
      runRedisReconciliationCheck({
        trigger: "startup_bootstrap",
        repair: REDIS_RECONCILIATION_AUTO_REPAIR,
      })
    )
    .catch((error) => {
      console.warn("[RedisReconciliation] Initial run failed:", error.message || error);
    });
  setInterval(() => {
    operationalBootstrapPromise
      .then(() =>
        runRedisReconciliationCheck({
          trigger: "interval",
          repair: REDIS_RECONCILIATION_AUTO_REPAIR,
        })
      )
      .catch((error) => {
        console.warn("[RedisReconciliation] Interval run failed:", error.message || error);
      });
  }, REDIS_RECONCILIATION_INTERVAL_MS);
}

// Test harness endpoints (for internal use only)
app.get(`${API_PREFIX}/test-harness/match`, (req, res) => {
  const matchId = req.query.matchId || null;
  const match = testMatchState.getMatch(matchId);
  if (!match) {
    res.json({ active: false, match: null });
  } else {
    res.json({
      active: true,
      match: match,
      config: match.config,
      isPaused: match.isPaused,
      matchMinute: match.matchMinute,
    });
  }
});

app.post(`${API_PREFIX}/test-harness/match/create`, express.json(), (req, res) => {
  try {
    const match = testMatchState.createMatch(req.body);
    res.json({ success: true, match });
  } catch (err) {
    console.error("Failed to create test match:", err);
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/start`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.startSimulation(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/pause`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.pauseSimulation(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/resume`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.resumeSimulation(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/add-goal`, express.json(), (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    const isHome = req.body.team === "home";
    testMatchState.addGoal(matchId, isHome, req.body.playerName, req.body.assisterName);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/add-red-card`, express.json(), (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    const isHome = req.body.team === "home";
    testMatchState.addRedCard(matchId, isHome, req.body.playerName);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/simulate-var-disallowed-goal`, express.json(), (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    const isHome = req.body.team === "home";
    const result = testMatchState.simulateVarDisallowedGoal(matchId, isHome, {
      playerName: req.body.playerName,
      assisterName: req.body.assisterName,
      revertDelayMs: req.body.revertDelayMs,
    });
    if (!result) {
      res.status(400).json({ error: "Failed to schedule VAR-disallowed goal simulation." });
      return;
    }
    res.json({ success: true, ...result });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/jump-to-ht`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.jumpToHalfTime(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/jump-to-ft`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.jumpToFullTime(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/restart`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.restartMatch(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/set-speed`, express.json(), (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    const speedMs = parseInt(req.body.speedMs);
    if (isNaN(speedMs) || speedMs < 100) {
      return res.status(400).json({ error: "speedMs must be a number >= 100" });
    }
    testMatchState.setMatchSpeed(matchId, speedMs);
    res.json({ success: true, speedMs });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/delete`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.deleteMatch(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ===== Match Monitoring for Push Notifications =====
const matchMonitor = require("./match_monitor");

// Initialize and start match monitoring
const SERVER_BASE_URL = `http://localhost:${PORT}${API_PREFIX}`;
if (shouldRunRuntime) {
  matchMonitor.initialize(SERVER_BASE_URL);
}
matchMonitor.setLiveActivityMatchDetailsProvider(() => {
  const snapshot = currentFastMatchDetailsLookupSnapshot("live_activity_eval");
  return snapshot && snapshot.lookup ? snapshot.lookup : {};
});

// Status endpoint for monitoring
app.get(`${API_PREFIX}/monitor/status`, (req, res) => {
  setCacheOnlyHeaders(res);
  const rawMatchId = req.query.match_id ? String(req.query.match_id).trim() : "";
  const normalizedMatchId = rawMatchId ? normalizeMatchDetailsId(rawMatchId) : "";
  if (rawMatchId && !normalizedMatchId) {
    res.status(400).json({
      error: "Invalid match_id. Expected BBC details id (e.g. c043pne0q3kt).",
    });
    return;
  }
  const limitRecent = parsePositiveInt(req.query.limit_recent, 50, 1, 500);
  const status = matchMonitor.getStatus({
    matchId: normalizedMatchId || "",
    limitRecent,
  });
  res.status(200).json({
    success: true,
    filters: {
      match_id: normalizedMatchId || null,
      limit_recent: limitRecent,
    },
    ...status,
  });
});

// Trigger an immediate Live Activity evaluation cycle.
app.post(`${API_PREFIX}/live-activity/reconcile`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  try {
    const force = String(_req.query.force || _req.body?.force || "").trim().toLowerCase();
    const forceDispatch = force === "1" || force === "true" || force === "yes";
    const allowEndRaw = String(_req.query.allowEnd || _req.body?.allowEnd || "").trim().toLowerCase();
    const allowEnd = allowEndRaw === "1" || allowEndRaw === "true" || allowEndRaw === "yes";
    const explicitDeviceToken =
      typeof _req.body?.userDeviceToken === "string"
        ? _req.body.userDeviceToken
        : _req.body?.deviceToken;
    const userDeviceToken = _req.deviceToken || normalizeDeviceToken(explicitDeviceToken);
    const result = await matchMonitor.runLiveActivityEvaluationNow({
      userDeviceToken,
      trigger: typeof _req.body?.trigger === "string" ? _req.body.trigger : "",
      forceDispatch,
      preserveExistingOnEmpty: forceDispatch && !allowEnd,
    });

    // Build foreground-start content state so the app can call Activity.request()
    // when it is in the foreground and push-to-start can't reach it.
    let foregroundStart = null;
    if (userDeviceToken) {
      try {
        const record = await getUserPreferences(userDeviceToken);
        if (record) {
          const hooks = matchMonitor.__testHooks;
          if (
            hooks &&
            typeof hooks.monitoredMatchStatesSnapshot === "function" &&
            typeof hooks.buildLiveActivityEntriesForUser === "function" &&
            typeof hooks.buildLiveActivityPresentationForUser === "function" &&
            typeof hooks.buildLiveActivityContentState === "function" &&
            typeof hooks.collectLiveActivityTimelineCandidateMatchIds === "function" &&
            typeof hooks.combineLiveActivityOperationalMatches === "function" &&
            typeof hooks.enrichLiveActivityOperationalMatches === "function" &&
            typeof hooks.loadRedisDelayedSnapshotsByMatchId === "function"
          ) {
            const nowMs = Date.now();
            const [mergedDataset, recentDataset] = await Promise.all([
              getOperationalDataset("merged_matches"),
              getOperationalDataset("recent_matches"),
            ]);
            const monitoredEntries = hooks.monitoredMatchStatesSnapshot(nowMs);
            const matchDetailsSnapshot = currentFastMatchDetailsLookupSnapshot("live_activity_reconcile");
            const detailsRecords = matchDetailsSnapshot && matchDetailsSnapshot.lookup
              ? matchDetailsSnapshot.lookup
              : {};
            const operationalMatches = hooks.combineLiveActivityOperationalMatches(
              hooks.enrichLiveActivityOperationalMatches(
                mergedDataset && Array.isArray(mergedDataset.payload) ? mergedDataset.payload : [],
                detailsRecords
              ),
              hooks.enrichLiveActivityOperationalMatches(
                recentDataset && Array.isArray(recentDataset.payload) ? recentDataset.payload : [],
                detailsRecords
              )
            );
            const entries = hooks.buildLiveActivityEntriesForUser(
              record,
              monitoredEntries,
              operationalMatches,
              nowMs
            );
            const delayMinutes =
              record && record.preferences && typeof record.preferences === "object"
                ? Math.max(
                  0,
                  Number(
                    record.preferences.liveActivityDelayMinutes ??
                      record.preferences.notificationDelayMinutes ??
                      0
                  )
                )
                : 0;
            const delayedSnapshotsByMatchId =
              delayMinutes > 0
                ? await hooks.loadRedisDelayedSnapshotsByMatchId(
                  hooks.collectLiveActivityTimelineCandidateMatchIds(
                    monitoredEntries,
                    operationalMatches
                  ),
                  delayMinutes,
                  nowMs
                )
                : null;
            const presentation = hooks.buildLiveActivityPresentationForUser(record, entries, nowMs, {
              delayedSnapshotsByMatchId,
            });
            if (presentation && presentation.mode) {
              const contentState = hooks.buildLiveActivityContentState(
                presentation.mode,
                presentation.matches,
                presentation.delayMinutes,
                nowMs,
                presentation.fantasyCurrentScore
              );

              foregroundStart = { contentState };
            }
          }
        }
      } catch (_err) {
        // Non-fatal: foreground start is best-effort
      }
    }

    res.status(200).json({
      success: true,
      userDeviceToken: userDeviceToken || null,
      forceDispatch,
      preserveExistingOnEmpty: forceDispatch && !allowEnd,
      foregroundStart,
      ...result,
    });
  } catch (error) {
    console.error("[API] Error reconciling live activities:", error);
    res.status(500).json({
      error: "Failed to reconcile live activities",
      message: error.message,
    });
  }
});

if (shouldRunRuntime) {
  app.listen(PORT, () => {
    console.log(`Server listening on http://localhost:${PORT}`);

    // Start match monitoring after server is ready
    setTimeout(async () => {
      await operationalBootstrapPromise;
      matchMonitor.startMonitoring();
    }, 2000); // Wait 2 seconds for server to fully initialize
  });

  // Graceful shutdown
  process.on("SIGTERM", async () => {
    console.log("SIGTERM received, shutting down gracefully");
    if (fantasyBootstrapDailyRefreshTimer) {
      clearTimeout(fantasyBootstrapDailyRefreshTimer);
      fantasyBootstrapDailyRefreshTimer = null;
    }
    matchMonitor.stopMonitoring();
    const { shutdown: shutdownAPNS } = require("./apns_client");
    await shutdownAPNS();
    process.exit(0);
  });

  process.on("SIGINT", async () => {
    console.log("SIGINT received, shutting down gracefully");
    if (fantasyBootstrapDailyRefreshTimer) {
      clearTimeout(fantasyBootstrapDailyRefreshTimer);
      fantasyBootstrapDailyRefreshTimer = null;
    }
    matchMonitor.stopMonitoring();
    const { shutdown: shutdownAPNS } = require("./apns_client");
    await shutdownAPNS();
    process.exit(0);
  });
}

module.exports = {
  app,
  __private: {
    toMatchListPayload,
    toMonitorCandidateFromDetailsPayload,
    mergeMonitorCandidate,
    buildMonitorCandidatesForDate,
    buildFallbackMatchDetailsPayload,
    getMatchDetailsStatePayload,
    mergeConfirmedVarDisallowedGoalsIntoPayload,
    enrichMatchDetailsAggregateImmediately,
    enrichKnockoutAggregatesForListMatches,
    buildPrometheusMetricsText,
    matchDetailsNeedsBackfill,
    markMatchDetailsActive,
    isMatchDetailsActive,
    normalizeMatchDetailsPayload,
    mergeMatchDetailsPayload,
    resolveStableMatchScoreStatus,
    withStableMatchDetailsState,
    pickPreferredMatchStatus,
    normalizeMatchStatusValue,
    parseMatchStatusMinute,
    normalizeTeamName,
    normalizeCompetitionFilterName,
    isAllowedCompetition,
    mergeBbcAndLiveMatches,
    matchIncludesHomeNation,
    matchIsMajorTournament,
    matchPassesCategoryFilters,
    matchDetailsIdFromUrl,
    filterStaleBbcMatches,
    buildDefaultOperationalCacheState,
    normalizeCacheStateDomains,
    normalizeOperationalCacheState,
    bumpCacheStateSnapshot,
    buildLiveActivityTestContentState,
    buildLiveActivityTestPresets,
    resolveLiveActivityTestPreset,
  },
};
