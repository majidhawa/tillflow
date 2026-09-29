// G3 capacity test: spike.
//
// Establishes a small baseline, rapidly jumps to a much higher VU level,
// holds briefly, then rapidly returns to baseline — used to observe
// whether the golden path recovers cleanly from a sudden burst (ECS
// auto-recovery, ALB/target-group behavior, queue/connection backlog)
// rather than staying degraded after the spike passes.
//
// Default TARGET_PATH ("/pos/health") is a plain health-check path reached
// through the real routed path (ALB routes "/pos*" to the pos target
// group; POS's own handler serves "/health" inside the container) — safe
// to load-test, and touches no payment/Daraja code at all.
//
// Usage:
//   BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
//     k6 run scripts/k6/spike-load-test.js
//
//   # Bigger spike: baseline 10 VUs, spike to 400 VUs
//   BASE_URL=... BASELINE_VUS=10 SPIKE_VUS=400 \
//     k6 run scripts/k6/spike-load-test.js

import http from 'k6/http';
import { check, sleep } from 'k6';
import { capacityThresholds } from './lib/thresholds.js';
import { summaryHandler } from './lib/summary.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const TARGET_PATH = __ENV.TARGET_PATH || '/pos/health';
const P95_MS = Number(__ENV.P95_MS) || 500;

const BASELINE_VUS = Number(__ENV.BASELINE_VUS) || 5;
const SPIKE_VUS = Number(__ENV.SPIKE_VUS) || 200;
const BASELINE_DURATION = __ENV.BASELINE_DURATION || '30s';
const SPIKE_RAMP = __ENV.SPIKE_RAMP || '10s';
const SPIKE_HOLD = __ENV.SPIKE_HOLD || '30s';
const RECOVERY_DURATION = __ENV.RECOVERY_DURATION || '30s';

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '10s', target: BASELINE_VUS }, // establish baseline
        { duration: BASELINE_DURATION, target: BASELINE_VUS },
        { duration: SPIKE_RAMP, target: SPIKE_VUS }, // rapid spike up
        { duration: SPIKE_HOLD, target: SPIKE_VUS },
        { duration: SPIKE_RAMP, target: BASELINE_VUS }, // rapid return
        { duration: RECOVERY_DURATION, target: BASELINE_VUS }, // observe recovery
        { duration: '10s', target: 0 },
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
  return summaryHandler('spike')(data);
}
