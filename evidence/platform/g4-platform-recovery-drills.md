# G4: Platform Recovery Drills (Broken Release, Platform Failure, Restore)

- DRI: Hawa (Reliability + Operations, per [docs/ownership.md](../../docs/ownership.md)). Glory assisted with the drills in coordination with Hawa.
- Date: 2026-09-29 (UTC). ECS events and canary timestamps are shown in UTC here. The raw output uses `+03:00`.
- Environment: dev, AWS `eu-west-3`, cluster `devops-g8-tillflow`, AWS CLI profile `devops-g8-new`
- Raw evidence: captured CLI output in `~/tillflow-g4-evidence/` on the operator's workstation (files `00`–`38` below). It is **not committed**. The excerpts below are copied from those files, with the AWS account ID replaced by `<account-id>`.
- Related:
  - [Payments G4 drills](../payments/g4-recovery-drills.md) (uncertain payment, callback replay; owned by Payments + Integrity, unchanged)
  - [Runbook](../../docs/runbook.md)
  - [ADR-003 → Rollback](../../docs/adr/003-delivery-deployment.md)

**Scope:** this file records three drills that ran. It does not claim the G4 gate is signed off.

| Drill | Result | Measured recovery |
|---|---|---|
| 1. Broken release → rollback (Payments) | **PASS**. Real bad-image-reference failure, rolled back to the known-good image. | 2m01s from `update-service` to stable |
| 2. Platform failure: ECS task loss (Web) | **PASS**. ECS replaced the task automatically. | 66s from stop to steady state. 1 failed canary run. |
| 3. Backup restore: RDS PITR | **PASS (infrastructure only)**. Restored to a separate instance and verified. | 32m26s from restore request to `available` |

---

## Drill 1: Broken release → rollback (Payments)

### What actually failed

This was a **real deployment failure caused by a bad image reference**. It was **not** the failure the drill was designed to cause.

**The intended failure.** PR #22 (`g4-drill: deliberately break /health for broken-release rollback drill`) makes Payments `/health` return HTTP 500. Its image was built and pushed as `6603225ace9f8c1791fc5d22c71460c35dca7ec1` (ECR, pushed 2026-09-29T21:15:58Z, `05-ecr-good-tags.json`). **That image was never deployed.** The `/health`-500 failure mode was not exercised.

**What was deployed instead.** Payments task definition **revision 5** referenced `devops-g8-payments:43cc50f60f87e97c6cad4372dd6b0cff64ccf081`. That is the merge commit of PR #23, a docs-only change. The `services/**` path filter in `build-images.yml` means no image is ever built for a docs-only commit.

**ECR confirmed the image does not exist** (`04-ecr-bad-tag.txt`):

```
ImageNotFoundException ... imageTag:'43cc50f60f87e97c6cad4372dd6b0cff64ccf081' does not exist within the repository with name 'devops-g8-payments'
```

### State before rollback

Captured at 2026-09-29T22:05:49Z (`01-before-service.json`):

| Deployment | Task definition | Rollout | Running | Failed |
|---|---|---|---|---|
| PRIMARY | `devops-g8-payments:5` | `IN_PROGRESS` | 0 | **10** |
| ACTIVE | `devops-g8-payments:4` | `COMPLETED` | 1 | 0 |

- **Deployment configuration:** `minimumHealthyPercent: 100`, `maximumPercent: 200`, `deploymentCircuitBreaker.enable: false`, `rollback: false`.
- **Why Payments stayed available:** with `minimumHealthyPercent=100`, ECS never stopped the healthy revision 4 task while revision 5 tasks failed to start.
- **Nothing stopped the retries:** there is no circuit breaker, so ECS would have kept retrying revision 5 indefinitely.

Service events repeated this cycle roughly every 6–7 minutes. The last 10 events are captured, from 21:37:21Z to 22:04:56Z (`02-before-events.txt`):

```
(service devops-g8-payments) has started 1 tasks: (task c39c9561c0cf42aaa8218f10b75ff6cd).
(service devops-g8-payments) was unable to place a task. Reason: CannotPullContainerError: pull image manifest has been retried 7 time(s): failed to resolve ref <account-id>.dkr.ecr.eu-west-3.amazonaws.com/devops-g8-payments:43cc50f60f87e97c6cad4372dd6b0cff64ccf081: ... not found.
```

**Known-good version:** revision 4 used `devops-g8-payments:76288a655d98f357e9fdf18513d0e84d7c258545` (pushed 2026-09-29T10:09:47Z by Build Images run `36553717389`). Revision 4 was **`INACTIVE`**, deregistered at 2026-09-29T21:20:00Z (`06a-rev4.json`). That timestamp is consistent with Terraform replacing the task definition, because `aws_ecs_task_definition` deregisters the previous revision. ECS does not allow a service to be updated to an INACTIVE revision.

### Rollback action

1. **Exported** revision 4 with `describe-task-definition --include TAGS` (`td-rev4-source.json`). Read-only fields were stripped (`taskDefinitionArn`, `revision`, `status`, `requiresAttributes`, `compatibilities`, `registeredAt`, `registeredBy`, `deregisteredAt`). The 6 resource tags were kept (`td-rollback-input.json`).
2. **Verified before registering:**
   - The `containerDefinitions` were **identical** to revision 4 (`diff` of the sorted JSON, no output).
   - `family`, `cpu`, `memory`, `networkMode`, `executionRoleArn`, `taskRoleArn` and `requiresCompatibilities` also matched.
   - These checks were re-run against the saved files when this document was written.
3. **Registered** the definition as **revision 7**, `ACTIVE`. It contains `devops-g8-payments:76288a6…` and `aws-otel-collector:v0.39.0` (`07-register.json`).
4. **Ran** `aws ecs update-service --task-definition devops-g8-payments:7`. Rollback started at **2026-09-29T22:10:12Z** (`08-rollback-start.txt`, `09-update-service.json`).
5. **Waited** with `aws ecs wait services-stable`. The service reached stable at **2026-09-29T22:12:13Z** (`10-stable.txt`).

**Observed rollback time: 2m01s.**

### Restored health result

- **Service** (`11-after-service.json`): `desired=1`, `running=1`, `pending=0`. It has a single PRIMARY deployment, `devops-g8-payments:7`, rollout `COMPLETED`, `failed=0`.
- **ALB target group** `devops-g8-payments-tg` (`14-target-health.json`): the new target `10.20.11.15` was `healthy` while the old revision 4 target `10.20.11.70` was `draining` (`Target.DeregistrationInProgress`). The ALB health check calls `/health`, so this is the real health signal.
- **External** (`15-external.txt`): `GET <api>/payments/health` returned `payments: ok` / **HTTP 200**. This proves the API Gateway → ALB → Payments path. Through the ALB this path reaches Payments' `/` handler, not `/health`, so the ALB target health above is the stronger proof.

### Findings

1. **No deployment alarm or circuit breaker.** The captured revision 5 failure events alone span 27 minutes (21:37Z–22:04Z), and the failure was found by manual inspection. None of the 24 CloudWatch alarms covers failed ECS deployments. The service stayed up, so the ALB, canary and API alarms had nothing to detect. The circuit breaker is disabled (`enable: false`).
2. **The old runbook rollback didn't work as written.** It said to `update-service` to the previous revision. That fails once Terraform has deregistered the previous revision (it is `INACTIVE`). The procedure that worked, re-registering from the known-good revision, is now in [docs/runbook.md](../../docs/runbook.md#failed-deployment--rollback).
3. **Payments state is in memory.** Replacing the revision 4 task with revision 7 cleared every in-memory payment, idempotency record and payout held by Payments.
4. **Image-tag hazard.** The live deploy passes image tags at apply time. Using a `main` commit SHA that never produced an image (a docs-only merge) creates exactly this failure. Nothing checks that a tag exists in ECR before `terraform apply`.
5. **Terraform drift is still open.** The live Payments service runs revision 7. Terraform state still records revision 5 (`43cc50f…`). An apply without the correct Payments `image_tags` value would re-deploy the broken reference. This has **not** been reconciled, and no Terraform was run as part of this drill.
6. **The drill code is still on `main`.** As of this write-up, `services/payments/main.go` on `main` still returns HTTP 500 from `/health` (from PR #22). PR #22 says the change "should never stay in main beyond the drill". Any later `services/**` merge will build an image with the broken `/health`. It needs a revert PR.

---

## Drill 2: Platform failure (ECS task loss, Web)

This drill proves that **ECS replaces a lost task on its own**. It is **not** an Availability Zone loss test: no subnet, NAT or AZ was disrupted. Web was chosen because it holds no in-memory state and the synthetic canary targets it.

**Before** (`20-platform-before.json`): `devops-g8-web` `desired=1`, `running=1`, task definition `devops-g8-web:3`.

**Failure injected:** at 2026-09-29T22:13:42Z, `aws ecs stop-task` was run on task `4958410ac83e4b6caf2593ad6989eb31`. The response was `lastStatus: DEACTIVATING`, `desiredStatus: STOPPED` (`21-…`, `22-platform-stop.json`).

**Self-healing timeline** (ECS service events, `24-platform-after.json`):

| Time (UTC) | Event |
|---|---|
| 22:13:42 | Stop requested (drill start) |
| 22:14:20 | Old target deregistered from `devops-g8-web-tg`. Draining begins. |
| 22:14:21 | ECS started replacement task `d189b2f59d424f19886443156ad71545` |
| 22:14:40 | Replacement target registered in `devops-g8-web-tg` |
| 22:14:48 | Service reached steady state |

**Final state:** `desired=1`, `running=1`, `pending=0`, single PRIMARY deployment with rollout `COMPLETED`. **Stop to steady state took 66s.**

**External signal** (synthetic canary `devops-g8-probe`, one run per minute, `25-platform-canary.txt`):

| Canary run (UTC) | Result |
|---|---|
| 22:13:27 | PASSED (before the stop) |
| 22:14:27 | **FAILED** (during the incident) |
| 22:15:27 | PASSED (after recovery) |

**Findings:**

- **One task per service means a short outage.** With `desired_count = 1`, losing a task is a user-visible outage until the replacement registers. The canary saw one failed run.
- **Alarm and Slack delivery weren't captured.** The alarm state and any Slack notification for this failure were not recorded in the evidence set. This drill makes no claim about either.

---

## Drill 3: Backup restore (RDS point-in-time restore)

**Source instance** `devops-g8-postgres` (`30-rds-source.json`):

- status `available`, PostgreSQL **16.14**, `db.t4g.micro`
- `encrypted: true`, `public: false`, `multiAZ: false`, backup retention **7 days**
- subnet group `devops-g8-postgres-subnet-group`, security group `sg-0705b4ff7fee5ac40`
- latest restorable time **2026-09-29T22:09:30Z**

**Backups:** 8 automated snapshots, all `encrypted: True` and `available`, taken daily at about 10:14Z from 2026-09-22 to 2026-09-29 (`31-rds-snapshots.txt`). A pre-check confirmed that no `devops-g8-postgres-restore-drill` instance existed yet (`32-…`, `DBInstanceNotFound`).

**Restore action:** at 2026-09-29T22:17:07Z, a PITR was requested (`restore-db-instance-to-point-in-time --use-latest-restorable-time`). It restored into a **separate** instance, `devops-g8-postgres-restore-drill`, with the same subnet group, security group and class, not publicly accessible (`33-…`, `34-rds-restore-request.json`). The source instance was not modified.

**Verification:** the restored instance reached `available`, recorded at **2026-09-29T22:49:33Z** (`35-…`). Its attributes (`36-rds-restore-verified.json`):

| Attribute | Source | Restored |
|---|---|---|
| Engine / version | postgres 16.14 | postgres 16.14 |
| Class | db.t4g.micro | db.t4g.micro |
| Encrypted | true | true |
| Publicly accessible | false | false |
| Multi-AZ | false | false |
| Subnet group | devops-g8-postgres-subnet-group | devops-g8-postgres-subnet-group |
| Security groups | sg-0705b4ff7fee5ac40 | sg-0705b4ff7fee5ac40 |

**Restore request to `available`: 32m26s.** This is an upper bound, because it includes the CLI waiter's polling interval.

**Cleanup:** at 2026-09-29T22:51:08Z, after evidence capture, deletion of the temporary instance was requested. The response showed `status: deleting` (`37-…`, `38-rds-cleanup.json`). `aws rds wait db-instance-deleted` then completed successfully at **2026-09-29T22:56:37Z**, confirming that `devops-g8-postgres-restore-drill` was deleted. The source `devops-g8-postgres` was not touched.

### Limitation: infrastructure restorability only

**TillFlow services do not use RDS today.** POS, Payments and Commission hold all application state in memory. This drill therefore proves that:

- the automated backups exist and are encrypted,
- PITR works, and
- a restored instance comes up with the expected engine, encryption and network placement.

It does **not** prove **application-data integrity**:

- No application data was in the database.
- No marker row was written or read back.
- No service was pointed at the restored instance.

For the running application, the real RPO today is **total loss of in-memory state** on any task replacement (Drills 1 and 2 both caused one). The RDS restore does not change that.

Other points:

- The restore instance was created with the AWS CLI outside Terraform, as a temporary drill resource.
- No RPO/RTO targets are defined anywhere in the repo (ADR-001 only says backups "must support the agreed RPO and RTO"). The times above are observations, not results measured against a target.

---

## Evidence not captured

These items were not captured, so this file doesn't rely on them:

- **Stopped-task `stoppedReason` for revision 5 (planned file `03`).** It wasn't saved, so the ECS service events are the record of `CannotPullContainerError`.
- **Running-task details and post-rollback service events (planned `12`, `13`)** weren't saved. `06-td-rev4-rev5.json` is empty; `06a`/`06b` replace it.
- **CloudWatch alarm states and history (planned `16`)** weren't saved for any drill, nor were any Slack notifications.
- **Live image tags for all services (planned `17`)** weren't saved, so Terraform reconciliation (Drill 1, finding 5) has no input recorded.
