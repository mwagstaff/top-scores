const test = require("node:test");
const assert = require("node:assert/strict");
const cheerio = require("cheerio");

const {
  parseMatchDetailsFromHtml,
  __private,
} = require("./fetch_bbc_scores");

function minuteToAccessibleText(minute) {
  const normalized = String(minute || "").trim().replace(/'$/, "");
  const match = normalized.match(/^(\d+)\+(\d+)$/);
  if (match) {
    return `${match[1]} minutes plus ${match[2]}`;
  }
  return `${normalized} minutes`;
}

function buildFormationPlayer(player) {
  return `
    <div class="PlayerItem">
      <div data-testid="player-notation-circle">
        <div aria-hidden="true">${player.number}</div>
        <span class="visually-hidden">${player.number}, ${player.short_name}, ${player.role}</span>
      </div>
      <span data-testid="player-name">${player.short_name}</span>
    </div>
  `;
}

function buildPlayerListItem(player) {
  return `
    <li data-testid="player-list-item">
      <button>
        <div>
          <div data-testid="player-notation-circle">
            <div aria-hidden="true">${player.number}</div>
            <span class="visually-hidden">${player.number}, ${player.short_name}, ${player.role}</span>
          </div>
        </div>
        <div>
          <span class="PlayerNameWrapper">
            <span>${player.name}</span>
            ${player.captain
              ? ' <span role="text"><span aria-hidden="true">(c)</span><span class="visually-hidden">, Captain</span></span>'
              : ""}
          </span>
          ${player.substitution
            ? `
              <span class="PlayerSubstitutes">
                <span>
                  <span aria-hidden="true">${player.substitution.name} ${player.substitution.minute}</span>
                  <span class="visually-hidden">, substituted for ${player.substitution.name} at ${minuteToAccessibleText(player.substitution.minute)}</span>
                </span>
              </span>
            `
            : ""}
        </div>
      </button>
    </li>
  `;
}

function buildTeamBlock(side, teamName, manager, formation, formationRows, starters, substitutes) {
  return `
    <div>${side} team, ${teamName}</div>
    <div>
      <p data-testid="match-lineups-${side}-manager">Manager: ${manager}</p>
      <p data-testid="match-lineups-${side}-formation">Formation: ${formation.replace(/-/g, " - ")}</p>
    </div>
    <section>
      <h4>Pitch Formation</h4>
      <div data-testid="formation-container">
        <ul class="FormationRows">
          ${formationRows.map((row) => `<li>${row.map(buildFormationPlayer).join("")}</li>`).join("")}
        </ul>
      </div>
      <h4>Starting lineup</h4>
      <ul data-testid="player-list">
        ${starters.map(buildPlayerListItem).join("")}
      </ul>
    </section>
    <section>
      <h4>Substitutes</h4>
      <ul data-testid="player-list">
        ${substitutes.map(buildPlayerListItem).join("")}
      </ul>
    </section>
  `;
}

test("parseMatchDetailsFromHtml parses own goals and red cards from key events", () => {
  const html = `
    <div class="KeyEventsHome">
      <ul>
        <li>
          <span role="text">Eric García </span>
          <span aria-hidden="true"><span>(6' og)</span></span>
          <span class="visually-hidden">Own Goal 6 minutes</span>
        </li>
        <li>
          <span role="text">A. Griezmann </span>
          <span aria-hidden="true"><span>(14')</span></span>
          <span class="visually-hidden">Goal 14 minutes</span>
        </li>
        <li>
          <span role="text">A. Lookman </span>
          <span aria-hidden="true"><span>(33')</span></span>
          <span class="visually-hidden">Goal 33 minutes</span>
        </li>
        <li>
          <span role="text">J. Alvarez </span>
          <span aria-hidden="true"><span>(45'+2)</span></span>
          <span class="visually-hidden">Goal 45 minutes plus 2</span>
        </li>
      </ul>
    </div>
    <div class="KeyEventsAway">
      <ul>
        <li>
          <span role="text">Eric García </span>
          <span aria-hidden="true">
            <span>(<img data-testid="red-card-img" alt="" src="red-card.svg">85')</span>
          </span>
          <span class="visually-hidden">Red Card 85 minutes</span>
        </li>
      </ul>
    </div>
  `;

  const parsed = parseMatchDetailsFromHtml(html);
  assert.ok(parsed);

  assert.deepStrictEqual(parsed.home_goal_scorers, [
    {
      player: "Eric García",
      own_goal_times: ["6'"],
    },
    {
      player: "A. Griezmann",
      goal_times: ["14'"],
    },
    {
      player: "A. Lookman",
      goal_times: ["33'"],
    },
    {
      player: "J. Alvarez",
      goal_times: ["45+2'"],
    },
  ]);
  assert.deepStrictEqual(parsed.away_goal_scorers, []);
  assert.deepStrictEqual(parsed.home_red_cards, []);
  assert.deepStrictEqual(parsed.away_red_cards, [
    {
      player: "Eric García",
      red_card_times: ["85'"],
    },
  ]);
});

test("parseMatchDetailsFromHtml keeps normal goal objects backward-compatible", () => {
  const html = `
    <div class="KeyEventsHome">
      <ul>
        <li>
          <span role="text">K. Havertz </span>
          <span aria-hidden="true"><span>(12')</span></span>
          <span class="visually-hidden">Goal 12 minutes</span>
        </li>
      </ul>
    </div>
    <div class="KeyEventsAway"><ul></ul></div>
  `;

  const parsed = parseMatchDetailsFromHtml(html);
  assert.ok(parsed);
  assert.deepStrictEqual(parsed.home_goal_scorers, [
    {
      player: "K. Havertz",
      goal_times: ["12'"],
    },
  ]);
  assert.deepStrictEqual(parsed.home_red_cards, []);
  assert.deepStrictEqual(parsed.away_red_cards, []);
});

test("parseMatchDetailsFromHtml preserves stoppage-time goals in apostrophe-plus format", () => {
  const html = `
    <div class="KeyEventsHome">
      <ul>
        <li>
          <span role="text">Z. Flemming </span>
          <span aria-hidden="true"><span>(90'+3)</span></span>
          <span class="visually-hidden">Goal 90 minutes plus 3</span>
        </li>
      </ul>
    </div>
  `;

  const parsed = parseMatchDetailsFromHtml(html);
  assert.ok(parsed);
  assert.deepStrictEqual(parsed.home_goal_scorers, [
    {
      player: "Z. Flemming",
      goal_times: ["90+3'"],
    },
  ]);
});

test("parseMatchDetailsFromHtml parses aggregate score when only aggregate markup is present", () => {
  const html = `
    <div class="ssrcss-xxm013-MatchProgressContainer">
      <div class="ssrcss-m3fdxs-MatchProgressWrapper">
        <span class="visually-hidden">Aggregate score Atletico Madrid 3 , Club Brugge 3</span>
        <div data-testid="agg-score" class="ssrcss-smi1ab-AggregateScore">(Agg 3-3)</div>
      </div>
    </div>
  `;

  const parsed = parseMatchDetailsFromHtml(html);
  assert.ok(parsed);
  assert.equal(parsed.aggregate_home_score, "3");
  assert.equal(parsed.aggregate_away_score, "3");
  assert.deepStrictEqual(parsed.home_goal_scorers, []);
  assert.deepStrictEqual(parsed.away_goal_scorers, []);
});

test("parseMatchDetailsFromHtml extracts header metadata from BBC live match pages", () => {
  const html = `
    <html>
      <head>
        <title>Celta Vigo vs Real Madrid: Spanish La Liga stats &amp; head-to-head - BBC Sport</title>
      </head>
      <body>
        <div class="ssrcss-18cf29i-CompetitionFormatter">Spanish La Liga</div>
        <div data-participant-id="home">
          <div class="ssrcss-1ff7ivz-TeamNameWrapper">
            <span aria-hidden="true">Celta Vigo</span>
          </div>
        </div>
        <div data-testid="score" class="ssrcss-kfbgyz-StyledScore">
          <div class="ssrcss-qsbptj-HomeScore">1</div>
          <div class="ssrcss-fri5a2-AwayScore">1</div>
        </div>
        <div data-participant-id="away">
          <div class="ssrcss-1ff7ivz-TeamNameWrapper">
            <span aria-hidden="true">Real Madrid</span>
          </div>
        </div>
        <script type="application/json">
          {"coverageStartTime":"2026-03-06T20:00:00.000Z"}
        </script>
      </body>
    </html>
  `;

  const parsed = parseMatchDetailsFromHtml(html);
  assert.ok(parsed);
  assert.equal(parsed.date, "2026-03-06");
  assert.equal(parsed.time, "20:00");
  assert.equal(parsed.league, "Spanish La Liga");
  assert.equal(parsed.home_team, "Celta Vigo");
  assert.equal(parsed.away_team, "Real Madrid");
  assert.equal(parsed.home_score, 1);
  assert.equal(parsed.away_score, 1);
});

test("parseMatchDetailsFromHtml ignores head-to-head score widgets for pre-match fixtures", () => {
  const html = `
    <html>
      <head>
        <title>Fulham vs Southampton: FA Cup stats &amp; head-to-head - BBC Sport</title>
      </head>
      <body>
        <div class="CompetitionFormatter">FA Cup - 5th Round</div>
        <article data-event-id="match-1">
          <div data-participant-id="home">
            <div class="TeamNameWrapper">
              <span>Fulham</span>
            </div>
          </div>
          <time datetime="2026-03-08T12:00:00Z">12:00</time>
          <div data-participant-id="away">
            <div class="TeamNameWrapper">
              <span>Southampton</span>
            </div>
          </div>
        </article>
        <section>
          <div data-testid="score" class="HistoricalScore">
            <div class="HomeScore">1</div>
            <div class="AwayScore">2</div>
          </div>
          <div class="MatchProgress">
            <div class="StyledPeriod">26 APR 2025</div>
          </div>
        </section>
        <script type="application/json">
          {"coverageStartTime":"2026-03-08T12:00:00.000Z"}
        </script>
      </body>
    </html>
  `;

  const parsed = parseMatchDetailsFromHtml(html);
  assert.ok(parsed);
  assert.equal(parsed.date, "2026-03-08");
  assert.equal(parsed.time, "12:00");
  assert.equal(parsed.home_team, "Fulham");
  assert.equal(parsed.away_team, "Southampton");
  assert.equal(parsed.home_score, undefined);
  assert.equal(parsed.away_score, undefined);
  assert.equal(parsed.score_status, undefined);
});

test("parseMatchDetailsFromHtml parses team lineups, bench players, and substitutions", () => {
  const homeStarters = [
    { number: 1, short_name: "Roberts", role: "Goalkeeper", name: "L. Roberts" },
    { number: 2, short_name: "Knoyle", role: "Defender", name: "K. Knoyle", substitution: { name: "E. Hewitt", minute: "87'" } },
    { number: 23, short_name: "Oshilaja", role: "Defender", name: "A. Oshilaja" },
    { number: 20, short_name: "Blake-Tracy", role: "Defender", name: "F. Blake-Tracy" },
    { number: 7, short_name: "Akins", role: "Midfielder", name: "L. Akins" },
    { number: 13, short_name: "Russell", role: "Midfielder", name: "J. Russell" },
    { number: 25, short_name: "Reed", role: "Midfielder", name: "L. Reed", captain: true },
    { number: 40, short_name: "Abbott", role: "Midfielder", name: "G. Abbott" },
    { number: 3, short_name: "McLaughlin", role: "Midfielder", name: "S. McLaughlin" },
    { number: 18, short_name: "Oates", role: "Striker", name: "R. Oates" },
    { number: 29, short_name: "Roberts", role: "Striker", name: "T. Roberts" },
  ];
  const homeSubstitutes = [
    { number: 4, short_name: "Hewitt", role: "Substitute", name: "E. Hewitt" },
    { number: 19, short_name: "Adeboyejo", role: "Substitute", name: "V. Adeboyejo" },
    { number: 11, short_name: "Evans", role: "Substitute", name: "W. Evans" },
  ];
  const awayStarters = [
    { number: 13, short_name: "Arrizabalaga", role: "Goalkeeper", name: "Kepa Arrizabalaga" },
    { number: 89, short_name: "Salmon", role: "Defender", name: "M. Salmon", substitution: { name: "J. Timber", minute: "62'" } },
    { number: 3, short_name: "Mosquera", role: "Defender", name: "Cristhian Mosquera" },
    { number: 33, short_name: "Calafiori", role: "Defender", name: "R. Calafiori" },
    { number: 20, short_name: "Madueke", role: "Midfielder", name: "N. Madueke" },
    { number: 56, short_name: "Dowman", role: "Midfielder", name: "M. Dowman" },
    { number: 16, short_name: "Nørgaard", role: "Midfielder", name: "C. Nørgaard" },
    { number: 19, short_name: "Trossard", role: "Midfielder", name: "L. Trossard" },
    { number: 11, short_name: "Gabriel Martinelli", role: "Midfielder", name: "Gabriel Martinelli" },
    { number: 29, short_name: "Havertz", role: "Attacking Midfielder", name: "K. Havertz" },
    { number: 9, short_name: "Gabriel Jesus", role: "Striker", name: "Gabriel Jesus", captain: true },
  ];
  const awaySubstitutes = [
    { number: 12, short_name: "Timber", role: "Substitute", name: "J. Timber" },
    { number: 10, short_name: "Eze", role: "Substitute", name: "E. Eze" },
    { number: 7, short_name: "Saka", role: "Substitute", name: "B. Saka" },
  ];

  const html = `
    <section id="Line-ups">
      <div data-testid="styled-match-lineup">
        <div class="GridContainer-LineupsGridContainer">
          ${buildTeamBlock(
            "home",
            "Mansfield Town",
            "Nigel Clough",
            "3-5-2",
            [
              [homeStarters[0]],
              [homeStarters[1], homeStarters[2], homeStarters[3]],
              [homeStarters[4], homeStarters[5], homeStarters[6], homeStarters[7], homeStarters[8]],
              [homeStarters[9], homeStarters[10]],
            ],
            homeStarters,
            homeSubstitutes
          )}
          ${buildTeamBlock(
            "away",
            "Arsenal",
            "Mikel Arteta",
            "3-5-1-1",
            [
              [awayStarters[0]],
              [awayStarters[1], awayStarters[2], awayStarters[3]],
              [awayStarters[4], awayStarters[5], awayStarters[6], awayStarters[7], awayStarters[8]],
              [awayStarters[9]],
              [awayStarters[10]],
            ],
            awayStarters,
            awaySubstitutes
          )}
        </div>
      </div>
    </section>
  `;

  const parsed = parseMatchDetailsFromHtml(html);
  assert.ok(parsed);
  assert.ok(parsed.team_lineups);

  assert.equal(parsed.team_lineups.home.team, "Mansfield Town");
  assert.equal(parsed.team_lineups.home.manager, "Nigel Clough");
  assert.equal(parsed.team_lineups.home.formation, "3-5-2");
  assert.equal(parsed.team_lineups.home.starting_lineup.length, 11);
  assert.deepStrictEqual(parsed.team_lineups.home.starting_lineup[0], {
    number: 1,
    name: "L. Roberts",
    position_category: "goalkeeper",
  });
  assert.deepStrictEqual(parsed.team_lineups.home.starting_lineup[9], {
    number: 18,
    name: "R. Oates",
    position_category: "attacker",
  });
  assert.deepStrictEqual(parsed.team_lineups.home.substitutions, [
    {
      minute: "87'",
      player_off: {
        number: 2,
        name: "K. Knoyle",
      },
      player_on: {
        number: 4,
        name: "E. Hewitt",
      },
    },
  ]);

  assert.equal(parsed.team_lineups.away.team, "Arsenal");
  assert.equal(parsed.team_lineups.away.formation, "3-5-1-1");
  assert.equal(parsed.team_lineups.away.starting_lineup.length, 11);
  assert.deepStrictEqual(parsed.team_lineups.away.starting_lineup[9], {
    number: 29,
    name: "K. Havertz",
    position_category: "midfielder",
  });
  assert.deepStrictEqual(parsed.team_lineups.away.starting_lineup[10], {
    number: 9,
    name: "Gabriel Jesus (c)",
    position_category: "attacker",
  });
  assert.deepStrictEqual(parsed.team_lineups.away.substitutions, [
    {
      minute: "62'",
      player_off: {
        number: 89,
        name: "M. Salmon",
      },
      player_on: {
        number: 12,
        name: "J. Timber",
      },
    },
  ]);
});

test("parseMatchDetailsFromHtml splits competition name and subheading across formatter nodes", () => {
  const html = `
    <html>
      <head>
        <title>FA Cup LIVE: Wolves vs Liverpool - BBC Sport</title>
      </head>
      <body>
        <div class="ssrcss-18cf29i-CompetitionFormatter">FA Cup - </div>
        <div class="ssrcss-18cf29i-CompetitionFormatter">5th Round</div>
        <div data-participant-id="home">
          <div class="ssrcss-1ff7ivz-TeamNameWrapper">
            <span aria-hidden="true">Wolverhampton Wanderers</span>
          </div>
        </div>
        <div data-testid="score" class="ssrcss-kfbgyz-StyledScore">
          <div class="ssrcss-qsbptj-HomeScore">1</div>
          <div class="ssrcss-fri5a2-AwayScore">3</div>
        </div>
        <div data-participant-id="away">
          <div class="ssrcss-1ff7ivz-TeamNameWrapper">
            <span aria-hidden="true">Liverpool</span>
          </div>
        </div>
        <script type="application/json">
          {"coverageStartTime":"2026-03-06T18:45:00.000Z"}
        </script>
      </body>
    </html>
  `;

  const parsed = parseMatchDetailsFromHtml(html);
  assert.ok(parsed);
  assert.equal(parsed.league, "FA Cup");
  assert.equal(parsed.league_subcategory, "5th Round");
  assert.equal(parsed.date, "2026-03-06");
  assert.equal(parsed.time, "18:45");
  assert.equal(parsed.home_team, "Wolverhampton Wanderers");
  assert.equal(parsed.away_team, "Liverpool");
  assert.equal(parsed.home_score, 1);
  assert.equal(parsed.away_score, 3);
});

test("parseMatchDetailsFromHtml falls back to title and metadata when header competition is absent", () => {
  const html = `
    <html>
      <head>
        <title>Celta Vigo vs Real Madrid: Spanish La Liga stats &amp; head-to-head - BBC Sport</title>
        <meta
          name="description"
          content="Follow live text commentary, score updates and match stats from Celta Vigo vs Real Madrid in the Spanish La Liga"
        />
      </head>
      <body>
        <script type="application/json">
          {"coverageStartTime":"2026-03-06T20:00:00.000Z"}
        </script>
      </body>
    </html>
  `;

  const parsed = parseMatchDetailsFromHtml(html);
  assert.ok(parsed);
  assert.equal(parsed.date, "2026-03-06");
  assert.equal(parsed.time, "20:00");
  assert.equal(parsed.league, "Spanish La Liga");
  assert.equal(parsed.home_team, "Celta Vigo");
  assert.equal(parsed.away_team, "Real Madrid");
});

test("extractStatusFromText does not treat aggregate text as live minute", () => {
  assert.equal(__private.extractStatusFromText("(Agg 3-3)"), null);
  assert.equal(
    __private.extractStatusFromText("Aggregate score Atletico Madrid 3 , Club Brugge 3"),
    null
  );
  assert.equal(__private.extractStatusFromText("3'"), "3");
});

test("extractStatusFromText parses minute-word formats", () => {
  assert.equal(__private.extractStatusFromText("24 minutes"), "24");
  assert.equal(__private.extractStatusFromText("45 minutes plus 2"), "45+2");
});

test("pickEventStatus prefers live minute over conflicting FT token", () => {
  const event = {
    periodLabel: { accessible: "24 minutes" },
    statusComment: { value: "FT" },
    status: "FT",
  };
  assert.equal(__private.pickEventStatus(event), "24");
});

test("pickEventStatus prefers terminal status when lifecycle is post-event", () => {
  const event = {
    periodLabel: { accessible: "49 minutes" },
    statusComment: { value: "FT", accessible: "Full time" },
    status: "PostEvent",
  };
  assert.equal(__private.pickEventStatus(event), "FT");
});

test("parseMatchesFromDom ignores aggregate-only fixture cards", () => {
  const html = `
    <article data-event-id="cdxzkljkjxkt">
      <div data-participant-id="home">
        <div class="TeamNameWrapper">
          <span>Atletico Madrid</span>
        </div>
      </div>
      <div class="WithInlineFallback-Scores">
        <div class="StyledCentre">
          <time class="StyledTime">17:45</time>
        </div>
      </div>
      <div data-participant-id="away">
        <div class="TeamNameWrapper">
          <span>Club Brugge</span>
        </div>
      </div>
      <div class="MatchProgressContainer">
        <div class="MatchProgressWrapper">
          <span class="visually-hidden">Aggregate score Atletico Madrid 3 , Club Brugge 3</span>
          <div data-testid="agg-score" class="AggregateScore">(Agg 3-3)</div>
        </div>
      </div>
    </article>
  `;

  const $ = cheerio.load(html);
  const parsed = __private.parseMatchesFromDom($);
  assert.deepStrictEqual(parsed, []);
});

test("pickCompetitionName disambiguates non-English Premier League competitions", () => {
  const node = {
    competitionName: "Premier League",
    tournamentSlug: "ukrainian-premier-league",
    url: "/sport/football/ukrainian-premier-league/scores-fixtures",
  };

  const league = __private.pickCompetitionName(node, null);
  assert.equal(league, "Ukraine Premier League");
});

test("normalizeDetailsUrl rejects non-football BBC URLs", () => {
  const valid = __private.normalizeDetailsUrl("https://www.bbc.co.uk/sport/football/live/cm247jz3p05t");
  const invalid = __private.normalizeDetailsUrl("https://www.bbc.co.uk/64bxxwu2mv2qqlv0monbkj1om");

  assert.equal(valid, "https://www.bbc.co.uk/sport/football/live/cm247jz3p05t");
  assert.equal(invalid, null);
});

test("selectMatchCandidateByDetailsUrl only returns exact details-url matches", () => {
  const candidates = [
    {
      home_team: "Aston Villa",
      away_team: "Leeds United",
      details_url: "https://www.bbc.co.uk/sport/football/live/ceqvjrgl5x5t",
    },
  ];
  const normalizedTarget =
    __private.normalizeDetailsUrlKey(
      __private.normalizeDetailsUrl("https://www.bbc.co.uk/sport/football/live/c1kgj4ve3jkt")
    );

  const selected = __private.selectMatchCandidateByDetailsUrl(candidates, normalizedTarget);
  assert.equal(selected, null);
});
