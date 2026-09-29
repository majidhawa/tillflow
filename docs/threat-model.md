# TillFlow Threat Model

- Status: Accepted as the G0 baseline, written retrospectively against the implemented system.
- Date: 2026-09-30, reviewed against `main` @ `f022126`
- Owner: Hawa (Platform + Delivery). Payments rows are reviewed by Glory (Payments + Integrity), POS/tenancy rows by Consolate (Product + POS).
- Method: STRIDE per trust boundary. Each threat lists **implemented controls** (with the file that implements them) separately from **gaps**. A control is listed as implemented only if it exists in this repository today.
- Related: [ADR-001](adr/001-platform-architecture.md), [ADR-002](adr/002-tenancy-data-ownership.md), [ADR-003](adr/003-delivery-deployment.md), [sale-payment contract](contracts/sale-payment.md), [CI/CD](cicd.md)

## Scope

In scope is the deployed dev environment in `eu-west-3`:

- the four ECS services (`web`, `pos`, `payments`, `commission`)
- the AWS resources in `infra/environments/dev`
- the Daraja (M-Pesa) integration
- the GitHub Actions delivery path

Out of scope: Safaricom's own platform, the AWS control plane, and developer laptops beyond the credentials they hold.

This is a dev environment. Its money-path evidence covers Daraja sandbox runs plus a single live KES 1 run (`evidence/payments/g2-live-money-path.md`). Several gaps below are tolerable for that controlled testing and would block any wider use. The severity ratings assume a real launch.

## Architecture and trust boundaries

```
                Internet (untrusted)                        Safaricom Daraja (semi-trusted, external)
                        │                                        ▲  STK / query / B2C (HTTPS, OAuth)
          TB1           ▼                                        │           │ callbacks (HTTPS POST)
        ┌────────────────────────────┐                           │           ▼
        │ API Gateway HTTP API       │◄──────────────────────────┼───────────┘
        │ route $default → VPC Link  │  TLS at the edge, no authorizer
        └─────────────┬──────────────┘
          TB2         │ VPC Link SG → ALB SG, port 80 only
   ┌──────────────────▼─────────────────────────────── VPC, private subnets ───────────────┐
   │  Internal ALB (HTTP :80, access logs → S3)                                            │
   │   default → web   /tenants*,/tills*,/attendants*,/sales*,/pos* → pos                   │
   │   /payments,/payments/* → payments      /commission,/commission/* → commission          │
   │        │                   ▲ TB3: service-to-service via the same ALB (SG-to-SG :80)   │
   │   ┌────▼───┐ ┌─────┐ ┌─────┴────┐ ┌────────────┐   egress via NAT → Daraja             │
   │   │  web   │ │ pos │→│ payments │←│ commission │                                       │
   │   └────────┘ └─────┘ └──────────┘ └────────────┘   one shared task role / exec role    │
   │   RDS Postgres, Redis, SQS+DLQ: provisioned, not yet used by any service (TB4)         │
   └────────────────────────────────────────────────────────────────────────────────────────┘
   TB5: GitHub Actions ──OIDC──► AWS (plan / apply / deploy roles)   TB6: CloudWatch → SNS → Lambda → Slack
```

Trust boundaries:

- **TB1:** internet → API Gateway
- **TB2:** API Gateway → private ALB
- **TB3:** service ↔ service
- **TB4:** services → data stores and secrets
- **TB5:** CI/CD → AWS
- **TB6:** telemetry → external alerting

## Assets

| Asset | Why it matters |
|---|---|
| Money movement: STK charges to customers and B2C payouts from the business shortcode | Direct financial loss or double-charging |
| Payment and payout state (`pending` / `confirmed` / `failed` / `timed_out`) | A wrong state means goods released unpaid, or a paid sale shown as unpaid |
| Tenant-scoped records (tenants, tills, attendants, sales, commission ledger) | Cross-tenant disclosure or tampering |
| Daraja credentials (consumer key/secret, passkey, B2C security credential) | Full control of the business's M-Pesa API access |
| RDS master credentials, Slack webhook | Data access, alert spoofing |
| AWS deploy/apply capability (OIDC roles, Terraform state) | Full infrastructure compromise |
| Customer PII (MSISDN / phone numbers, B2C recipient names) | Privacy and regulatory exposure |

## Threats, controls and gaps

Severity reflects likelihood × impact **for a production launch** of the code as it stands.

### T1. Public API: unauthenticated access to every route (TB1) — **Critical**

| | |
|---|---|
| Threat | **S/E.** API Gateway has a single `$default` route with no authorizer (`infra/modules/apigw-vpclink/main.tf`), and the ALB forwards by path prefix. Anyone who knows the API URL can therefore call **every** service endpoint, including `POST /payments/b2c` (disburse money), `POST /commission/close` (compute and trigger payouts), `POST /payments/callback` and `POST /tenants`. |
| Implemented controls | TLS at the API Gateway edge. The ALB is `internal = true` with no public IP, and its only ingress is from the VPC Link SG and the ECS task SG (`infra/environments/dev/main.tf`). API Gateway access logs record source IP, route and status. |
| Gaps | No authentication or authorization on any route (no JWT/Cognito/Lambda authorizer, API key or IAM auth). Internal-only operations (`/payments/b2c`, `/commission/close`, `/payments/query`) are not separated from public ones. No route allowlist: `$default` exposes everything. |
| Planned mitigation | Explicit API Gateway routes, with an authorizer on POS routes. Don't route `/payments/b2c` or `/commission/*` through the public API at all: split the internal ALB rules, or call Payments directly over a non-public listener. Expose only the Daraja callback paths publicly. |

### T2. Multi-tenancy: cross-tenant access and tampering (TB1, TB3) — **High**

| | |
|---|---|
| Threat | **I/T.** ADR-002 requires tenant context from an *authenticated principal*. In the code, `tenant_id` is taken from the request body, and `GET /sales/{id}` returns any sale by ID with no tenant check (`services/pos/handlers.go` `getSale`). Sale, till and attendant IDs are client-supplied, so they are guessable. |
| Implemented controls | On sale creation POS checks that the till and attendant belong to the stated `tenant_id` (`services/pos/handlers.go` `createSale`). Commission close skips sales whose `tenant_id` differs from the close's tenant (`services/commission/main.go`, shown in `evidence/payments/g2-payment-integrity.md` §7). Every record carries `tenant_id`. |
| Gaps | No principal, so no binding of caller to tenant (depends on T1). Reads are not tenant-scoped. IDs are not server-generated or opaque. ADR-002's per-service Postgres schemas and roles don't exist yet (see T9). |

### T3. Daraja callback spoofing (TB1 → payments) — **High**

| | |
|---|---|
| Threat | **S/T.** `POST /payments/callback` and `/payments/b2c/callback` are public and unauthenticated. A forged `ResultCode: 0` for a known `CheckoutRequestID` marks a payment `confirmed` without money moving. The checkout ID is not secret: it is embedded in the `payment_id` (`pay_<CheckoutRequestID>`, `services/payments/stkpush.go`) that is returned to the caller. |
| Implemented controls | Callbacks for unknown checkout/conversation IDs are ignored. A terminal state is never overwritten (duplicate and reordered callbacks are a no-op: `processedTerminal` in `services/payments/callback.go`, tests in `callback_test.go`). An independent Daraja transaction-status query exists (`/payments/query`, `services/payments/query.go`) and was used as the source of truth in the live G2 run. |
| Gaps | No callback authenticity check: no source-IP allowlist for Safaricom ranges, no unguessable per-payment token in the callback URL, and no mandatory query-before-confirm. The payment ID leaks the checkout ID. |
| Planned mitigation | Confirm only after a Daraja status query (or treat the callback as a hint). Add a secret path token and a Safaricom IP allowlist at API Gateway or WAF. Make `payment_id` opaque. |

### T4. Idempotency and replay: double charge or double payout — **High**

| | |
|---|---|
| Threat | **T/R.** A retried STK initiation sends a second prompt. A replayed close or B2C request pays out twice. |
| Implemented controls | Payments STK and B2C are keyed by caller `idempotency_key`, and a sequential retry returns the original result (`evidence/payments/g2-payment-integrity.md` §3, §6). The Commission ledger is keyed `tenant:attendant:close_date`, and a live replay produced **0** extra B2C calls (`evidence/payments/g2-live-money-path.md` §7). POS rejects reuse of a sale idempotency key with a different sale (`services/pos/handlers.go`). |
| Gaps | (a) **All idempotency state is in-memory.** A task restart or redeploy forgets every key, and a retry afterwards creates a new charge or payout. (b) **Check-then-act race:** the Payments store is looked up before the Daraja call and written only after it returns, so two concurrent retries can both send STK. (c) The maps have no lock. Concurrent writes are a Go data race, and the runtime can abort the process on them. (d) Commission's key includes caller-chosen `close_date`, so varying it creates a fresh payout for the same sales (see T6). |
| Planned mitigation | Persist idempotency records in Postgres with a unique constraint, and reserve the key **before** calling Daraja. |

### T5. Payment timeout and reconciliation: wrong terminal state — **Medium**

| | |
|---|---|
| Threat | **T.** A slow or absent provider response is misread as a decline (customer paid, sale failed), or as success. |
| Implemented controls | Result code 1037 is classified `timed_out`, distinct from `failed` (1032), and covered by unit tests. Reconciliation via the status query doesn't disturb terminal states (`state_changed: false`, live and sandbox evidence). POS → Payments has a 10 s client timeout (`services/pos/payments_client.go`). |
| Gaps | Payments → Daraja and Commission → Payments use Go's default HTTP client, which has **no timeout** (`services/payments/*.go`, `services/commission/main.go`). No scheduled or automatic reconciliation of stuck `pending` payments. **Confirmed payment state is not propagated to POS**, so the sale stays `pending_payment` (known G2 limitation). |

### T6. Service boundaries: POS / Payments / Commission (TB3) — **High**

| | |
|---|---|
| Threat | **T/E.** A caller that can reach Commission can supply fabricated sales, including any `attendant_phone`, and cause a B2C payout of arbitrary size. A compromised or buggy service can call any other service. |
| Implemented controls | Only Payments receives the Daraja secret as container env (`infra/environments/dev/main.tf`). The execution-role policy for it is scoped to that one secret ARN. Payments is the only component that talks to Daraja. |
| Gaps | **Commission trusts caller-supplied sales** and does not verify them against POS or Payments confirmed state (known G2 limitation). Service-to-service calls carry no identity (no mTLS, no signed token), and every task shares one SG. **All four services share one ECS task role**, which may `GetSecretValue` on every app secret (Daraja, Slack webhook) and the DB secret (`infra/modules/secrets-placeholders`, `infra/modules/rds-postgres`). Web, POS and Commission can therefore read Daraja credentials through the AWS API. Internal traffic is plain HTTP on the internal ALB, an accepted, documented exception in `infra/modules/alb/main.tf`. |

### T7. Secrets management (TB4) — **Medium**

| | |
|---|---|
| Threat | **I.** Leakage of Daraja, DB or Slack credentials through source, state, images or logs. |
| Implemented controls | Secrets live in AWS Secrets Manager. Terraform creates placeholders only, and values are set out of band (`infra/modules/secrets-placeholders`). ECS injects Daraja values at start via `valueFrom` (not baked into images). Gitleaks runs on every PR over full history (`pr-ci.yml`). `.env` and `.env.*` are gitignored. Only `observability/grafana/.env.example` is tracked. The RDS master password is generated by Terraform and stored in Secrets Manager. |
| Gaps | The generated RDS password also exists in Terraform state, so state must be treated as secret (the backend is S3 + DynamoDB, created in `infra/bootstrap`). No rotation for any secret. The shared task role over-grants read access (T6). |

### T8. CI/CD and GitHub OIDC supply chain (TB5) — **Medium**

| | |
|---|---|
| Threat | **E/T.** A PR or fork assumes a mutating AWS role, a malicious image or dependency reaches ECR, or `main` changes without review. |
| Implemented controls | No long-lived AWS keys: OIDC only. Three roles with **mutually exclusive** trust (plan ← `pull_request` read-only, apply ← `environment:production`, deploy ← `refs/heads/main`), scoped to `majidhawa/tillflow` (`infra/modules/github-oidc-roles`). The `production` environment requires a reviewer. `main` requires 1 approving review, enforced for admins. ECR tags are `IMMUTABLE`, with scan-on-push. Trivy image scan (HIGH/CRITICAL fails) runs **before** push, and an SBOM is generated. Images are tagged by commit SHA only. Containers run as non-root `USER 1000:1000`. |
| Gaps | No required status checks on `main`. Most actions are pinned to tags, not SHAs. No image signing or provenance verification at deploy. Go unit tests don't run in CI. A temporary OIDC-claims diagnostic step is still in `terraform.yml`. Live infrastructure was applied manually from a workstation, outside the reviewed apply path (see `docs/cicd.md`). |

### T9. RDS and shared schemas (TB4) — **Low today, High once used**

| | |
|---|---|
| Threat | **I/T.** One service reads or writes another's data in the shared Postgres instance. The database is reachable from outside. |
| Implemented controls | RDS has `storage_encrypted = true` and `publicly_accessible = false`, sits in private subnets, and only accepts ingress from the ECS task SG (`infra/modules/rds-postgres`). Backups follow `backup_retention_period`. |
| Gaps | **No service uses RDS yet** (all state is in memory), so ADR-002's per-service schemas (`pos`, `payments`, `commission`) and least-privilege DB roles **don't exist**. Every service would connect with the master credential through the shared task role. Single-AZ (`multi_az = false`). No restore has been rehearsed (G4). |

### T10. SQS / DLQ (TB4) — **Low**

| | |
|---|---|
| Threat | **T/D.** Poison messages, lost events, or unauthorized enqueue. |
| Implemented controls | A queue and DLQ are provisioned with redrive and SSE (`sqs_managed_sse_enabled`) (`infra/modules/sqs`). IAM send/receive access is granted to the shared ECS task role. |
| Gaps | **No service produces or consumes SQS messages today**, so none of these controls protect a live flow. Callback handling and POS state propagation are synchronous. No DLQ-depth alarm. |

### T11. Logging, PII and secret exposure in telemetry (TB6) — **Medium**

| | |
|---|---|
| Threat | **I.** Credentials or customer PII land in CloudWatch Logs, Grafana or Slack. |
| Implemented controls | Log groups have a fixed retention (14 days for ECS). Payments STK logs record IDs, state and trace IDs, not phone numbers or tokens (`services/payments/stkpush.go`). The Slack webhook is read from Secrets Manager by the Lambda. Grafana runs on `127.0.0.1` only, with no anonymous access (`observability/grafana`). |
| Gaps | Payments logs **raw Daraja B2C responses and raw B2C result/timeout callback bodies** (`services/payments/b2c.go`). These include recipient MSISDN and name. No log redaction layer, and no CMK encryption on log groups. |

### T12. Availability and abuse (TB1, TB3) — **Medium**

| | |
|---|---|
| Threat | **D.** Request floods exhaust tasks or run up Daraja calls. An STK-prompt spam attack targets arbitrary phone numbers. |
| Implemented controls | 24 CloudWatch alarms (ALB 5xx/latency/unhealthy hosts, ECS CPU/memory, API Gateway, synthetic canary) route to Slack via SNS. Firing and recovery were manually exercised against the live environment. No artifact of that is in the repo yet (`docs/runbook.md`). k6 showed a 200-VU spike on `/pos/health` with 0% errors (`evidence/reliability/capacity-envelope.md`). |
| Gaps | No stage or route throttling on API Gateway (account defaults only). No WAF. One task per service with no autoscaling. No ECS deployment circuit breaker. `POST /payments` sends an STK prompt to any supplied phone number without authentication (T1). |

## Summary of top risks

These must be closed before any production (non-sandbox) use:

1. **T1 + T6:** unauthenticated public access to `/payments/b2c` and `/commission/close`, combined with Commission trusting caller-supplied sales. Anyone who knows the URL can trigger payouts.
2. **T3:** forgeable payment-success callbacks, made easier because the checkout ID leaks through `payment_id`.
3. **T4:** idempotency held only in memory, with a concurrent-retry race. A restart or parallel retry can double-charge or double-pay.
4. **T2:** tenant identity supplied by the caller, and reads not scoped by tenant.

Everything in the "Gaps" rows is a known, unimplemented control. This document does not claim any of them are mitigated.
