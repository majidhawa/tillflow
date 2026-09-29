# G2 — Product / POS Implementation Evidence

Owner: Consolate (Product + POS)
Compiled: 2026-09-30

This file assembles evidence for the POS service from material already
merged elsewhere in the repo — the product ADR and the live end-to-end
proof captured during Payments integration testing. It is a starting
point compiled by Glory (Payments + Integrity) to close a gap in
`evidence/product/`, not a substitute for Consolate's own testing
narrative. Consolate should review, correct, and expand this with her
own test evidence.

## Data model

Per `docs/adr/product-pos.md`:

- **Tenant**: `id`, `name`, `commission_rate`, `created_at`
- **Till**: `id`, `tenant_id`, `name`, `created_at` — must belong to
  the tenant associated with a given sale
- **Attendant**: `id`, `tenant_id`, `name`, `role`, `created_at` — must
  belong to the same tenant as the sale
- **Commission rate**: stored on the tenant as an integer

## API surface

Per `services/pos/main.go`:

- `POST /tenants` — tenant creation
- `POST /tills` — till creation
- `POST /attendants` — attendant creation
- `POST /sales` — sale creation
- `GET /sales/{id}` and related routes — sale lookup and payment
  initiation (`/sales/{id}/payment`, calling the Payments service)

POS does not call Daraja directly, per the contract boundary in
`docs/contracts/sale-payment.md` — all M-Pesa interaction goes through
Payments.

## Live proof (cross-referenced)

Captured during live Payments integration testing against the
deployed ECS environment (full detail in
[`evidence/payments/g2-live-money-path.md`](../payments/g2-live-money-path.md)):

- A live POS sale was created successfully: HTTP 201, amount 100 minor
  units (KES 1), initial state `pending_payment`.
- The sale's payment was initiated through the deployed POS API,
  flowing POS → internal ALB → Payments → Daraja. The real STK prompt
  was approved.

## Known gap (also cross-referenced)

- **Payment state is not propagated back to the POS sale record.**
  After Payments independently confirmed the transaction, the
  corresponding POS sale was queried again and still showed
  `pending_payment`, not `confirmed`. This is an open integration gap
  between Payments and POS, not a POS-only defect — the fix would
  involve either POS polling Payments for status, or Payments
  notifying POS on confirmation (e.g. via a webhook or shared event).

## Still needed from Consolate

- Her own test evidence for tenant/till/attendant creation
  (request/response examples)
- Any validation-boundary tests (e.g. a sale rejected for a
  mismatched till/tenant)
- Whether idempotent sale creation has been tested directly (the ADR
  states "idempotent sale creation" as a responsibility, but no test
  evidence for it exists yet in this file)