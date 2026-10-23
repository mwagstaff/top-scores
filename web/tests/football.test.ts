import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
registerHooks({ resolve(specifier, context, next) {
  try { return next(specifier, context); }
  catch (error) {
    if (error.code === "ERR_MODULE_NOT_FOUND" && specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier)) return next(`${specifier}.ts`, context);
    throw error;
  }
} });
const { rankedTVMatches, ukChannels, ukDate, moveDate, validDate, isUKRelevant, matchPath } = await import("../src/client/football.ts");
import {
  isMatchLive,
  isMatchFinished,
  displayStatus,
} from "../src/client/matchState.ts";
import { selectStadium, homeStadiums, randomStadium, requiresPhotoCredit } from "../src/client/stadium.ts";
import type { Match } from "../src/client/types.ts";

const match = (extra: Partial<Match> = {}): Match => ({
  id: "42",
  date: "2026-10-21",
  time: "20:00",
  homeTeam: "Example",
  awayTeam: "Visitors",
  league: "Example League",
  tvChannels: [],
  ...extra,
});
test("UK dates handle midnight, BST and the autumn clock change", () => {
  assert.equal(ukDate(new Date("2026-07-01T23:30:00Z")), "2026-07-02");
  assert.equal(ukDate(new Date("2026-10-25T23:30:00Z")), "2026-10-25");
  assert.equal(moveDate("2026-10-25", 1), "2026-10-26");
  assert.equal(moveDate("2027-01-01", -1), "2026-12-31");
  assert.equal(validDate("2026-02-30"), false);
  assert.equal(validDate("2028-02-29"), true);
  assert.equal(validDate("<script>"), false);
});
test("UK broadcasts deduplicate aliases without treating overseas channels as UK", () => {
  const channel = (name: string, countryCode: string | null = null) => ({
    name,
    countryCode,
    country: null,
    logo: null,
  });
  assert.deepEqual(
    ukChannels([
      channel("HBO Max (UK)", "GB"),
      channel("HBO Max", "GB"),
      channel("Sky Sports", "NZ"),
      channel("BBC One"),
      channel("ESPN", "US"),
    ]).map((c) => c.name),
    ["HBO Max", "BBC One"],
  );
  assert.equal(isUKRelevant(match({ league: "Scottish Premiership" })), true);
  assert.equal(
    isUKRelevant(
      match({
        league: "La Liga",
        tvChannels: [channel("Premier Sports 1", "GB")],
      }),
    ),
    true,
  );
  assert.equal(isUKRelevant(match({ league: "La Liga" })), false);
  assert.equal(isUKRelevant(match({ league: "UEFA Champions League" })), true);
});
test("live, extra time and settled states remain distinct", () => {
  for (const status of ["45+3", "HT", "ET 105", "LIVE"])
    assert.equal(isMatchLive(match({ scoreStatus: status })), true);
  for (const status of [
    "FT",
    "AET",
    "PENS",
    "POSTPONED",
    "CANCELLED",
    "ABANDONED",
  ])
    assert.equal(isMatchLive(match({ scoreStatus: status })), false);
  assert.equal(isMatchFinished(match({ scoreStatus: "PENS" })), true);
  assert.equal(displayStatus(match({ scoreStatus: "45+3" })), "45+3'");
  assert.equal(displayStatus(match()), "20:00");
  assert.equal(
    matchPath(match({ matchDetailsId: "601100" })),
    "/matches/601100?date=2026-10-21",
  );
});
test("stadium selection prioritises IDs, supports aliases and has a stable generic fallback", () => {
  const asset = (id: string, role: string, team_ids: string[] = []) => ({
    id,
    role,
    team_ids,
    sha256: id,
  });
  const catalog = {
    teams: {
      a: { name: "Wrong", aliases: ["Arsenal"], source_team_ids: [] },
      b: {
        name: "Arsenal",
        aliases: ["Gunners"],
        source_team_ids: ["legacy"],
        bsd_team_id: "10",
      },
    },
    assets: [
      asset("arsenal", "team", ["b"]),
      asset("fallback", "generic_match"),
      asset("header", "generic_backdrop"),
    ],
  };
  assert.equal(selectStadium(catalog, "Arsenal", "10")?.id, "arsenal");
  assert.equal(selectStadium(catalog, "Gunners")?.id, "arsenal");
  assert.equal(selectStadium(catalog, "Unknown")?.id, "fallback");
  assert.equal(selectStadium(catalog)?.id, "header");
  assert.equal(selectStadium({ teams: {}, assets: [] }), undefined);
});

test("competition activity counts games once and leaves inactive leagues absent", async () => {
  const { countCompetitions } = await import("../src/client/football.ts");
  assert.deepEqual(
    countCompetitions([
      match({ id: "1", league: "UEFA Champions League" }),
      match({ id: "2", league: "UEFA Champions League" }),
      match({ id: "1", league: "UEFA Champions League" }),
    ]),
    { "UEFA Champions League": 2 },
  );
  assert.deepEqual(countCompetitions([]), {});
});
test("league badges resolve the app identity instead of the app icon", async () => {
  const { competitionLogo } = await import("../src/client/competitionLogos.ts");
  assert.match(
    competitionLogo("premier-league", "Premier League")!,
    /FantasyPremierLeagueLion/,
  );
  assert.match(
    competitionLogo("bsd-7", "UEFA Champions League")!,
    /CompetitionLogo7/,
  );
  assert.equal(competitionLogo("unknown", "Unknown League"), undefined);
});

test("TV guide ranks API watchability first, breaks ties by kickoff, and excludes finished games", () => {
  const channel = {
    name: "TNT Sports",
    countryCode: "GB",
    country: null,
    logo: null,
  };
  const game = (
    id: string,
    score: number | null,
    time: string,
    scoreStatus?: string,
  ) =>
    match({
      id,
      time,
      scoreStatus,
      tvChannels: [channel],
      watchabilityIndex:
        score === null ? null : { score, stars: 4, tier: "highly_watchable" },
    });
  const input = [
    game("low", 40, "12:00"),
    game("late", 80, "20:00"),
    game("early", 80, "17:45"),
    game("finished", 99, "12:00", "FT"),
    game("unknown", null, "10:00"),
  ];
  assert.deepEqual(
    rankedTVMatches(input).map((m) => m.id),
    ["early", "late", "low", "unknown"],
  );
  assert.equal(input[0].id, "low");
});

test("rotating artwork prefers home stadiums, avoids repeats and preserves third-party credits", () => {
  const a = { id: "a", sha256: "a", role: "team", team_ids: ["home"] };
  const b = { ...a, id: "b", sha256: "b" };
  const fallback = { ...a, id: "generic", role: "generic_backdrop", team_ids: [] };
  const catalog = { teams: { home: { name: "Home", aliases: ["Short"], source_team_ids: [], bsd_team_id: "12" } }, assets: [a, b, fallback] };
  assert.deepEqual(homeStadiums(catalog, [{ name: "Short" }]), [a, b]);
  assert.deepEqual(homeStadiums(catalog, [{ name: "Unknown", id: "12" }]), [a, b]);
  assert.deepEqual(homeStadiums(catalog, [{ name: "Unknown" }]), [fallback]);
  assert.equal(randomStadium([a, b], "a"), b);
  assert.equal(randomStadium([a], "a"), a);
  assert.equal(randomStadium([]), undefined);
  assert.equal(requiresPhotoCredit({ ...a, credit: { author: "Top Scores", attribution: "Top Scores artwork" } }), false);
  assert.equal(requiresPhotoCredit({ ...a, credit: { author: "Photographer", attribution: "Licensed photo" } }), true);
});
