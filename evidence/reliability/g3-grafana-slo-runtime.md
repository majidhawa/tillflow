# G3 — Grafana SLO Dashboard: Runtime Evidence

- Owner: Hawaah (Reliability + Operations)
- Date: 2026-09-29
- Environment: dev, AWS `eu-west-3`, live account
- Dashboard: **TillFlow — SLOs & Operations (CloudWatch)** (uid `tillflow-slo`)
- Implementation: [`observability/grafana/`](../../observability/grafana/README.md)
- SLO source of truth: [`docs/slo-error-budgets.md`](../../docs/slo-error-budgets.md) (targets unchanged)

## Summary

The self-hosted Grafana instance was started locally and connected to the live CloudWatch account in `eu-west-3`. The provisioned dashboard loaded, and every panel either showed live data or a correct "no traffic" or "No data" state. **No red datasource or query errors were observed.** Screenshots were captured manually for the submission and demo. They are kept outside the repository and are not committed here.

The dashboard proves the Grafana/SLO presentation for the SLIs that existing CloudWatch telemetry can support: Web (external and ALB), POS (ALB proxy) and a Payments HTTP proxy. It does **not** prove the Payments or Commission SLIs as defined, because the telemetry for them doesn't exist yet (see [Limitations](#telemetry-limitations)).

## Architecture

```
laptop: docker compose (observability/grafana)
  Grafana OSS 11.1.0  ── 127.0.0.1:3001 (localhost only, admin login, no anonymous access)
    └─ CloudWatch datasource (uid tillflow-cloudwatch, region eu-west-3)
         auth: AWS SDK default chain ← short-lived SSO credentials exported
               into the shell and passed through by Compose (none in the repo)
         reads: AWS/ApplicationELB, AWS/ApiGateway, AWS/ECS,
                ECS/ContainerInsights, CloudWatchSynthetics,
                Logs Insights on /ecs/devops-g8-payments, /ecs/devops-g8-commission
```

- **Self-hosted, not Amazon Managed Grafana:** Managed Grafana isn't available in `eu-west-3`. In `eu-west-1` the cohort SSO role has an explicit deny on `grafana:ListWorkspaces`.
- **CloudWatch, not Prometheus:** all usable signals are already in CloudWatch, and no service exposes metrics for Prometheus to scrape.
- **Read-only:** no AWS resources were created or changed to run this.
- **Window maths:** done in CloudWatch metric math. `SUM()` adds up each window, then the ratio is taken. For example, the ALB SLI is `1 − SUM(FILL(err,0)) / SUM(req)`. Burn rate is `(bad/eligible) / (1 − target)`, and budget remaining is `1 − burn` over the 28-day window.

## Runtime verification

| Check | Result |
|---|---|
| Grafana container started | ✅ `localhost:3001` |
| CloudWatch datasource connected to `eu-west-3` | ✅ |
| Provisioned dashboard loaded | ✅ "TillFlow — SLOs & Operations (CloudWatch)" |
| Datasource or query errors | ✅ none observed (no red panel errors) |
| Dashboard variables found the ALB and target groups | ✅ shown by populated ALB panels for all four services |
| Logs Insights panels ran | ✅ money-path tables populated. Panels with no matching events show "No data". |
| Screenshots | Captured manually for submission and demo; not stored in this repo |

## Observed live values

"28d" below means **a 28-day query window over the data available now**. The services haven't existed for 28 days, so this isn't 28 days of collected production history.

### SLO rows

| SLI (type) | Target | 5m | 1h | 28d window (available data) | Budget remaining | Burn 5m / 1h / 30m / 6h |
|---|---|---|---|---|---|---|
| Web — external synthetic (real, time-based) | 99.9% | 100.000% | 100.000% | 99.611% | **−288.5%** | 0.00× / 0.00× / 0.00× / 0.00× |
| Web — ALB request availability (real, proxy) | 99.9% | 100% | 100% | 100% | 100% | — |
| POS — ALB request availability (real, proxy) | 99.9% | no traffic in window | no traffic in window | 100% | 100% | — |
| Payments — HTTP acceptance (proxy, **not the Payments SLI**) | 99.5% shown | no traffic | no traffic | 100% | — | — |
| Commission | 99.0% / 0 duplicates | not measurable (labelled text panel) | | | | |

"—" means no value was recorded in this run.

**Why the Web external budget is negative:** the numbers are consistent with each other. A 99.611% success rate means 0.389% of canary runs failed. Divided by the 0.1% allowed that's 3.89×, and 1 − 3.89 = −288.5%. The dashboard is calculating correctly. The most likely source of the failed runs is the period when the one-minute canary was running before a healthy backend was behind API Gateway: `infra/modules/synthetic-probe/main.tf` notes the canary "will show failing runs until a real backend is deployed". The current 5m, 1h, 30m and 6h burn rates are all 0.00×, so no budget is being spent now.

- **Reading the number:** −288.5% is a true reading of the data in the window, not proof of a production outage.
- **Scope is still open:** the SLO doc doesn't yet say whether canary runs from before launch count as eligible events. It's recorded here as an open item, not "fixed" by changing the calculation.
- **To confirm the cause:** check the failed-runs series on the Synthetics time-series panel.

### Latency (ALB `TargetResponseTime` p95)

| Service | Current p95 | Worst observed | Target |
|---|---|---|---|
| Web | ≈ 1.40 ms | — | < 500 ms |
| POS | ≈ 877 µs | ≈ 3.86 s | < 400 ms |
| Payments | multi-second observations (current and historical) | multi-second | no latency SLO defined |

- **POS worst case breaches the target:** its worst observed p95 (≈ 3.86 s) is above the 400 ms target. That's shown as it is. The most likely cause is `POST /sales/{id}/payment`, which waits for Payments, which in turn waits for Daraja (`services/pos/payments_client.go`, 10 s client timeout).
- **Why Payments is slow:** its multi-second latency matches the same synchronous Daraja STK, query and B2C calls.
- **Not yet cross-checked:** neither explanation has been checked against request logs here.

### RED and saturation

- **API Gateway:** request, 4xx/5xx and latency metrics populated.
- **ALB:** requests and latency populated for Web, POS, Payments and Commission.
- **ECS:** CPU and memory populated for all four services.
- **Tasks:** running task count is 1 for every service, from Container Insights.
- **Target health:** 0 unhealthy targets for every service.

### Money path (Logs Insights)

| Panel | Observed |
|---|---|
| STK pushes started, by state | `pending` = 2 |
| STK callback transitions | `confirmed` = 1 |
| Reconciliation queries | 4 |
| B2C payout requests | 1 |
| Other money-path panels | "No data" where no matching event happened in the range |

These are counts of log lines from the live G2 runs. They aren't ledger totals (see the limitations below).

## Which panels are real and which are proxies

| Panel group | Status |
|---|---|
| Web external synthetic availability, budget and burn | **Real.** Time-based, 1 probe per minute, and covers **Web only**: the canary GETs the API Gateway root, which the ALB routes to Web. |
| Web and POS ALB availability, budget and burn | **Real data, proxy SLI.** Covers all requests to the target group, including probe and k6 traffic, not just the SLO doc's *eligible* events. ALB-generated 5xx aren't counted per service. |
| Web and POS p95 latency | **Real.** Window stats show the *worst* period p95, not a true windowed p95. |
| Payments row | **Proxy only.** HTTP 5xx or requests, labelled "NOT the Payments SLI". |
| Commission | **Not measurable.** Shown as a labelled text panel. |
| RED and saturation | **Real** AWS metrics. |
| Money path | **Real log counts.** Not metrics, and not a ledger. |

## Telemetry limitations

1. **The Payments SLI isn't measured.** The SLO is "commands accepted and callbacks processed within 60 s", but no metric records command or callback outcomes or time to a final state. Payments returns HTTP 200 even when Daraja rejects a push, so the HTTP proxy can read 100% while payments fail.
2. **The Commission SLI and its invariant aren't measured.**
   - The EventBridge close schedule has no target, so there's no scheduled run to be on time for.
   - The ledger is held in memory.
   - A successful close writes no log or metric.
   - B2C idempotent replays aren't logged, so the duplicate-disbursement invariant can't be observed either way.
3. **The 28-day history is incomplete.** The 28d panels cover only the data since deployment. The window isn't full, so budget and 28d availability figures describe a shorter real period.
4. **Log retention is 14 days**, so the money-path tables can't cover a 28-day window.
5. **State is held in memory.** POS, Payments and Commission lose it on restart, and log counts can't show what was lost.
6. **No business metrics.** Services emit OTel traces (Payments) but no OTel metrics. "Sale paid" isn't visible at all, because POS never learns what happened to a payment.
7. **No burn-rate alerting.** Burn rates are *displayed*. The deployed alarms are static thresholds, not multi-window burn-rate alarms.

## How to reproduce

Follow [`observability/grafana/README.md`](../../observability/grafana/README.md#start-it-locally). In short: export SSO credentials into the shell, run `docker compose up -d` in `observability/grafana/`, then open <http://localhost:3001>.
