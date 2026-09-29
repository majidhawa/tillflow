// G3 capacity test: stepped baseline.
//
// Gradually increases load through several VU levels, holding long enough
// at each one to observe whether the golden path (API Gateway -> VPC Link
// -> ALB -> ECS Fargate) is stable at that level, before stepping up
// again. Used to find the highest sustainable load where SLOs still hold
// (see the CloudWatch dashboard's ECS CPU/memory and ALB latency widgets
// during a run, alongside this script's own request-rate/failure-rate/
// p95/checks output).
//
// Default TARGET_PATH ("/pos/health") is a plain health-check path reached
// through the real routed path (ALB routes "/pos*" to the pos target
// group; POS's own handler serves "/health" inside the container) — safe
// to load-test, and touches no payment/Daraja code at all.
//
// Usage:
//   BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
//     k6 run scripts/k6/stepped-baseline-load-test.js
//
//   # Custom steps: 3 stages of 20, 50, 100 VUs, 2 minutes each
//   BASE_URL=... STEPS=20,50,100 STEP_DURATION=2m \
//     k6 run scripts/k6/stepped-baseline-load-test.js

import http from 'k6/http';
import { check, sleep } from 'k6';
import { capacityThresholds } from './lib/thresholds.js';
import { summaryHandler } from './lib/summary.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const TARGET_PATH = __ENV.TARGET_PATH || '/pos/health';
const STEP_DURATION = __ENV.STEP_DURATION || '60s';
const RAMP_DURATION = __ENV.RAMP_DURATION || '20s';
const P95_MS = Number(__ENV.P95_MS) || 500;

// Comma-separated VU levels to step through, ascending.
const STEPS = (__ENV.STEPS || '10,30,60,100')
  .split(',')
  .map((s) => Number(s.trim()))
  .filter((n) => n > 0);

function buildStages() {
  const stages = [];
  for (const target of STEPS) {
    stages.push({ duration: RAMP_DURATION, target });
    stages.push({ duration: STEP_DURATION, target });
  }
  stages.push({ duration: RAMP_DURATION, target: 0 });
  return stages;
}

export const options = {
  scenarios: {
    stepped_baseline: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: buildStages(),
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
  return summaryHandler('stepped-baseline')(data);
}
