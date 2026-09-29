# k6 capacity tests (G3)

Four profiles cover the G3 capacity-testing envelope: smoke, stepped baseline, spike, and soak. All target the real deployed path (API Gateway -> VPC Link -> ALB -> ECS Fargate) and default to `TARGET_PATH=/pos/health` — a plain health-check path reached through the real routed path (the ALB routes `/pos*` to the `pos` target group; POS's own handler serves `/health` inside the container). This is safe to load-test at any RPS and touches no payment/Daraja code.

Install k6: https://k6.io/docs/get-started/installation/

Get `<api-id>` from the `api_gateway_endpoint` Terraform output (`infra/environments/dev/outputs.tf`), or the AWS Console.

## 1. Smoke

`golden-path-load-test.js` (pre-existing). Low-VU sanity check against the golden path, thresholds matched to `docs/slo-error-budgets.md`'s per-service SLOs.

```bash
BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
  k6 run scripts/k6/golden-path-load-test.js
```

## 2. Stepped baseline

`stepped-baseline-load-test.js`. Ramps through ascending VU levels (default `10,30,60,100`), holding at each one long enough to see whether it's stable, before stepping up. Use this to find the highest sustainable load where the thresholds below still pass — watch the CloudWatch dashboard's ECS CPU/memory and ALB latency widgets alongside this script's own output.

```bash
BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
  k6 run scripts/k6/stepped-baseline-load-test.js

# Custom steps: 20, 50, 100 VUs, 2 minutes at each
BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
  STEPS=20,50,100 STEP_DURATION=2m \
  k6 run scripts/k6/stepped-baseline-load-test.js
```

| Env var | Default | Meaning |
|---|---|---|
| `BASE_URL` | `http://localhost:8080` | API Gateway invoke URL |
| `TARGET_PATH` | `/pos/health` | Path to hit |
| `STEPS` | `10,30,60,100` | Comma-separated ascending VU levels |
| `STEP_DURATION` | `60s` | Hold time at each step |
| `RAMP_DURATION` | `20s` | Ramp time between/into/out of steps |
| `P95_MS` | `500` | p95 latency threshold (ms) |

## 3. Spike

`spike-load-test.js`. Small baseline, rapid jump to a much higher VU level, brief hold, rapid return to baseline — observes whether the golden path recovers cleanly after a burst rather than staying degraded.

```bash
BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
  k6 run scripts/k6/spike-load-test.js

# Bigger spike: baseline 10 VUs, spike to 400 VUs
BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
  BASELINE_VUS=10 SPIKE_VUS=400 \
  k6 run scripts/k6/spike-load-test.js
```

| Env var | Default | Meaning |
|---|---|---|
| `BASE_URL` | `http://localhost:8080` | API Gateway invoke URL |
| `TARGET_PATH` | `/pos/health` | Path to hit |
| `BASELINE_VUS` | `5` | Steady-state VUs before/after the spike |
| `SPIKE_VUS` | `200` | Peak VUs during the spike |
| `BASELINE_DURATION` | `30s` | How long baseline holds before the spike |
| `SPIKE_RAMP` | `10s` | Ramp time up into, and back down out of, the spike |
| `SPIKE_HOLD` | `30s` | How long the spike holds at peak |
| `RECOVERY_DURATION` | `30s` | How long to observe recovery at baseline after the spike |
| `P95_MS` | `500` | p95 latency threshold (ms) |

## 4. Soak

`soak-load-test.js`. Stable, moderate load held for an extended period — surfaces issues a short test can't (memory growth, task restarts, connection/queue buildup). **Default duration is 15 minutes, satisfying the G3 soak requirement.** Do not shorten `DURATION` below 15m for an actual soak-evidence run — only override it for a quick local functional check.

```bash
# Real soak run (>= 15 minutes, do not shorten for evidence)
BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
  k6 run scripts/k6/soak-load-test.js

# Longer soak at higher load
BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
  VUS=50 DURATION=30m \
  k6 run scripts/k6/soak-load-test.js
```

| Env var | Default | Meaning |
|---|---|---|
| `BASE_URL` | `http://localhost:8080` | API Gateway invoke URL |
| `TARGET_PATH` | `/pos/health` | Path to hit |
| `VUS` | `20` | Steady-state VUs for the whole soak |
| `DURATION` | `15m` | Soak duration (>= 15m for real evidence runs) |
| `P95_MS` | `500` | p95 latency threshold (ms) |

## Thresholds (stepped/spike/soak)

Per the G3 capacity envelope's expected targets — deliberately different from the smoke test's tighter per-service SLO thresholds (`docs/slo-error-budgets.md`), since these three profiles are about capacity/stability, not per-service SLO conformance:

- failed requests < 1% (`http_req_failed`)
- p95 latency < 500ms (`http_req_duration`, overridable via `P95_MS`)
- checks > 99% (`checks`)

Defined once in `lib/thresholds.js` and shared by all three profiles.

## Evidence output

Each of the three new profiles writes a machine-readable JSON summary (k6's full metrics object) to `evidence/reliability/k6-<profile>-summary.json` when the run finishes, via the shared `lib/summary.js` `handleSummary()` — alongside a short human-readable recap printed to stdout (requests, failed rate, p95, checks). This is what should be committed as G3 capacity evidence after a real run — not a screenshot.

`golden-path-load-test.js` is unmodified and does not yet write a summary file; k6's default end-of-run summary printed to the terminal is its only output today.

## Payments/Daraja capacity testing — deliberately out of scope here

None of these profiles touch `/payments/*`. Load-testing the payment path for real would need a deterministic fake Daraja server (the real `DARAJA_BASE_URL` points at Safaricom's sandbox — hammering it at load-test RPS would be non-deterministic, rate-limited, and likely a ToS violation). That's a separate, follow-up piece of work — see the task report for exactly why/where it would plug in.
