const test = require("node:test");
const assert = require("node:assert/strict");
const cheerio = require("cheerio");

const {
  parseMatchDetailsFromHtml,
  __private,
} = require("./fetch_bbc_scores");

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
