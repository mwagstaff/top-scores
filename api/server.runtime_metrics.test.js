const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    buildPrometheusMetricsText,
  },
} = require("./server");

test("buildPrometheusMetricsText includes top-scores runtime health metrics", () => {
  const metricsText = buildPrometheusMetricsText();

  [
    "top_scores_runtime_info",
    "top_scores_process_uptime_seconds",
    "top_scores_process_cpu_usage_ratio",
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
  ].forEach((metricName) => {
    assert.match(metricsText, new RegExp(`(^|\\n)# HELP ${metricName}\\b`));
  });
});
