// TillFlow G1 golden-path load test.
//
// Exercises the real deployed path — API Gateway -> VPC Link -> ALB ->
// ECS Fargate — against the endpoints the golden-path stub services
// actually expose today (services/*/main.go: "/", "/health", "/ready").
// This deliberately does NOT simulate a business endpoint (e.g. a POS
// sale or a Daraja STK push): no such endpoint exists yet (see
// docs/adr/003-delivery-deployment.md and the "What's still needed"
// section of docs/slo-error-budgets.md), and inventing one here would
// test something that isn't real.
//
// Thresholds mirror the targets already agreed in
// docs/slo-error-budgets.md, not new numbers invented for this script:
//   - Web ("/"):        p95 < 500ms, >= 99.9% availability
//   - POS ("/health"):  p95 < 400ms, >= 99.9% availability
// (Payments/Commission's SLOs are about async completion — STK/callback
// resolution and daily payout timing — not raw HTTP latency, so they
// aren't a fit for a k6 http threshold and are intentionally left out.)
//
// Usage:
//   BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
//     k6 run scripts/k6/golden-path-load-test.js
//
//   # Point at the POS path instead of the default web root, with a
//   # smaller/quicker run for a live demo:
//   BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
//     TARGET_PATH=/pos/health VUS=200 DURATION=45s \
//     k6 run scripts/k6/golden-path-load-test.js
//
// Note: the current services are minimal stdlib HTTP stubs (near-zero
// per-request work), so on a t4g/Fargate-256 task, pushing ECS CPU or ALB
// latency high enough to trip an alarm organically may need a fairly high
// VUS count. See docs/runbook.md's incident-demo section for the
// alternative (deliberately setting an alarm to ALARM state) if a live
// demo needs a guaranteed trigger.

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const TARGET_PATH = __ENV.TARGET_PATH || '/';
const VUS = Number(__ENV.VUS) || 50;
const DURATION = __ENV.DURATION || '90s';

// Web's SLO (p95 < 500ms) is the default threshold, since "/" is the
// default TARGET_PATH. If you point TARGET_PATH at "/health" to demo the
// POS path instead, its documented target is p95 < 400ms — tighten
// SLO_P95_MS accordingly via the env var when doing that.
const SLO_P95_MS = Number(__ENV.SLO_P95_MS) || 500;

export const options = {
  scenarios: {
    golden_path: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: VUS }, // ramp up
        { duration: DURATION, target: VUS }, // steady state
        { duration: '15s', target: 0 }, // ramp down
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    http_req_duration: [`p(95)<${SLO_P95_MS}`],
    // >= 99.9% availability, expressed as k6's failed-request rate.
    http_req_failed: ['rate<0.001'],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}${TARGET_PATH}`);
  check(res, {
    'status is 200': (r) => r.status === 200,
  });
  sleep(1);
}
