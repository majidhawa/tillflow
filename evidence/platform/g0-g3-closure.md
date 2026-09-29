# G0–G3 Closure Summary

- Owner: Hawa (Platform + Delivery, Reliability + Operations)
- Date: 2026-09-30, audited against `main` @ `f022126`
- Environment: dev, AWS `eu-west-3`
- Purpose: one place that states what G0–G3 have proven and what they haven't. Each line points to the evidence behind it. Nothing here is proven unless the linked file or run ID proves it.

**Scope:** this file covers G0–G3 only. **It does not claim G4 (Recover) or G5 (Release) is complete.** Formal ownership follows [docs/ownership.md](../../docs/ownership.md): Hawa remains the Reliability + Operations DRI, which includes recovery. Glory is currently executing and assisting with the G4 recovery drills in coordination with Hawa. Consolate is currently executing and coordinating G5 final validation with the team. No formal transfer of ownership for either gate is implied.

## G0: Foundations

**Present:**

- ADRs:
  - [ADR-001 platform architecture](../../docs/adr/001-platform-architecture.md), including the region justification
  - [ADR-002 tenancy and data ownership](../../docs/adr/002-tenancy-data-ownership.md)
  - [ADR-003 delivery and deployment](../../docs/adr/003-delivery-deployment.md)
  - [POS product ADR](../../docs/adr/product-pos.md)
- [Sale ↔ payment contract](../../docs/contracts/sale-payment.md)
- [Ownership / DRI matrix](../../docs/ownership.md), `CODEOWNERS`, `CONTRIBUTING.md`
- [SLOs and error budgets](../../docs/slo-error-budgets.md)
- [Threat model](../../docs/threat-model.md), added in this closure pass

**Remaining gaps:**

- `docs/contracts/sale-payment.md` is still `Status: Proposed`. Its open validation items between POS and Payments have not been signed off.
- The threat model was written **retrospectively** against the implemented system, not before the build. Its top risks are open: unauthenticated public routes, callback spoofing, in-memory idempotency, and caller-supplied tenant identity.

## G1: Platform and delivery

**Implemented and proven:**

- **Terraform for the full dev platform:**
  - network, ECR, ECS cluster and services, internal ALB with S3 access logs, API Gateway and VPC Link
  - RDS, Redis, SQS and DLQ, purpose-separated KMS S3 buckets
  - Secrets Manager placeholders, GitHub OIDC roles, observability, Slack alerts, synthetic canary
- **Applied live.** All four services run on ECS. This was a **manual** local `terraform apply`, not a GitHub Actions apply.
- **PR CI on GitHub:**
  - gitleaks: run `36622649837`
  - fmt/validate and Trivy IaC: run `36614714721`
  - service Docker build validation: run `36553574148`
- **Image pipeline on GitHub.** OIDC → ECR → Trivy image scan → SBOM → push, for all four services: run `36553717389`.
- **Terraform PR plan with the read-only OIDC role:** run `36470667717`, once.
- **Repository settings:**
  - `production` environment with required reviewers
  - three OIDC role variables set
  - `main` requires 1 review, enforced for admins

Details: [docs/cicd.md → Runtime verification status](../../docs/cicd.md#runtime-verification-status) and [g1-cicd/README.md](g1-cicd/README.md).

**Not proven:**

- **No GitHub Actions Terraform apply has ever executed.** Apply run `36471319002` has waited for approval since 2026-09-28, and later Terraform runs were cancelled while queued behind it.
- **No CodePipeline/CodeBuild deploy or smoke stage exists** (planned in ADR-003).
- **No required status checks on `main`.**
- **Go unit tests don't run in CI.**
- The live deploy depends on apply-time overrides (`enable_services`, `image_tags`) that aren't committed.

## G2: Product and money path

**Live evidence** ([g2-live-money-path.md](../payments/g2-live-money-path.md), deployed ECS, real Daraja calls, no forged callbacks):

- POS sale created (HTTP 201, `pending_payment`, KES 1).
- STK push went POS → internal ALB → Payments → Daraja. The real STK prompt was approved.
- Daraja status query returned `ResultCode 0`. Payments moved to `confirmed` / `reconciled: true`. A repeat query returned the same state with `state_changed: false`.
- Commission daily close ran. Commission → Payments → Daraja B2C was accepted (`ResponseCode 0`).
- Replaying the identical close returned the same ledger and **0** extra B2C calls.

**Supporting sandbox and unit evidence** ([g2-payment-integrity.md](../payments/g2-payment-integrity.md)):

- idempotent STK and B2C retry
- 1037 timeout classified `timed_out`, not `failed`
- decline, duplicate and reordered callback unit tests
- Commission tenant-mismatch exclusion

**Two known integration limitations (open):**

1. **Payments doesn't propagate confirmed state back to POS.** The sale stays `pending_payment` after the payment is `confirmed`.
2. **Commission accepts caller-supplied sales.** It doesn't verify that each sale is confirmed-paid. The live Commission/B2C run is therefore an isolated integration proof, not a coupled POS-paid → commission flow.

**Also open:**

- All payment, payout and ledger state is in memory.
- The B2C result callback has not been observed end to end, so only acceptance is proven, not final settlement.
- See threat-model T1, T3, T4 and T6 for the security side of these gaps.

## G3: Operate and observe

**Evidence:**

- **Grafana SLO dashboard.** Self-hosted, on the live CloudWatch data in `eu-west-3`. It loaded with no datasource or query errors, and RED, saturation and money-path panels populated. See [g3-grafana-slo-runtime.md](../reliability/g3-grafana-slo-runtime.md). Screenshots were captured manually and are not committed.
- **k6 against the live path** (`/pos/health`), all with 0% failures and p95 ≈ 190 ms. Peak CPU was ≈ 2.1% and memory ≈ 4.1%. See [capacity-envelope.md](../reliability/capacity-envelope.md) and the three `k6-*-summary.json` files.
  - stepped baseline: 100 VUs
  - spike: 200 VUs
  - 16-minute soak
- **Alerts.** 24 CloudWatch threshold alarms (`infra/modules/observability`) publish to SNS `devops-g8-alerts` → Lambda → Slack. Alert **firing** and **recovery** were manually exercised against the live environment through this path. The repository does not currently contain the screenshot or log artifact for that exercise. See [runbook → Rehearsal status](../../docs/runbook.md#rehearsal-status).

**Remaining telemetry limitations:**

- **Payments SLI not measured.** No command or callback outcome metric exists, and HTTP 200 is returned even when Daraja rejects.
- **Commission SLI and its no-duplicate-payout invariant not measured.** The close schedule has no target, the ledger is in memory, and there is no success log or metric.
- **The 28-day window is only partly filled**, and log retention is 14 days.
- **Web external budget reads −288.5%.** That is most likely from canary failures before a backend was deployed. Whether those runs count as eligible events is still an open scope decision.
- **POS worst observed p95 (≈ 3.86 s) breaches the 400 ms target**, most likely from the synchronous Daraja wait. Not yet cross-checked against request logs.
- **No burn-rate alerting.** Burn is displayed only.
- **No OTel metrics or business metrics.**
- **k6 covered `/pos/health` only**, not the Sale → Payments → M-Pesa path.

## Handover

| Gate | Owner | Status in this file |
|---|---|---|
| G0 | Hawa (with all DRIs) | Artifacts present. Gaps listed above. |
| G1 | Hawa | Implemented. Partially proven (no Actions apply, no deploy stage). |
| G2 | Glory / Consolate / Hawa (infra wiring) | Live money path proven, with two documented integration limitations. |
| G3 | Hawa | Proven for the telemetry that exists. Limitations listed above. |
| G4 | Hawa (Reliability + Operations DRI, per `docs/ownership.md`). Glory executing and assisting with drills in coordination with Hawa. | **Not complete. Not claimed here.** Payments drills are in [g4-recovery-drills.md](../payments/g4-recovery-drills.md). The platform-failure, broken-release and restore drills are not recorded in this repo. |
| G5 | Team. Consolate executing and coordinating final validation. | **Not complete. Not claimed here.** |
