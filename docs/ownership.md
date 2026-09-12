# TillFlow Ownership

## Primary DRI matrix

| Area | DRI | Responsibilities |
|---|---|---|
| Platform + Delivery | Hawa | Terraform, IAM, ECS, data services, caching, GitHub Actions, CodePipeline, scans |
| Reliability + Operations | Hawa | SLOs, error budgets, ADOT, Grafana, k6, alerts, recovery, runbook |
| Payments + Integrity | Glory | Daraja STK/B2C, callbacks, payment/payout state, idempotency, reconciliation, replay |
| Product + POS | Consolate | Tenant model, POS frontend/API, sale state, validation, sale idempotency |

## Cross-review

- Hawa reviews Product + POS
- Glory reviews Platform + Delivery and Reliability + Operations
- Consolate reviews Payments + Integrity

## Working agreement

- Every primary area has one DRI.
- DRIs own decisions, implementation PRs, runtime proof, and live defence.
- Collaboration is encouraged, but ownership remains explicit.
- No direct work is merged to `main` without review.
