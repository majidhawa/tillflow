# TillFlow Operational Runbook

- Status: Active for G3 alerting. All four services (`web`, `pos`, `payments`, `commission`) are deployed on ECS in `eu-west-3` (one running task each), behind the internal ALB and the public API Gateway. The alarm → SNS → Lambda → Slack path has been exercised end to end, both firing and recovery (see [Rehearsal status](#rehearsal-status)). The G4 broken-release rollback, task-loss and RDS restore procedures below were run live on 2026-09-29 ([evidence/platform/g4-platform-recovery-drills.md](../evidence/platform/g4-platform-recovery-drills.md)). The latency, 5xx and CPU/memory procedures have **not** yet been rehearsed.
- Last reviewed: 2026-09-29 against `main` @ `f022126`. The G4 sections were updated from the 2026-09-29 drill results.
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
| Unhealthy ECS service/tasks: diagnose → recover | **Partially exercised** | ECS task replacement was observed live in the platform-failure drill. The alarm-driven diagnosis path was not exercised. |
| Elevated latency / 5xx / CPU-memory: diagnose → resolve | Not yet rehearsed | — |
| Synthetic probe failure: diagnose | **Partially exercised** | `get-canary-runs` showed PASSED → FAILED → PASSED around the platform-failure drill. The alarm state was not captured. |
| Failed deployment / rollback | **Exercised (G4)**, 2026-09-29 | Real bad-image-reference failure on Payments, rolled back in 2m01s: [G4 platform drills → Drill 1](../evidence/platform/g4-platform-recovery-drills.md#drill-1-broken-release--rollback-payments) |
| Platform failure: ECS task loss | **Exercised (G4)**, 2026-09-29 | Web task stopped. ECS self-healed in 66s, with one failed canary run: [Drill 2](../evidence/platform/g4-platform-recovery-drills.md#drill-2-platform-failure-ecs-task-loss-web). **AZ loss has not been rehearsed.** |
| Backup restore (RDS PITR) | **Exercised (G4), infrastructure only**, 2026-09-29 | PITR into a separate instance and verified. The temporary restore instance was then successfully deleted: [Drill 3](../evidence/platform/g4-platform-recovery-drills.md#drill-3-backup-restore-rds-point-in-time-restore). This does **not** prove application-data integrity, because the services hold state in memory, not in RDS. |
| Payments uncertain-payment and callback-replay drills | Executed locally by Payments (sandbox and unit tests) | [evidence/payments/g4-recovery-drills.md](../evidence/payments/g4-recovery-drills.md). This is not a rehearsal of this runbook. |

Recovery sits under the Reliability + Operations DRI (`docs/ownership.md`). Glory assisted with the G4 drills in coordination with Hawa. Nothing here claims the G4 gate is signed off.

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

**Resolve:** if a bad image caused it, see "Failed deployment / rollback" below. If it's a transient crash, ECS will keep replacing the task automatically — confirm `runningCount` climbs back to `desiredCount`. In the G4 task-loss drill this took 66s (see "Platform failure: ECS task loss" below).

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

> **Exercised in G4 on 2026-09-29** (Payments, real bad-image-reference failure). Evidence: [g4-platform-recovery-drills.md → Drill 1](../evidence/platform/g4-platform-recovery-drills.md#drill-1-broken-release--rollback-payments). The steps below are the ones that worked.

**Signal:** no alarm exists for this. The deployment circuit breaker is **disabled**, and with `minimumHealthyPercent=100` the old task keeps serving, so the ALB, canary and API alarms stay quiet. Detect it by inspecting the service directly:

- a PRIMARY deployment stuck at `rolloutState: IN_PROGRESS`
- `failedTasks` climbing
- service events such as `CannotPullContainerError` or failing health checks

```bash
P="--profile devops-g8-new --region eu-west-3"; C=devops-g8-tillflow; S=devops-g8-<service>

aws ecs describe-services --cluster $C --services $S $P --output json \
  --query 'services[0].{deploymentConfiguration:deploymentConfiguration,deployments:deployments[].{status:status,td:taskDefinition,rollout:rolloutState,running:runningCount,pending:pendingCount,failed:failedTasks}}'
aws ecs describe-services --cluster $C --services $S $P --output text --query 'services[0].events[0:10].[createdAt,message]'
```

Confirm `minimumHealthyPercent` is 100 before you touch anything. That setting is what keeps the old task serving during the rollback.

**1. Identify the failed and known-good versions.**
```bash
aws ecs describe-task-definition --task-definition $S:<failed-rev> $P --query 'taskDefinition.{rev:revision,status:status,images:containerDefinitions[].image}'
aws ecs describe-task-definition --task-definition $S:<good-rev>   $P --query 'taskDefinition.{rev:revision,status:status,deregisteredAt:deregisteredAt,images:containerDefinitions[].image}'
# For a pull failure, confirm the tag is missing and the known-good tag exists
aws ecr describe-images --repository-name $S --image-ids imageTag=<failed-tag> $P   # expect ImageNotFoundException
aws ecr describe-images --repository-name $S --image-ids imageTag=<good-tag> $P
```

**2. Re-register the known-good revision if it is `INACTIVE`.** Terraform deregisters the previous revision whenever it replaces a task definition, so this is the normal case. ECS won't let you `update-service` to an INACTIVE revision. Skip this step only if the known-good revision is still `ACTIVE`.
```bash
E=~/tillflow-evidence-<date>; mkdir -p "$E"     # keep evidence outside the repo
aws ecs describe-task-definition --task-definition $S:<good-rev> --include TAGS $P --output json > "$E/td-good-source.json"
jq '(.taskDefinition | del(.taskDefinitionArn,.revision,.status,.requiresAttributes,.compatibilities,.registeredAt,.registeredBy,.deregisteredAt))
    + (if ((.tags // []) | length) > 0 then {tags: .tags} else {} end)' "$E/td-good-source.json" > "$E/td-rollback-input.json"
diff <(jq -S '.taskDefinition.containerDefinitions' "$E/td-good-source.json") \
     <(jq -S '.containerDefinitions' "$E/td-rollback-input.json") && echo "CONTAINER DEFS IDENTICAL"   # must print this before you continue
aws ecs register-task-definition --cli-input-json "file://$E/td-rollback-input.json" $P --output json \
  --query 'taskDefinition.{arn:taskDefinitionArn,revision:revision,status:status,images:containerDefinitions[].image}'
```

**3. Roll back and wait.**
```bash
date -u +%FT%TZ
aws ecs update-service --cluster $C --service $S --task-definition $S:<new-rev> $P \
  --query 'service.deployments[].{status:status,td:taskDefinition,rollout:rolloutState,running:runningCount}'
aws ecs wait services-stable --cluster $C --services $S $P; date -u +%FT%TZ
```

In the G4 drill, `update-service` to stable took 2m01s.

**Side effect:** replacing the task clears that service's in-memory state. POS, Payments and Commission keep all their state in memory.

**Verify recovery:**
```bash
aws ecs describe-services --cluster $C --services $S $P \
  --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,deployments:deployments[].{status:status,td:taskDefinition,rollout:rolloutState,running:runningCount,failed:failedTasks}}'
TG=$(aws elbv2 describe-target-groups --names $S-tg $P --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn $TG $P --query 'TargetHealthDescriptions[].{ip:Target.Id,state:TargetHealth.State,reason:TargetHealth.Reason}'
API=$(aws apigatewayv2 get-apis $P --query "Items[?Name=='devops-g8-http-api'].ApiEndpoint" --output text)
curl -sS -w '\nHTTP %{http_code}\n' "$API/<service-prefix>/health"
```

- **Service check:** you want a single PRIMARY deployment on the new revision, `COMPLETED`, with `failed=0`.
- **Target health:** the new target should be `healthy`. The old one may still show `draining`.
- **External `curl`:** this only proves routing. Through the ALB, `/payments/health` reaches Payments' `/` handler. The ALB target health, which uses `/health`, is the real health signal.

**Afterwards (not part of the stopgap):**

- **Reconcile Terraform.** The service now runs a revision Terraform doesn't know about, and state still points at the failed revision. The next apply must pass the known-good tag in `image_tags["<service>"]`, or it will redeploy the broken reference.
  - Run `terraform plan` first. The only expected change is that service's task-definition replacement and service update.
  - The GitHub Actions apply path has never executed (see `docs/cicd.md` → Runtime verification status), so this is a manual local apply with the same overrides as the live deploy.
- **Check the tag before you apply.** Before using any commit SHA as an image tag, confirm it exists with `aws ecr describe-images`. Docs-only merges never produce an image. That is exactly what caused the G4 failure.

---

## Platform failure: ECS task loss

> **Exercised in G4 on 2026-09-29** (Web). Evidence: [Drill 2](../evidence/platform/g4-platform-recovery-drills.md#drill-2-platform-failure-ecs-task-loss-web). This covers task loss only. **AZ loss has not been rehearsed.**

**What to expect:** ECS replaces a stopped or crashed task automatically, with no operator action. With `desired_count = 1` there is a short user-visible outage. In the drill, stop to steady state took 66s and the canary recorded one failed run.

**To rehearse it,** use `web`, because it's stateless. Stopping `pos`, `payments` or `commission` clears their in-memory state.
```bash
P="--profile devops-g8-new --region eu-west-3"; C=devops-g8-tillflow; S=devops-g8-web
T=$(aws ecs list-tasks --cluster $C --service-name $S --desired-status RUNNING $P --query 'taskArns[0]' --output text)
date -u +%FT%TZ
aws ecs stop-task --cluster $C --task $T --reason "G4 platform-failure drill" $P --query 'task.{task:taskArn,last:lastStatus,desired:desiredStatus}'
aws ecs wait services-stable --cluster $C --services $S $P; date -u +%FT%TZ
```

**Verify recovery:**
```bash
aws ecs describe-services --cluster $C --services $S $P \
  --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,deployments:deployments[].{status:status,rollout:rolloutState,running:runningCount},events:events[0:6].[createdAt,message]}'
aws synthetics get-canary-runs --name devops-g8-probe --max-results 10 $P --output text --query 'CanaryRuns[].[Timeline.Started,Status.State]'
```

- **Service events:** look for "deregistered 1 targets", then "has started 1 tasks", then "registered 1 targets", then "has reached a steady state".
- **Canary:** it should return to `PASSED` within about a minute of the target registering.
- **Also capture** `aws cloudwatch describe-alarm-history --alarm-name devops-g8-synthetic-probe-failed-runs --history-item-type StateUpdate $P`. The G4 drill did not record it.

---

## Backup restore (RDS point-in-time restore)

> **Exercised in G4 on 2026-09-29**, **infrastructure only**. Evidence: [Drill 3](../evidence/platform/g4-platform-recovery-drills.md#drill-3-backup-restore-rds-point-in-time-restore).
>
> No TillFlow service stores data in RDS today, since all application state is in memory. A successful restore proves that the backups exist and can be restored. It does **not** prove application data survives.

**Always restore into a separate instance.** Never restore over, or modify, `devops-g8-postgres`.

```bash
P="--profile devops-g8-new --region eu-west-3"; SRC=devops-g8-postgres; DST=devops-g8-postgres-restore-drill

aws rds describe-db-instances --db-instance-identifier $SRC $P --output json \
  --query 'DBInstances[0].{status:DBInstanceStatus,version:EngineVersion,class:DBInstanceClass,encrypted:StorageEncrypted,multiAZ:MultiAZ,retention:BackupRetentionPeriod,latestRestorable:LatestRestorableTime,subnetGroup:DBSubnetGroup.DBSubnetGroupName,sgs:VpcSecurityGroups[].VpcSecurityGroupId,public:PubliclyAccessible}'
aws rds describe-db-snapshots --db-instance-identifier $SRC --snapshot-type automated $P --output table \
  --query 'DBSnapshots[].{snapshot:DBSnapshotIdentifier,created:SnapshotCreateTime,encrypted:Encrypted,status:Status}'
aws rds describe-db-instances --db-instance-identifier $DST $P 2>&1 | head -2   # expect DBInstanceNotFound before you start

date -u +%FT%TZ
aws rds restore-db-instance-to-point-in-time $P \
  --source-db-instance-identifier $SRC --target-db-instance-identifier $DST \
  --use-latest-restorable-time --db-subnet-group-name <subnetGroup> --vpc-security-group-ids <sg-id> \
  --db-instance-class <class> --no-publicly-accessible --no-multi-az \
  --query 'DBInstance.{id:DBInstanceIdentifier,status:DBInstanceStatus,class:DBInstanceClass,encrypted:StorageEncrypted}'
aws rds wait db-instance-available --db-instance-identifier $DST $P; date -u +%FT%TZ
```

Take `<subnetGroup>`, `<sg-id>` and `<class>` from the first command's output. In the G4 drill, request to `available` took 32m26s.

**Verify:** the restored instance should match the source on engine version, class, encryption, public access, subnet group and security groups.
```bash
aws rds describe-db-instances --db-instance-identifier $DST $P --output json \
  --query 'DBInstances[0].{status:DBInstanceStatus,version:EngineVersion,class:DBInstanceClass,encrypted:StorageEncrypted,multiAZ:MultiAZ,public:PubliclyAccessible,subnetGroup:DBSubnetGroup.DBSubnetGroupName,sgs:VpcSecurityGroups[].VpcSecurityGroupId}'
```

**Clean up the same day.** This is destructive, so check the identifier before running it. It must be the `-restore-drill` instance, never `devops-g8-postgres`.
```bash
aws rds delete-db-instance --db-instance-identifier $DST --skip-final-snapshot --delete-automated-backups $P \
  --query 'DBInstance.{id:DBInstanceIdentifier,status:DBInstanceStatus}'
aws rds wait db-instance-deleted --db-instance-identifier $DST $P    # confirm completion
```

In the G4 drill, `aws rds wait db-instance-deleted` completed successfully at 2026-09-29T22:56:37Z, confirming deletion of `devops-g8-postgres-restore-drill`.

**Not covered yet:**

- **Data integrity.** Checking a marker row needs a Postgres client inside the VPC, and there's no bastion. That becomes necessary once services actually persist to RDS.
- **RPO/RTO targets.** None have been agreed (ADR-001 only references them).

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
