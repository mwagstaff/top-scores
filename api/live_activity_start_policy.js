const dayFormatter = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/London", year: "numeric", month: "2-digit", day: "2-digit",
});

function pushToStartAttemptsForDay(state = {}, nowMs = Date.now()) {
  const updatedAt = Date.parse(state.pushToStartAttemptsUpdatedAt || "");
  // Legacy counters have no reliable day and may include foreground failures.
  if (!Number.isFinite(updatedAt) || dayFormatter.format(updatedAt) !== dayFormatter.format(nowMs)) return 0;
  const attempts = Number(state.pushToStartAttempts);
  return Number.isFinite(attempts) ? Math.max(0, Math.floor(attempts)) : 0;
}

function latestPushToStartBudget(states) {
  return states.reduce((latest, state) => {
    const timestamp = Date.parse(state.pushToStartAttemptsUpdatedAt || "");
    const latestTimestamp = Date.parse(latest.pushToStartAttemptsUpdatedAt || "");
    return Number.isFinite(timestamp) && (!Number.isFinite(latestTimestamp) || timestamp > latestTimestamp)
      ? { pushToStartAttempts: state.pushToStartAttempts || 0, pushToStartAttemptsUpdatedAt: state.pushToStartAttemptsUpdatedAt }
      : latest;
  }, { pushToStartAttempts: 0, pushToStartAttemptsUpdatedAt: null });
}

module.exports = { pushToStartAttemptsForDay, latestPushToStartBudget };
