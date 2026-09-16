# CI/CD

- Status: Proposed
- Owner: Hawa (Platform + Delivery)
- Related: [docs/adr/003-delivery-deployment.md](adr/003-delivery-deployment.md)

This document explains the GitHub Actions workflows under `.github/workflows/` and what
they assume about repository configuration. It is descriptive of what the workflow
files currently implement — it does not claim any of this has run successfully yet,
since no workflow has executed in GitHub as of this writing.

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
  - if neither file exists (true for all four services today — they are still stubs),
    the job logs a clear skip message and succeeds rather than failing.

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
    cannot, write GitHub repository settings itself. This document does not claim those
    variables are already set — see Limitations below.
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
must set them after `infra/environments/dev` has been applied. This document does not
claim they have been set yet. `AWS_TERRAFORM_PLAN_ROLE_ARN` and `AWS_TERRAFORM_ROLE_ARN`
are deliberately different roles with mutually exclusive OIDC trust — do not point both
variables at the same ARN, as that would defeat the trust split described under OIDC
design above.

## Required protected GitHub environment

`terraform.yml`'s `apply` job targets `environment: production`. For this to actually
gate on human approval, a repo admin must configure a GitHub Environment named
`production` (or rename the workflow's `environment:` value to match one already in
use, e.g. `infrastructure`) with **required reviewers** turned on. Until that
environment exists and has protection rules configured, the `environment:` key has no
gating effect — see Limitations.

## Image tagging

Every image built by `build-images.yml` is tagged with the immutable Git commit SHA
(`${{ github.sha }}`) only. No workflow in this repository tags or pushes `:latest`.

## SBOM and image scanning

- **SBOM**: generated with `anchore/sbom-action` (Syft), SPDX JSON format, uploaded as
  a workflow artifact per service/commit (90-day retention).
- **Scanning**: `aquasecurity/trivy-action` is used for three distinct scans:
  - IaC config scan of `infra/` (PR CI)
  - filesystem dependency scan of a service directory, when a manifest exists (PR CI)
  - built container image scan, before push (build-images)

  All three fail the job on HIGH/CRITICAL findings — none of them are configured to
  suppress or ignore failures.

## Current limitations

- **No application services exist yet.** `services/web`, `services/pos`,
  `services/payments`, `services/commission` currently contain only `.gitkeep`. Every
  workflow degrades safely for this (clear skip logs, job still succeeds) rather than
  failing, but none of the Node lint/typecheck/test, Docker build, or image
  build/push/scan logic has actually executed against real code yet.
- **The IAM roles exist in Terraform config but have not necessarily been applied, and
  the GitHub repository variables have not necessarily been set.** The roles
  (`devops-g8-github-terraform-plan-role`, `devops-g8-github-terraform-role`,
  `devops-g8-github-deploy-role`) are defined in `infra/modules/github-oidc-roles`;
  until `terraform apply` has actually run for `infra/environments/dev` **and** a repo
  admin has copied the resulting `github_terraform_plan_role_arn` /
  `github_terraform_role_arn` / `github_deploy_role_arn` outputs into the
  `AWS_TERRAFORM_PLAN_ROLE_ARN` / `AWS_TERRAFORM_ROLE_ARN` / `AWS_DEPLOY_ROLE_ARN`
  repository variables, all three workflow jobs will fail at the "Configure AWS
  credentials" step if triggered. This document does not claim any of those steps has
  happened.
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
- **The `production` GitHub Environment does not exist yet** (or hasn't been verified
  to exist) with required-reviewer protection turned on. Until a repo admin configures
  it, `terraform.yml`'s `apply` job's `environment: production` has no enforcement
  effect — the job would run unattended on every push to `main` that touches `infra/`.
- **No GitHub branch protection rule has been confirmed to require any of these
  workflows as passing/required status checks.** This document describes what the
  workflows conceptually should gate merges on (secret scan, Terraform validate/plan,
  IaC scan, service CI) — it does **not** claim branch protection on `main` currently
  enforces any of them. That is a separate, manual repository-settings step, and
  whether the current GitHub plan/tier for this repo supports the desired required-checks
  configuration has not been confirmed.
- **Action versions are pinned to major/minor tags** (e.g. `@v4`, `@0.24.0`), not
  commit SHAs. This is the common baseline, not the strongest possible supply-chain
  posture — pinning to full commit SHAs would be a reasonable later hardening step.
- **No workflow run has ever executed in GitHub for any of these files.** Everything
  above describes intended behavior verified only via local `terraform fmt`/`validate`
  and manual review of the YAML — see `evidence/platform/g1-cicd/README.md` for what
  has and hasn't been verified.
