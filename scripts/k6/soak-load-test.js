// G3 capacity test: soak.
//
// Holds a stable, moderate load for an extended period (>= 15 minutes by
// default) to surface issues a short test can't: memory growth, ECS task
// restarts, connection/queue buildup, or slow degradation that only shows
// up over time. Same thresholds as the other capacity profiles.
//
// Default TARGET_PATH ("/pos/health") is a plain health-check path reached
// through the real routed path (ALB routes "/pos*" to the pos target
// group; POS's own handler serves "/health" inside the container) — safe
// to load-test, and touches no payment/Daraja code at all.
//
// DURATION can be overridden (e.g. for a quick local syntax/functional
// check), but the default satisfies the >= 15 minute G3 soak requirement.
// Do not override it below 15m for an actual G3 soak-evidence run.
//
// Usage:
//   BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
//     k6 run scripts/k6/soak-load-test.js
//
//   # Longer soak at higher load
//   BASE_URL=... VUS=50 DURATION=30m \
//     k6 run scripts/k6/soak-load-test.js

import http from 'k6/http';
import { check, sleep } from 'k6';
import { capacityThresholds } from './lib/thresholds.js';
import { summaryHandler } from './lib/summary.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const TARGET_PATH = __ENV.TARGET_PATH || '/pos/health';
const VUS = Number(__ENV.VUS) || 20;
const DURATION = __ENV.DURATION || '15m';
const P95_MS = Number(__ENV.P95_MS) || 500;

export const options = {
  scenarios: {
    soak: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: VUS }, // ramp up
        { duration: DURATION, target: VUS }, // sustained soak
        { duration: '30s', target: 0 }, // ramp down
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: capacityThresholds(P95_MS),
};

export default function () {
  const res = http.get(`${BASE_URL}${TARGET_PATH}`);
  check(res, {
    'status is 200': (r) => r.status === 200,
  });
  sleep(1);
}

export function handleSummary(data) {
  return summaryHandler('soak')(data);
}
