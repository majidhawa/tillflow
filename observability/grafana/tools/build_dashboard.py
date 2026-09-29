#!/usr/bin/env python3
"""Generate the provisioned TillFlow SLO/operations Grafana dashboard.

Every panel is backed by an existing CloudWatch metric or ECS log line in
eu-west-3 (see ../README.md for the panel-to-telemetry map). Nothing here
emits, simulates or hard-codes telemetry values; where an SLI cannot be
computed from what exists today, the dashboard shows a labelled text
panel instead of a number.

Run from the repo root:
    python3 observability/grafana/tools/build_dashboard.py
It rewrites observability/grafana/dashboards/tillflow-slo.json. Commit the
generated JSON together with any change to this script.
"""

import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "dashboards" / "tillflow-slo.json"

REGION = "eu-west-3"
DS = {"type": "cloudwatch", "uid": "tillflow-cloudwatch"}

# Deterministic names from infra/ (not secrets). Dynamic IDs (ALB and
# target-group ARN suffixes) are discovered at runtime by template
# variables instead of being copied into the repo.
CLUSTER = "devops-g8-tillflow"          # infra/environments/dev/main.tf module.ecs_cluster
CANARY = "devops-g8-probe"              # infra/modules/synthetic-probe: "${name_prefix}-probe"
API_ID_DEFAULT = "c2po857caj"           # public API Gateway id (part of the public invoke URL)
SERVICES = ["web", "pos", "payments", "commission"]

# Authoritative targets: docs/slo-error-budgets.md
SLO = {"web": 0.999, "pos": 0.999, "payments": 0.995}
LATENCY_P95_S = {"web": 0.5, "pos": 0.4}

_panel_id = 0


def next_id():
    global _panel_id
    _panel_id += 1
    return _panel_id


# --- query builders ---------------------------------------------------------

def metric(ref, namespace, name, dims, stat, period, qid="", hide=False, label=""):
    return {
        "refId": ref,
        "datasource": DS,
        "queryMode": "Metrics",
        "metricQueryType": 0,
        "metricEditorMode": 0,
        "region": REGION,
        "namespace": namespace,
        "metricName": name,
        "dimensions": dims,
        "statistic": stat,
        "period": str(period),
        "matchExact": True,
        "id": qid,
        "expression": "",
        "label": label,
        "hide": hide,
    }


def math(ref, qid, expression, period, label=""):
    return {
        "refId": ref,
        "datasource": DS,
        "queryMode": "Metrics",
        "metricQueryType": 0,
        "metricEditorMode": 1,
        "region": REGION,
        "id": qid,
        "expression": expression,
        "period": str(period),
        "label": label,
        "hide": False,
    }


def logs(ref, group, expression, stats_groups=None):
    return {
        "refId": ref,
        "datasource": DS,
        "queryMode": "Logs",
        "region": REGION,
        "id": "",
        "expression": expression,
        "logGroupNames": [group],
        "logGroups": [],
        "statsGroups": stats_groups or [],
    }


def alb_dims(svc):
    return {"LoadBalancer": "$alb", "TargetGroup": f"$tg_{svc}"}


def ecs_dims(svc):
    return {"ClusterName": CLUSTER, "ServiceName": f"devops-g8-{svc}"}


# --- panel builders ---------------------------------------------------------

def row(title, y):
    return {"type": "row", "title": title, "collapsed": False, "id": next_id(),
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


def text(title, content, x, y, w, h):
    return {"type": "text", "title": title, "id": next_id(),
            "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "options": {"mode": "markdown", "content": content}}


def stat(title, targets, x, y, w, h, unit, thresholds, decimals=None,
         time_from=None, reducer="lastNotNull", no_value="no traffic in window",
         description=""):
    p = {
        "type": "stat", "title": title, "id": next_id(), "datasource": DS,
        "description": description,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets,
        "options": {
            "reduceOptions": {"calcs": [reducer], "fields": "", "values": False},
            "colorMode": "background", "graphMode": "none", "textMode": "value",
            "justifyMode": "center", "orientation": "auto",
        },
        "fieldConfig": {"defaults": {
            "unit": unit, "noValue": no_value,
            "thresholds": {"mode": "absolute", "steps": thresholds},
        }, "overrides": []},
    }
    if decimals is not None:
        p["fieldConfig"]["defaults"]["decimals"] = decimals
    if time_from:
        p["timeFrom"] = time_from
        p["hideTimeOverride"] = False
    return p


def timeseries(title, targets, x, y, w, h, unit, thresholds=None, description=""):
    defaults = {"unit": unit, "custom": {"lineWidth": 1, "fillOpacity": 10,
                                         "spanNulls": False, "showPoints": "never"}}
    if thresholds:
        defaults["thresholds"] = {"mode": "absolute", "steps": thresholds}
        defaults["custom"]["thresholdsStyle"] = {"mode": "line+area"}
    return {
        "type": "timeseries", "title": title, "id": next_id(), "datasource": DS,
        "description": description,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets,
        "options": {"legend": {"displayMode": "table", "placement": "bottom",
                               "calcs": ["lastNotNull", "max"]},
                    "tooltip": {"mode": "multi"}},
        "fieldConfig": {"defaults": defaults, "overrides": []},
    }


def table(title, targets, x, y, w, h, description=""):
    return {"type": "table", "title": title, "id": next_id(), "datasource": DS,
            "description": description,
            "gridPos": {"h": h, "w": w, "x": x, "y": y}, "targets": targets,
            "options": {"showHeader": True}, "fieldConfig": {"defaults": {}, "overrides": []}}


# Threshold palettes
def avail_thresholds(target):
    return [{"color": "red", "value": None}, {"color": "green", "value": target}]


FAST_BURN = [{"color": "green", "value": None}, {"color": "orange", "value": 1},
             {"color": "red", "value": 14.4}]
SLOW_BURN = [{"color": "green", "value": None}, {"color": "orange", "value": 1},
             {"color": "red", "value": 6}]
BUDGET = [{"color": "red", "value": None}, {"color": "orange", "value": 0.25},
          {"color": "green", "value": 0.5}]

# Window -> query period (seconds). 1-minute data is kept 15 days, so the
# 28-day window uses hourly periods.
WINDOWS = {"5m": 60, "30m": 60, "1h": 60, "6h": 300, "28d": 3600}


# --- SLI expressions ----------------------------------------------------------
# Window aggregation happens inside CloudWatch metric math: SUM(series)
# collapses a single time series to a scalar over the queried range, and
# "req*0 + scalar" turns it back into a series so Grafana can display it.
# FILL(err, 0) is required because ALB only publishes 5XX counts for
# periods that had 5XX responses.

def alb_sli_targets(svc, period, kind, target):
    base = [
        metric("A", "AWS/ApplicationELB", "RequestCount", alb_dims(svc), "Sum", period, qid="req", hide=True),
        metric("B", "AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", alb_dims(svc), "Sum", period, qid="err", hide=True),
    ]
    ratio = "(SUM(FILL(err, 0)) / SUM(req))"
    budget = round(1 - target, 6)
    expr = {
        "avail": f"req*0 + (1 - {ratio})",
        "burn": f"req*0 + ({ratio} / {budget})",
        "budget": f"req*0 + (1 - {ratio} / {budget})",
    }[kind]
    return base + [math("C", "sli", expr, period, label=kind)]


def probe_sli_targets(period, kind, target):
    dims = {"CanaryName": CANARY}
    base = [
        metric("A", "CloudWatchSynthetics", "SuccessPercent", dims, "Sum", period, qid="ok", hide=True),
        metric("B", "CloudWatchSynthetics", "SuccessPercent", dims, "SampleCount", period, qid="runs", hide=True),
    ]
    # SuccessPercent is 0 or 100 per one-step run, so SUM/100 = successful
    # runs and SampleCount = runs. Weighted exactly, no averaging of averages.
    fail = "(1 - SUM(ok) / (100 * SUM(runs)))"
    budget = round(1 - target, 6)
    expr = {
        "avail": f"runs*0 + (1 - {fail})",
        "burn": f"runs*0 + ({fail} / {budget})",
        "budget": f"runs*0 + (1 - {fail} / {budget})",
    }[kind]
    return base + [math("C", "sli", expr, period, label=kind)]


def slo_row(panels, y, title, intro, builder, target):
    panels.append(row(title, y))
    y += 1
    panels.append(text("SLI definition", intro, 0, y, 6, 8))
    x = 6
    for win in ["5m", "1h", "28d"]:
        panels.append(stat(f"Availability {win}", builder(WINDOWS[win], "avail", target),
                           x, y, 3, 4, "percentunit", avail_thresholds(target), decimals=3,
                           time_from=win))
        x += 3
    panels.append(stat("Error budget remaining (28d)", builder(WINDOWS["28d"], "budget", target),
                       x, y, 3, 4, "percentunit", BUDGET, decimals=1, time_from="28d",
                       description="1 - (bad/eligible) / (1 - target). <25% = release freeze; "
                                   "work resumes >50% after burn <1x for 24h."))
    x += 3
    panels.append(text("SLO target", f"## {target * 100:.1f}%\n28-day rolling window",
                       x, y, 3, 4))
    # burn rates on the second line
    x = 6
    for win, th in [("5m", FAST_BURN), ("1h", FAST_BURN), ("30m", SLOW_BURN), ("6h", SLOW_BURN)]:
        kind = "fast" if th is FAST_BURN else "slow"
        panels.append(stat(f"Burn rate {win} ({kind})", builder(WINDOWS[win], "burn", target),
                           x, y + 4, 3, 4, "x", th, decimals=2, time_from=win,
                           description="Fast burn pages when 5m AND 1h are both >= 14.4x; "
                                       "slow burn when 30m AND 6h are both >= 6x."))
        x += 3
    panels.append(text("Burn policy", "Fast: 5m **and** 1h ≥ 14.4×\n\nSlow: 30m **and** 6h ≥ 6×",
                       x, y + 4, 6, 4))
    return y + 8


def build():
    panels = []
    y = 0

    panels.append(text("Read me first — what is real on this dashboard", README_PANEL, 0, y, 24, 7))
    y += 7

    # 1. External availability (canary hits the API Gateway root -> ALB default -> Web)
    y = slo_row(panels, y, "SLO · Web — external synthetic availability (CloudWatch Synthetics)",
                "**Real telemetry.** `CloudWatchSynthetics/SuccessPercent` for canary "
                f"`{CANARY}` — one GET of the public API Gateway root every minute. "
                "That path lands on the ALB default action, i.e. **Web**.\n\n"
                "SLI = successful runs / runs (time-based, 1 sample/min). It does **not** "
                "exercise POS, Payments or Commission.",
                lambda p, k, t: probe_sli_targets(p, k, t), SLO["web"])

    # 2-3. Request-based ALB SLIs for Web and POS
    for svc, label in [("web", "Web"), ("pos", "POS")]:
        y = slo_row(panels, y, f"SLO · {label} — request availability at the ALB target group",
                    f"**Real telemetry, proxy SLI.** 1 − `HTTPCode_Target_5XX_Count` / "
                    f"`RequestCount` for target group `{svc}`.\n\n"
                    "Counts every request routed to the service (including k6 and probe "
                    "traffic), not only the eligible events in the SLO doc. ALB-generated "
                    "5xx (e.g. no healthy targets) are load-balancer-level only and are "
                    "**not** included — see the RED row and the external SLI.",
                    lambda p, k, t, s=svc: alb_sli_targets(s, p, k, t), SLO[svc])

    # 4. Payments: HTTP proxy only
    y = slo_row(panels, y, "Payments — HTTP acceptance proxy only (NOT the Payments SLI)",
                "**Proxy, not the SLI.** The Payments SLO is *commands accepted and callbacks "
                "processed within 60 s*. No metric records command/callback outcomes or "
                "their timing, so this row only shows ALB 5xx vs requests for the payments "
                "target group. Payments returns HTTP 200 even when Daraja rejects an STK "
                "push (state `failed`), so this row can be green while payments fail.",
                lambda p, k, t: alb_sli_targets("payments", p, k, t), SLO["payments"])

    # 5. Commission
    panels.append(row("Commission — on-time terminal state ≥ 99.0% · duplicate disbursement = 0", y))
    y += 1
    panels.append(text("Commission SLI: cannot be calculated from current telemetry",
                       COMMISSION_GAP, 0, y, 24, 6))
    y += 6

    # 6. Latency SLOs
    panels.append(row("Latency SLOs — ALB TargetResponseTime p95", y))
    y += 1
    for i, (svc, label) in enumerate([("web", "Web"), ("pos", "POS")]):
        tgt = LATENCY_P95_S[svc]
        th = [{"color": "green", "value": None}, {"color": "red", "value": tgt}]
        x0 = i * 12
        panels.append(timeseries(
            f"{label} p95 latency (5-min periods) vs {int(tgt * 1000)} ms target",
            [metric("A", "AWS/ApplicationELB", "TargetResponseTime", alb_dims(svc), "p95", 300,
                    label=f"{svc} p95")],
            x0, y, 8, 8, "s", th))
        panels.append(stat(f"{label} worst 5-min p95 (1h)",
                           [metric("A", "AWS/ApplicationELB", "TargetResponseTime", alb_dims(svc),
                                   "p95", 300)],
                           x0 + 8, y, 4, 4, "s", th, decimals=3, time_from="1h", reducer="max",
                           description="Max of 5-minute p95 values. A true windowed p95 would "
                                       "need raw request latencies."))
        panels.append(stat(f"{label} worst hourly p95 (28d)",
                           [metric("A", "AWS/ApplicationELB", "TargetResponseTime", alb_dims(svc),
                                   "p95", 3600)],
                           x0 + 8, y + 4, 4, 4, "s", th, decimals=3, time_from="28d", reducer="max",
                           description="Max of hourly p95 values over 28 days — conservative, "
                                       "not a 28-day p95."))
    y += 8

    # 7. RED
    panels.append(row("RED — rate, errors, duration (edge + per service)", y))
    y += 1
    api = {"ApiId": "$api_id"}
    panels.append(timeseries("API Gateway requests / 4xx / 5xx", [
        metric("A", "AWS/ApiGateway", "Count", api, "Sum", 60, label="requests"),
        metric("B", "AWS/ApiGateway", "4xx", api, "Sum", 60, label="4xx"),
        metric("C", "AWS/ApiGateway", "5xx", api, "Sum", 60, label="5xx"),
    ], 0, y, 8, 8, "short"))
    panels.append(timeseries("API Gateway error ratio (5xx / requests)", [
        metric("A", "AWS/ApiGateway", "Count", api, "Sum", 60, qid="req", hide=True),
        metric("B", "AWS/ApiGateway", "5xx", api, "Sum", 60, qid="err", hide=True),
        math("C", "ratio", "FILL(err, 0) / req", 60, label="5xx ratio"),
    ], 8, y, 8, 8, "percentunit"))
    panels.append(timeseries("API Gateway latency p95 (total vs integration)", [
        metric("A", "AWS/ApiGateway", "Latency", api, "p95", 60, label="latency p95"),
        metric("B", "AWS/ApiGateway", "IntegrationLatency", api, "p95", 60, label="integration p95"),
    ], 16, y, 8, 8, "ms"))
    y += 8
    panels.append(timeseries("ALB requests per service", [
        metric(chr(65 + i), "AWS/ApplicationELB", "RequestCount", alb_dims(s), "Sum", 60, label=s)
        for i, s in enumerate(SERVICES)], 0, y, 8, 8, "short"))
    panels.append(timeseries("ALB target 5xx per service + ALB-generated 5xx", [
        metric(chr(65 + i), "AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", alb_dims(s), "Sum", 60,
               label=f"{s} target 5xx") for i, s in enumerate(SERVICES)] + [
        metric("E", "AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", {"LoadBalancer": "$alb"}, "Sum", 60,
               label="ALB-generated 5xx (all services)")], 8, y, 8, 8, "short"))
    panels.append(timeseries("ALB target response time p95 per service", [
        metric(chr(65 + i), "AWS/ApplicationELB", "TargetResponseTime", alb_dims(s), "p95", 60, label=s)
        for i, s in enumerate(SERVICES)], 16, y, 8, 8, "s"))
    y += 8

    # 8. Saturation
    panels.append(row("Saturation — ECS (AWS/ECS + Container Insights)", y))
    y += 1
    panels.append(timeseries("ECS CPUUtilization (%)", [
        metric(chr(65 + i), "AWS/ECS", "CPUUtilization", ecs_dims(s), "Average", 60, label=s)
        for i, s in enumerate(SERVICES)], 0, y, 8, 8, "percent",
        [{"color": "green", "value": None}, {"color": "red", "value": 70}]))
    panels.append(timeseries("ECS MemoryUtilization (%)", [
        metric(chr(65 + i), "AWS/ECS", "MemoryUtilization", ecs_dims(s), "Average", 60, label=s)
        for i, s in enumerate(SERVICES)], 8, y, 8, 8, "percent",
        [{"color": "green", "value": None}, {"color": "red", "value": 75}]))
    panels.append(timeseries("Running tasks (Container Insights) + unhealthy ALB targets", [
        metric(chr(65 + i), "ECS/ContainerInsights", "RunningTaskCount", ecs_dims(s), "Average", 60,
               label=f"{s} running") for i, s in enumerate(SERVICES)] + [
        metric(chr(69 + i), "AWS/ApplicationELB", "UnHealthyHostCount", alb_dims(s), "Maximum", 60,
               label=f"{s} unhealthy") for i, s in enumerate(SERVICES)], 16, y, 8, 8, "short"))
    y += 8

    # 9. Money path from logs
    panels.append(row("Money path — from Payments / Commission log lines (CloudWatch Logs Insights)", y))
    y += 1
    pay = "/ecs/devops-g8-payments"
    com = "/ecs/devops-g8-commission"
    panels.append(table("STK push initiations by initial state", [logs("A", pay,
        "fields @timestamp, @message\n| filter @message like /stk_push: payment=/\n"
        "| parse @message \"state=* trace_id=\" as state\n| stats count(*) as initiations by state",
        ["state"])], 0, y, 6, 8,
        "Logged by services/payments/stkpush.go when Daraja answers an STK push. "
        "Idempotent retries return early and are not logged."))
    panels.append(table("STK callback transitions by terminal state", [logs("A", pay,
        "fields @timestamp, @message\n| filter @message like /callback: payment .* transitioned to/\n"
        "| parse @message \"transitioned to * (\" as state\n| stats count(*) as callbacks by state",
        ["state"])], 6, y, 6, 8,
        "Callback-driven transitions only. State changes applied by /payments/query "
        "reconciliation are not logged as transitions."))
    panels.append(table("Callbacks ignored (duplicate/reordered or unknown)", [logs("A", pay,
        "fields @timestamp, @message\n"
        "| filter @message like /callback: duplicate\\/reordered callback/ or @message like /callback: unknown CheckoutRequestID/\n"
        "| parse @message /callback: (?<kind>duplicate|unknown)/\n| stats count(*) as ignored by kind",
        ["kind"])], 12, y, 6, 8,
        "Evidence that idempotency held: duplicates were recognised and not re-applied."))
    panels.append(table("Reconciliation queries by Daraja ResultCode", [logs("A", pay,
        "fields @timestamp, @message\n| filter @message like /query: raw daraja response/\n"
        "| parse @message /\"ResultCode\":\\s*\"(?<result_code>[^\"]*)\"/\n"
        "| stats count(*) as queries by result_code", ["result_code"])], 18, y, 6, 8))
    y += 8
    panels.append(table("B2C payout requests by Daraja ResponseCode", [logs("A", pay,
        "fields @timestamp, @message\n| filter @message like /b2c: raw daraja response/\n"
        "| parse @message /\"ResponseCode\":\\s*\"(?<response_code>[^\"]*)\"/\n"
        "| stats count(*) as b2c_requests by response_code", ["response_code"])], 0, y, 8, 8,
        "Daraja acceptance of the payout request, not the final payout result."))
    panels.append(table("B2C result callbacks", [logs("A", pay,
        "fields @timestamp, @message\n| filter @message like /b2c callback: payout .* transitioned to/ "
        "or @message like /b2c callback: duplicate/\n"
        "| parse @message /b2c callback: (?<kind>payout|duplicate)/\n| stats count(*) as callbacks by kind",
        ["kind"])], 8, y, 8, 8))
    panels.append(table("Commission close: B2C failures and tenant-isolation skips", [logs("A", com,
        "fields @timestamp, @message\n"
        "| filter @message like /commission: B2C request failed/ or @message like /commission: skipping sale/\n"
        "| parse @message /commission: (?<event>B2C request failed|skipping sale)/\n"
        "| stats count(*) as events by event", ["event"])], 16, y, 8, 8,
        "Successful closes are not logged by Commission, so there is no on-time/terminal count here."))
    y += 8
    panels.append(text("Money-path limits", MONEY_GAP, 0, y, 24, 6))
    y += 6

    return {
        "uid": "tillflow-slo",
        "title": "TillFlow — SLOs & Operations (CloudWatch)",
        "tags": ["tillflow", "slo", "cloudwatch", "capstone"],
        "timezone": "browser",
        "schemaVersion": 39,
        "version": 1,
        "editable": False,
        "graphTooltip": 1,
        "refresh": "1m",
        "time": {"from": "now-24h", "to": "now"},
        "templating": {"list": TEMPLATING},
        "annotations": {"list": []},
        "panels": panels,
    }


def dim_values_var(name, label, metric_name, key, regex, filters=None):
    return {
        "name": name, "label": label, "type": "query", "datasource": DS,
        "query": {"queryType": "dimensionValues", "region": REGION,
                  "namespace": "AWS/ApplicationELB", "metricName": metric_name,
                  "dimensionKey": key, "dimensionFilters": filters or {},
                  "refId": "CloudWatchVariableQueryEditor-VariableQuery"},
        "regex": regex, "refresh": 1, "sort": 1, "multi": False, "includeAll": False,
        "hide": 0, "current": {}, "options": [],
    }


TEMPLATING = [
    dim_values_var("alb", "ALB", "RequestCount", "LoadBalancer", "/^app\\/devops-g8-alb\\/.+$/"),
] + [
    dim_values_var(f"tg_{s}", f"TG {s}", "RequestCount", "TargetGroup",
                   f"/^targetgroup\\/devops-g8-{s}-tg\\/.+$/", {"LoadBalancer": "$alb"})
    for s in SERVICES
] + [
    {"name": "api_id", "label": "API Gateway id", "type": "textbox", "query": API_ID_DEFAULT,
     "current": {"text": API_ID_DEFAULT, "value": API_ID_DEFAULT}, "hide": 0},
]

README_PANEL = """\
**Datasource:** CloudWatch, eu-west-3 — existing AWS metrics and ECS logs only. No values on this dashboard are simulated or typed in.

| Panel group | Backed by | Honest? |
|---|---|---|
| Web external availability | `CloudWatchSynthetics/SuccessPercent` (1 probe/min to the API Gateway root → Web) | ✅ real, time-based |
| Web / POS request availability | ALB `RequestCount` + `HTTPCode_Target_5XX_Count` per target group | ✅ real, **proxy** (all requests, excludes ALB-generated 5xx) |
| Web / POS p95 latency | ALB `TargetResponseTime` p95 per target group | ✅ real (window values are max-of-period p95) |
| Payments row | ALB HTTP 5xx for payments | ⚠️ proxy only — the Payments SLI needs outcome/timing metrics that do not exist |
| Commission | — | ❌ not measurable today (text panel explains why) |
| Money path | Logs Insights over Payments/Commission log lines | ✅ real counts, **14-day log retention**, in-memory service state |

**28d panels** only cover data since the services were deployed — the SLO window is not yet full. Empty stats read *no traffic in window* rather than a fake 100%.
"""

COMMISSION_GAP = """\
**Not calculated — no telemetry exists for this SLI.** Required: per-payout records of *scheduled at / terminal at / terminal state* and a disbursement count per idempotency key.

Why not today (from the current source):
- The daily close is only triggered manually — the EventBridge rule has **no target** (`infra/modules/eventbridge-schedule/main.tf`), so there is no scheduled run to be on time for.
- The payout ledger is **in memory** (`services/commission/main.go`) and a successful close emits **no log line or metric**; only failures and tenant-mismatch skips are logged (see Money path row).
- Payments' B2C idempotent replays return early **without logging**, so a prevented duplicate is invisible, and there is no metric that could show an actual duplicate disbursement.
- Commission records `requested` whenever Payments returns HTTP 200, even if the payout state is `failed`.

To make this real: emit an OTel counter/histogram (via the existing ADOT sidecar → CloudWatch EMF) for `payout_terminal_total{state}`, `payout_terminal_latency_seconds`, `b2c_disbursements_total{idempotency_key}`, and persist the ledger.
"""

MONEY_GAP = """\
**Limits of the money-path view (from logs, not metrics):**
- Counts come from log lines, not from a ledger. Log groups keep **14 days** (`infra/modules/ecs-cluster` `log_retention_days`), so these tables cannot cover a 28-day window.
- Payments, POS and Commission keep state **in memory**; a task restart resets it, and the logs do not reveal what was lost.
- **POS sale → paid is not visible anywhere:** POS never learns a payment's outcome (no notify/poll integration), so there is no "sales paid" metric or log to chart.
- Payments emits OTel **traces only** (no metrics), so there is no business-metric time series (e.g. confirmed payments/min, KES collected). Adding OTel metrics exported via ADOT to CloudWatch would make these first-class, alertable SLIs.
"""


if __name__ == "__main__":
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(build(), indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {OUT}")
