# G5 Destroy / Rebuild Reproducibility Evidence

- Date: 2026-09-30 (UTC)
- Environment: `infra/environments/dev`, AWS `eu-west-3`, profile `devops-g8-new`
- Release under test: commit `b9dd7493ae47026753bda5e0677aaccd58b7b958` on all four services
- Raw logs and plans: `~/tillflow-g5-rebuild/` on the operator workstation. They are not committed. Every figure below is copied from those files or from read-only AWS/GitHub queries run during the exercise.

## Result summary

| Step | Result | Time (UTC) |
|---|---|---|
| Full destroy | `0 added, 0 changed, 193 destroyed`. State empty afterwards. | 00:11:25 → 00:19:42 (8m17s) |
| Backend survival | State bucket `devops-g8-terraform-state-a8a9220d` and lock table `devops-g8-terraform-locks` are not in the dev stack (`infra/bootstrap`). Both kept working throughout. | — |
| Cold-start bootstrap (ECR + app S3 buckets) | 16 to create (ECR ×4, S3 ×6, `random_id` ×6). Applied successfully. | ≈ 01:00 |
| Secret import (both restored secrets in one plan) | `2 imported, 0 added, 2 changed, 0 destroyed` | — |
| Phase A (all infrastructure, ECS services disabled) | `171 added, 0 changed, 0 destroyed` | 01:17:11 → 01:27:47 (10m36s) |
| Image rebuild | Build Images run `36644840281` re-run (attempt 2). All 4 jobs succeeded. | pushed 01:33:37–01:33:51 |
| Phase D (enable ECS services) | `4 added, 0 changed, 0 destroyed`. `services-stable` returned. | 01:37:29 → 01:38:36 |
| Final drift check | `terraform plan -detailed-exitcode` gave **exit 0**, "No changes. Your infrastructure matches the configuration." | 01:44:24 |

**Total:** destroy start to all services stable took 1h27m11s (00:11:25Z → 01:38:36Z). That includes the manual bootstrap, the secret recovery and the image rebuild.

## 1. Destroy

- **Pre-destroy inventory:** `terraform state list` returned 219 entries, including data sources (`state-before.txt`). The backend check found no `terraform-state`, `terraform-locks` or `aws_dynamodb_table` entries in the dev state.
- **Emptied before destroy:** ECR images and all object versions in the 8 stack-owned S3 buckets (`buckets.txt`). ECR has no `force_delete` and the buckets have no `force_destroy`.
- **Destroy result** (`destroy.log`): `Apply complete! Resources: 0 added, 0 changed, 193 destroyed.` Afterwards, `terraform state list` was empty.
- **What the destroy removed permanently:**
  - All ECR images.
  - The RDS instance, with no final snapshot (`skip_final_snapshot = true`).
  - The previous API Gateway (`c2po857caj`).

## 2. Cold-start recovery

**Secrets.** Terraform had scheduled the secrets for deletion with the 30-day recovery window.

- `devops-g8-daraja` and `devops-g8-slack-webhook` were **restored** (`restore-secret`), keeping their out-of-band values. Each still has its single original value version.
- `devops-g8-rds-postgres-credentials` is Terraform-generated, so it was force-deleted, and `DescribeSecret` then returned `ResourceNotFoundException`. Phase A recreated it with a new generated password.

**Bootstrap.** With an empty state, configuration evaluation failed on cross-module references. A targeted plan created only `module.ecr.aws_ecr_repository.this` and `module.s3_buckets.aws_s3_bucket.this`, plus their `random_id` suffixes. The plan (`bootstrap.tfplan`) has 16 creates.

**Importing the secrets.** Importing the secrets one at a time with `terraform import` failed with `Invalid index` on `module.app_secrets.secret_arns["daraja"]` or `["slack-webhook"]`. `main.tf` needs both keys at once. The fix:

1. A **temporary** file (`g5_bootstrap_imports.tf`) declared two `import {}` blocks, one per secret ARN (`…devops-g8-daraja-S5on7Z` and `…devops-g8-slack-webhook-9fAN96`).
2. A plan targeted at `module.app_secrets.aws_secretsmanager_secret.this` gave **2 to import, 0 to add, 2 to change, 0 to destroy**. The in-place changes are Terraform-side attributes only (`recovery_window_in_days`, `force_overwrite_replica_secret`), plus the config `tags` map, which matches the `tags_all` values already applied.
3. After apply, both secrets were in state and the temporary file was deleted. No production Terraform code was changed.

## 3. Phase A: infrastructure with `TF_VAR_enable_services=false`

- **Plan** (`g5-phase-a-plan.txt`): `171 to add, 0 to change, 0 to destroy`, 18 no-op. That is 193 minus the 4 ECS services, minus the 18 resources already in state.
- **Checks on the plan:**
  - 0 `aws_ecs_service` creates.
  - 0 destroys or replacements.
  - Both app secrets no-op.
  - All 4 task definitions created from the `b9dd749…` tags.
- **Apply:** `171 added, 0 changed, 0 destroyed`, 01:17:11Z → 01:27:47Z.
- **New endpoints:** API Gateway `https://1ucys9xwdb.execute-api.eu-west-3.amazonaws.com` (was `c2po857caj`), and internal ALB `internal-devops-g8-alb-346381176.eu-west-3.elb.amazonaws.com`.
- **Task definitions registered** (`taskdefs-phase-a.txt`): `devops-g8-web:4`, `devops-g8-pos:5`, `devops-g8-payments:9`, `devops-g8-commission:5`, all on `:b9dd7493ae47026753bda5e0677aaccd58b7b958`.

## 4. Images

- **Before:** all four new ECR repositories had 0 images, and `b9dd749…` returned `ImageNotFoundException`.
- **Deploy role:** `devops-g8-github-deploy-role` was recreated at 01:17:28Z under the same name, so its ARN matches the unchanged `AWS_DEPLOY_ROLE_ARN` repository variable.
- **Rebuild:** `gh run rerun 36644840281` (the original Build Images run for `b9dd749`). Attempt 2 finished `completed success`, and `build (web|pos|payments|commission)` all succeeded.

Resulting images (`ecr-b9dd-images.txt`):

| Repository | Digest | Pushed (UTC) |
|---|---|---|
| devops-g8-web | `sha256:529cf90d3eaeb21ca7d685079a55384b30dd6392eae3f20951586dec819a6be3` | 01:33:37 |
| devops-g8-pos | `sha256:f3dbde6255f8d33e8924fda61c7d61595c1c5aab1faa7966dea72eeff6631433` | 01:33:47 |
| devops-g8-payments | `sha256:3e78317325775da928c70de242668834853f8bf6cacd5e6401518354a0b27cd0` | 01:33:51 |
| devops-g8-commission | `sha256:a9207b35cf122cab3563bbaf0a6e9c1924f5dd8f949f89ae5d60712f4f786b9f` | 01:33:41 |

**The Payments digest differs from the one in [fresh-commit-release.md](fresh-commit-release.md)** (`59076a54…`). The image was rebuilt from the same commit, and container builds aren't bit-for-bit reproducible. The tag is the same, but the digest is new.

## 5. Phase D: `TF_VAR_enable_services=true`

- **Plan** (`g5-phase-d-plan.txt`): `4 to add, 0 to change, 0 to destroy`. The only changes were the creation of `module.ecs_service_{web,pos,payments,commission}.aws_ecs_service.this[0]`.
- **Apply:** `4 added, 0 changed, 0 destroyed`, started 01:37:29Z. `aws ecs wait services-stable` returned at 01:38:36Z.

## 6. Runtime verification

These checks ran read-only between 01:40Z and 01:45Z.

**ECS services** (`verify-services.txt`):

| Service | Desired | Running | Pending | Task definition | Rollout |
|---|---|---|---|---|---|
| devops-g8-web | 1 | 1 | 0 | web:4 | COMPLETED |
| devops-g8-pos | 1 | 1 | 0 | pos:5 | COMPLETED |
| devops-g8-payments | 1 | 1 | 0 | payments:9 | COMPLETED |
| devops-g8-commission | 1 | 1 | 0 | commission:5 | COMPLETED |

**Running tasks** (`verify-tasks.txt`):
- All four are `RUNNING` / `HEALTHY`.
- Each app container image is `devops-g8-<svc>:b9dd7493ae47026753bda5e0677aaccd58b7b958`.
- Each runtime `imageDigest` equals the ECR digest in the table above.

**ALB targets** (`verify-targets.txt`): one `healthy` target in each of `devops-g8-{web,pos,payments,commission}-tg`.

**External requests through API Gateway** (`verify-external.txt`, `https://1ucys9xwdb.execute-api.eu-west-3.amazonaws.com`):

| Path | HTTP | Body |
|---|---|---|
| `/` | 200 | `web: ok` |
| `/health` | 200 | `healthy` |
| `/pos/health` | 200 | `{"service":"pos","status":"ok"}` |
| `/payments/health` | 200 | `payments: ok` |
| `/commission/health` | 200 | `commission: ok` |

`/payments/health` and `/commission/health` reach those services' `/` handlers through the ALB path rules. The container `HEALTHY` status and the ALB target health confirm their `/health` endpoints.

**Synthetic canary** (`verify-canary.txt`): runs at 01:36, 01:37 and 01:38Z `FAILED` with `503 Service Unavailable`, while the services were still starting. Every run from 01:39:02Z to 01:43:02Z `PASSED`.

**Alarms** (`verify-alarms-not-ok.txt`):
- At 01:43Z, 22 of the 24 were `OK`. The 2 synthetic-probe alarms were `ALARM`, raised at 01:20Z, while the canary ran with no services behind it.
- `devops-g8-synthetic-probe-success-low` returned to `OK` at 01:44:05Z.
- `devops-g8-synthetic-probe-failed-runs` was still `ALARM` at 01:44:41Z. That alarm's evaluation window still contained the pre-Phase-D failed runs.
- It then returned to `OK` automatically at 2026-09-30T01:54:37.965Z, and its SNS OK action succeeded at 01:54:38Z. Slack delivery was not verified. See section 8.

## 7. Final drift check

```bash
TF_VAR_enable_services=true TF_VAR_image_tags='{"web":"b9dd749…","pos":"b9dd749…","payments":"b9dd749…","commission":"b9dd749…"}' \
  terraform plan -detailed-exitcode
```

The result, at 01:44:24Z (`final-drift-plan.txt`, `final-drift-exitcode.txt`), was **exit code 0**: "No changes. Your infrastructure matches the configuration."

The Slack Lambda package-hash drift noted in `fresh-commit-release.md` no longer appears after the rebuild.

## 8. Outstanding items and limitations

- **Daraja callback URLs: fixed and verified after Phase D.** After Phase D, `DARAJA_CALLBACK_URL`, `DARAJA_B2C_RESULT_URL` and `DARAJA_B2C_TIMEOUT_URL` in `devops-g8-daraja` still used the destroyed API host `c2po857caj` (`verify-daraja-hosts.txt`). The fix:
  1. A new secret version was written, changing only those three hosts to `1ucys9xwdb`. It is `a4d134f2…` (`AWSCURRENT`), and the previous version `8cda3d08…` is now `AWSPREVIOUS`.
  2. `aws ecs update-service --force-new-deployment` was run on `devops-g8-payments`, and `services-stable` returned at 01:52:11Z.

  Verification at 01:53Z (read-only, `verify2-*.txt`):
  - All three URLs now start with `https://1ucys9xwdb.`. Only the host was checked, and no values were printed.
  - Payments: `desired=1`, `running=1`, `pending=0`, one PRIMARY deployment with rollout `COMPLETED`, task definition `devops-g8-payments:9`.
  - The new task `7e2b5a259b754319b370ad4dc6901e05` started at 01:50:41Z, after the secret update. It is `RUNNING`/`HEALTHY` on `devops-g8-payments:b9dd7493ae47026753bda5e0677aaccd58b7b958`, digest `sha256:3e78317325775da928c70de242668834853f8bf6cacd5e6401518354a0b27cd0`, the same as the ECR image.
  - ALB: new target `10.20.10.235` is `healthy`, and the old target `10.20.10.139` is `draining`.
  - External `GET /payments/health` returned `payments: ok`, **HTTP 200**.
  - A repeat `terraform plan -detailed-exitcode` gave **exit code 0**, "No changes" (01:53:58Z, `final2-drift-plan.txt`). The secret-value change and the forced redeploy caused no Terraform drift.

  A live Daraja callback to the new host has **not** been exercised. The URLs are correct, but end-to-end callback delivery is unproven.
- **`devops-g8-synthetic-probe-failed-runs` recovered to `OK` on its own.** Details:
  - It moved from `ALARM` to `OK` at **2026-09-30T01:54:37.965Z**, and a read-only check at 01:56:42Z confirmed it was still `OK`.
  - The recovery reason was that no datapoint arrived for the evaluation period (1 × 300s `Sum`), and missing data is configured as `notBreaching`. The state reason reads: "no datapoints were received for 1 period and 1 missing datapoint was treated as [NonBreaching]".
  - The last failing `CloudWatchSynthetics` `Failed` five-minute bucket began at 01:36Z (Sum 3). Every canary run from 01:39Z onwards `PASSED`.
  - The OK action to SNS `devops-g8-alerts` succeeded at 01:54:38Z, per the alarm history. Only the SNS action's success is evidenced here: **delivery of the recovery message to Slack was not verified.**
  - `devops-g8-synthetic-probe-success-low` had already returned to `OK` at 01:44:05Z.
- **The rebuild wasn't a single command.** It needed manual cold-start steps:
  - restoring and importing the secrets,
  - a targeted bootstrap, and
  - an image re-run between Phase A and Phase D.

  These are documented above, but not scripted.
- **Configuration that made this manual:**
  - ECR has no `force_delete`.
  - The buckets have no `force_destroy`.
  - The secrets use a 30-day recovery window.
  - `build-images.yml` has no `workflow_dispatch`.
- **No data was carried over.** All application state is in memory. RDS was recreated empty, with no snapshot restore.
