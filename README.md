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
