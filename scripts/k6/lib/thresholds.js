// Shared G3 capacity-test thresholds (stepped/spike/soak profiles only —
// golden-path-load-test.js's smoke thresholds are intentionally different
// and untouched: golden-path enforces the tighter per-service SLO from
// docs/slo-error-budgets.md, while these capacity profiles use the G3
// "Expected targets" as given: failed requests <1%, p95 <500ms, checks >99%.

export function capacityThresholds(p95Ms) {
  return {
    http_req_duration: [`p(95)<${p95Ms}`],
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
  };
}
