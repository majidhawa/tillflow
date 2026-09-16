# ADR-001: TillFlow Platform Architecture

- Status: Accepted
- Date: 2026-09-14
- Group: 8
- AWS Region: eu-west-3
- Resource Prefix: devops-g8-

## Context

TillFlow is a multi-tenant POS platform with M-Pesa payment processing deployed on AWS.

The platform must use infrastructure as code, containerized services on ECS Fargate, private networking for backend workloads, reproducible delivery pipelines, and observable runtime behavior.

The architecture must support the following primary services:

- Web
- POS
- Payments
- Commission

## Region justification

eu-west-3 (Paris) is the region assigned to Group 8 by the DevOps Mentorship cohort for this
capstone; it was not chosen by the group for cost, latency, or data-residency reasons. All
`name_prefix`/tagging and IAM trust conditions in this repo assume this fixed region, and any
account-specific values derived from it (for example, the ELB log-delivery account ID used for
ALB access-log bucket permissions in `infra/modules/alb`) are pinned to eu-west-3 accordingly.

## Decision

TillFlow will use the following request path:

Web -> API Gateway -> VPC Link -> ALB -> ECS Fargate

Backend ECS tasks will run in private subnets.

Each backend task will include:

- application container
- ADOT sidecar for OpenTelemetry telemetry collection

## Core AWS Services

### Networking

- One VPC across two Availability Zones
- Public subnets for public-facing infrastructure where required
- Private subnets for ECS tasks and data services
- Security groups will use least-privilege ingress and egress rules

### Compute

- Amazon ECS on AWS Fargate
- Separate ECS services for:
  - web
  - pos
  - payments
  - commission
- ECR repositories will store immutable service images
- Deployments must use SHA- or digest-based image references and never `latest`

### Ingress

- API Gateway is the public API entry point
- API Gateway connects through VPC Link
- VPC Link forwards traffic to the internal ALB
- ALB routes traffic to ECS services

### Database

- Amazon RDS for PostgreSQL
- Service-owned schemas and least-privilege database roles
- Backups and recovery settings must support the agreed RPO and RTO

### Cache

- Redis/Valkey will be used for caching and short-lived operational state
- Cache failure must not corrupt payment or sale correctness

### Messaging

- Amazon SQS for asynchronous workloads
- Dead-letter queues for failed messages
- Message consumers must be safe for retries where applicable

### Scheduling

- Amazon EventBridge for scheduled jobs
- Daily scheduled reconciliation will be supported where required

### Object Storage

- Amazon S3 for purpose-separated storage
- Buckets will have public access blocked unless explicitly required
- Encryption and versioning will be enabled where appropriate

### Secrets and Access

- AWS Secrets Manager will store runtime credentials and sensitive configuration
- IAM roles will follow least privilege
- GitHub Actions will authenticate to AWS using OIDC rather than long-lived AWS access keys

## Naming and Tagging

All AWS resources must use the prefix:

`devops-g8-`

Required tags will include:

- `group = 8`
- `owner`
- `service`
- `environment`
- `managed-by = terraform`
- `capstone = tillflow`

## Service Boundaries

### POS

Owns:

- sale creation
- sale ID
- sale validation
- sale line items and totals
- tenant/till context

POS does not call Daraja directly.

### Payments

Owns:

- payment ID
- M-Pesa provider references
- payment state
- Daraja integration
- callbacks
- reconciliation
- idempotency for payment operations

Payments links each payment to the POS-owned `sale_id`.

### Commission

Owns:

- commission calculation workflow
- payout workflow coordination

Commission must call the Payments service for payment execution and must not call Daraja directly.

### Web

Owns the user-facing application and communicates with backend APIs through the approved ingress path.

## Money Representation

Monetary values must be represented using integer minor units.

Example:

KES 125.50 -> 12550

Floating-point values must not be used for persisted or transferred monetary amounts.

## Payment State Principle

Payment timeout is not treated as a decline.

The system must preserve a distinct uncertain or timed-out state until reconciliation establishes a terminal result.

## Observability

Backend services will emit:

- structured JSON logs
- traces
- metrics

Telemetry will flow through ADOT/OpenTelemetry into the selected AWS and Grafana observability stack.

Logs should include correlation fields such as:

- trace_id
- span_id
- service
- tenant identifier where safe and appropriate

## Delivery

Infrastructure will be managed with Terraform.

Delivery will use:

- GitHub Actions for pull-request validation
- AWS CodePipeline / CodeBuild for deployment flow
- ECR for immutable images
- ECS for runtime deployment
- post-deployment smoke validation
- rollback support

## Consequences

### Positive

- Clear separation between public ingress and private workloads
- Independent service deployment
- Stronger payment integrity boundaries
- Infrastructure is reproducible
- Runtime behavior can be observed and defended during assessment
- Architecture aligns platform, delivery, and reliability responsibilities

### Trade-offs

- More AWS components increase setup and operational complexity
- Distributed tracing is required to follow requests across services
- Service-to-service contracts must be defined early to avoid integration drift
- Payment timeout and reconciliation require explicit state-machine handling

## Ownership

- Platform + Delivery: Hawa
- Reliability + Operations: Hawa
- Payments + Integrity: Glory
- Product + POS: Consolate

Cross-review follows the repository ownership agreement.
