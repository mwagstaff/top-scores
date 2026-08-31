"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { managerRecords } = require("./fetch_bsd_managers");

test("managerRecords deduplicates managers and retains supported league ids", () => {
  const records = managerRecords([
    {
      leagueId: "1",
      managers: [{ id: 264, name: "Álvaro Arbeloa", current_team_id: 6, country: "Spain" }],
    },
    {
      leagueId: "90",
      managers: [{ id: 264, name: "Álvaro Arbeloa", current_team_id: 6, tactical_profile: "attacking" }],
    },
  ]);

  assert.equal(records.length, 1);
  assert.equal(records[0].id, "264");
  assert.deepEqual(records[0].extra.league_ids, ["1", "90"]);
  assert.equal(records[0].extra.current_team_id, "6");
  assert.equal(records[0].payload.country, "Spain");
  assert.equal(records[0].payload.tactical_profile, "attacking");
});
