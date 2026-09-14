# Sale ↔ Payment Contract

- Status: Proposed
- Date: 2026-09-14
- Group: 8
- POS DRI: Consolate
- Payments DRI: Glory
- Platform/Integration DRI: Hawa

## Purpose

This contract defines the boundary between the TillFlow POS and Payments services.

It exists to prevent integration drift while allowing each service to own its internal implementation independently.

## Ownership Boundary

POS owns:

- `sale_id`
- tenant and till context
- sale line items
- sale totals
- sale validation
- sale idempotency

Payments owns:

- `payment_id`
- payment state
- M-Pesa request references
- provider transaction references
- payment idempotency
- callbacks
- reconciliation

POS must not call Daraja directly.

Payments is the only service allowed to integrate with the M-Pesa adapter.

## Money Representation

All monetary amounts exchanged between services use integer minor units.

Example:

KES 125.50 is represented as:

`12550`

Floating-point monetary values are not permitted in the service contract.

## Sale Object

The minimum sale representation required at the payment boundary is:

```json
{
  "sale_id": "sale_01...",
  "tenant_id": "tenant_01...",
  "till_id": "till_01...",
  "currency": "KES",
  "amount_minor": 12550,
  "idempotency_key": "tenant_01:till_01:sale_01"
}
```

## Payment Creation

POS requests payment from the Payments service using the POS-owned `sale_id`.

Example request:

```json
{
  "sale_id": "sale_01...",
  "tenant_id": "tenant_01...",
  "till_id": "till_01...",
  "amount_minor": 12550,
  "currency": "KES",
  "phone_number": "<sandbox-test-number>",
  "idempotency_key": "tenant_01:till_01:sale_01"
}
```

## Payment Response

Payments creates and owns `payment_id`.

Example response:

```json
{
  "payment_id": "pay_01...",
  "sale_id": "sale_01...",
  "state": "pending",
  "amount_minor": 12550,
  "currency": "KES"
}
```

Provider identifiers must not replace the internal `payment_id`.

## Payment States

The shared payment states are:

- `pending`
- `processing`
- `confirmed`
- `failed`
- `timed_out`
- `uncertain`

`confirmed` and `failed` are terminal only when the provider outcome is known.

A timeout is not equivalent to payment failure.

If the final provider outcome is unknown, Payments must preserve the transaction as `timed_out` or `uncertain` until reconciliation establishes the authoritative outcome.

POS must not automatically convert an uncertain payment into a declined sale.

## Idempotency

Payment initiation must be idempotent.

Recommended initial key format:

`{tenant_id}:{till_id}:{sale_id}`

Repeated requests with the same idempotency key must not create duplicate financial effects.

The final key format must be validated jointly by the POS and Payments DRIs.

## Callback Handling

M-Pesa callbacks may be duplicated, delayed, or reordered.

Payments must process callbacks idempotently.

Duplicate callbacks must not:

- create duplicate payments
- confirm a payment twice
- trigger duplicate commission effects
- trigger duplicate payout effects

## Reconciliation

Reconciliation resolves transactions whose provider outcome is not known locally.

It may transition an uncertain or timed-out payment to an authoritative terminal state when sufficient provider evidence exists.

Reconciliation must not create a second logical payment for the same idempotent request.

## Tenant Integrity

Every payment must remain associated with the correct `tenant_id` and `sale_id`.

Cross-tenant mutation is prohibited.

## Commission Boundary

Commission must not call Daraja directly.

Required flow:

Commission -> Payments -> M-Pesa adapter

Payments owns provider interaction and payment execution integrity.

Commission owns commission calculation and payout workflow state.

## Observability

Cross-service payment operations should propagate:

- `trace_id`
- `span_id`
- `sale_id`
- `payment_id`
- service name

Sensitive payment credentials and secrets must never be logged.

## Required Contract Tests

Before G2 is considered complete, the POS and Payments integration should demonstrate:

1. successful payment initiation
2. idempotent retry
3. confirmed payment
4. provider-declined or failed payment
5. timeout resulting in uncertain state
6. duplicate callback safety
7. reordered callback safety
8. reconciliation of uncertain payment
9. tenant isolation
10. integer minor-unit preservation

## Open Validation Items

Before this contract moves from Proposed to Accepted, Consolate and Glory must confirm:

- final request and response field names
- final payment state enum
- final idempotency-key format
- whether `timed_out` and `uncertain` remain separate states
- exact API endpoint paths
- commission-to-payments payout request shape

## Approval

This contract requires cross-domain validation.

- Product + POS: Consolate
- Payments + Integrity: Glory
- Platform/Integration: Hawa

Once the POS and Payments DRIs agree on the open validation items, update this document to `Status: Accepted`.
