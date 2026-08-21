const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    autoRepairEligibleMatchIds,
    buildEmptyCurrentRun,
    buildFutureRedisFixtureAuditResults,
    computeNextScheduledRunAt,
    evaluateAuditIssues,
    groupIssuesByMatch,
    mergeAuditResults,
    summarizeAuditReport,
    normalizeMatchId,
    resolveTeamAlias,
    updateCurrentRun,
    buildPrometheusMetricsText,
    sleepMs,
    isRetryableDetailError,
    computeRetryDelayMs,
    auditState,
  },
} = require("./match_audit_service");

function baseMatch(overrides = {}) {
  return {
    match_details_id: "c36r36ngd87t",
    date: "2026-04-18",
    time: "19:45",
    league: "Italian Serie A",
    home_team: "Roma",
    away_team: "Atalanta",
    home_score: 1,
    away_score: 1,
    score_status: "FT",
    ...overrides,
  };
}

test("normalizeMatchId accepts BBC-style ids and rejects invalid values", () => {
  assert.equal(normalizeMatchId("c36r36ngd87t"), "c36r36ngd87t");
  assert.equal(normalizeMatchId("C36R36NGD87T"), "c36r36ngd87t");
  assert.equal(normalizeMatchId("bad/id"), null);
});

test("evaluateAuditIssues flags missing match_details_id after kickoff", () => {
  const result = evaluateAuditIssues(
    baseMatch({
      match_details_id: null,
      score_status: "12'",
      home_score: 0,
      away_score: 0,
    }),
    {
      nowMs: Date.parse("2026-04-18T19:50:00Z"),
    }
  );

  assert.equal(result.issues.some((issue) => issue.code === "missing_match_details_id"), true);
});

test("evaluateAuditIssues flags matches that should have finished but are still live", () => {
  const result = evaluateAuditIssues(
    baseMatch({
      score_status: "78'",
      home_score: 1,
      away_score: 1,
    }),
    {
      nowMs: Date.parse("2026-04-18T23:30:00Z"),
    }
  );

  assert.equal(
    result.issues.some((issue) => issue.code === "match_not_finished_after_max_window"),
    true
  );
});

test("evaluateAuditIssues passes a healthy finished match with detail payload", () => {
  const result = evaluateAuditIssues(baseMatch(), {
    nowMs: Date.parse("2026-04-18T22:30:00Z"),
    detailPayload: {
      id: "c36r36ngd87t",
      date: "2026-04-18",
      time: "19:45",
      league: "Italian Serie A",
      home_team: "Roma",
      away_team: "Atalanta",
      home_score: 1,
      away_score: 1,
      score_status: "FT",
    },
  });

  assert.equal(result.issues.length, 0);
});

test("groupIssuesByMatch aggregates issue severity per match", () => {
  const results = [
    {
      summary: {
        match_id: "c36r36ngd87t",
        audit_match_id: "c36r36ngd87t",
        date: "2026-04-18",
        time: "19:45",
        league: "Italian Serie A",
        home_team: "Roma",
        away_team: "Atalanta",
        score_status: "FT",
        home_score: 1,
        away_score: 1,
      },
      issues: [
        {
          key: "c36r36ngd87t:missing_match_details_payload",
          code: "missing_match_details_payload",
          severity: "critical",
          message: "Missing details",
          audit_match_id: "c36r36ngd87t",
        },
      ],
    },
  ];

  const grouped = groupIssuesByMatch(results);
  assert.equal(grouped.length, 1);
  assert.equal(grouped[0].highest_severity, "critical");
});

test("summarizeAuditReport counts issues and healthy matches", () => {
  const results = [
    {
      summary: {
        match_id: "c36r36ngd87t",
        audit_match_id: "c36r36ngd87t",
        score_status: "FT",
      },
      should_have_kicked_off: true,
      should_be_finished: true,
      should_have_detail_payload: true,
      issues: [],
    },
    {
      summary: {
        match_id: "c111",
        audit_match_id: "c111",
        score_status: "90'",
      },
      should_have_kicked_off: true,
      should_be_finished: true,
      should_have_detail_payload: true,
      issues: [
        {
          key: "c111:match_not_finished_after_max_window",
          code: "match_not_finished_after_max_window",
          severity: "critical",
          audit_match_id: "c111",
        },
      ],
    },
  ];
  const issues = results.flatMap((result) => result.issues);
  const summary = summarizeAuditReport(results, issues);

  assert.equal(summary.matches_checked, 2);
  assert.equal(summary.matches_with_issues, 1);
  assert.equal(summary.healthy_matches, 1);
  assert.equal(summary.issue_counts_by_code.match_not_finished_after_max_window, 1);
});

test("updateCurrentRun computes progress and throughput", () => {
  const baseline = buildEmptyCurrentRun();
  updateCurrentRun(baseline);
  const snapshot = updateCurrentRun({
    trigger: "test",
    status: "running",
    stage: "auditing_matches",
    started_at: new Date(Date.now() - 5000).toISOString(),
    total_matches: 20,
    matches_audited: 5,
    detail_candidates: 8,
    detail_checks_completed: 3,
    issues_found: 2,
  });

  assert.equal(snapshot.matches_remaining, 15);
  assert.equal(snapshot.progress_ratio, 0.25);
  assert.equal(snapshot.detail_candidates, 8);
  assert.equal(snapshot.detail_checks_completed, 3);
  assert.equal(snapshot.issues_found, 2);
  assert.equal(snapshot.matches_per_second > 0, true);
});

test("computeNextScheduledRunAt targets the next London midnight", () => {
  const sameDay = computeNextScheduledRunAt(Date.parse("2026-04-20T21:15:00.000Z"));
  const nextDay = computeNextScheduledRunAt(Date.parse("2026-04-20T23:30:00.000Z"));

  assert.equal(new Date(sameDay).toISOString(), "2026-04-20T23:00:00.000Z");
  assert.equal(new Date(nextDay).toISOString(), "2026-04-21T23:00:00.000Z");
});

test("buildFutureRedisFixtureAuditResults flags future redis fixtures absent from BBC listing", () => {
  const results = buildFutureRedisFixtureAuditResults(
    [
      {
        match_id: "syn9ac5773a676f5286",
        date: "2026-04-28",
        time: "00:00",
        league: "UEFA Champions League",
        home_team: "Atletico Madrid",
        away_team: "Arsenal",
        has_bsd_source: true,
      },
    ],
    [
      {
        match_details_id: "c-real-match",
        date: "2026-04-28",
        time: "20:00",
        league: "UEFA Champions League",
        home_team: "Paris Saint-Germain",
        away_team: "Bayern Munich",
      },
    ],
    {
      nowMs: Date.parse("2026-04-20T12:00:00.000Z"),
      coverageEnd: "2026-07-19",
    }
  );

  assert.equal(results.length, 1);
  assert.equal(results[0].issues[0].code, "future_fixture_missing_from_bbc_listing");
  assert.equal(results[0].summary.match_id, "syn9ac5773a676f5286");
});

test("resolveTeamAlias maps known aliases to canonical names", () => {
  assert.equal(resolveTeamAlias("Athletic Club"), "Athletic Bilbao");
  assert.equal(resolveTeamAlias("Real Mallorca"), "Mallorca");
  assert.equal(resolveTeamAlias("Athletic Bilbao"), "Athletic Bilbao");
  assert.equal(resolveTeamAlias("Unknown FC"), "Unknown FC");
});

test("buildFutureRedisFixtureAuditResults matches Redis fixture via team alias (Athletic Bilbao = Athletic Club)", () => {
  const results = buildFutureRedisFixtureAuditResults(
    [
      {
        match_id: "syn9d037fcc02bda76d",
        date: "2026-04-21",
        time: "18:00",
        league: "Spanish La Liga",
        home_team: "Athletic Bilbao",
        away_team: "Osasuna",
        has_bsd_source: true,
      },
    ],
    [
      {
        date: "2026-04-21",
        time: "18:00",
        league: "Spanish La Liga",
        home_team: "Athletic Club",
        away_team: "Osasuna",
      },
    ],
    {
      nowMs: Date.parse("2026-04-20T12:00:00.000Z"),
      coverageEnd: "2026-07-19",
    }
  );

  assert.equal(results.length, 0, "should not flag Athletic Bilbao as missing when BBC lists Athletic Club");
});

test("mergeAuditResults appends reconciliation issues onto existing matches", () => {
  const base = [
    {
      summary: {
        match_id: "syn9ac5773a676f5286",
        audit_match_id: "syn9ac5773a676f5286",
      },
      issues: [],
    },
  ];
  const extra = [
    {
      summary: {
        match_id: "syn9ac5773a676f5286",
        audit_match_id: "syn9ac5773a676f5286",
      },
      issues: [
        {
          key: "syn9ac5773a676f5286:future_fixture_missing_from_bbc_listing",
          code: "future_fixture_missing_from_bbc_listing",
        },
      ],
    },
  ];

  const merged = mergeAuditResults(base, extra);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].issues.length, 1);
  assert.equal(merged[0].issues[0].code, "future_fixture_missing_from_bbc_listing");
});

test("buildPrometheusMetricsText includes scheduled next run timestamp", () => {
  const previousNextRun = auditState.next_run_scheduled_at;
  const previousLastDuration = auditState.last_duration_ms;
  const previousLastSuccess = auditState.last_success_at;

  try {
    auditState.next_run_scheduled_at = "2026-04-20T12:05:00.000Z";
    auditState.last_duration_ms = 42000;
    auditState.last_success_at = "2026-04-20T12:00:00.000Z";

    const metrics = buildPrometheusMetricsText();

    assert.match(metrics, /top_scores_match_audit_last_duration_seconds 42(?:\.0+)?/);
    assert.match(metrics, /top_scores_match_audit_next_run_timestamp_seconds 1776686700(?:\.0+)?/);
  } finally {
    auditState.next_run_scheduled_at = previousNextRun;
    auditState.last_duration_ms = previousLastDuration;
    auditState.last_success_at = previousLastSuccess;
  }
});

test("evaluateAuditIssues does not flag match_details_status_mismatch when both statuses are in-progress", () => {
  const result = evaluateAuditIssues(
    baseMatch({
      score_status: "7'",
      home_score: 0,
      away_score: 0,
    }),
    {
      nowMs: Date.parse("2026-04-18T19:55:00Z"),
      detailPayload: {
        date: "2026-04-18",
        time: "19:45",
        league: "Italian Serie A",
        home_team: "Roma",
        away_team: "Atalanta",
        home_score: 0,
        away_score: 0,
        score_status: "12'",
      },
    }
  );

  assert.equal(
    result.issues.some((issue) => issue.code === "match_details_status_mismatch"),
    false,
    "should not flag mismatch when both list and detail are in-progress minute statuses"
  );
});

test("evaluateAuditIssues still flags match_details_status_mismatch when statuses differ meaningfully", () => {
  const result = evaluateAuditIssues(
    baseMatch({ score_status: "FT" }),
    {
      nowMs: Date.parse("2026-04-18T22:30:00Z"),
      detailPayload: {
        date: "2026-04-18",
        time: "19:45",
        league: "Italian Serie A",
        home_team: "Roma",
        away_team: "Atalanta",
        home_score: 1,
        away_score: 1,
        score_status: "HT",
      },
    }
  );

  assert.equal(
    result.issues.some((issue) => issue.code === "match_details_status_mismatch"),
    true,
    "should flag mismatch when list says FT but detail says HT"
  );
});

test("isRetryableDetailError returns true for network errors, timeouts, and 5xx", () => {
  const networkError = new Error("ECONNREFUSED");
  assert.equal(isRetryableDetailError(networkError), true);

  const abortError = new Error("The operation was aborted");
  abortError.name = "AbortError";
  assert.equal(isRetryableDetailError(abortError), true);

  const err408 = new Error("Request Timeout");
  err408.status = 408;
  assert.equal(isRetryableDetailError(err408), true);

  const err429 = new Error("Too Many Requests");
  err429.status = 429;
  assert.equal(isRetryableDetailError(err429), true);

  const err503 = new Error("Service Unavailable");
  err503.status = 503;
  assert.equal(isRetryableDetailError(err503), true);
});

test("isRetryableDetailError returns false for 404 and 4xx client errors", () => {
  const err404 = new Error("Not Found");
  err404.status = 404;
  assert.equal(isRetryableDetailError(err404), false);

  const err400 = new Error("Bad Request");
  err400.status = 400;
  assert.equal(isRetryableDetailError(err400), false);

  const err403 = new Error("Forbidden");
  err403.status = 403;
  assert.equal(isRetryableDetailError(err403), false);
});

test("computeRetryDelayMs produces exponentially growing delays within bounds", () => {
  const base = 500;
  const max = 5000;
  const factor = 2.0;

  for (let attempt = 1; attempt <= 5; attempt += 1) {
    const delay = computeRetryDelayMs(attempt, base, max, factor);
    assert.equal(delay >= 0, true, `attempt ${attempt}: delay should be >= 0`);
    assert.equal(delay <= max * 1.25, true, `attempt ${attempt}: delay should not far exceed max`);
  }

  // Attempt 1 should be near base (500ms ± 25%)
  const delay1 = computeRetryDelayMs(1, base, max, factor);
  assert.equal(delay1 >= 375 && delay1 <= 625, true, `attempt 1 delay ${delay1} should be near 500ms`);
});

test("sleepMs resolves after approximately the specified duration", async () => {
  const start = Date.now();
  await sleepMs(20);
  const elapsed = Date.now() - start;
  assert.equal(elapsed >= 10, true, "sleepMs(20) should take at least 10ms");
});

test("autoRepairEligibleMatchIds selects rescrapeable issue matches with ids", () => {
  const report = {
    issues: [
      { match_id: "c36r36ngd87t", code: "missing_match_details_payload" },
      { match_id: "c36r36ngd87t", code: "match_details_score_mismatch" },
      { match_id: null, code: "missing_match_details_id" },
      { match_id: "c222", code: "match_not_finished_after_max_window" },
    ],
  };

  const eligible = autoRepairEligibleMatchIds(report, Date.now());
  assert.deepEqual(eligible, ["c36r36ngd87t", "c222"]);
});
