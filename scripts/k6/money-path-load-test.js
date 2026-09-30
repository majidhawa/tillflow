// G3 capacity test: money path (against the fake Daraja adapter).
//
// Unlike the other three capacity profiles, this one exercises the real
// payment-processing code path — POST /payments (STK Push initiation) —
// instead of a health-check endpoint. Per the capstone brief, "CI and k6
// must use a deterministic fake adapter — never real money or customer
// data." The real Daraja sandbox is shared, rate-limited, and
// non-deterministic under load, so this MUST run against
// scripts/fake-daraja (see scripts/fake-daraja/README.md), never the real
// sandbox.
//
// Each virtual user generates a unique idempotency_key per iteration, so
// this measures genuine STK Push throughput — not idempotent-cache hits,
// which would make the results meaningless (every request would resolve
// in-memory with no real work done).
//
// Usage (local, against a Payments instance pointed at the fake adapter):
//   1. cd scripts/fake-daraja && go run . &
//   2. cd services/payments && export $(grep -v '^#' .env.fake | xargs) \
//        && go run . &
//   3. BASE_URL=http://localhost:8080 k6 run scripts/k6/money-path-load-test.js
//
// Custom load:
//   BASE_URL=http://localhost:8080 VUS=50 DURATION=60s \
//     k6 run scripts/k6/money-path-load-test.js

import http from 'k6/http';
import { check, sleep } from 'k6';
import { capacityThresholds } from './lib/thresholds.js';
import { summaryHandler } from './lib/summary.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const VUS = Number(__ENV.VUS) || 20;
const DURATION = __ENV.DURATION || '60s';
const P95_MS = Number(__ENV.P95_MS) || 1500; // STK Push has a real network round-trip to the adapter + async callback; not a raw health-check latency budget.

export const options = {
  scenarios: {
    money_path: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '15s', target: VUS },
        { duration: DURATION, target: VUS },
        { duration: '10s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: capacityThresholds(P95_MS),
};

export default function () {
  const uniqueID = `${__VU}-${__ITER}-${Date.now()}`;
  const payload = JSON.stringify({
    sale_id: `k6_sale_${uniqueID}`,
    tenant_id: 'tenant_001',
    till_id: 'till_001',
    amount_minor: 100,
    currency: 'KES',
    phone_number: '254708374149',
    idempotency_key: `k6:${uniqueID}`,
  });

  const res = http.post(`${BASE_URL}/payments`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });

  check(res, {
    'status is 200': (r) => r.status === 200,
    'state is pending': (r) => {
      try {
        return JSON.parse(r.body).state === 'pending';
      } catch (e) {
        return false;
      }
    },
  });

  sleep(1);
}

export function handleSummary(data) {
  return summaryHandler('money-path')(data);
}