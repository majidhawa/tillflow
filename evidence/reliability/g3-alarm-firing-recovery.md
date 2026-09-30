# G3 — Alarm Firing and Recovery Evidence

Owner: Glory (Payments + Integrity), re-exercising a procedure owned
by Hawa (Reliability + Operations), per the documented fallback in
`docs/runbook.md`'s "Incident demo procedure" section.

Date: 2026-09-30

## Context

The alarm -> SNS -> Lambda -> Slack path had been manually exercised
twice before (both firing and recovery reached Slack), but the repo
contained no artifact of either — per `docs/runbook.md`'s "Rehearsal
status" table. This closes that gap: same procedure, this time with
captured JSON state and the actual Slack messages.

Per the runbook's own honest framing: the G3 k6 capacity runs peaked
at approximately 2% CPU on `/pos/health` — nowhere near this alarm's
80% threshold. Rather than wait indefinitely for organic load to
trigger it, this uses the runbook's documented, deliberate
`set-alarm-state` fallback. This proves the alarm -> Slack pipeline
itself works; it does not claim the service was genuinely CPU-bound.

## Baseline

    aws cloudwatch describe-alarms --alarm-names devops-g8-web-ecs-cpu-high --region eu-west-3 --query 'MetricAlarms[0].StateValue'
    "OK"

## Firing

Triggered:

    aws cloudwatch set-alarm-state --alarm-name devops-g8-web-ecs-cpu-high \
      --state-value ALARM --state-reason "G3 evidence capture — deliberate demo trigger, not genuine CPU pressure" \
      --region eu-west-3

Captured alarm state (`StateValue: ALARM`, transitioned
2026-09-30T18:05:06.908+03:00):

    {
      "AlarmName": "devops-g8-web-ecs-cpu-high",
      "StateValue": "ALARM",
      "StateReason": "G3 evidence capture — deliberate demo trigger, not genuine CPU pressure",
      "StateUpdatedTimestamp": "2026-09-30T18:05:06.908000+03:00",
      "Threshold": 80.0,
      "ComparisonOperator": "GreaterThanThreshold"
    }

Slack notification received (18:05 local time):

    ALARM — High ECS CPU utilization
    Environment: capstone   Service: web
    User/SLO impact: web may become slow or start failing health checks if this continues
    Observed value: CPUUtilization > 80% (service: devops-g8-web)
    Grafana panel: https://console.aws.amazon.com/cloudwatch/home?region=eu-west-3#dashboards:name=devops-g8-tillflow-operations
    Runbook: docs/runbook.md#high-ecs-cpumemory
    Owner: Hawaah (Reliability + Operations)
    First safe action: Confirm whether this is expected load (e.g. a k6 test) before considering a scale-up

This matches the alert contract required by the capstone brief in
full: environment, service, symptom, user/SLO impact, observed value,
Grafana panel link, runbook link, owner, and first safe action.

## Recovery

Triggered approximately 34 seconds later:

    aws cloudwatch set-alarm-state --alarm-name devops-g8-web-ecs-cpu-high \
      --state-value OK --state-reason "G3 evidence capture — demo recovery" \
      --region eu-west-3

Captured alarm state (`StateValue: OK`, transitioned
2026-09-30T18:05:40.226+03:00):

    {
      "AlarmName": "devops-g8-web-ecs-cpu-high",
      "StateValue": "OK",
      "StateReason": "G3 evidence capture — demo recovery",
      "StateUpdatedTimestamp": "2026-09-30T18:05:40.226000+03:00"
    }

Slack recovery notification received, same message shape with "OK"
in place of "ALARM."

## Result

Full ALARM -> OK cycle: 34 seconds. Both transitions produced a real
CloudWatch state change and a real Slack message with every required
alert-contract field. This closes the "capture one real firing to
recovery" gap flagged in the all-gates review — the pipeline itself
(alarm -> SNS -> Lambda -> Slack) is proven end to end, with an
artifact in the repo this time.

## What this does not prove

This was a deliberately triggered state change, not organic load. The
G3 capacity tests (`evidence/reliability/capacity-envelope.md`) show
the real traffic pattern never approached this alarm's threshold — so
this evidence proves the alerting *pipeline* works, not that the
service has actually experienced high CPU in practice.