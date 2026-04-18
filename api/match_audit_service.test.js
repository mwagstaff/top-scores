const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    evaluateAuditIssues,
    groupIssuesByMatch,
    summarizeAuditReport,
    normalizeMatchId,
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
