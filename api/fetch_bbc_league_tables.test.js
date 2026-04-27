const test = require("node:test");
const assert = require("node:assert/strict");

const { extractLeagueTableFromHtml } = require("./fetch_bbc_league_tables");

function participant(rank, name, matchesPlayed, points) {
  return {
    rank,
    name,
    matchesPlayed,
    wins: 0,
    draws: 0,
    losses: 0,
    goalsScoredFor: 0,
    goalsScoredAgainst: 0,
    goalDifference: 0,
    points,
  };
}

function htmlForFootballTable(tournaments) {
  const payload = {
    data: {
      "football-table?test": {
        data: {
          tournaments,
        },
      },
    },
  };
  return `<script>window.__INITIAL_DATA__ = ${JSON.stringify(JSON.stringify(payload))};</script>`;
}

test("extractLeagueTableFromHtml prefers the current split phase over the larger first phase", () => {
  const html = htmlForFootballTable([
    {
      lastUpdated: "26th April 2026 at 19:37",
      stages: [
        {
          name: "2nd Phase",
          rounds: [
            {
              name: "Championship Group",
              participants: [
                participant(1, "Hearts", 34, 73),
                participant(2, "Celtic", 34, 70),
              ],
            },
            {
              name: "Relegation Group",
              participants: [
                participant(1, "Dundee United", 34, 43),
                participant(2, "Livingston", 34, 19),
              ],
            },
          ],
        },
        {
          name: "1st Phase",
          rounds: [
            {
              participants: [
                participant(1, "Hearts", 33, 70),
                participant(2, "Rangers", 33, 69),
                participant(3, "Celtic", 33, 67),
                participant(4, "Livingston", 33, 16),
              ],
            },
          ],
        },
      ],
    },
  ]);

  const table = extractLeagueTableFromHtml(html, {
    id: "scottish-premiership",
    name: "Scottish Premiership",
    url: "https://www.bbc.co.uk/sport/football/scottish-premiership/table",
  });

  assert.equal(table.stage_name, "2nd Phase");
  assert.deepEqual(
    table.groups.map((group) => group.name),
    ["Championship Group", "Relegation Group"]
  );
  assert.deepEqual(
    table.groups.map((group) => group.rows.map((row) => `${row.position}. ${row.team} ${row.played} ${row.points}`)),
    [
      ["1. Hearts 34 73", "2. Celtic 34 70"],
      ["1. Dundee United 34 43", "2. Livingston 34 19"],
    ]
  );
  assert.deepEqual(
    table.rows.map((row) => `${row.position}. ${row.team} ${row.played} ${row.points}`),
    [
      "1. Hearts 34 73",
      "2. Celtic 34 70",
      "3. Dundee United 34 43",
      "4. Livingston 34 19",
    ]
  );
});
