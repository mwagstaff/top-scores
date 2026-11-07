"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const bsdHttpMetrics = require("./bsd_http_metrics");

test("bad URLs survive busy successful traffic and expire from the rolling window", () => {
  bsdHttpMetrics.__private.resetForTests();
  const now = Date.now();
  const record = (url, statusCode, timestampMs = now) => bsdHttpMetrics.trackRequestMetric({
    source: "bsd_social", url, statusCode, durationMs: 44, timestampMs,
  });
  for (let i = 0; i < 110; i += 1) {
    record(`https://sports.bzzoiro.com/api/v2/events/${i}`, 200);
    record(`https://sports.bzzoiro.com/api/v2/events/${i}`, 200);
  }
  const url = "https://sports.bzzoiro.com/api/v2/social?event_id=123&limit=200&offset=0";
  record(url, 502);
  record(url, 502, now + 1000);
  record(url, 404, now + 1000);
  record(url, 0, now + 1000);
  record(url, 302, now + 1000);
  const rows = bsdHttpMetrics.__private.buildTopUrlRows(now + 1000).badRows;
  assert.deepEqual(rows.map((row) => row.labels.status_code).sort(), ["0", "404", "502"]);
  assert.equal(rows[0].count, 2);
  assert.equal(rows[0].labels.url, url);
  assert.equal(rows[0].lastTimestampSeconds, (now + 1000) / 1000);
  const text = bsdHttpMetrics.buildPrometheusMetricsText({ nowMs: now + 1000 });
  assert.match(text, /top_scores_bsd_http_bad_url_requests\{.*status_code="502".*\} 2/);
  assert.match(text, /top_scores_bsd_http_bad_url_last_timestamp_seconds\{/);
  assert.equal(bsdHttpMetrics.__private.buildTopUrlRows(now + 7 * 3600000).badRows.length, 0);
  bsdHttpMetrics.__private.resetForTests();
});

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
