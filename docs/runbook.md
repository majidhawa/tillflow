# TillFlow Operational Runbook

- Status: Active for G3 alerting. All four services (`web`, `pos`, `payments`, `commission`) are deployed on ECS in `eu-west-3` (one running task each), behind the internal ALB and the public API Gateway. The alarm → SNS → Lambda → Slack path has been exercised end to end, both firing and recovery (see [Rehearsal status](#rehearsal-status)). Most of the diagnose/resolve procedures below have **not** yet been rehearsed. The G4 recovery drills are still open.
- Last reviewed: 2026-09-29 against `main` @ `f022126`
- DRI: Hawaah (Reliability + Operations)
- Alerting: all alarms below publish to the `devops-g8-alerts` SNS topic (`infra/modules/slack-alerts`), which forwards to Slack via the existing Lambda subscriber.
- Dashboard: `devops-g8-tillflow-operations` (CloudWatch console -> Dashboards), created by `infra/modules/observability`.
- Alarm naming convention: `devops-g8-<service>-<signal>` for per-service alarms, `devops-g8-apigw-<signal>` and `devops-g8-synthetic-probe-<signal>` for the shared ones. The full list of 24 alarms and their exact thresholds is defined in `infra/modules/observability/main.tf`.

## Rehearsal status

This table shows which procedures below have actually been run. A procedure marked "not yet rehearsed" is a written plan, not a proven one.

| Procedure | Status | Evidence |
|---|---|---|
| Alarm → SNS (`devops-g8-alerts`) → Lambda → Slack, **firing** notification | **Exercised (manually)** | Alert firing was manually exercised against the live environment, and the notification reached Slack. The repository does not currently contain the screenshot or log artifact. |
| Same path, **recovery** (`ok_actions`) notification | **Exercised (manually)** | Recovery was manually exercised the same way, and the recovery notification reached Slack. Same caveat: no artifact in the repo. |
| Live telemetry for the signals below (ALB, ECS, API Gateway, Synthetics) | **Observed** | Populated from live data in the Grafana SLO dashboard: [evidence/reliability/g3-grafana-slo-runtime.md](../evidence/reliability/g3-grafana-slo-runtime.md) |
| k6 load against the live path (stepped, spike, soak on `/pos/health`) | **Exercised** | [evidence/reliability/capacity-envelope.md](../evidence/reliability/capacity-envelope.md). No alarm crossed its threshold under this load (peak CPU ≈ 2%). |
| Unhealthy ECS service/tasks: diagnose → recover | Not yet rehearsed (G4) | — |
| Elevated latency / 5xx / CPU-memory: diagnose → resolve | Not yet rehearsed | — |
| Synthetic probe failure: diagnose | Not yet rehearsed | The canary's historical failed runs appear in the G3 evidence, but they were not worked through this procedure. |
| Failed deployment / rollback | **Not yet rehearsed (G4 broken-release drill)** | — |
| Platform failure (e.g. task/AZ loss) recovery | **Not yet rehearsed (G4)** | No procedure written in this runbook yet. |
| Backup restore (RDS) | **Not yet rehearsed (G4)** | No procedure written in this runbook yet. The services currently hold state in memory, not in RDS. |
| Payments uncertain-payment and callback-replay drills | Executed locally by Payments (sandbox and unit tests) | [evidence/payments/g4-recovery-drills.md](../evidence/payments/g4-recovery-drills.md). This is not a rehearsal of this runbook. |

Recovery sits under the Reliability + Operations DRI (`docs/ownership.md`). Glory is currently executing and assisting with the G4 drills in coordination with Hawa. Nothing here claims G4 is complete.

This runbook covers threshold-based alerting only. The multi-window burn-rate policy described in `docs/slo-error-budgets.md`'s "Budget policy" section is explicitly **not yet implemented** — that document already says so, and this runbook doesn't claim otherwise.

## How to read an alarm notification

Every alarm's Slack message includes the alarm name, which tells you the service and signal directly (e.g. `devops-g8-pos-ecs-cpu-high`). Jump to the matching section below.

---

## Unhealthy ECS service/tasks

**Signal:** `devops-g8-<service>-alb-unhealthy-hosts` (`UnHealthyHostCount` >= 1, 2x 60s periods)

**Likely causes:** the container's `/health` check is failing (crash loop, bad image, missing env/secret), or the task can't reach the ALB's health-check port.

**Diagnose:**
```bash
aws ecs describe-services --cluster devops-g8-tillflow --services devops-g8-<service> \
  --query 'services[0].{status:status,running:runningCount,desired:desiredCount,events:events[0:5]}'

aws logs tail /ecs/devops-g8-<service> --since 15m --follow
```

**Resolve:** if a bad image caused it, see "Failed deployment / rollback" below. If it's a transient crash, ECS will keep replacing the task automatically — confirm `runningCount` climbs back to `desiredCount`.

**Verify recovery:** the alarm returns to `OK` (its `ok_actions` also notify Slack), and `UnHealthyHostCount` reads 0 in the dashboard's "ALB unhealthy target count" widget.

---

## Elevated latency

**Signal:** `devops-g8-<service>-alb-latency-p90` (`TargetResponseTime` p90 > 1.0s, 3x 60s) or `devops-g8-apigw-latency` (average > 1000ms, 3x 60s)

**Likely causes:** CPU/memory pressure on the task (check the CPU/memory alarms next), a downstream dependency slowdown (RDS/Redis/SQS), or a genuine load spike (e.g. the k6 test running).

**Diagnose:**
```bash
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime --statistics p90 --period 60 \
  --start-time "$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --dimensions Name=LoadBalancer,Value=<alb_arn_suffix> Name=TargetGroup,Value=<target_group_arn_suffix>
```
(ARN suffixes are in the `alb_arn_suffix` / per-service `target_group_arn_suffixes` Terraform outputs, or read them off the dashboard widget directly.)

**Resolve:** if it's a real load spike beyond expected capacity, scale the ECS service (`desired_count` in `infra/environments/dev/main.tf`, or manually with `aws ecs update-service --desired-count N` as an immediate stopgap). If it's the k6 test, stop it and confirm latency recovers.

**Verify recovery:** the alarm returns to `OK`; the dashboard's latency widget drops back under threshold.

---

## Elevated 5xx

**Signal:** `devops-g8-<service>-alb-target-5xx` (>= 5 in 5 min) or `devops-g8-apigw-5xx` (>= 5 in 5 min)

**Likely causes:** application error (check container logs first), or the target is unhealthy and the ALB has nothing to route to (check the unhealthy-hosts alarm too — they often fire together).

**Diagnose:**
```bash
aws logs tail /ecs/devops-g8-<service> --since 15m --filter-pattern "ERROR"
```

**Resolve:** depends on the underlying cause found in logs. If it's a bad release, go to "Failed deployment / rollback."

**Verify recovery:** `HTTPCode_Target_5XX_Count` / API Gateway `5xx` return to 0 in the relevant 5-minute window; alarm state returns to `OK`.

---

## High ECS CPU/memory

**Signal:** `devops-g8-<service>-ecs-cpu-high` or `devops-g8-<service>-ecs-memory-high` (average > 80%, 3x 60s)

**Likely causes:** real load (expected during the k6 demo), a resource leak, or the task's CPU/memory allocation (`infra/modules/ecs-service` `cpu`/`memory` variables, default 256/512) being too small for actual demand.

**Diagnose:**
```bash
aws ecs describe-tasks --cluster devops-g8-tillflow \
  --tasks $(aws ecs list-tasks --cluster devops-g8-tillflow --service-name devops-g8-<service> --query 'taskArns[]' --output text) \
  --query 'tasks[].{cpu:cpu,memory:memory,health:healthStatus}'
```

**Resolve:** if load-driven and expected (k6 demo), no action needed beyond watching it recover once the test stops. If persistent under normal traffic, raise the task's `cpu`/`memory` in Terraform (a genuine, deliberate change — not covered by this runbook alone) or investigate the service for a leak.

**Verify recovery:** CPUUtilization/MemoryUtilization drop back under 80% for 3 consecutive periods; alarm returns to `OK`.

---

## Synthetic probe failure

**Signal:** `devops-g8-synthetic-probe-success-low` (`SuccessPercent` < 90% over 5 min) or `devops-g8-synthetic-probe-failed-runs` (`Failed` >= 1 in 5 min)

**Likely causes:** the external path (API Gateway -> VPC Link -> ALB -> ECS) is down or unreachable end-to-end — this is the same signal a real external user would experience, so treat it as high-priority.

**Diagnose:**
```bash
aws synthetics get-canary-runs --name devops-g8-probe --max-results 5
```
Check the canary's artifact S3 bucket (`infra/modules/synthetic-probe` `canary_artifacts_bucket` output) for the failure screenshot/HAR if the cause isn't obvious from the run status.

**Resolve:** this is usually a downstream symptom of one of the other signals above (unhealthy targets, 5xx, latency) — check those alarms first; they likely already fired.

**Verify recovery:** the next canary run (within 1 minute) succeeds; `SuccessPercent` climbs back above 90%.

---

## Failed deployment / rollback

> **Not yet rehearsed.** This procedure is the planned G4 broken-release drill and has not been run against the live services.

**Signal:** a new task definition revision fails to reach steady state (observed manually via `aws ecs describe-services`, because the ECS deployment circuit breaker is **not** enabled in `infra/modules/ecs-service`), or any of the above alarms fire immediately after a deploy.

**Rollback:**
```bash
# Find the previous known-good task definition revision
aws ecs list-task-definitions --family-prefix devops-g8-<service> --sort DESC --max-items 5

# Point the service back at it
aws ecs update-service --cluster devops-g8-tillflow --service devops-g8-<service> \
  --task-definition devops-g8-<service>:<previous-revision>
```
The durable fix is still through Terraform: revert `image_tags["<service>"]` in `infra/environments/dev/variables.tf` (or its tfvars override) to the previous known-good image tag and re-apply through the normal PR -> plan -> merge -> apply flow, so state doesn't drift from what's actually running. **Caveat:** the GitHub Actions apply path has never executed (see `docs/cicd.md` → Runtime verification status). Until it has, that re-apply is a manual local `terraform apply` with the same variable overrides used for the live deploy.

**Verify recovery:** `aws ecs describe-services` shows `runningCount == desiredCount` on the rolled-back revision; the ALB/ECS alarms that fired return to `OK`; a manual hit of `/health` (or the synthetic canary's next run) succeeds.

---

## How to verify recovery (general)

For any incident: confirm (1) the specific alarm(s) that fired are back to `OK` in CloudWatch (their `ok_actions` post a Slack recovery message automatically), (2) the dashboard's relevant widget shows the metric back under threshold, and (3) a direct request to the affected path succeeds:
```bash
curl -f "https://<api-id>.execute-api.eu-west-3.amazonaws.com/<path>"
```

---

## Incident demo procedure (3-5 minute recording)

A live, reproducible sequence: k6 load -> metric change -> alarm -> dashboard -> explanation -> recovery -> verification.

1. **Baseline (15s):** Show the CloudWatch dashboard (`devops-g8-tillflow-operations`) with all widgets green/quiet, and the alarms list (`aws cloudwatch describe-alarms --alarm-name-prefix devops-g8- --state-value OK` or the console) all `OK`.
2. **Generate load (~ 1-2 min):**
   ```bash
   BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com \
     VUS=300 DURATION=60s \
     k6 run scripts/k6/golden-path-load-test.js
   ```
   Narrate what's being exercised (the real API Gateway -> VPC Link -> ALB -> ECS path) while it runs.
3. **Watch the signal move:** switch to the dashboard's ECS CPU/latency widgets and show the line climbing in near-real time.
   - **If the workload doesn't push CPU/latency over threshold within the recording window** (the likely outcome: see the caveat in the k6 script's header comment, and the ≈ 2% peak CPU in the G3 capacity evidence), fall back to a deliberate, honest trigger instead of waiting indefinitely:
     ```bash
     aws cloudwatch set-alarm-state --alarm-name devops-g8-web-ecs-cpu-high \
       --state-value ALARM --state-reason "Deliberate demo trigger"
     ```
     Say on camera that this is a manual trigger standing in for sustained load, so it's clear the alarm→Slack→dashboard pipeline itself is what's being proven, not a claim that the service was genuinely CPU-bound. This fallback is the realistic path: the G3 k6 runs peaked at ≈ 2% CPU on `/pos/health` (`evidence/reliability/capacity-envelope.md`). Alert firing and recovery through Slack have already been manually exercised once (see [Rehearsal status](#rehearsal-status)).
4. **Show the alert land in Slack** (the `alarm_actions` -> SNS -> Lambda -> Slack path) and point out the dashboard widget corroborating it.
5. **Explain the cause** on camera in one or two sentences (load-driven CPU pressure, or "manually triggered for demo purposes" if you used the fallback).
6. **Recover:**
   - If k6-driven: stop k6 (it already ramps down automatically at the end of `DURATION`); wait for the metric to drop.
   - If manually triggered: `aws cloudwatch set-alarm-state --alarm-name devops-g8-web-ecs-cpu-high --state-value OK --state-reason "Demo recovery"`.
7. **Verify recovery on camera:** show the alarm back to `OK` in the console/Slack, and the dashboard widget back under threshold.

Total: comfortably fits 3-5 minutes if step 2's `DURATION` is kept short (45-60s) and steps 1/4/5/7 stay brief.
