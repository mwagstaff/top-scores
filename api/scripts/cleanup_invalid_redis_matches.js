#!/usr/bin/env node
/* eslint-disable no-console */

const fs = require("fs");
const path = require("path");
const {
  getAllOperationalMatchDetails,
  deleteOperationalMatchDetailsRecords,
  closeRedisConnection,
} = require("../redis_client");

const COMPETITION_WEIGHTS_PATH = path.resolve(
  __dirname,
  "../competition_weights.json"
);

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

function printUsage() {
  console.log(`
Usage:
  node api/scripts/cleanup_invalid_redis_matches.js [options]

Options:
  --apply                Delete invalid Redis match records. Default is dry-run only.
  --competition <text>   Only act on competitions matching this substring.
  --limit <n>            Limit the number of invalid matches processed.
  --chunk-size <n>       Delete in batches of N match IDs. Default: 250.
  --verbose              Print every invalid match ID and competition.
  --help                 Show this help.

Examples:
  node api/scripts/cleanup_invalid_redis_matches.js
  node api/scripts/cleanup_invalid_redis_matches.js --competition "a league"
  node api/scripts/cleanup_invalid_redis_matches.js --apply
`);
}

function normalizeCompetitionName(value) {
  return String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function stripStageDescriptors(name) {
  let normalized = normalizeCompetitionName(name);
  if (!normalized) return "";

  let changed = true;
  while (changed) {
    changed = false;
    for (const pattern of STAGE_PATTERNS) {
      if (!pattern.test(normalized)) continue;
      normalized = normalized.replace(pattern, "").trim();
      normalized = normalized.replace(/[-:–]\s*$/, "").trim();
      changed = true;
    }
  }

  return normalized;
}

function canonicalCompetitionName(name) {
  const normalized = stripStageDescriptors(name);
  const aliases = {
    "efl cup": "english league cup",
    "carabao cup": "english league cup",
    "uefa europa conference league": "uefa conference league",
  };
  return aliases[normalized] || normalized;
}

function loadAllowedCompetitions() {
  const raw = fs.readFileSync(COMPETITION_WEIGHTS_PATH, "utf8");
  const parsed = JSON.parse(raw);
  const names = Object.keys(parsed || {});
  if (names.length === 0) {
    throw new Error(`No competition names found in ${COMPETITION_WEIGHTS_PATH}`);
  }

  const allowed = new Set();
  names.forEach((name) => {
    const canonical = canonicalCompetitionName(name);
    if (canonical) {
      allowed.add(canonical);
    }
  });
  return {
    allowed,
    names,
  };
}

function parseArgs(argv) {
  const args = {
    apply: false,
    competition: "",
    limit: null,
    chunkSize: 250,
    verbose: false,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--apply") {
      args.apply = true;
      continue;
    }
    if (token === "--verbose") {
      args.verbose = true;
      continue;
    }
    if (token === "--help" || token === "-h") {
      args.help = true;
      continue;
    }
    if (token === "--competition") {
      args.competition = String(argv[index + 1] || "").trim();
      index += 1;
      continue;
    }
    if (token === "--limit") {
      const parsed = Number(argv[index + 1]);
      if (Number.isFinite(parsed) && parsed > 0) {
        args.limit = Math.floor(parsed);
      }
      index += 1;
      continue;
    }
    if (token === "--chunk-size") {
      const parsed = Number(argv[index + 1]);
      if (Number.isFinite(parsed) && parsed > 0) {
        args.chunkSize = Math.floor(parsed);
      }
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${token}`);
  }

  return args;
}

function chunk(items, size) {
  const output = [];
  for (let index = 0; index < items.length; index += size) {
    output.push(items.slice(index, index + size));
  }
  return output;
}

function summarizeInvalidMatches(records) {
  const summary = new Map();
  records.forEach((record) => {
    const key = record.league || "(missing league)";
    const current = summary.get(key) || { count: 0, canonical: record.canonicalLeague, sampleIds: [] };
    current.count += 1;
    if (current.sampleIds.length < 5) {
      current.sampleIds.push(record.matchId);
    }
    summary.set(key, current);
  });

  return Array.from(summary.entries())
    .map(([league, info]) => ({ league, ...info }))
    .sort((left, right) => {
      if (left.count !== right.count) return right.count - left.count;
      return left.league.localeCompare(right.league);
    });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printUsage();
    return;
  }

  const { allowed, names } = loadAllowedCompetitions();
  console.log(
    `[cleanup-invalid-redis-matches] Loaded ${allowed.size} allowed competitions from ${COMPETITION_WEIGHTS_PATH}`
  );

  const snapshot = await getAllOperationalMatchDetails();
  const records = snapshot && snapshot.records && typeof snapshot.records === "object"
    ? snapshot.records
    : {};
  const allEntries = Object.entries(records);
  console.log(
    `[cleanup-invalid-redis-matches] Redis snapshot source=${snapshot && snapshot.source ? snapshot.source : "unknown"} total=${allEntries.length}`
  );

  const competitionFilter = normalizeCompetitionName(args.competition);
  let invalidMatches = allEntries
    .map(([matchId, payload]) => {
      const league = String(payload && payload.league ? payload.league : "").trim();
      const canonicalLeague = canonicalCompetitionName(league);
      return {
        matchId,
        payload,
        league,
        canonicalLeague,
      };
    })
    .filter((record) => {
      if (competitionFilter) {
        const haystacks = [record.league, record.canonicalLeague].map(normalizeCompetitionName);
        if (!haystacks.some((value) => value.includes(competitionFilter))) {
          return false;
        }
      }
      return !allowed.has(record.canonicalLeague);
    });

  if (Number.isFinite(args.limit)) {
    invalidMatches = invalidMatches.slice(0, args.limit);
  }

  const summaries = summarizeInvalidMatches(invalidMatches);
  console.log(
    `[cleanup-invalid-redis-matches] Invalid matches=${invalidMatches.length} dry_run=${args.apply ? "false" : "true"}`
  );

  if (summaries.length === 0) {
    console.log("[cleanup-invalid-redis-matches] No invalid matches found.");
    return;
  }

  console.log("[cleanup-invalid-redis-matches] Invalid competitions:");
  summaries.forEach((summary) => {
    console.log(
      `  - ${summary.league} | canonical=${summary.canonical} | count=${summary.count} | sample_ids=${summary.sampleIds.join(",")}`
    );
  });

  if (args.verbose) {
    console.log("[cleanup-invalid-redis-matches] Invalid match records:");
    invalidMatches.forEach((record) => {
      const homeTeam = String(record.payload && record.payload.home_team ? record.payload.home_team : "").trim();
      const awayTeam = String(record.payload && record.payload.away_team ? record.payload.away_team : "").trim();
      console.log(
        `  - ${record.matchId} | ${record.league || "(missing league)"} | ${homeTeam} vs ${awayTeam}`
      );
    });
  }

  if (!args.apply) {
    console.log("[cleanup-invalid-redis-matches] Dry run complete. Re-run with --apply to delete.");
    console.log("[cleanup-invalid-redis-matches] Allowed competitions:");
    names.forEach((name) => console.log(`  - ${name}`));
    return;
  }

  const invalidIds = invalidMatches.map((record) => record.matchId);
  const batches = chunk(invalidIds, Math.max(1, args.chunkSize));
  let deleted = 0;
  let missing = 0;

  for (const [index, batch] of batches.entries()) {
    const result = await deleteOperationalMatchDetailsRecords(batch, {
      updated_at: new Date().toISOString(),
      source: "cleanup_invalid_redis_matches_script",
      delete_write_logs: true,
    });
    deleted += Number(result && result.deleted ? result.deleted : 0);
    missing += Array.isArray(result && result.missing_ids) ? result.missing_ids.length : 0;
    console.log(
      `[cleanup-invalid-redis-matches] Batch ${index + 1}/${batches.length} requested=${batch.length} deleted=${result.deleted} missing=${result.missing_ids.length} remaining_total=${result.total}`
    );
  }

  console.log(
    `[cleanup-invalid-redis-matches] Complete. deleted=${deleted} missing=${missing} requested=${invalidIds.length}`
  );
}

main()
  .catch((error) => {
    console.error("[cleanup-invalid-redis-matches] Failed:", error);
    process.exitCode = 1;
  })
  .finally(async () => {
    try {
      await closeRedisConnection();
    } catch (error) {
      console.error("[cleanup-invalid-redis-matches] Failed to close Redis connection:", error);
    }
  });
