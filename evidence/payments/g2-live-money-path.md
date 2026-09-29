# G2 Live Money-Path Evidence

Date: 2026-09-29
Environment: AWS ECS / eu-west-3

## 1. Sale Creation

A live POS sale was created successfully.

- HTTP: 201
- Amount: 100 minor units (KES 1)
- Initial state: `pending_payment`

## 2. Live M-Pesa STK Payment

Payment was initiated through the deployed POS API.

Flow:

POS -> internal ALB -> Payments -> Safaricom Daraja

Initial payment response:

- HTTP: 200
- State: `pending`
- Amount: 100 minor units

The real M-Pesa STK prompt was approved.

## 3. Successful Payment Reconciliation

The deployed Payments service queried Daraja for the transaction.

Daraja returned:

- `ResponseCode: 0`
- `ResultCode: 0`
- `ResultDesc: The service request is processed successfully.`

Application payment state:

- `state: confirmed`
- `reconciled: true`
- `state_changed: false`

A second query returned the same terminal `confirmed` state with
`state_changed: false`, demonstrating safe terminal-state replay.

## 4. Known POS State Propagation Gap

After Payments confirmed the transaction, the corresponding POS sale was
queried again.

Payments state:

`confirmed`

POS sale state:

`pending_payment`

This demonstrates a known integration gap: successful payment state is not
currently propagated from Payments back into the POS sale state.

The successful Daraja payment itself was independently confirmed by the
Payments service.

## 5. Daily Close / Commission

A daily close was submitted to the deployed Commission service.

Input used a 100% commission rate for this isolated KES 1 integration test so
the resulting payout would remain exactly KES 1.

Commission produced:

- Total sales: 100 minor units
- Commission: 100 minor units
- Currency: KES
- Payout state: `requested`

## 6. Commission -> Payments -> Daraja B2C

Payments CloudWatch logs confirmed that the Commission request reached
Payments and Payments called the Daraja B2C endpoint.

Daraja returned HTTP 200 with:

- `ResponseCode: 0`
- `ResponseDescription: Accept the service request successfully.`

This proves the live integration path:

Commission -> internal ALB -> Payments -> Daraja B2C

This evidence demonstrates B2C request acceptance by Daraja. It does not claim
that the asynchronous B2C result callback confirmed final recipient settlement.

## 7. Daily-Close Idempotency

The identical daily close was replayed.

The Commission service returned the same ledger and the same idempotency key.

CloudWatch Payments logs were checked from immediately before the replay.

Result:

`B2C events after replay: 0`

Therefore replaying the same close did not trigger another B2C request.

## 8. Evidence Limitations

Two architectural limitations were observed during this live verification:

1. Payments does not currently propagate confirmed payment state back to POS,
   so the POS sale remains `pending_payment`.
2. Commission currently accepts caller-supplied sales for close processing and
   does not independently verify that each supplied sale has a confirmed paid
   state.

Therefore the Commission/B2C test is recorded as an isolated live integration
proof rather than claiming a fully coupled POS-paid-to-commission workflow.

No callbacks or provider responses were forged during this verification.
