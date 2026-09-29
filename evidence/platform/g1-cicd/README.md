# G1 CI/CD — Evidence

Status: **partially proven**, audited 2026-09-29 against `main` @ `f022126`.
PR CI and image build/push have run successfully on GitHub. Terraform PR plan
has succeeded once. **Terraform apply through GitHub Actions and any
CodePipeline deploy stage are not proven.** Run IDs below come from the
repository's GitHub Actions history
(`https://github.com/majidhawa/tillflow/actions/runs/<id>`). No screenshots
are committed here.

See [docs/cicd.md](../../../docs/cicd.md) for the full design.

## Local reproduction commands

Run from the repository root unless noted otherwise.

### Terraform formatting

```bash
terraform fmt -recursive -check infra
```

Expected: no output, exit code 0.

### Terraform validate

```bash
cd infra/bootstrap
terraform init -backend=false -input=false
terraform validate

cd ../environments/dev
terraform init -backend=false -input=false
terraform validate
```

Expected: `Success! The configuration is valid.` for both.

### Secret scan (gitleaks)

Requires `gitleaks` installed locally (`brew install gitleaks` or see
https://github.com/gitleaks/gitleaks#installing).

```bash
gitleaks detect --source . --no-git -v
```

Run with `--no-git` for a working-tree scan, or omit it to scan full history
(`gitleaks detect --source . -v`) — the latter is closer to what
`gitleaks/gitleaks-action` runs in `pr-ci.yml` (`fetch-depth: 0`).

**Actual local run** (working tree, `gitleaks` v8, 2026-09-15):

```
1:17AM INF scanned ~215123 bytes (215.12 KB) in 637ms
1:17AM INF no leaks found
```

This is a working-tree scan only (`--no-git`), run locally outside GitHub
Actions — it is not a substitute for the `pr-ci.yml` `secret-scan` job
actually running in GitHub, which additionally scans full git history.

### Workflow files present

```bash
ls -la .github/workflows/
```

Expected: `pr-ci.yml`, `terraform.yml`, `build-images.yml` present (alongside
the pre-existing `.gitkeep`).

### Terraform provider lockfiles present

```bash
find infra -name ".terraform.lock.hcl"
```

Expected: one file under `infra/bootstrap/` and one under
`infra/environments/dev/`, both tracked in git (confirm with
`git check-ignore -v infra/bootstrap/.terraform.lock.hcl` — should report
"not ignored").

## Checklist

### Proven locally / in code

- [x] `terraform fmt -recursive -check infra` passes locally
- [x] `terraform validate` passes locally for `infra/bootstrap`
- [x] `terraform validate` passes locally for `infra/environments/dev`
- [x] `.github/workflows/pr-ci.yml`, `terraform.yml`, `build-images.yml` present
- [x] `.terraform.lock.hcl` present for both root Terraform configurations
      and no longer excluded by `.gitignore`
- [x] `gitleaks` run locally with zero findings (working tree only; see run
      output above)
- [x] Three GitHub OIDC IAM roles defined in Terraform
      (`infra/modules/github-oidc-roles`), trust scoped to `majidhawa/tillflow`
- [x] Terraform plan/apply roles split with mutually exclusive trust: the plan role
      trusts only `pull_request` and is read-only against AWS; the apply role trusts
      only `environment:production`
- [x] All four services have a `Dockerfile` (multi-stage Go build, non-root
      `USER 1000:1000`) and Go sources; ECR repos are `IMMUTABLE` with
      scan-on-push (`infra/modules/ecr`)

### Proven on GitHub / AWS

- [x] OIDC roles exist in AWS. Evidence: the plan role authenticated in run
      `36470667717` and the deploy role in run `36553717389`. The roles were
      applied by a **manual** local `terraform apply`, not by `terraform.yml`.
- [x] `AWS_TERRAFORM_PLAN_ROLE_ARN`, `AWS_TERRAFORM_ROLE_ARN`,
      `AWS_DEPLOY_ROLE_ARN` repository variables set, each pointing at a
      distinct `devops-g8-github-*` role (read via `gh variable list`)
- [x] `production` GitHub Environment exists with `required_reviewers` and
      `branch_policy` protection rules (read via the GitHub environments API).
      Run `36471319002`'s apply job is currently held on it for approval.
- [x] `pr-ci.yml` succeeded on GitHub:
      - `detect-changes` + `secret-scan`: run `36622649837` (PR #21)
      - `terraform-checks` + `iac-scan`: run `36614714721` (PR #21)
      - `service-ci (payments)` Docker build validation: run `36553574148` (PR #18)
- [x] `terraform.yml` **plan** succeeded once: run `36470667717` (PR #6)
- [x] `build-images.yml` succeeded for all four services, including OIDC, ECR
      login, build, Trivy image scan, SBOM upload and **push to ECR**: run
      `36553717389` (push to `main`, commit `76288a6`)
- [x] Branch protection on `main`: 1 approving review, stale-review dismissal,
      last-push approval, enforced for admins

### Not proven (still open)

- [ ] **`terraform.yml` apply run.** No apply job has ever executed. Run
      `36471319002` (28 Sep) is still `waiting` for `production` approval, and
      later Terraform runs were cancelled while queued behind it (`concurrency:
      terraform-infra-dev`, `cancel-in-progress: false`). *Missing evidence:* an
      approved apply run with its plan output and a successful `apply` step.
      The live environment was applied manually, which proves the Terraform
      converges but is not evidence for this item.
- [ ] **A second, current `terraform.yml` PR plan.** The only successful plan
      (`36470667717`) predates the G2/G3 infra changes. *Missing evidence:* a plan
      run on a current infra PR, which needs the stuck apply run resolved first.
- [ ] **ECS deployment + smoke stage (CodePipeline/CodeBuild per ADR-003).** Not
      implemented in the repo. *Missing evidence:* pipeline definition, an
      execution ID, deploy logs and a smoke result.
- [ ] **Required status checks on `main`.** Branch protection has no required
      checks, so CI is not merge-blocking. *Missing evidence:* the protection
      config listing `secret-scan`, `terraform-checks`, `iac-scan`, `service-ci`.
- [ ] **Go unit tests in CI.** `service-ci` only runs `npm` scripts, so
      `services/pos/handlers_test.go` and `services/payments/callback_test.go`
      are not executed on GitHub. *Missing evidence:* a CI step running
      `go test ./...` per service, and a passing run.
- [ ] **Screenshots / exported logs of the runs above.** None are committed.
      The run IDs are the evidence pointer.

## Known gaps at time of writing (2026-09-29)

- The Terraform GitHub Actions lane is blocked by the waiting apply run
  `36471319002` (see above). The committed defaults in
  `infra/environments/dev/variables.tf` still say `enable_services = false` and
  `image_tags = "pending"`, so the live deploy relied on apply-time overrides that
  are not recorded in the repo.
- `terraform.yml` still contains the **TEMPORARY OIDC diagnostic** step in the
  `plan` job. It prints non-secret claims only, and should be removed now that
  plan-role authentication has succeeded.
- The PR plan role (`devops-g8-github-terraform-plan-role`) cannot refresh
  `aws_secretsmanager_secret_version.db` (no `secretsmanager:GetSecretValue`
  by design). A PR touching `infra/` may show an error for that one
  resource during `terraform plan`. See `docs/cicd.md` Limitations.
- Several `build-images.yml` runs on `main` failed before later fixes
  (`36551295953`, `36504192900`, `36485683623`, `36483688030`, `36475766522`).
  Only the successful run above is claimed as evidence.
