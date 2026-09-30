# G3 — Money Path k6 Load Test (Fake Daraja Adapter)

Owner: Glory (Payments + Integrity)
Date: 2026-09-30

## Context

The all-gates review flagged: "k6 load tests `/pos/health` only, not
the money path... Re-run k6 against the sale/pay path to find an
actual boundary." Per the capstone brief, real Daraja sandbox load
testing is explicitly disallowed ("CI and k6 must use a deterministic
fake adapter — never real money or customer data") — hammering the
shared, rate-limited sandbox would be non-deterministic and plausibly
a ToS violation, which is exactly why the existing k6 profiles
deliberately excluded `/payments/*` (see
`scripts/k6/README.md`'s "Payments/Daraja capacity testing" section).

This closes that gap properly: a deterministic fake Daraja adapter
(`scripts/fake-daraja/`) stands in for the real sandbox, and
`scripts/k6/money-path-load-test.js` load-tests the real `POST
/payments` code path (STK Push initiation → async callback →
confirmed) against it.

## Setup

1. Fake Daraja adapter running on `:9090` (`scripts/fake-daraja/`) —
   deterministically accepts every STK Push and B2C request, firing a
   success callback ~200ms later.
2. Payments service running locally on `:8080`, `DARAJA_BASE_URL`
   pointed at the fake adapter instead of the real sandbox.

No code in `services/payments/` needed to change — the fake adapter
matches Daraja's real JSON response shapes exactly.

## First run — found a real concurrency bug

    BASE_URL=http://localhost:8080 VUS=100 DURATION=60s \
      k6 run scripts/k6/money-path-load-test.js

Result: the Payments process **crashed** partway through, at
approximately 80 seconds and ~7,275 requests, with:

    fatal error: concurrent map writes
    main.(*paymentStore).put(...)
        services/payments/stkpush.go:75

`paymentStore`'s idempotency map had no mutex — every prior test
tonight was sequential (one request at a time), so this was invisible
until genuine concurrent load hit it. See `docs/scar-log.md` for the
full incident writeup and fix.

## Fix

Added the same `sync.Mutex` pattern already used correctly by
`callbackStore` and `payoutStore` to `paymentStore.get` and
`paymentStore.put`.

## Re-run after fix — real capacity result

    BASE_URL=http://localhost:8080 VUS=100 DURATION=60s \
      k6 run scripts/k6/money-path-load-test.js

    requests:      7273
    failed rate:   0.000%
    p95 duration:  4.78ms
    checks passed: 100.000%

No crash. 100 concurrent virtual users sustained for 60 seconds against
the real STK Push initiation and confirmation code path, with zero
failures and a p95 of under 5ms.

## What this proves and what it doesn't

**Proves:** the Payments STK Push handler itself, including the
idempotency-key store and the callback-driven state transition, is
correct and stable under genuine concurrent load once the mutex bug
was fixed. This is a real capacity result for the application code
path, not a health-check proxy for it.

**Does not prove:** real-world capacity against the actual Daraja
sandbox, whose latency and rate limits are entirely different from the
fake adapter's near-instant, always-succeeding responses. This
establishes a ceiling on the application code's own overhead, not an
end-to-end production capacity number. It also doesn't include ECS
Fargate resource constraints, since this ran locally, not on the
deployed cluster.


## Capacity progression — finding the actual boundary

Per the review's specific ask ("find an actual boundary," since the
prior `/pos/health` test never reached one), progressively higher VU
levels were run after the concurrency fix, bisecting toward the
breaking point:

| VUs | Requests | Failed rate | p95 | Checks passed | Result |
|---|---|---|---|---|---|
| 100 | 7,273 | 0.000% | 4.78ms | 100.000% | PASS |
| 500 | 28,401 | 0.000% | 70.99ms | 100.000% | PASS |
| 1000 | 51,398 | 0.000% | 289.16ms | 99.617% | PASS |
| 1500 | 74,116 | 0.000% | 455.83ms | 99.406% | PASS (near threshold) |
| 2000 | 95,821 | 0.000% | **541.86ms** | **98.901%** | **THRESHOLD BREACH** |

The real capacity boundary sits between **1500 and 2000 concurrent
VUs** against the local Payments process (fake adapter, no ECS/Fargate
resource constraints). At 1500 VUs the system is already close to its
limit (p95 within 45ms of the 500ms threshold); at 2000 VUs it
breaches both the latency and checks thresholds.

Notably, `failed rate` stayed at 0.000% across every level tested —
this is latency degradation under load, not request failure. The
system slows down predictably under increasing concurrent load rather
than dropping requests outright, up to and including the point where
it breaches its own latency SLO.

This result is local-only (no ECS/Fargate CPU or memory constraints,
no real network hop to an ALB) — a real production boundary against
the deployed cluster would likely differ and should be measured
separately.