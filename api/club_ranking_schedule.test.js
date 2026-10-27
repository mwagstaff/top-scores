const test = require("node:test");
const assert = require("node:assert/strict");
const { weeklyClubRankingSchedule, clubRankingRefreshDue } = require("./club_ranking_schedule");
test("Sunday at 09:00 UK time follows winter, summer and DST boundaries", () => {
  for (const [now, previous, next] of [
    ["2026-10-26T12:00Z", "2026-10-25T09:00Z", "2026-11-01T09:00Z"],
    ["2026-07-06T12:00Z", "2026-07-05T08:00Z", "2026-07-12T08:00Z"],
    ["2026-03-28T12:00Z", "2026-03-22T09:00Z", "2026-03-29T08:00Z"],
    ["2026-10-24T12:00Z", "2026-10-18T08:00Z", "2026-10-25T09:00Z"],
    ["2026-11-01T08:59Z", "2026-10-25T09:00Z", "2026-11-01T09:00Z"],
    ["2026-11-01T09:00Z", "2026-11-01T09:00Z", "2026-11-08T09:00Z"],
  ]) {
    assert.deepEqual(weeklyClubRankingSchedule(Date.parse(now)), { previous: Date.parse(previous), next: Date.parse(next) });
  }
});
test("restart catches up missed Sundays without re-fetching a current weekly snapshot", () => {
  const now = Date.parse("2026-11-02T10:00Z");
  assert.equal(clubRankingRefreshDue("2026-11-01T09:01Z", now), false);
  assert.equal(clubRankingRefreshDue("2026-10-26T16:00Z", now), true);
  assert.equal(clubRankingRefreshDue(null, now), true);
});
