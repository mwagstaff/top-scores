// Renew while the old activity still has 30 minutes of its eight-hour lifetime.
const RENEW_AFTER_MS = 7.5 * 60 * 60 * 1000;
const RETRY_MS = 5 * 60 * 1000;
const MAX_ATTEMPTS = 5;

async function renewLiveActivityIfNeeded(user, contentState, nowMs, { persist, send, record }) {
  const state = user.liveActivity || {};
  const startedAt = Date.parse(state.lastStartAt || "");
  if (!state.currentActivityId || !state.currentActivityPushToken || !state.pushToStartToken ||
      !Number.isFinite(startedAt) || nowMs - startedAt < RENEW_AFTER_MS) return;
  const sameActivity = state.renewalForActivityId === state.currentActivityId;
  const attempts = sameActivity ? Number(state.renewalAttempts || 0) : 0;
  const lastAttempt = sameActivity ? Date.parse(state.renewalLastAttemptAt || "") : NaN;
  if (attempts >= MAX_ATTEMPTS || (Number.isFinite(lastAttempt) && nowMs - lastAttempt < RETRY_MS)) return;

  // Save before sending: a fast token callback must not be overwritten afterwards.
  // Do not change the current token, lifetime, or update hashes while awaiting arrival.
  await persist(user.deviceToken, {
    renewalForActivityId: state.currentActivityId,
    renewalRequestedAt: sameActivity ? state.renewalRequestedAt : new Date(nowMs).toISOString(),
    renewalLastAttemptAt: new Date(nowMs).toISOString(),
    renewalAttempts: attempts + 1,
  });
  const result = await send({
    token: state.pushToStartToken,
    event: "start",
    attributesType: "TopScoresLiveActivityAttributes",
    attributes: { appScope: "top-scores", startedAtEpochSeconds: Math.floor(nowMs / 1000) },
    contentState,
    staleDate: Math.floor(nowMs / 1000) + 120,
    alert: { title: "Top Scores", body: "Today’s fixtures and scores" },
    isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
  }).catch(error => ({ success: false, error: error.message }));
  await record(user, {
    record_type: "push", dispatch_kind: "start", dispatch_reason: "lifetime_renewal",
    status: result.success ? "success" : "failure", mode: contentState.mode,
    current_activity_id: state.currentActivityId, attempt: attempts + 1,
    error: result.error || null, content_state: contentState,
  });
  return true;
}

module.exports = { renewLiveActivityIfNeeded };
