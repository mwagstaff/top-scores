"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const bsdHttpMetrics = require("./bsd_http_metrics");

test("BSD HTTP metrics expose timeout counters and top timeout URLs", () => {
  bsdHttpMetrics.__private.resetForTests();
  bsdHttpMetrics.trackRequestMetric({
    source: "bsd_events_live",
    url: "https://sports.bzzoiro.com/api/v2/events/live",
    statusCode: 0,
    errorCode: "ETIMEDOUT",
    durationMs: 30_000,
    timestampMs: Date.now(),
  });

  const metricsText = bsdHttpMetrics.buildPrometheusMetricsText();

  assert.match(
    metricsText,
    /top_scores_bsd_http_timeouts_total\{error_code="ETIMEDOUT",source="bsd_events_live"\}\s+1\b/
  );
  assert.match(
    metricsText,
    /top_scores_bsd_http_timeout_url_requests\{error_code="ETIMEDOUT",source="bsd_events_live",url="https:\/\/sports\.bzzoiro\.com\/api\/v2\/events\/live"\}\s+1\b/
  );
  bsdHttpMetrics.__private.resetForTests();
});
