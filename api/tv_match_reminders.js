"use strict";

const crypto = require("crypto");
const MINUTE = 60_000;

// Scores filtering and broadcast selection are supplied by the same server rules
// used for Scores. A reminder never opts a user into match-event notifications.
function reminderGroups(user, matches, nowMs, channelsForMatch) {
  const prefs = user.preferences || {};
  if (!user.apnsToken || prefs.notificationsEnabled !== true || prefs.tvMatchRemindersEnabled === false) return [];
  const minutes = [5, 10, 15, 30].includes(prefs.tvMatchReminderMinutes) ? prefs.tvMatchReminderMinutes : 10;
  const minimum = [0, 55, 70, 85].includes(prefs.tvMatchReminderMinimumScore) ? prefs.tvMatchReminderMinimumScore : 70;
  const groups = new Map();
  for (const match of matches) {
    const kickoff = Date.parse(match.kickoff_at);
    const status = String(match.score_status || match.match_time || "").toLowerCase();
    if (status && !["ns", "notstarted", "not_started", "scheduled"].includes(status)) continue;
    // A bounded catch-up window avoids stale reminders after an outage or opt-in.
    const due = kickoff - minutes * MINUTE;
    if (!Number.isFinite(kickoff) || kickoff <= nowMs || due > nowMs || nowMs - due > 90_000) continue;
    const score = match.watchability_index?.score;
    if (minimum > 0 && (typeof score !== "number" || !Number.isFinite(score) || score < minimum)) continue;
    const id = String(match.match_details_id || match.id || "");
    const channels = channelsForMatch(match, prefs);
    if (!id || channels.length === 0) continue;
    if (!groups.has(kickoff)) groups.set(kickoff, new Map());
    groups.get(kickoff).set(id, { ...match, reminderID: id, reminderChannels: channels });
  }
  return [...groups].map(([kickoff, entries]) => ({
    kickoff,
    matches: [...entries.values()].sort((a, b) => (b.watchability_index?.score || 0) - (a.watchability_index?.score || 0) || a.reminderID.localeCompare(b.reminderID)),
  }));
}

function reminderMessage(user, group, nowMs) {
  const prefs = user.preferences || {};
  let time;
  try {
    time = new Intl.DateTimeFormat(prefs.deviceLocale || "en-GB", { timeZone: prefs.deviceTimeZone || "Europe/London", hour: "2-digit", minute: "2-digit" }).format(group.kickoff);
  } catch {
    time = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", hour: "2-digit", minute: "2-digit" }).format(group.kickoff);
  }
  const matches = group.matches;
  const names = (match) => `${match.home_team} v ${match.away_team}`;
  const remaining = Math.max(1, Math.ceil((group.kickoff - nowMs) / MINUTE));
  return {
    title: matches.length === 1 ? `${names(matches[0])} · ${time}` : `${matches.length} TV Matches Start at ${time}`,
    body: matches.length === 1
      ? `Starts in ${remaining} minutes on ${matches[0].reminderChannels.join(", ")}.`
      : matches.slice(0, 2).map((match) => `${names(match)} — ${match.reminderChannels.join(", ")}.`).join("\n") + (matches.length > 2 ? `\nPlus ${matches.length - 2} more matches.` : ""),
    payload: { type: "tv_match_reminder", kickoffAt: new Date(group.kickoff).toISOString(), matchIDs: matches.map((m) => m.reminderID) },
  };
}

function createTVReminderScheduler(deps) {
  let inFlight = false;
  let timer = null;
  async function evaluate() {
    if (inFlight) return;
    inFlight = true;
    try {
      const users = (await deps.users()).filter((u) => u.apnsToken &&
        u.preferences?.notificationsEnabled === true && u.preferences?.tvMatchRemindersEnabled !== false);
      if (users.length === 0) return;
      const matches = await deps.matches();
      for (const originalUser of users) {
        // Re-read immediately before eligibility evaluation so disabling/changing
        // preferences does not leave queued reminders using an old snapshot.
        const user = await deps.user(originalUser.deviceToken);
        if (!user || user.preferences?.notificationsEnabled !== true || user.preferences?.tvMatchRemindersEnabled === false) continue;
        const nowMs = deps.now();
        const visible = deps.visible(matches, user.preferences || {});
        for (const group of reminderGroups(user, visible, nowMs, deps.channels)) {
          const target = crypto.createHash("sha256").update(`${Boolean(user.isDevelopmentBuild)}:${user.apnsToken}`).digest("hex");
          // Independent of lead time/rating/membership: changing preferences must
          // not resend the same kick-off group. Shared Redis claims survive restarts.
          const id = `tv_match_reminder:${target}:${group.kickoff}`;
          const claim = await deps.claim(id);
          if (!claim.claimed || claim.source !== "redis") continue;
          if (deps.now() >= group.kickoff) continue;
          const message = reminderMessage(user, group, deps.now());
          const result = await deps.send(user, message, group.kickoff, id);
          await deps.record(user, group, message, result, id);
        }
      }
    } catch (error) {
      deps.error(error);
    } finally {
      inFlight = false;
    }
  }
  return {
    evaluate,
    start() { if (!timer) { timer = setInterval(() => void evaluate(), 30_000); void evaluate(); } },
    stop() { clearInterval(timer); timer = null; },
  };
}

module.exports = { reminderGroups, reminderMessage, createTVReminderScheduler };
