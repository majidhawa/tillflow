# Self-hosted Grafana — TillFlow SLOs & Operations

- Owner: Hawaah (Reliability + Operations)
- Status: run against the live account on 2026-09-29 — datasource connected, dashboard loaded, no query errors observed. Evidence: [`evidence/reliability/g3-grafana-slo-runtime.md`](../../evidence/reliability/g3-grafana-slo-runtime.md)
- SLO source of truth: [`docs/slo-error-budgets.md`](../../docs/slo-error-budgets.md)

A single local Grafana container that reads TillFlow's **existing** CloudWatch metrics and ECS logs in `eu-west-3`. It creates, changes or deletes nothing in AWS. It only needs read access.

```
observability/grafana/
├── docker-compose.yml                      # Grafana OSS, bound to 127.0.0.1:3001
├── .env.example                            # admin password only (copy to .env, gitignored)
├── provisioning/datasources/cloudwatch.yaml  # CloudWatch datasource, default AWS credential chain
├── provisioning/dashboards/tillflow.yaml     # loads dashboards/ read-only
├── dashboards/tillflow-slo.json            # generated — do not hand-edit
└── tools/build_dashboard.py                # generator for the dashboard JSON
```

## Why this setup

**Self-hosted, not Amazon Managed Grafana.** Amazon Managed Grafana isn't available in `eu-west-3`. In `eu-west-1` the API responds, but the cohort SSO role has an explicit IAM deny on `grafana:ListWorkspaces`, so we can't create or use a workspace. Grafana OSS running locally in Docker is the smallest setup that gives real Grafana dashboards without any new AWS resources.

**CloudWatch datasource, not Prometheus.** Every signal the SLOs can currently use is already in CloudWatch: ALB, API Gateway, ECS/Container Insights, Synthetics and ECS logs. Grafana's built-in CloudWatch datasource can read all of it and do the window maths with CloudWatch metric math. Prometheus would add a scrape target, storage and a second copy of the same data, and nothing would feed it: no service exposes a `/metrics` endpoint, and the ADOT sidecars only forward Payments' traces. There's no technical need for it today. Once services emit OpenTelemetry metrics, the existing ADOT → CloudWatch path (EMF) would still let this datasource read them.

## Start it locally

Prerequisites: Docker Desktop, AWS CLI v2 (2.9 or later, for `export-credentials`), and an SSO session for the TillFlow account.

```sh
cd observability/grafana
cp .env.example .env            # then set GRAFANA_ADMIN_PASSWORD in .env

aws sso login --profile devops-g8-new
eval "$(aws configure export-credentials --profile devops-g8-new --format env)"

docker compose up -d
docker compose logs -f grafana  # wait for "HTTP Server Listen"
```

Open <http://localhost:3001>, sign in as `admin` with your `.env` password, and the **TillFlow — SLOs & Operations (CloudWatch)** dashboard opens as the home page. It's also under *Dashboards → TillFlow*.

Stop with `docker compose down`. Add `-v` if you also want to delete the local Grafana volume.

## AWS authentication (no credentials in the repo)

- The datasource uses `authType: default`, which is the AWS SDK default credential chain. `GF_AWS_ALLOWED_AUTH_PROVIDERS=default` disables every other method, including typing access keys into the UI.
- `aws configure export-credentials` puts **short-lived** SSO role credentials into your current shell only. `docker-compose.yml` lists `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN` without values, so Compose copies them from that shell into the container. They're never written to a file in the repo.
- When the SSO session expires, panels start failing with auth errors. Run `aws sso login` and the `eval` line again, then `docker compose up -d --force-recreate`.
- The port is bound to `127.0.0.1` only, and anonymous access and sign-up are off, because anyone who can reach this Grafana can read CloudWatch with your role.
- Don't run `docker compose config` without `--quiet` while credentials are exported: it prints the resolved environment.

**Read permissions needed** by the role: `cloudwatch:GetMetricData`, `cloudwatch:ListMetrics`, `logs:StartQuery`, `logs:GetQueryResults`, `logs:StopQuery`, `logs:DescribeLogGroups`, `logs:GetLogGroupFields` and `ec2:DescribeRegions`. If the cohort role denies any of these, the matching panels show a permission error. They don't show fake data.

## What the dashboard shows

Every number comes from CloudWatch. Dynamic IDs such as the ALB and target group ARN suffixes are looked up at runtime by dashboard variables (`alb`, `tg_*`) that filter by the Terraform resource names. Fixed names come from `infra/`: cluster `devops-g8-tillflow`, canary `devops-g8-probe`, API id `c2po857caj` (editable in the `api_id` box).

### Panels backed by real telemetry

| Row | Source | How it's calculated |
|---|---|---|
| **SLO · Web — external synthetic availability** | `CloudWatchSynthetics` `SuccessPercent` (`Sum` and `SampleCount`), canary `devops-g8-probe` | Successful runs / runs over each window: `SUM(ok) / (100 × SUM(runs))`. The canary does a GET on the API Gateway root once a minute. That request hits the ALB's default route, so this measures **Web only**, based on probe runs rather than requests. |
| **SLO · Web / POS — request availability** | ALB `RequestCount` and `HTTPCode_Target_5XX_Count` per target group | `1 − SUM(FILL(err,0)) / SUM(req)` over each window. This is a **proxy** (see the limits below). |
| **5m / 1h / 28d availability** | the two rows above | `SUM()` in CloudWatch metric math adds up the whole window before dividing, so it isn't an average of per-minute ratios. |
| **Error budget remaining (28d)** | as above | `1 − (bad/eligible) / (1 − target)`. Thresholds: red below 25% (release freeze), orange from 25%, green above 50%. |
| **Burn rate 5m / 1h / 30m / 6h** | as above | `(bad/eligible) / (1 − target)`. The 5m and 1h panels go red at 14.4× (fast burn); the 30m and 6h panels go red at 6× (slow burn). |
| **Latency SLOs** | ALB `TargetResponseTime` p95 per target group | A 5-minute p95 time series against the 500 ms (Web) and 400 ms (POS) targets. The stat panels show the **worst** 5-minute p95 in the last hour and the **worst** hourly p95 in 28 days, which errs on the strict side. |
| **RED** | API Gateway `Count`, `4xx`, `5xx`, `Latency`, `IntegrationLatency` (dimension `ApiId`); ALB `RequestCount`, `HTTPCode_Target_5XX_Count`, `HTTPCode_ELB_5XX_Count`, `TargetResponseTime` | Requests, errors, error ratio and p95 latency at the edge and for each service. |
| **Saturation** | `AWS/ECS` `CPUUtilization` and `MemoryUtilization`; `ECS/ContainerInsights` `RunningTaskCount`; ALB `UnHealthyHostCount` | Threshold lines match the existing alarms and the capacity envelope (CPU 70%, memory 75%). |
| **Money path (Logs Insights)** | `/ecs/devops-g8-payments` and `/ecs/devops-g8-commission` log lines | Counts of STK starts by state, callback transitions, ignored duplicate or unknown callbacks, reconciliation `ResultCode`s, B2C `ResponseCode`s, B2C result callbacks, and Commission's B2C failures and tenant-isolation skips. |

### Required panels that can't yet be calculated honestly

| Required view | Why not | What would fix it |
|---|---|---|
| **Payments SLI** (commands accepted and callbacks processed within 60 s, target 99.5%) | No metric records command outcomes, callback timing or time to a final state. Payments returns HTTP 200 even when Daraja rejects a push. The Payments row is labelled as an **HTTP proxy only**. | Emit OTel metrics (for example `payment_terminal_total{state}` and `payment_time_to_terminal_seconds`) through the ADOT sidecar to CloudWatch (EMF). |
| **Commission on-time final state (target 99.0%)** | The EventBridge rule has **no target**, so there's no scheduled run to be on time for. The ledger is held in memory, and a successful close writes no log line or metric. | A scheduled trigger, a stored ledger, and OTel metrics for payout final state and timing. |
| **Duplicate disbursement rate = 0** | Payments' B2C returns early on an idempotent replay **without logging**. No metric counts disbursements per idempotency key, so neither a blocked duplicate nor a real one can be seen. | A disbursement counter per idempotency key, plus a log line or metric when a replay is blocked. |
| **POS "sale paid" / business outcome** | POS never learns what happened to a payment: Payments doesn't notify it and POS doesn't ask. Sales stay `pending_payment` forever. | An integration from Payments to POS, then a business metric. |
| **Exact Web/POS SLIs as written** | The SLO doc counts *eligible* requests answered *within the latency target*. The ALB only gives all requests and 5xx, and latency percentiles per period. ALB-generated 5xx (for example, no healthy targets) are counted for the load balancer only, not per service. | Application-side metrics for each request, recording outcome and latency. |
| **Full 28-day window** | The services were only deployed recently, so the 28-day panels cover data since deployment. Log groups keep only **14 days** of data. | Time. Longer log retention if the money-path tables need to cover 28 days. |

Panels with no data show **"no traffic in window"**. They never default to 100%.

## Changing the dashboard

Edit `tools/build_dashboard.py`, then run:

```sh
python3 observability/grafana/tools/build_dashboard.py
```

Commit the script and the regenerated `dashboards/tillflow-slo.json` together. Changes made in the Grafana UI are deliberately not saved (`allowUiUpdates: false`).

## Assumptions and first-run results

The first live run (2026-09-29) showed no query errors. Money-path tables populated, which confirms `logGroupNames` works on this image, and Container Insights reported one running task per service.

- **Hidden metric queries:** the SLO stats use hidden metric queries (`req`/`err`, `ok`/`runs`) referenced by a single CloudWatch metric-math query in the same panel, which is Grafana's standard pattern for CloudWatch metric math. If a stat shows an expression error, check the panel's query inspector.
- **`FILL(err, 0)` with zero 5xx:** this is how a window with no 5xx at all counts as 100% available. The ALB doesn't publish zero values for 5xx counts. Check one Web or POS availability stat against a manual `aws cloudwatch get-metric-data` run.
- **Log group names:** the Logs Insights panels use `logGroupNames`. If a newer Grafana image asks for log group ARNs instead, re-select the two log groups in the panel editor and update the generator.
- **Container Insights:** `RunningTaskCount` needs Container Insights to be publishing. It's enabled on the cluster.
