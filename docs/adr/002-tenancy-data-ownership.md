# ADR-002: Multi-Tenancy and Data Ownership

- Status: Accepted
- Date: 2026-09-14
- Group: 8

## Context

TillFlow is a multi-tenant POS platform.

The architecture must prevent data leakage across tenants while allowing shared infrastructure and independently owned services.

The core business entities include:

- tenant
- till
- attendant
- sale
- payment
- commission
- payout

## Decision

TillFlow will use logical multi-tenancy on shared platform infrastructure.

Every tenant-scoped business record must include an explicit `tenant_id`.

Tenant context must be propagated through authenticated requests and service-to-service calls where required.

Service boundaries remain explicit even when services share the same PostgreSQL instance.

## Tenant Model

A tenant represents one merchant or business organization using TillFlow.

A tenant may own multiple:

- tills
- attendants
- sales
- payments
- commissions
- payouts

Tenant-scoped operations must validate that the acting principal is authorized for the referenced tenant.

## Core Identifiers

The following identifiers are owned by the corresponding domain:

- `tenant_id` — Product/POS domain
- `till_id` — Product/POS domain
- `sale_id` — POS domain
- `payment_id` — Payments domain
- provider transaction/reference IDs — Payments domain
- `commission_id` — Commission domain
- `payout_id` — Commission/Payments boundary as defined by implementation contract

Identifiers must be opaque and globally unique enough to avoid collisions across tenants.

## Database Ownership

TillFlow will use one PostgreSQL RDS instance with service-owned schemas.

Recommended schema boundaries:

- `pos`
- `payments`
- `commission`

Each service will receive a least-privilege database role scoped to its own schema.

Cross-service database writes are not allowed.

Services must integrate through APIs, queues, or explicit shared contracts rather than directly mutating another service's tables.

## POS Data Ownership

POS owns:

- tenants
- tills
- attendants
- sales
- sale line items
- sale totals
- sale idempotency records

Each tenant-scoped POS record must include `tenant_id`.

POS is responsible for validating tenant/till ownership before initiating payment.

## Payments Data Ownership

Payments owns:

- payment records
- payment idempotency records
- M-Pesa request references
- callback records
- provider transaction references
- reconciliation state
- payment state transitions

Payments stores the POS-owned `sale_id` as an external domain reference.

Payments must not rewrite POS sale data directly.

## Commission Data Ownership

Commission owns:

- commission calculation records
- commission state
- payout workflow state

Commission must not call Daraja directly.

Payment execution must go through the Payments service.

## Tenant Isolation

Tenant isolation must be enforced at the application layer and supported by database access patterns.

At minimum:

- every tenant-scoped query must filter by `tenant_id`
- API requests must not trust client-supplied tenant context without authorization
- logs must avoid exposing sensitive tenant or payment data
- caches must use tenant-aware keys
- asynchronous messages must include enough tenant context for safe processing

Example cache key pattern:

`tillflow:{tenant_id}:{resource}:{id}`

## Money

All monetary values are represented using integer minor units.

Floating-point monetary values are prohibited for persisted and transferred business amounts.

## Cross-Service Contracts

Cross-service references must use stable identifiers rather than direct table access.

Example:

POS creates `sale_id`.

Payments creates `payment_id` and stores the related `sale_id`.

Commission references payment and sale identifiers through approved service contracts.

## Failure and Integrity Rules

Tenant isolation and domain ownership must remain valid during retries, replays, and recovery.

Duplicate messages or callbacks must not cause cross-tenant writes or duplicate financial effects.

Timeouts must not cause payment state to be incorrectly marked as failed if the provider outcome is still unknown.

## Consequences

### Positive

- Clear ownership of data and write responsibility
- Reduced risk of cross-service coupling
- Easier live defence of service boundaries
- Tenant-aware cache and database access patterns
- Shared RDS infrastructure remains operationally manageable

### Trade-offs

- Shared database infrastructure still requires strict role and schema discipline
- Application code must consistently propagate tenant context
- Cross-service reads may require APIs or replicated views instead of direct joins
- More explicit contracts are required between domains

## Ownership

- Product + POS: Consolate
- Payments + Integrity: Glory
- Platform + Delivery: Hawa
- Reliability + Operations: Hawa

Hawa owns the platform enforcement mechanisms such as database roles, networking, secrets, and runtime configuration.

Domain DRIs own application-level tenant validation within their services.
