# CI/CD

- Status: Implemented. PR CI and image build/push are verified on GitHub. Terraform
  plan is verified once. Terraform apply via GitHub Actions and the CodePipeline deploy
  stage are **not** verified (see [Runtime verification status](#runtime-verification-status)).
- Owner: Hawa (Platform + Delivery)
- Related: [docs/adr/003-delivery-deployment.md](adr/003-delivery-deployment.md),
  [evidence/platform/g1-cicd/README.md](../evidence/platform/g1-cicd/README.md)
- Last audited: 2026-09-29 against `main` @ `f022126`

This document explains the GitHub Actions workflows under `.github/workflows/` and what
they assume about repository configuration. The design sections below describe what the
workflow files implement. What has actually run on GitHub is recorded separately under
[Runtime verification status](#runtime-verification-status), with run IDs, so the two
are never confused.

## Runtime verification status

Source: GitHub Actions run history for `majidhawa/tillflow` (`gh run list`), plus
repository settings read through the GitHub API, audited 2026-09-29. Run URLs have the
form `https://github.com/majidhawa/tillflow/actions/runs/<id>`.

| Capability | Implemented | Runtime-verified | Evidence |
|---|---|---|---|
| PR CI: change detection + gitleaks secret scan | Yes | **Yes** | e.g. run `36622649837` (PR #21) |
| PR CI: `terraform fmt`/`validate` + Trivy IaC scan | Yes | **Yes** | run `36614714721` (PR #21): `terraform-checks` and `iac-scan` succeeded |
| PR CI: `service-ci` (Docker build validation) | Yes | **Yes** | run `36553574148` (PR #18): `service-ci (payments)` succeeded |
| PR CI: Go unit tests / Go dependency scan | **No** | No | `service-ci` only runs `npm` scripts and the Trivy fs scan when a `package.json` exists. All four services are Go, so `go test` (`services/pos/handlers_test.go`, `services/payments/callback_test.go`) is **not** run in CI. |
| Build Images: OIDC → ECR login → build → Trivy image scan → SBOM → push (all 4 services) | Yes | **Yes** | run `36553717389` (push to `main`, commit `76288a6`): all four `build` jobs succeeded, including `Push image to ECR`. Earlier runs `36551295953`, `36504192900`, `36485683623`, `36483688030`, `36475766522` failed. Runs after those fixes passed. |
| Terraform PR plan via read-only OIDC plan role | Yes | **Once** | run `36470667717` (PR #6): `plan` succeeded. Every earlier PR plan run failed (OIDC trust debugging, 15–28 Sep). Every later one was cancelled while queued (see next row). |
| Terraform apply via GitHub Actions (`production` env, apply role) | Yes | **No** | No apply job has ever executed. Run `36471319002` (merge of PR #5, 28 Sep) is still `waiting` for `production` approval. Because `concurrency: terraform-infra-dev` has `cancel-in-progress: false`, later Terraform runs queued behind it and were cancelled before starting (e.g. `36614714639`, `36504148093`). Run `36615323260` is currently `pending`. |
| `production` GitHub Environment with required reviewers | Yes | **Yes (configured)** | Environment `production` has `required_reviewers` and `branch_policy` protection rules. Run `36471319002`'s pending deployment is waiting on its reviewer. |
| Repository variables for the three OIDC roles | Yes | **Yes (set)** | `AWS_TERRAFORM_PLAN_ROLE_ARN`, `AWS_TERRAFORM_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN` are set to the three distinct `devops-g8-github-*` roles. Successful OIDC auth in runs `36470667717` (plan role) and `36553717389` (deploy role) shows those roles exist in AWS. |
| Branch protection on `main` | Partial | **Yes (configured)** | 1 approving review required, stale reviews dismissed, last-push approval required, enforced for admins. **No required status checks** are configured, so a red CI run does not block merge on its own. |
| ECS deploy / smoke stage (CodePipeline/CodeBuild per ADR-003) | **No** | No | There is no CodePipeline, CodeBuild or ECS-deploy workflow in this repo. |

**How the live environment was actually deployed:** the ECS services and the rest of
`infra/environments/dev` were applied **manually** by the Platform DRI with local
Terraform, not by the `terraform.yml` apply job. Images were pushed by
`build-images.yml`. All four services are running on ECS. The live G2/G3 evidence
([evidence/payments/g2-live-money-path.md](../evidence/payments/g2-live-money-path.md),
[evidence/reliability/g3-grafana-slo-runtime.md](../evidence/reliability/g3-grafana-slo-runtime.md))
depends on that. The manual apply proves that the Terraform code converges and that the
platform works. It is **not** proof that the GitHub Actions apply path or a pipeline
deploy stage works. The committed defaults in `infra/environments/dev/variables.tf` are
still `enable_services = false` and `image_tags = "pending"`, so the live service
configuration depends on values passed at apply time that are not in the repo.

## PR CI lane (`.github/workflows/pr-ci.yml`)

Triggers on every pull request targeting `main`. Requires no AWS credentials at all —
everything in this lane is static analysis or local build validation.

Jobs:

- **detect-changes** — computes which of `infra/`, `services/web/`, `services/pos/`,
  `services/payments/`, `services/commission/` changed (via `dorny/paths-filter`), and
  builds a JSON list of affected services for the `service-ci` matrix. A change under
  `services/_shared/` is treated as affecting all four services, since it holds shared
  contracts, the M-Pesa adapter interface, and OTel setup.
- **secret-scan** — runs `gitleaks` over the full repository history on every PR,
  regardless of changed paths (secrets can land anywhere).
- **terraform-checks** — only runs if `infra/**` changed. Runs `terraform fmt -check`,
  then `terraform init -backend=false` + `terraform validate` for both
  `infra/bootstrap` and `infra/environments/dev`. `-backend=false` is used deliberately
  so this lane never needs AWS credentials or state access.
- **iac-scan** — only runs if `infra/**` changed. Runs a Trivy IaC config scan
  (`scan-type: config`) over `infra/`. Purely static analysis, no AWS access.
- **service-ci** — matrix over the affected services from `detect-changes`. For each:
  - if `services/<name>/package.json` exists: installs dependencies, then runs
    `npm run lint --if-present`, `npm run typecheck --if-present`, `npm run test
    --if-present`. A script that doesn't exist is a silent no-op; a script that exists
    and fails still fails the job — this lane never invents scripts and never
    suppresses a real failure.
  - if `services/<name>/package.json` exists: runs a Trivy filesystem scan for
    dependency vulnerabilities.
  - if `services/<name>/Dockerfile` exists: runs `docker build` to validate the image
    builds (no push).
  - if neither file exists, the job logs a clear skip message and succeeds rather than
    failing.
  - **Current effect:** all four services are Go (`go.mod`, no `package.json`), so for
    every service only the Docker build validation runs. There is no `go vet`/`go test`
    step and no Trivy filesystem scan of Go dependencies in this lane. Go dependency
    vulnerabilities are caught later, by the Trivy **image** scan in `build-images.yml`.

## Terraform PR-plan / main-apply lane (`.github/workflows/terraform.yml`)

Two jobs, gated by event type, sharing one `concurrency` group (`terraform-infra-dev`)
so a plan and an apply against the same remote state can never run at the same time,
and two pushes to `main` queue instead of racing.

- **plan** — runs on `pull_request` to `main` when `infra/**` changed. Authenticates to
  AWS via OIDC as a **separate, read-only role** (see below), then runs `fmt -check`,
  `init`, `validate`, and `plan` against the real S3/DynamoDB backend (so the plan
  reflects real remote state), using `working-directory: infra/environments/dev`
  consistently for every Terraform command. Never runs `apply`, and cannot — the role it
  assumes has no infrastructure mutation permissions at all.
- **apply** — runs only on `push` to `main` when `infra/**` changed. Targets the
  `production` GitHub Environment (see below), authenticates via OIDC as the
  **apply-only role** (different from the plan role above), then runs `init`,
  `validate`, `plan -out=tfplan`, `apply tfplan`.

The `plan` job reads its role from **`AWS_TERRAFORM_PLAN_ROLE_ARN`**; the `apply` job
reads its role from **`AWS_TERRAFORM_ROLE_ARN`** — two distinct repository variables,
pointing at two distinct IAM roles, never a hardcoded ARN or account ID. This split
exists specifically so that **a pull request can never assume the apply-capable role**:
the two roles' OIDC trust policies accept mutually exclusive subjects (see OIDC design
below), so even if a PR workflow tried to reference `AWS_TERRAFORM_ROLE_ARN`, AWS would
reject the `AssumeRoleWithWebIdentity` call — the trust policy only recognizes the
`environment:production` subject, which GitHub does not issue for a `pull_request` job.

`infra/environments/dev/backend.tf` (S3 state bucket + DynamoDB lock table) is
unchanged by this work — this workflow only runs `terraform init` against that
existing backend, it does not define or alter it.

## Container build lane (`.github/workflows/build-images.yml`)

Runs on `push` to `main` when `services/**` (or the workflow file itself) changes.
Matrix over `web`, `pos`, `payments`, `commission`. For each service:

1. Skip immediately (clear log message, job still succeeds) if
   `services/<name>/Dockerfile` doesn't exist yet.
2. Authenticate to AWS via OIDC, using the **repository variable**
   `AWS_DEPLOY_ROLE_ARN`.
3. Log in to the corresponding `devops-g8-<name>` ECR repository.
4. Build the image, tagged **only** with the Git commit SHA (`${{ github.sha }}`) —
   `:latest` is never used.
5. Scan the built image with Trivy (HIGH/CRITICAL fails the job) **before** pushing —
   a failing scan means the push step never runs.
6. Generate an SPDX SBOM with Syft and upload it as a workflow artifact.
7. Push the image to ECR.

This lane stops at "image pushed to ECR." Per
[ADR-003](adr/003-delivery-deployment.md), ECS deployment and smoke verification are
owned by the separate CodePipeline/CodeBuild deployment stage, not by GitHub Actions.
**That stage is not implemented yet** (see Current limitations).

## OIDC design

All AWS authentication in these workflows uses `aws-actions/configure-aws-credentials`
with `role-to-assume` pointed at a repository variable — never `aws-access-key-id` /
`aws-secret-access-key` secrets. No long-lived AWS credentials are stored in GitHub.

- `permissions: id-token: write` is granted only on the specific jobs that call
  `configure-aws-credentials` (the `plan`/`apply` jobs in `terraform.yml`, the `build`
  job in `build-images.yml`). Every other job, and the workflow-level default, is
  `contents: read` only.
- The PR CI lane (`pr-ci.yml`) requests no AWS permissions at all — it cannot assume
  any role, by design.
- There are **three** IAM roles, all **Terraform-managed**, defined in
  [`infra/modules/github-oidc-roles`](../infra/modules/github-oidc-roles) and wired into
  `infra/environments/dev/main.tf`. The module discovers the account ID and the
  existing GitHub OIDC provider (`token.actions.githubusercontent.com`) via data
  sources — it does not create the OIDC provider itself and does not hardcode an
  account ID or provider ARN anywhere. Trust is scoped to this repository only
  (`majidhawa/tillflow`), and **each role trusts exactly one OIDC subject**:
  - `devops-g8-github-terraform-plan-role` (`AWS_TERRAFORM_PLAN_ROLE_ARN`) trusts only
    the `pull_request` subject. Used solely by `terraform.yml`'s `plan` job. Its
    permissions are **read-only against AWS** (Describe/List/Get actions only — see
    Limitations for the one narrow exception, DynamoDB state-lock `PutItem`/`DeleteItem`).
    It has no `iam:PassRole`, no IAM mutation actions, no `secretsmanager:GetSecretValue`
    or `PutSecretValue`, and no Terraform state `PutObject`/`DeleteObject`.
  - `devops-g8-github-terraform-role` (`AWS_TERRAFORM_ROLE_ARN`) trusts only the
    `environment:production` subject. Used solely by `terraform.yml`'s `apply` job,
    which targets the `production` GitHub Environment. It holds the scoped
    create/update/delete permissions needed to actually apply changes (see
    `infra/modules/github-oidc-roles/main.tf` for the full policy). **A pull_request
    can never assume this role** — GitHub only issues the `environment:production`
    subject for a job that targets that GitHub Environment, and `plan` does not.
  - `devops-g8-github-deploy-role` (`AWS_DEPLOY_ROLE_ARN`) trusts only the
    `ref:refs/heads/main` subject, matching `build-images.yml`, which runs solely on
    pushes to `main`.

  No role grants any other repository, branch, or environment access.
  - The dev environment exposes these as Terraform outputs —
    `github_terraform_plan_role_arn`, `github_terraform_role_arn`, and
    `github_deploy_role_arn`. **The GitHub repository variables themselves
    (`AWS_TERRAFORM_PLAN_ROLE_ARN`, `AWS_TERRAFORM_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`)
    still have to be populated by hand** from those outputs (`terraform output
    github_terraform_plan_role_arn` / `github_terraform_role_arn` /
    `github_deploy_role_arn` in `infra/environments/dev`) — Terraform does not, and
    cannot, write GitHub repository settings itself. As of the 2026-09-29 audit all three
    variables **are set** to three distinct role ARNs (see
    [Runtime verification status](#runtime-verification-status)).
  - No long-lived AWS credentials (access key/secret) are used anywhere in this setup;
    all three roles are reachable only via short-lived STS tokens issued through the
    OIDC exchange.

## Required GitHub repository variables

Configured under Settings → Secrets and variables → Actions → Variables (these are
plain repository **variables**, not secrets — the ARNs themselves aren't sensitive):

| Variable                       | Used by                | Purpose                                          | Source of value |
| ------------------------------- | ----------------------- | -------------------------------------------------- | ---------------- |
| `AWS_TERRAFORM_PLAN_ROLE_ARN`   | `terraform.yml` (`plan`) | Read-only role assumed via OIDC for PR `plan` only  | `terraform output github_terraform_plan_role_arn` (`infra/environments/dev`) |
| `AWS_TERRAFORM_ROLE_ARN`        | `terraform.yml` (`apply`) | Apply-only role assumed via OIDC for main `apply`  | `terraform output github_terraform_role_arn` (`infra/environments/dev`) |
| `AWS_DEPLOY_ROLE_ARN`           | `build-images.yml`      | Role assumed via OIDC for ECR login/push            | `terraform output github_deploy_role_arn` (`infra/environments/dev`) |

These values come from Terraform outputs, not from a hand-written ARN — a repo admin
must set them after `infra/environments/dev` has been applied. They are set as of the
2026-09-29 audit. `AWS_TERRAFORM_PLAN_ROLE_ARN` and `AWS_TERRAFORM_ROLE_ARN`
are deliberately different roles with mutually exclusive OIDC trust — do not point both
variables at the same ARN, as that would defeat the trust split described under OIDC
design above.

## Required protected GitHub environment

`terraform.yml`'s `apply` job targets `environment: production`. For this to actually
gate on human approval, a repo admin must configure a GitHub Environment named
`production` (or rename the workflow's `environment:` value to match one already in
use, e.g. `infrastructure`) with **required reviewers** turned on. Until that
environment exists and has protection rules configured, the `environment:` key has no
gating effect. As of the 2026-09-29 audit, `production` **exists** with
`required_reviewers` and `branch_policy` rules, and it is actively holding apply run
`36471319002` for approval.

## Image tagging

Every image built by `build-images.yml` is tagged with the immutable Git commit SHA
(`${{ github.sha }}`) only. No workflow in this repository tags or pushes `:latest`.

## SBOM and image scanning

- **SBOM**: generated with `anchore/sbom-action` (Syft), SPDX JSON format, uploaded as
  a workflow artifact per service/commit (90-day retention).
- **Scanning**: `aquasecurity/trivy-action` is used for three distinct scans:
  - IaC config scan of `infra/` (PR CI)
  - filesystem dependency scan of a service directory, when a `package.json` exists
    (PR CI; currently never runs, because all services are Go)
  - built container image scan, before push (build-images)

  All three fail the job on HIGH/CRITICAL findings — none of them are configured to
  suppress or ignore failures.

## Current limitations

- **The Terraform apply path through GitHub Actions has never executed.** Apply run
  `36471319002` has waited for `production` approval since 2026-09-28. Because the
  workflow uses one `concurrency` group with `cancel-in-progress: false`, every later
  Terraform run (PR plans included) queued behind it and was cancelled before starting.
  Until that run is approved or cancelled, no new plan or apply can run through Actions.
  All live infrastructure changes so far were applied manually with local Terraform.
- **No deployment stage exists.** ADR-003 assigns ECS deployment and smoke verification
  to CodePipeline/CodeBuild. Neither exists in this repository. `build-images.yml`
  stops at "image pushed to ECR", and running services pick up a new image only through
  a Terraform apply of `image_tags`.
- **Go services get no unit tests or dependency scan in PR CI.** See the `service-ci`
  note above. The Trivy image scan in `build-images.yml` runs only after merge to `main`.
- **No required status checks on `main`.** Branch protection requires one approving
  review (enforced for admins) but no passing checks, so a failing CI run does not block
  merge on its own. Earlier failed `PR CI` runs (e.g. `36505286869`, `36504572523`) were
  followed by passing runs before merge, but that is reviewer discipline, not enforcement.
- **A temporary OIDC diagnostic step is still in `terraform.yml`'s `plan` job.** It
  prints non-secret token claims only (never the raw JWT). It was added to debug the
  plan-role trust policy and should be removed now that the plan role has authenticated
  successfully (run `36470667717`).
- **The PR plan role's `terraform plan` will fail to refresh one specific resource.**
  `devops-g8-github-terraform-plan-role` intentionally has no
  `secretsmanager:GetSecretValue` (it is read-only against secret *values*, not just
  metadata). Terraform needs `GetSecretValue` to refresh
  `aws_secretsmanager_secret_version.db` (`infra/modules/rds-postgres`) and detect drift
  on the stored RDS credentials. Under the plan role, that one resource's refresh will
  return `AccessDenied`. This is an accepted trade-off of keeping the plan role
  read-only against secret contents, not an oversight — see
  `infra/modules/github-oidc-roles/main.tf`'s `SecretsManagerMetadataOnly` statement.
- **The PR plan role holds one narrow write permission: DynamoDB state-lock
  `PutItem`/`DeleteItem`.** Terraform's S3 backend takes a state lock for `plan` the
  same way it does for `apply` (acquired via `PutItem` against the lock table,
  released via `DeleteItem`); without it, `plan` cannot acquire the lock and fails
  outright. This writes only a transient lock record keyed by the state path — never
  infrastructure, never state content — and is scoped to the one lock table
  (`devops-g8-terraform-locks`) only. It is documented here because it is the sole
  exception to the plan role otherwise being pure Describe/List/Get.
- **Action pinning is mixed.** Only `aquasecurity/trivy-action` is pinned to a commit
  SHA (v0.35.0). Every other action (`actions/checkout@v4`, `actions/setup-node@v4`,
  `actions/upload-artifact@v4`, `aws-actions/configure-aws-credentials@v4`,
  `aws-actions/amazon-ecr-login@v2`, `hashicorp/setup-terraform@v3`,
  `anchore/sbom-action@v0`, `dorny/paths-filter@v3`, `gitleaks/gitleaks-action@v2`) uses a
  tag. Pinning all of them to SHAs is a reasonable later hardening step.
