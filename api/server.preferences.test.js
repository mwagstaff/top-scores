const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    preferencesSaveShouldTriggerLiveActivityReconcile,
    liveActivityReconcileTriggerForPreferencesSave,
  },
} = require("./server");

test("preferences save triggers a live activity reconcile for viewing preference changes", () => {
  assert.equal(
    preferencesSaveShouldTriggerLiveActivityReconcile({
      preferences: {
        englishPremierLeagueTeamsOnly: true,
      },
    }),
    true
  );
  assert.equal(
    liveActivityReconcileTriggerForPreferencesSave({
      preferences: {
        englishPremierLeagueTeamsOnly: true,
      },
    }),
    "preferences_sync"
  );
});

test("preferences save keeps the fantasy-specific reconcile trigger when only fantasy changes", () => {
  assert.equal(
    preferencesSaveShouldTriggerLiveActivityReconcile({
      fantasy: null,
    }),
    true
  );
  assert.equal(
    liveActivityReconcileTriggerForPreferencesSave({
      fantasy: null,
    }),
    "preferences_fantasy_sync"
  );
});

test("preferences save uses a combined trigger when both preferences and fantasy change", () => {
  assert.equal(
    liveActivityReconcileTriggerForPreferencesSave({
      preferences: {
        englishPremierLeagueTeamsOnly: true,
      },
      fantasy: null,
    }),
    "preferences_and_fantasy_sync"
  );
});
