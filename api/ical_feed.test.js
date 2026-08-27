const test = require("node:test");
const assert = require("node:assert/strict");

const { escapeText, foldLine, generateICalendar } = require("./ical_feed");

test("generateICalendar emits a stable timed match event", () => {
  const match = {
    id: "8324",
    match_details_id: "8324",
    date: "2026-08-30",
    kickoff_at: "2026-08-30T15:30:00.000Z",
    home_team: "Arsenal",
    away_team: "Chelsea",
    league: "Premier League",
    tv_channels: ["Sky Sports Main Event"],
    venue_details: { name: "Emirates Stadium" },
    updated_at: "2026-08-27T12:00:00.000Z",
  };

  const { body, etag } = generateICalendar([match], {
    generatedAt: new Date("2026-08-27T13:00:00.000Z"),
  });

  assert.match(body, /UID:bsd-8324@top-scores\r\n/);
  assert.match(body, /DTSTART:20260830T153000Z\r\n/);
  assert.match(body, /DTEND:20260830T173000Z\r\n/);
  assert.match(body, /SUMMARY:Arsenal vs Chelsea\r\n/);
  assert.match(body, /DESCRIPTION:Premier League\\nTV: Sky Sports Main Event\r\n/);
  assert.match(body, /LOCATION:Emirates Stadium\r\n/);
  assert.match(body, /STATUS:CONFIRMED\r\n/);
  assert.ok(body.endsWith("END:VCALENDAR\r\n"));
  assert.match(etag, /^"[a-f0-9]{64}"$/);
});

test("generateICalendar emits an all-day tentative event for a TBC kickoff", () => {
  const { body } = generateICalendar([
    {
      match_details_id: "9001",
      date: "2026-09-01",
      kickoff_at: null,
      home_team: "Winner SF1",
      away_team: "Winner SF2",
      league: "Cup",
      tv_channels: [],
    },
  ], { generatedAt: new Date("2026-08-27T00:00:00Z") });

  assert.match(body, /DTSTART;VALUE=DATE:20260901\r\n/);
  assert.match(body, /DTEND;VALUE=DATE:20260902\r\n/);
  assert.match(body, /STATUS:TENTATIVE\r\n/);
});

test("iCalendar text is escaped and folded to 75 UTF-8 octets", () => {
  assert.equal(escapeText("A, B; C\\D\nE"), "A\\, B\\; C\\\\D\\nE");
  const folded = foldLine(`DESCRIPTION:${"é".repeat(80)}`);
  const physicalLines = folded.split("\r\n");
  assert.ok(physicalLines.length > 1);
  physicalLines.forEach((line) => {
    assert.ok(Buffer.byteLength(line, "utf8") <= 75);
  });
  assert.ok(physicalLines.slice(1).every((line) => line.startsWith(" ")));
});

test("a rescheduled fixture keeps the same UID while its start changes", () => {
  const base = {
    match_details_id: "42",
    date: "2026-09-02",
    home_team: "Home",
    away_team: "Away",
    league: "League",
  };
  const first = generateICalendar([
    { ...base, kickoff_at: "2026-09-02T12:00:00Z" },
  ], { generatedAt: new Date(0) }).body;
  const second = generateICalendar([
    { ...base, kickoff_at: "2026-09-02T14:00:00Z" },
  ], { generatedAt: new Date(0) }).body;

  assert.match(first, /UID:bsd-42@top-scores/);
  assert.match(second, /UID:bsd-42@top-scores/);
  assert.match(first, /DTSTART:20260902T120000Z/);
  assert.match(second, /DTSTART:20260902T140000Z/);
});
