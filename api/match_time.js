"use strict";

const DEFAULT_MATCH_TIME_ZONE = process.env.MATCH_DISPLAY_TIME_ZONE || "Europe/London";

function dateTimePartsInTimeZone(date, timeZone = DEFAULT_MATCH_TIME_ZONE) {
  const formatter = new Intl.DateTimeFormat("en-GB", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  });
  const values = {};
  formatter.formatToParts(date).forEach((part) => {
    if (part.type !== "literal") values[part.type] = part.value;
  });
  return values;
}

function utcDateTimeToZonedDateTime(dateString, timeString, timeZone = DEFAULT_MATCH_TIME_ZONE) {
  const date = String(dateString || "").trim();
  const time = String(timeString || "").trim();
  const timeMatch = time.match(/^(\d{1,2}):(\d{2})$/);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !timeMatch) {
    return { date: date || null, time: time || null };
  }

  const hour = timeMatch[1].padStart(2, "0");
  const minute = timeMatch[2];
  const timestamp = Date.parse(`${date}T${hour}:${minute}:00Z`);
  if (!Number.isFinite(timestamp)) {
    return { date, time };
  }

  const parts = dateTimePartsInTimeZone(new Date(timestamp), timeZone);
  if (!parts.year || !parts.month || !parts.day || !parts.hour || !parts.minute) {
    return { date, time };
  }

  return {
    date: `${parts.year}-${parts.month}-${parts.day}`,
    time: `${parts.hour}:${parts.minute}`,
  };
}

function zonedDateTimeToUtcMs(dateString, timeString, timeZone = DEFAULT_MATCH_TIME_ZONE) {
  const dateMatch = String(dateString || "").match(/^(\d{4})-(\d{2})-(\d{2})$/);
  const timeMatch = String(timeString || "").match(/^(\d{1,2}):(\d{2})$/);
  if (!dateMatch || !timeMatch) return null;

  const targetYear = Number(dateMatch[1]);
  const targetMonth = Number(dateMatch[2]);
  const targetDay = Number(dateMatch[3]);
  const targetHour = Number(timeMatch[1]);
  const targetMinute = Number(timeMatch[2]);
  if (
    !Number.isFinite(targetYear) ||
    !Number.isFinite(targetMonth) ||
    !Number.isFinite(targetDay) ||
    !Number.isFinite(targetHour) ||
    !Number.isFinite(targetMinute)
  ) {
    return null;
  }

  let guessMs = Date.UTC(targetYear, targetMonth - 1, targetDay, targetHour, targetMinute, 0);
  const desiredMs = Date.UTC(targetYear, targetMonth - 1, targetDay, targetHour, targetMinute, 0);
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const parts = dateTimePartsInTimeZone(new Date(guessMs), timeZone);
    const observedMs = Date.UTC(
      Number(parts.year),
      Number(parts.month) - 1,
      Number(parts.day),
      Number(parts.hour),
      Number(parts.minute),
      Number(parts.second || "0")
    );
    const diffMs = desiredMs - observedMs;
    if (diffMs === 0) return guessMs;
    guessMs += diffMs;
  }

  return guessMs;
}

function zonedDateTimeToZonedDateTime(
  dateString,
  timeString,
  sourceTimeZone = DEFAULT_MATCH_TIME_ZONE,
  targetTimeZone = DEFAULT_MATCH_TIME_ZONE
) {
  const timestampMs = zonedDateTimeToUtcMs(dateString, timeString, sourceTimeZone);
  if (!Number.isFinite(timestampMs)) {
    return {
      date: String(dateString || "").trim() || null,
      time: String(timeString || "").trim() || null,
    };
  }

  const iso = new Date(timestampMs).toISOString();
  return utcDateTimeToZonedDateTime(iso.slice(0, 10), iso.slice(11, 16), targetTimeZone);
}

module.exports = {
  DEFAULT_MATCH_TIME_ZONE,
  utcDateTimeToZonedDateTime,
  zonedDateTimeToUtcMs,
  zonedDateTimeToZonedDateTime,
};
