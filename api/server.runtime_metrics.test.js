const test = require("node:test");
const assert = require("node:assert/strict");
const {
  __private: {
    resetRedisMetricsForTests,
    recordRedisOpForTests,
  },
} = require("./redis_client");

const {
  __private: {
    buildPrometheusMetricsText,
  },
} = require("./server");

test("buildPrometheusMetricsText includes top-scores runtime health metrics", () => {
  resetRedisMetricsForTests();
  recordRedisOpForTests("test_payload_metric", 75, {
    resultCount: 2,
    payloadBytes: 2048,
  });
  const metricsText = buildPrometheusMetricsText();

  [
    "top_scores_runtime_info",
    "top_scores_process_uptime_seconds",
    "top_scores_process_cpu_usage_ratio",
    "top_scores_bbc_http_requests_total",
    "top_scores_bbc_http_failed_responses_total",
    "nodejs_eventloop_utilization_ratio",
    "nodejs_heap_size_limit_bytes",
    "nodejs_heap_size_available_bytes",
    "nodejs_heap_utilization_ratio",
    "nodejs_heap_limit_utilization_ratio",
    "nodejs_array_buffers_bytes",
    "nodejs_native_contexts_total",
    "nodejs_heap_space_size_used_bytes",
    "top_scores_match_details_active_refresh_targets",
    "top_scores_live_activity_active",
    "top_scores_live_activity_pushes_total",
    "top_scores_live_activity_starts_total",
    "top_scores_live_activity_ends_total",
    "top_scores_live_activity_payload_size_bytes_min",
    "top_scores_live_activity_payload_size_bytes_max",
    "top_scores_live_activity_payload_size_bytes_avg",
    "top_scores_operational_redis_reconciliation_generated_timestamp_seconds",
    "top_scores_operational_redis_reconciliation_duration_seconds",
    "top_scores_operational_redis_reconciliation_component_status_code",
    "top_scores_operational_memory_age_seconds",
    "top_scores_operational_redis_age_seconds",
    "top_scores_redis_operation_payload_bytes_total",
    "top_scores_redis_operation_payload_bytes_avg",
    "top_scores_redis_operation_payload_bytes_max",
  ].forEach((metricName) => {
    assert.match(metricsText, new RegExp(`(^|\\n)# HELP ${metricName}\\b`));
  });

  assert.match(metricsText, /top_scores_redis_operation_payload_bytes_total\{operation="test_payload_metric"\}\s+2048(?:\.0+)?\b/);
  assert.match(metricsText, /top_scores_redis_operation_payload_bytes_avg\{operation="test_payload_metric"\}\s+2048(?:\.0+)?\b/);
  assert.match(metricsText, /top_scores_redis_operation_payload_bytes_max\{operation="test_payload_metric"\}\s+2048(?:\.0+)?\b/);
  assert.match(metricsText, /top_scores_runtime_info\{[^}]*runtime="library"[^}]*service="top-scores-library"[^}]*\}\s+1(?:\.0+)?\b/);
  resetRedisMetricsForTests();
});
