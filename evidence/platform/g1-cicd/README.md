# G1 CI/CD — Evidence

Status: **starter checklist**. Nothing below claims a GitHub Actions run has
succeeded — no workflow in this repository has executed on GitHub as of this
writing. The commands here are reproducible locally; the GitHub Actions run
links/screenshots are explicitly left for a human to add once the workflows
have actually been triggered and observed.

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

- [x] `terraform fmt -recursive -check infra` passes locally
- [x] `terraform validate` passes locally for `infra/bootstrap`
- [x] `terraform validate` passes locally for `infra/environments/dev`
- [x] `.github/workflows/pr-ci.yml` present
- [x] `.github/workflows/terraform.yml` present
- [x] `.github/workflows/build-images.yml` present
- [x] `.terraform.lock.hcl` present for both root Terraform configurations
      and no longer excluded by `.gitignore`
- [x] `gitleaks` run locally with zero findings — see run output below
- [ ] `AWS_TERRAFORM_ROLE_ARN` repository variable configured
- [ ] `AWS_DEPLOY_ROLE_ARN` repository variable configured
- [ ] `production` (or equivalent) GitHub Environment created with required
      reviewers, for `terraform.yml`'s `apply` job
- [ ] First real `pr-ci.yml` run link/screenshot _(human to add)_
- [ ] First real `terraform.yml` plan run link/screenshot _(human to add)_
- [ ] First real `terraform.yml` apply run link/screenshot, post-approval
      _(human to add)_
- [ ] First real `build-images.yml` run link/screenshot, once a service has a
      Dockerfile _(human to add)_

## Known gaps at time of writing

- No service under `services/` has a `Dockerfile` or `package.json` yet —
  `pr-ci.yml`'s `service-ci` job and `build-images.yml` will skip
  Node/Docker/image steps for every service until that changes.
- `AWS_TERRAFORM_ROLE_ARN` / `AWS_DEPLOY_ROLE_ARN` and their IAM roles/OIDC
  trust policies do not exist yet, so `terraform.yml` and `build-images.yml`
  cannot yet authenticate to AWS if triggered.
