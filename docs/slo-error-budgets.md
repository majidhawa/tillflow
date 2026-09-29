# TillFlow SLOs and Error Budgets

- Status: Draft — targets may still change before final benchmarking (with a written rationale, per the capstone brief's rule). All four services are now deployed on ECS in `eu-west-3`; the Grafana SLO dashboard has been run against live data (`evidence/reliability/g3-grafana-slo-runtime.md`), but the Payments and Commission SLIs as defined, and a full 28-day window, do not yet have runtime proof (see "What's still needed" at the end).
- DRI: Hawaah (Reliability + Operations)
- Window: 28 days, rolling, for every SLO in this document
- Budget formula: `budget = eligible events × (1 − target)`. Invalid requests and genuine business declines may be excluded from the denominator; dependency outages still count against the budget when they cause the user-facing journey to fail.

## SLI/SLO table

### Web

| Field | Value |
|---|---|
| Numerator | Page/API-shell requests that return a successful response within the latency target |
| Denominator | All eligible Web requests (excludes bot/health-check traffic, excludes requests where the client disconnected before a response could be sent) |
| Target | ≥ 99.9% availability, p95 latency < 500 ms |
| 28-day budget | 0.1% of eligible events (≈ 40m 19s of equivalent downtime) |
| Exclusions | Invalid/malformed requests; scheduled maintenance windows (none exist yet) |
| User outcome represented | The attendant/owner can load the app shell and reach the POS/admin screens without a blocking error or a stall long enough to abandon the action |

### POS API

| Field | Value |
|---|---|
| Numerator | Valid sale-write requests accepted exactly once within the latency target |
| Denominator | All valid sale-write requests (excludes requests that fail validation for reasons the client controls — e.g. malformed line items) |
| Target | ≥ 99.9% availability, p95 latency < 400 ms |
| 28-day budget | 0.1% of eligible events (≈ 40m 19s of equivalent downtime) |
| Exclusions | Client-side validation failures; duplicate requests correctly rejected by idempotency (that's success, not failure, of this SLI) |
| User outcome represented | An attendant can record a sale once, get a confirmation, and never lose or duplicate that sale even under retry |

### Payments API

| Field | Value |
|---|---|
| Numerator | Valid STK/B2C commands accepted, and callbacks processed, within 60 s |
| Denominator | All valid STK/B2C commands and received callbacks |
| Target | ≥ 99.5% |
| 28-day budget | 0.5% of eligible events (≈ 3h 21m 36s of equivalent downtime) |
| Exclusions | Genuine Daraja-side business declines (insufficient funds, user cancels on their phone) — those are correct outcomes, not failures of this SLI. A Daraja **timeout** is explicitly NOT an exclusion — per the product contract, a timeout must resolve to `pending`/`uncertain`, and failure to reach a terminal state within budget counts against this SLO. |
| User outcome represented | A payment attempt reaches a definite, correct state (confirmed/failed/still-pending-and-explained) in reasonable time — the attendant is never left not knowing whether a sale was paid for |

### Commission

| Field | Value |
|---|---|
| Numerator | Eligible daily payouts that reach a terminal state by 06:30 EAT, with zero duplicate disbursements |
| Denominator | All eligible payouts scheduled for that day's run |
| Target | ≥ 99.0% on-time terminal state; duplicate disbursement rate = 0 (this half of the SLO has no error budget — it is a hard invariant, not a probabilistic target) |
| 28-day budget | 1% of eligible payout events late; ≤ 0.28 late scheduled runs per 28-day window |
| Exclusions | Payouts blocked on an upstream Payments API outage that is itself already counted against the Payments API budget (avoids double-counting the same root cause against both services) |
| User outcome represented | Every attendant who earned a commission actually gets paid, on schedule, exactly once — this is the one SLI in the system where the "success" side has zero tolerance, because a duplicate payout is a real money loss, not a UX degradation |

## Budget policy — fast/slow burn alerting

Burn-rate **alerting** is not yet implemented: the deployed CloudWatch alarms (`infra/modules/observability`) are static-threshold alarms, not multi-window burn-rate alarms. Burn rates for the SLIs that existing CloudWatch metrics can support are *displayed* on the self-hosted Grafana dashboard (`observability/grafana/`). Draft policy, using the standard multi-window, multi-burn-rate approach (Google SRE workbook pattern), adapted to this project's 28-day budget windows:

| Burn rate | Windows | Trigger | Response |
|---|---|---|---|
| Fast burn | 5 min AND 1 hour both breaching | Burn rate ≥ 14.4× (would exhaust the 28-day budget in ~2 days if sustained) | Page immediately via Slack. Treat as an active incident; consider a release freeze if a recent deploy correlates. |
| Slow burn | 30 min AND 6 hour both breaching | Burn rate ≥ 6× (would exhaust the budget in ~5 days if sustained) | Slack notification, non-paging. Investigate same business day. |

**Release freeze rule:** if any service's 28-day budget drops below 25% remaining, freeze non-critical merges to that service until the burn rate returns below 1× (i.e., tracking within target) for at least 24 hours. Feature work may resume once budget recovers above 50% remaining, with a written note in `docs/scar-log.md` (not yet created) explaining what caused the burn.

**Commission's duplicate-disbursement invariant** (zero tolerance) bypasses burn-rate alerting entirely: any duplicate disbursement is a page-immediately, freeze-immediately event regardless of remaining budget, since it represents a real money-correctness failure rather than a degraded-but-recoverable availability event.

## What's still needed before this has runtime proof

This document defines the targets. Current state:

**Now in place**

- ADOT Collector sidecar runs beside every backend service (`infra/modules/ecs-service`). Payments exports OTel **traces** through it; no service emits OTel **metrics** yet.
- CloudWatch alarms and an operations dashboard for ALB, ECS, API Gateway and Synthetics (`infra/modules/observability`), with firing/recovery notifications to Slack via SNS (`infra/modules/slack-alerts`).
- A one-minute external synthetic probe, CloudWatch Synthetics canary `devops-g8-probe` (`infra/modules/synthetic-probe`), which GETs the API Gateway root (→ Web).
- k6 stepped-baseline, spike and soak profiles (`scripts/k6/`) with results in `evidence/reliability/capacity-envelope.md`.
- A self-hosted Grafana dashboard definition on CloudWatch (`observability/grafana/`) showing 5m/1h/28d availability, budget remaining and burn rate for the SLIs existing metrics can support: Web (external probe and ALB), POS (ALB proxy), and Payments (HTTP proxy only). Run against the live account on 2026-09-29 with no query errors observed; see `evidence/reliability/g3-grafana-slo-runtime.md`. Its 28d panels are a 28-day query window over the data available since deployment, not 28 days of collected history.

**Still needed**

- Application metrics for the SLIs as defined. The Payments SLI (accepted/processed within 60 s), the Commission on-time terminal state SLI and the duplicate-disbursement invariant cannot be calculated from current telemetry; the Web/POS ALB figures are proxies (all requests, not eligible events). See `observability/grafana/README.md` for the per-panel gaps.
- Multi-window burn-rate alarms (fast/slow policy above) wired to Slack.
- A scheduled trigger for the Commission daily close (the EventBridge rule has no target).
- A full 28-day window of data (services have existed for less than 28 days), and a decision on whether synthetic-probe runs from before the services launched count as eligible events for the Web budget (they currently drive the Web external budget negative; see the G3 evidence).
