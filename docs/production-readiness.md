# Production Readiness Checklist

Status as of 2026-09-30, audited against `main`. A quick-scan checklist
across the system — for full detail and evidence links, see
`evidence/platform/g0-g3-closure.md` and each area's own evidence files.
Nothing here is marked Ready unless a linked file proves it.

Legend: Ready / Partial / Not ready

## Deployment

| Item | Status | Notes |
|---|---|---|
| Terraform manages all infra | Ready | `infra/` — network, ECS, RDS, Redis, SQS, S3, secrets, OIDC, observability |
| Live deploy on ECS | Ready | All four services running, applied manually (not yet via GitHub Actions) |
| Immutable image tags (no `latest`) | Ready | Git SHA tags, enforced in `build-images.yml` |
| GitHub Actions Terraform apply | Not ready | Apply has never run via Actions; all applies so far are manual/local |
| CodePipeline/CodeBuild deploy stage | Not ready | Not built (planned in ADR-003) |
| Required status checks on `main` | Not ready | Branch protection requires review, not passing CI checks |

## Testing and CI

| Item | Status | Notes |
|---|---|---|
| Docker build validation in CI | Ready | Runs on every PR |
| Secret/dependency/IaC scanning | Ready | Gitleaks, Trivy (image + IaC) |
| Go unit tests running in CI | Not ready | `pr-ci.yml` is Node-oriented; Go tests never execute in CI (see scar log) |
| Contract tests (sale/payment) | Partial | Covered via unit tests + live sandbox runs, not automated in CI |

## Product / Money Path

| Item | Status | Notes |
|---|---|---|
| Sale creation, STK Push, callback, confirm | Ready | Live proof: `evidence/payments/g2-live-money-path.md` |
| Idempotency (STK, B2C, daily close) | Ready | Proven live and in unit tests |
| Timeout vs. decline classification | Ready | Fixed and tested; see scar log |
| Payment state propagated back to POS | Not ready | Known gap — POS sale stays `pending_payment` after Payments confirms |
| Commission verifies sales are confirmed-paid | Not ready | Commission currently trusts caller-supplied sale data |
| Persistent storage (Postgres) | Not ready | All payment/payout/ledger state is in-memory, resets on restart |

## Observability

| Item | Status | Notes |
|---|---|---|
| Grafana SLO dashboard | Ready | Live CloudWatch data, populated panels |
| k6 load testing | Partial | Stepped/spike/soak all pass thresholds, but only against `/pos/health` — not the actual money path |
| CloudWatch alarms + Slack alerting | Ready | 24 alarms, fire/recovery manually verified |
| Trace propagation (trace_id/span_id) | Partial | Wired into Payments' STK Push handler only; not other handlers or other services |
| Payments/Commission-specific SLIs | Not ready | No command-success or duplicate-payout metric exists yet |

## Recovery (G4)

| Item | Status | Notes |
|---|---|---|
| Uncertain payment drill | Ready | `evidence/payments/g4-recovery-drills.md` |
| Callback replay drill | Ready | Same file, unit-test-backed |
| Platform failure / DLQ drill | Not ready | Not yet executed |
| Broken release / rollback drill | Partial | Broken image successfully deployed to live ECS; rollback proof not yet captured |
| Restore drill | Not ready | Not yet executed |

## Security

| Item | Status | Notes |
|---|---|---|
| Threat model | Ready | `docs/threat-model.md`, written retrospectively — top risks still open |
| Secrets never committed | Ready | `.env` patterns gitignored, Secrets Manager for real values |
| No `latest` tags, immutable digests | Ready | Enforced in image pipeline |
| Unauthenticated public routes | Not ready | Open risk per threat model |
| Callback spoofing protection | Not ready | Open risk per threat model |

## Cost and Cleanup

| Item | Status | Notes |
|---|---|---|
| Cost tracking | Not ready | No cost summary captured yet |
| Destroy/rebuild proof | Not ready | Not yet executed |