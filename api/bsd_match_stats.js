"use strict";

// One presentation contract for web and iOS; never turn absent coverage into zero.
const METRICS = [
  ["ball_possession", "Possession", "Key stats", "percent"],
  ["xg", "Expected goals (xG)", "Key stats", "xg"],
  ["total_shots", "Shots", "Key stats"],
  ["shots_on_target", "Shots on target", "Key stats"],
  ["big_chances", "Big chances", "Key stats"],
  ["corner_kicks", "Corners", "Key stats"],
  ["shots_off_target", "Shots off target", "Shooting"],
  ["blocked_shots", "Blocked shots", "Shooting"],
  ["hit_woodwork", "Hit woodwork", "Shooting"],
  ["shots_inside_box", "Shots inside the box", "Shooting"],
  ["shots_outside_box", "Shots outside the box", "Shooting"],
  ["big_chances_scored", "Big chances scored", "Shooting"],
  ["big_chances_missed", "Big chances missed", "Shooting"],
  ["expected_goals_on_target", "xG on target", "Shooting", "decimal"],
  ["passes", "Passes", "Passing"],
  ["accurate_passes", "Accurate passes", "Passing"],
  ["pass_accuracy_pct", "Pass accuracy", "Passing", "percent"],
  ["long_balls", "Long balls completed", "Passing", "ratio"],
  ["crosses", "Crosses completed", "Passing", "ratio"],
  ["final_third_phase", "Final-third passes completed", "Passing", "ratio"],
  ["final_third_entries", "Final-third entries", "Attacking"],
  ["touches_in_penalty_area", "Touches in opposition box", "Attacking"],
  ["dribbles", "Successful dribbles", "Attacking", "ratio"],
  ["dispossessed", "Dispossessed", "Attacking"],
  ["fouled_in_final_third", "Fouled in final third", "Attacking"],
  ["tackles", "Tackles", "Defending", "count", "total_tackles"],
  ["tackles_won", "Tackles won", "Defending", "percent"],
  ["interceptions", "Interceptions", "Defending"],
  ["clearances", "Clearances", "Defending"],
  ["recoveries", "Recoveries", "Defending"],
  ["duels", "Duels won", "Defending", "percent"],
  ["aerial_duels", "Aerial duels won", "Defending", "ratio"],
  ["ground_duels", "Ground duels won", "Defending", "ratio"],
  ["goalkeeper_saves", "Saves", "Goalkeeping", "count", "total_saves"],
  ["big_saves", "Big saves", "Goalkeeping"],
  ["high_claims", "High claims", "Goalkeeping"],
  ["goals_prevented", "Goals prevented", "Goalkeeping", "signed"],
  ["fouls", "Fouls committed", "Discipline"],
  ["offsides", "Offsides", "Discipline"],
  ["yellow_cards", "Yellow cards", "Discipline"],
  ["red_cards", "Red cards", "Discipline"],
  ["free_kicks", "Free kicks", "Restarts"],
  ["throw_ins", "Throw-ins", "Restarts"],
  ["goal_kicks", "Goal kicks", "Restarts"],
  ["average_rating", "Average player rating", "Other", "decimal"],
];
const number = value => typeof value === "number" && Number.isFinite(value) ? value : null;
const object = value => value && typeof value === "object" && !Array.isArray(value);

function statValue(side, [id, , , format = "count", alias]) {
  const raw = side?.[id] ?? (alias ? side?.[alias] : null);
  let value = number(format === "xg" ? raw?.actual : format === "ratio" ? raw?.value : raw);
  if (value != null && ((format !== "signed" && value < 0) || (format === "percent" && value > 100) ||
      (["count", "ratio"].includes(format) && !Number.isInteger(value)))) value = null;
  if (value == null) return { value: null, display: "—", estimated: false };
  let display;
  if (format === "ratio") {
    const total = number(raw.total);
    if (total == null || total < value || !Number.isInteger(total)) return { value: null, display: "—", estimated: false };
    display = `${value}/${total}`;
    const pct = number(raw.pct);
    if (pct != null && pct >= 0 && pct <= 100) display += ` (${pct}%)`;
  } else if (["xg", "decimal", "signed"].includes(format)) display = value.toFixed(2);
  else display = `${value}${format === "percent" ? "%" : ""}`;
  return { value, display, estimated: format === "xg" && raw?.estimated === true };
}

function shotCounts(shotmap, period) {
  // An empty feed means no coverage, not a match with no attempts.
  if (!Array.isArray(shotmap) || !shotmap.length) return null;
  const shots = shotmap.filter(s => s?.sit !== "shootout");
  if (!shots.length || shots.some(s => typeof s?.home !== "boolean" ||
      !["goal", "save", "miss", "block", "blocked-off-line", "post"].includes(s.type))) return null;
  if (period !== "all" && shots.some(s => number(s.min) == null || s.min < 0)) return null;
  const selected = shots.filter(s => period === "all" || (period === "first_half" ? s.min <= 45 : s.min > 45 && s.min <= 90));
  return Object.fromEntries(["home", "away"].map(side => {
    const attempts = selected.filter(s => s.home === (side === "home"));
    return [side, {
      total_shots: attempts.length,
      shots_on_target: attempts.filter(s => ["goal", "save"].includes(s.type)).length,
      shots_off_target: attempts.filter(s => s.type === "miss").length,
      blocked_shots: attempts.filter(s => ["block", "blocked-off-line"].includes(s.type)).length,
      hit_woodwork: attempts.filter(s => s.type === "post").length,
    }];
  }));
}

function projectMatchStats(doc, event, now = Date.now()) {
  const payload = doc?.payload;
  const periods = [];
  for (const [id, label] of [["all", "All"], ["first_half", "1st half"], ["second_half", "2nd half"]]) {
    const source = id === "all" ? payload?.stats : payload?.stats?.[id];
    if (!object(source)) continue;
    // A period is available only when BSD actually supplies counters for it.
    const supplied = METRICS.some(metric => [source.home, source.away].some(side => statValue(side, metric).value != null));
    if (id !== "all" && !supplied) continue;
    const shots = shotCounts(payload?.shotmap, id);
    const rows = METRICS.map((metric, index) => {
      const [key, title, group] = metric;
      const values = ["home", "away"].map(side => statValue({ ...source[side], ...shots?.[side] }, metric));
      return { id: key, label: title, group, headline: index < 6,
        home: values[0].value, away: values[1].value,
        home_display: values[0].display, away_display: values[1].display,
        home_estimated: values[0].estimated, away_estimated: values[1].estimated };
    }).filter(row => row.home != null || row.away != null);
    if (rows.length) periods.push({ id, label, rows });
  }
  const finished = event.status === "finished";
  const age = now - Date.parse(event.event_date);
  const recent = Number.isFinite(age) && age >= 0 && age <= 14 * 86400000;
  return {
    status: periods.length ? "available" : doc ? "unavailable" : "pending",
    periods, updated_at: doc?.updated_at || null,
    refresh_after_seconds: !finished || (recent && (!doc || age < 5 * 3600000)) ? 60 : null,
  };
}
module.exports = { projectMatchStats };
