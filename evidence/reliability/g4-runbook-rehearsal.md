# G4 — Runbook Procedure Rehearsal

Owner: Glory (Payments + Integrity)
Date: 2026-09-30

Per `docs/runbook.md`'s rehearsal status table: "Elevated latency /
5xx / CPU-memory: diagnose -> resolve | Not yet rehearsed." This
rehearses the diagnostic query portion for CPU (the resolve step
wasn't exercised since no incident occurred to resolve).

## CPU diagnosis query

    aws cloudwatch get-metric-statistics \
      --namespace AWS/ECS \
      --metric-name CPUUtilization \
      --dimensions Name=ServiceName,Value=devops-g8-payments Name=ClusterName,Value=devops-g8-tillflow \
      --start-time <60 minutes ago> --end-time <now> \
      --period 300 --statistics Average Maximum --region eu-west-3

Result: average ~0.42%, maximum ~1.19% across the queried window —
well below the 80% alarm threshold (`devops-g8-payments-ecs-cpu-high`).
Confirms the diagnostic query itself works correctly and that Payments
is currently healthy.

## Latency diagnosis — attempted, no data

Attempted the same rehearsal for `TargetResponseTime` on the ALB's
`payments` target group. Returned zero datapoints for both a 10-minute
and 60-minute window — no traffic passed through that target group in
the queried period. This is expected for a low-traffic dev
environment; the query itself is documented and correct
(`docs/runbook.md#elevated-latency`), it simply had nothing to
diagnose against at the time of rehearsal.

## What this does not prove

No actual incident occurred during this rehearsal — this confirms the
diagnostic queries in the runbook are correct and executable, not that
a real diagnose-then-resolve cycle was completed end to end.