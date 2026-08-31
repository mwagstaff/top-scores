"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  __private: {
    normalizePlayerDetailsPayload,
    normalizeTeamSquadPayload,
    playerPayloadWithExchangeRate,
    playerPayloadWithFantasyData,
    normalizeManagerPayload,
    normalizeManagerCareerPayload,
    normalizeTeamManagerPayload,
  },
} = require("./server");

test("player payload retains Pascal Gross BSD profile fields", () => {
  const payload = normalizePlayerDetailsPayload({
    id: 2173,
    name: "Pascal Groß",
    short_name: "P. Groß",
    position: "M",
    specific_position: "MID",
    jersey_number: 13,
    date_of_birth: "1991-06-15",
    preferred_foot: "R",
    nationality: "Germany",
    current_team_id: 5,
    current_team: { id: 5, name: "Brighton & Hove Albion", short_name: "Brighton" },
    market_value_eur: 2_300_000,
    availability: "available",
  });

  assert.equal(payload.id, "2173");
  assert.equal(payload.born, "1991-06-15");
  assert.equal(payload.date_of_birth, "1991-06-15");
  assert.equal(payload.team, "Brighton & Hove Albion");
  assert.equal(payload.side, "Right");
  assert.equal(payload.jersey_number, 13);
  assert.equal(payload.market_value_eur, 2_300_000);
  assert.equal(payload.availability, "available");
});

test("player payload adds FPL points, ownership and profile picture when matched", () => {
  const payload = playerPayloadWithFantasyData(
    {
      id: "2173",
      name: "Pascal Groß",
      team: "Brighton & Hove Albion",
      current_team: { name: "Brighton & Hove Albion" },
    },
    {
      total_players: 12_000_000,
      teams: [{ id: 5, name: "Brighton" }],
      elements: [{
        id: 200,
        code: 12345,
        first_name: "Pascal",
        second_name: "Groß",
        web_name: "Groß",
        team: 5,
        total_points: 155,
        selected_by_percent: "10.5",
      }],
    }
  );

  assert.equal(payload.fpl_element_id, 200);
  assert.equal(payload.fpl_first_name, "Pascal");
  assert.equal(payload.fpl_last_name, "Groß");
  assert.equal(payload.fpl_total_points, 155);
  assert.equal(payload.fpl_selected_by_percent, 10.5);
  assert.equal(payload.fpl_selected_by_count, 1_260_000);
  assert.match(payload.fpl_profile_url, /12345\.png$/);
});

test("player payload calculates GBP value when a rate is available", () => {
  const payload = playerPayloadWithExchangeRate({ market_value_eur: 10_000_000 }, { rate: 0.85 });
  assert.equal(payload.market_value_gbp, 8_500_000);
});

test("player payload does not invent a zero GBP value when market value is absent", () => {
  const payload = playerPayloadWithExchangeRate({ market_value_eur: null }, { rate: 0.85 });
  assert.equal(payload.market_value_gbp, null);
});

test("team squad merges full player values and availability", () => {
  const payload = normalizeTeamSquadPayload(
    "1",
    {
      team_id: 1,
      players: [{ id: 323, name: "Joe Gomez", jersey_number: 2, availability: "injured" }],
    },
    [{
      id: 323,
      name: "Joe Gomez",
      current_team_id: 1,
      nationality: "England",
      market_value_eur: 12_600_000,
      availability: "injured",
      injury_type: "Strain Injury",
    }],
    { rate: 0.85, date: "2026-08-30", source: "cache", stale: false }
  );

  assert.equal(payload.team_id, "1");
  assert.equal(payload.count, 1);
  assert.equal(payload.players[0].jersey_number, 2);
  assert.equal(payload.players[0].market_value_gbp, 10_710_000);
  assert.equal(payload.players[0].availability, "injured");
  assert.equal(payload.players[0].injury_type, "Strain Injury");
});

test("manager payload calculates draw and loss percentages from matches", () => {
  const payload = normalizeManagerPayload({
    id: 264,
    name: "Álvaro Arbeloa",
    country: "Spain",
    current_team_id: 6,
    matches_total: 63,
    wins: 40,
    draws: 7,
    losses: 16,
    win_pct: 63.5,
  });

  assert.equal(payload.current_team_id, "6");
  assert.equal(payload.draw_pct, 11.1);
  assert.equal(payload.loss_pct, 25.4);
  assert.match(payload.image_url, /\/img\/manager\/264\//);
});

test("team manager payload uses the current club tenure instead of career totals", () => {
  const payload = normalizeTeamManagerPayload(
    {
      id: 322,
      name: "Pierre Sage",
      current_team_id: 14,
      matches_total: 65,
      wins: 40,
      draws: 10,
      losses: 15,
      win_pct: 61.5,
    },
    "14",
    {
      manager_id: 322,
      tenures: [{
        team_id: 14,
        team_name: "Crystal Palace",
        date_from: "2026-03-21",
        date_to: null,
        matches: 14,
        wins: 7,
        draws: 1,
        losses: 6,
        win_pct: 50,
      }],
    }
  );

  assert.equal(payload.matches_total, 14);
  assert.equal(payload.wins, 7);
  assert.equal(payload.draws, 1);
  assert.equal(payload.losses, 6);
  assert.equal(payload.win_pct, 50);
  assert.equal(payload.draw_pct, 7.1);
  assert.equal(payload.loss_pct, 42.9);
  assert.equal(payload.record_scope, "current_team");
  assert.equal(payload.record_team_id, "14");
});

test("team manager payload omits career totals when current tenure is unavailable", () => {
  const payload = normalizeTeamManagerPayload(
    {
      id: 322,
      name: "Pierre Sage",
      current_team_id: 14,
      matches_total: 65,
      wins: 40,
      draws: 10,
      losses: 15,
    },
    "14",
    null
  );

  assert.equal(payload.matches_total, null);
  assert.equal(payload.wins, null);
  assert.equal(payload.draws, null);
  assert.equal(payload.losses, null);
});

test("manager career filters reversed dates and retains appointment effect data", () => {
  const payload = normalizeManagerCareerPayload("264", {
    manager_id: 264,
    tenures: [
      { team_id: 10, team_name: "Older FC", date_to: "2020-06-30", matches: 20 },
      {
        team_id: 57,
        team_name: "Real Madrid",
        date_from: "2026-04-04",
        matches: 3,
        appointment_effect: {
          window: 10,
          before: { matches: 10, points: 18, ppm: 1.8 },
          after: { matches: 4, points: 9, ppm: 2.25, matches_led_by_manager: 4 },
          ppm_change: 0.45,
        },
      },
      {
        team_id: 112,
        team_name: "Invalid FC",
        date_from: "2026-04-04",
        date_to: "2026-02-14",
        matches: 0,
      },
    ],
  });

  assert.equal(payload.manager_id, "264");
  assert.equal(payload.count, 2);
  assert.equal(payload.tenures[0].team_name, "Real Madrid");
  assert.match(payload.tenures[0].team_logo_url, /\/img\/team\/57\//);
  assert.equal(payload.tenures[0].appointment_effect.before.ppm, 1.8);
  assert.equal(payload.tenures[0].appointment_effect.after.matches_led_by_manager, 4);
  assert.equal(payload.tenures[0].appointment_effect.ppm_change, 0.45);
  assert.equal(payload.tenures.some((tenure) => tenure.team_name === "Invalid FC"), false);
});
