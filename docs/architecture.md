
Every backend ECS task runs two containers: the application, and an
ADOT sidecar collecting OpenTelemetry telemetry.

## Services

| Service | Owns | Notes |
|---|---|---|
| **Web** | User-facing application | Talks to backend APIs through the approved ingress path only |
| **POS** | Sale creation, sale ID, validation, line items/totals, tenant/till context | Never calls Daraja directly |
| **Payments** | Payment ID, M-Pesa provider references, payment state, Daraja integration, callbacks, reconciliation, idempotency | Links each payment to POS's `sale_id`. The only service that talks to Daraja |
| **Commission** | Commission calculation, payout workflow coordination | Calls Payments for disbursement — never Daraja directly |

## Core AWS services

- **Compute:** ECS on Fargate, one service per app, ECR for immutable images (SHA/digest tags only, never `latest`)
- **Ingress:** API Gateway → VPC Link → internal ALB → ECS
- **Database:** RDS PostgreSQL, service-owned schemas, least-privilege roles
- **Cache:** Redis/Valkey — cache failure must never corrupt payment/sale correctness
- **Messaging:** SQS with dead-letter queues, retry-safe consumers
- **Scheduling:** EventBridge for the daily commission reconciliation job
- **Storage:** S3, purpose-separated buckets, public access blocked by default
- **Secrets:** Secrets Manager for runtime credentials; GitHub Actions authenticates via OIDC, never long-lived keys

## Multi-tenancy

Logical multi-tenancy on shared infrastructure. Every tenant-scoped
record (till, attendant, sale, payment, commission, payout) carries an
explicit `tenant_id`, propagated through requests and service-to-service
calls. Full detail: [ADR-002](adr/002-tenancy-data-ownership.md).

## Money and payment-state principles

- All monetary values are integer minor units (KES 125.50 → `12550`).
  Floating-point is never used for persisted or transferred amounts.
- **A payment timeout is not a decline.** The system preserves a
  distinct `uncertain`/`timed_out` state until reconciliation
  establishes a terminal result. See
  [`evidence/payments/g2-payment-integrity.md`](../evidence/payments/g2-payment-integrity.md)
  for where this was implemented, tested, and — after an initial bug —
  corrected.

## Delivery

Two-stage model: GitHub Actions for PR/pre-merge validation (lint,
tests, secret/dependency/IaC scanning), then deployment execution.
Full detail: [ADR-003](adr/003-delivery-deployment.md). Current actual
status (as of this writing, not the original design intent) is tracked
in [`docs/production-readiness.md`](production-readiness.md) — notably,
GitHub Actions has never executed a Terraform apply; all applies so far
have been manual/local.

## Observability

Structured JSON logs, traces, and metrics via ADOT/OpenTelemetry, into
CloudWatch and a self-hosted Grafana instance. Logs carry `trace_id`,
`span_id`, `service`, and tenant identifier where safe. Current
coverage and gaps: [`evidence/reliability/g3-grafana-slo-runtime.md`](../evidence/reliability/g3-grafana-slo-runtime.md).

## Naming and tagging

Every resource is prefixed `devops-g8-` and tagged with `group`,
`owner`, `service`, `environment`, `managed-by=terraform`,
`capstone=tillflow`.