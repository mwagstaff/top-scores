import test from "node:test";
import assert from "node:assert/strict";
import {
  ukChannels,
  ukDate,
  moveDate,
  validDate,
  isUKRelevant,
  matchPath,
} from "../src/client/football.ts";
import {
  isMatchLive,
  isMatchFinished,
  displayStatus,
} from "../src/client/matchState.ts";
import { selectStadium } from "../src/client/stadium.ts";
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
    ["BBC One", "HBO Max"],
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
