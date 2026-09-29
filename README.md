# TillFlow

TillFlow is the DevOps Mentorship 2026 Final Capstone project for Group 8.

It is a multi-tenant POS platform with M-Pesa payments, deployed on AWS ECS and managed using Terraform, GitHub Actions, and AWS CodePipeline.

## Primary ownership

- Hawa — Platform + Delivery; Reliability + Operations
- Glory — Payments + Integrity
- Consolate — Product + POS

## Repository structure

- `services/web/` — frontend / API shell
- `services/pos/` — POS API
- `services/payments/` — Payments API
- `services/commission/` — Commission worker
- `services/_shared/` — shared contracts, M-Pesa adapter interface, OTel setup
- `infra/` — Terraform and AWS platform code
- `.github/workflows/` — GitHub Actions
- `docs/` — architecture, ADRs, SLOs, runbook, threat model, contracts
- `evidence/` — reproducible proof by owned area and shared gates
- `scripts/` — operational and automation scripts

## Delivery gates

- G0 — Decide
- G1 — Platform
- G2 — Product
- G3 — Operate
- G4 — Recover
- G5 — Release

## Security rules

- Daraja sandbox only
- Never commit credentials, customer data, Slack webhooks, or real-money information
- Infrastructure is managed through Terraform
- Deploy immutable image tags/digests, never `latest`


## Cost summary

Actual AWS cost for the `dev` environment, September 2026 (via
`aws ce get-cost-and-usage`, account `240462142849`, region
`eu-west-3` unless noted). Captured 2026-09-30.

**Total: ~$1,850 for the month.**

| Service | Cost (USD) | Notes |
|---|---|---|
| Amazon VPC | 422.60 | Largest single cost — primarily the NAT Gateway's hourly charge plus per-GB data processing |
| Amazon ECS | 335.92 | Running all 4 services continuously (`web`, `pos`, `payments`, `commission`) |
| Tax | 255.26 | |
| AmazonCloudWatch | 251.05 | 24 alarms, dashboard, log retention |
| Elastic Load Balancing | 132.46 | Internal ALB |
| Amazon RDS | 98.79 | PostgreSQL, `db.t4g.micro` |
| AWS X-Ray | 28.94 | Tracing |
| Amazon ElastiCache | 35.25 | Redis/Valkey |
| AWS Secrets Manager | 8.15 | |
| AWS KMS | 6.12 | |
| AWS WAF | 4.63 | |
| CodeBuild | 4.00 | |
| Everything else (ECR, S3, API Gateway, SNS/SQS, Route 53, Prometheus) | < 1 each | |

**Known optimization opportunities, not yet actioned:**
- The NAT Gateway (largest line item) could be replaced with a single
  shared NAT instance for a dev environment, or removed entirely if
  private subnets can reach ECR/Secrets Manager via VPC endpoints
  instead
- CloudWatch log retention could be reduced from its current setting
  to lower storage cost, since this is a training environment, not
  production
- `db.t4g.micro` and `cache.t4g.micro` are already the smallest
  practical instance classes for RDS/ElastiCache

## Cleanup status

Not yet performed. Full teardown (`terraform destroy` against the
shared `dev` environment) is a Reliability + Operations (Hawa)
responsibility, tracked separately from this README until executed.