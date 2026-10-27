"use strict";
const { zonedDateTimeToUtcMs } = require("./match_time");
const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
const localDate = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/London", year: "numeric", month: "2-digit", day: "2-digit",
});

function weeklyClubRankingSchedule(now = Date.now()) {
  const parts = Object.fromEntries(localDate.formatToParts(new Date(now)).map(p => [p.type, p.value]));
  const day = new Date(`${parts.year}-${parts.month}-${parts.day}T00:00:00Z`);
  day.setUTCDate(day.getUTCDate() - day.getUTCDay());
  const sundayAtNine = () => zonedDateTimeToUtcMs(day.toISOString().slice(0, 10), "09:00", "Europe/London");
  let previous = sundayAtNine();
  if (previous > now) {
    day.setUTCDate(day.getUTCDate() - 7);
    previous = sundayAtNine();
  }
  day.setUTCDate(day.getUTCDate() + 7);
  return { previous, next: sundayAtNine() };
}

function clubRankingRefreshDue(lastSuccess, now = Date.now()) {
  const last = Date.parse(lastSuccess || "");
  return !Number.isFinite(last) || last < weeklyClubRankingSchedule(now).previous;
}
module.exports = { WEEK_MS, weeklyClubRankingSchedule, clubRankingRefreshDue };
