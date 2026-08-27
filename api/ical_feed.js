const crypto = require("crypto");

const DEFAULT_EVENT_DURATION_MS = 2 * 60 * 60 * 1000;
const CALENDAR_NAME = "Top Scores — My Matches";

function escapeText(value) {
  return String(value ?? "")
    .replace(/\\/g, "\\\\")
    .replace(/\r\n|\r|\n/g, "\\n")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,");
}

function foldLine(line) {
  const segments = [];
  let current = "";
  let currentBytes = 0;

  for (const character of String(line)) {
    const characterBytes = Buffer.byteLength(character, "utf8");
    if (current && currentBytes + characterBytes > 75) {
      segments.push(current);
      current = ` ${character}`;
      currentBytes = 1 + characterBytes;
    } else {
      current += character;
      currentBytes += characterBytes;
    }
  }

  segments.push(current);
  return segments.join("\r\n");
}

function utcDateTime(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (!Number.isFinite(date.getTime())) return null;
  return date
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}Z$/, "Z");
}

function dateOnly(value) {
  const normalized = String(value || "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(normalized)) return null;
  return normalized.replace(/-/g, "");
}

function nextDateOnly(value) {
  const normalized = String(value || "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(normalized)) return null;
  const date = new Date(`${normalized}T00:00:00Z`);
  if (!Number.isFinite(date.getTime())) return null;
  date.setUTCDate(date.getUTCDate() + 1);
  return date.toISOString().slice(0, 10).replace(/-/g, "");
}

function matchIdentifier(match) {
  return String(match?.match_details_id || match?.id || "").trim();
}

function eventStatus(match, hasKickoff) {
  const status = String(match?.score_status || match?.match_time || "")
    .trim()
    .toUpperCase();
  if (status.includes("CANCEL")) return "CANCELLED";
  if (!hasKickoff || status.includes("POSTPON")) return "TENTATIVE";
  return "CONFIRMED";
}

function eventLines(match, generatedAt) {
  const identifier = matchIdentifier(match);
  const matchDate = dateOnly(match?.date);
  if (!identifier || !matchDate) return [];

  const kickoffMs = Date.parse(String(match?.kickoff_at || ""));
  const hasKickoff = Number.isFinite(kickoffMs);
  const homeTeam = String(match?.home_team || "").trim();
  const awayTeam = String(match?.away_team || "").trim();
  if (!homeTeam || !awayTeam) return [];

  const lines = [
    "BEGIN:VEVENT",
    `UID:${escapeText(`bsd-${identifier}@top-scores`)}`,
    `DTSTAMP:${utcDateTime(generatedAt)}`,
  ];

  const lastModified = utcDateTime(match?.updated_at);
  if (lastModified) lines.push(`LAST-MODIFIED:${lastModified}`);

  if (hasKickoff) {
    lines.push(`DTSTART:${utcDateTime(new Date(kickoffMs))}`);
    lines.push(`DTEND:${utcDateTime(new Date(kickoffMs + DEFAULT_EVENT_DURATION_MS))}`);
  } else {
    lines.push(`DTSTART;VALUE=DATE:${matchDate}`);
    lines.push(`DTEND;VALUE=DATE:${nextDateOnly(match?.date)}`);
  }

  lines.push(`SUMMARY:${escapeText(`${homeTeam} vs ${awayTeam}`)}`);
  lines.push(`STATUS:${eventStatus(match, hasKickoff)}`);

  const description = [];
  const league = String(match?.league || "").trim();
  if (league) description.push(league);
  const channels = Array.isArray(match?.tv_channels)
    ? match.tv_channels.map((channel) => String(channel || "").trim()).filter(Boolean)
    : [];
  if (channels.length > 0) description.push(`TV: ${channels.join(", ")}`);
  if (description.length > 0) {
    lines.push(`DESCRIPTION:${escapeText(description.join("\n"))}`);
  }

  const venue = String(match?.venue_details?.name || "").trim();
  if (venue) lines.push(`LOCATION:${escapeText(venue)}`);
  lines.push("END:VEVENT");
  return lines;
}

function generateICalendar(matches, options = {}) {
  const generatedAt = options.generatedAt instanceof Date
    ? options.generatedAt
    : new Date(options.generatedAt || Date.now());
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "PRODID:-//Top Scores//Personal Match Calendar//EN",
    `X-WR-CALNAME:${escapeText(options.calendarName || CALENDAR_NAME)}`,
    "REFRESH-INTERVAL;VALUE=DURATION:PT15M",
    "X-PUBLISHED-TTL:PT15M",
  ];

  (Array.isArray(matches) ? matches : []).forEach((match) => {
    lines.push(...eventLines(match, generatedAt));
  });
  lines.push("END:VCALENDAR");

  const body = `${lines.map(foldLine).join("\r\n")}\r\n`;
  const etag = `"${crypto.createHash("sha256").update(body).digest("hex")}"`;
  return { body, etag };
}

module.exports = {
  CALENDAR_NAME,
  escapeText,
  foldLine,
  generateICalendar,
  matchIdentifier,
  utcDateTime,
};
