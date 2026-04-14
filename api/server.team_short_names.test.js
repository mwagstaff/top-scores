const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    normalizeTeamShortNameEntry,
    extractTeamShortNameEntriesFromMatch,
    buildTeamShortNamesPayloadFromMaps,
    buildPersistedTeamShortNamesDataset,
    restoreScrapedTeamShortNamesFromDataset,
    buildResolvedTeamShortNameLookup,
    applyTeamShortNamesToApiValue,
    collectTeamShortNameScrapeCandidates,
  },
} = require("./server");

test("extractTeamShortNameEntriesFromMatch returns per-side short name mappings", () => {
  const entries = extractTeamShortNameEntriesFromMatch({
    home_team: "Paris Saint-Germain",
    home_short_name: "Paris SG",
    away_team: "Manchester City",
    away_short_name: "Man City",
    details_url: "https://www.bbc.co.uk/sport/football/live/c1234567890",
  });

  assert.equal(entries.length, 2);
  assert.deepEqual(
    entries.map((entry) => [entry.name, entry.short_name]),
    [
      ["Paris Saint-Germain", "Paris SG"],
      ["Manchester City", "Man City"],
    ]
  );
});

test("buildTeamShortNamesPayloadFromMaps prefers override values over scraped ones", () => {
  const scraped = new Map();
  const override = new Map();
  const scrapedEntry = normalizeTeamShortNameEntry("Paris Saint-Germain", "Paris SG", {
    updated_at: "2026-04-10T10:00:00.000Z",
    source: "scraped",
  });
  const overrideEntry = normalizeTeamShortNameEntry("Paris Saint-Germain", "PSG", {
    updated_at: "2026-04-11T10:00:00.000Z",
    source: "filesystem_override",
  });

  scraped.set(scrapedEntry.key, scrapedEntry);
  override.set(overrideEntry.key, overrideEntry);

  const payload = buildTeamShortNamesPayloadFromMaps(scraped, override);
  assert.equal(payload.short_names["Paris Saint-Germain"], "PSG");
});

test("collectTeamShortNameScrapeCandidates only returns BBC matches with unknown teams", () => {
  const knownKeys = new Set(["arsenal"]);
  const candidates = collectTeamShortNameScrapeCandidates(
    [
      {
        home_team: "Arsenal",
        away_team: "Paris Saint-Germain",
        details_url: "https://www.bbc.co.uk/sport/football/live/c111",
        date: "2026-04-14",
        time: "20:00",
      },
      {
        home_team: "Arsenal",
        away_team: "Manchester City",
        details_url: "https://www.bbc.co.uk/sport/football/live/c222",
        date: "2026-04-14",
        time: "19:45",
      },
      {
        home_team: "Paris Saint-Germain",
        away_team: "Manchester City",
        details_url: "https://www.bbc.co.uk/sport/football/live/c333",
        date: "2026-04-14",
        time: "20:15",
      },
    ],
    knownKeys
  );

  assert.deepEqual(
    candidates.map((candidate) => ({
      details_url: candidate.details_url,
      missing_team_names: candidate.missing_team_names,
      missing_count: candidate.missing_count,
    })),
    [
      {
        details_url: "https://www.bbc.co.uk/sport/football/live/c333",
        missing_team_names: ["Paris Saint-Germain", "Manchester City"],
        missing_count: 2,
      },
      {
        details_url: "https://www.bbc.co.uk/sport/football/live/c222",
        missing_team_names: ["Manchester City"],
        missing_count: 1,
      },
      {
        details_url: "https://www.bbc.co.uk/sport/football/live/c111",
        missing_team_names: ["Paris Saint-Germain"],
        missing_count: 1,
      },
    ]
  );
});

test("persisted team short names dataset restores scraped entries for Redis hydration", () => {
  const scraped = new Map();
  const paris = normalizeTeamShortNameEntry("Paris Saint-Germain", "Paris SG", {
    updated_at: "2026-04-10T10:00:00.000Z",
    source: "scraped",
    details_url: "https://www.bbc.co.uk/sport/football/live/c111",
  });
  const city = normalizeTeamShortNameEntry("Manchester City", "Man City", {
    updated_at: "2026-04-10T11:00:00.000Z",
    source: "scraped",
    details_url: "https://www.bbc.co.uk/sport/football/live/c222",
  });
  scraped.set(paris.key, paris);
  scraped.set(city.key, city);

  const dataset = buildPersistedTeamShortNamesDataset(
    scraped,
    "2026-04-10T12:00:00.000Z"
  );
  const restored = restoreScrapedTeamShortNamesFromDataset(dataset, {
    source: "redis_operational_dataset",
  });

  assert.equal(restored.updated_at, "2026-04-10T12:00:00.000Z");
  assert.equal(restored.map.size, 2);
  assert.equal(restored.map.get("paris saint germain").short_name, "Paris SG");
  assert.equal(restored.map.get("manchester city").short_name, "Man City");
});

test("applyTeamShortNamesToApiValue adds nested snake and camel short-name fields only", () => {
  const scraped = new Map();
  const overrides = new Map();
  const paris = normalizeTeamShortNameEntry("Paris Saint-Germain", "Paris SG");
  const city = normalizeTeamShortNameEntry("Manchester City", "Man City");
  const override = normalizeTeamShortNameEntry("Paris Saint-Germain", "PSG");
  scraped.set(paris.key, paris);
  scraped.set(city.key, city);
  overrides.set(override.key, override);

  const lookup = buildResolvedTeamShortNameLookup(scraped, overrides);
  const payload = {
    home_team: "Paris Saint-Germain",
    away_team: "Manchester City",
    notes: "Paris Saint-Germain should stay untouched in arbitrary text",
    matches: [
      {
        homeTeam: "Paris Saint-Germain",
        awayTeam: "Manchester City",
        team_lineups: {
          home: { team: "Paris Saint-Germain" },
          away: { team: "Manchester City" },
        },
      },
    ],
    foregroundStart: {
      contentState: {
        matches: [
          {
            homeTeam: "Paris Saint-Germain",
            awayTeam: "Manchester City",
          },
        ],
      },
    },
  };

  const transformed = applyTeamShortNamesToApiValue(payload, lookup);

  assert.equal(transformed.home_team, "Paris Saint-Germain");
  assert.equal(transformed.away_team, "Manchester City");
  assert.equal(transformed.home_short_name, "PSG");
  assert.equal(transformed.away_short_name, "Man City");
  assert.equal(
    transformed.notes,
    "Paris Saint-Germain should stay untouched in arbitrary text"
  );
  assert.equal(transformed.matches[0].homeTeam, "Paris Saint-Germain");
  assert.equal(transformed.matches[0].awayTeam, "Manchester City");
  assert.equal(transformed.matches[0].homeShortName, "PSG");
  assert.equal(transformed.matches[0].awayShortName, "Man City");
  assert.equal(transformed.matches[0].team_lineups.home.team, "Paris Saint-Germain");
  assert.equal(transformed.matches[0].team_lineups.away.team, "Manchester City");
  assert.equal(
    transformed.foregroundStart.contentState.matches[0].homeTeam,
    "Paris Saint-Germain"
  );
  assert.equal(
    transformed.foregroundStart.contentState.matches[0].homeShortName,
    "PSG"
  );
});

test("applyTeamShortNamesToApiValue adds Bolton short name from cache data", () => {
  const scraped = new Map();
  const bolton = normalizeTeamShortNameEntry("Bolton Wanderers", "Bolton");
  scraped.set(bolton.key, bolton);

  const lookup = buildResolvedTeamShortNameLookup(scraped, new Map());
  const transformed = applyTeamShortNamesToApiValue(
    {
      date: "2026-04-14",
      time: "19:45",
      league: "League One",
      home_team: "Bolton Wanderers",
      away_team: "Stevenage",
      tv_channels: ["Sky Sports+"],
      match_details_id: "ckgwd8x7yrlt",
      has_bbc_source: true,
    },
    lookup
  );

  assert.equal(transformed.home_team, "Bolton Wanderers");
  assert.equal(transformed.home_short_name, "Bolton");
  assert.equal(transformed.away_team, "Stevenage");
  assert.equal(transformed.away_short_name, undefined);
});
