# G4 — Recovery Drills: Uncertain Payment & Callback Replay

Owner: Glory (Payments + Integrity)
Date: 2026-09-29
Environment: Daraja sandbox, local dev

These two drills were executed and captured as part of building the
Payments callback and reconciliation logic (see
`evidence/payments/g2-payment-integrity.md` for the original context).
This document reframes that same evidence explicitly against the G4
drill requirements.

## Drill 1: Uncertain payment

**Requirement:** Force a Daraja timeout, keep it pending, query/
reconcile, and prove a retry cannot create another charge.

**Step 1 - force a timeout.** STK Push initiated against the sandbox
test number, which never responds to the prompt:

    curl -X POST localhost:8080/payments \
      -H "Content-Type: application/json" \
      -d '{"sale_id":"sale_011","tenant_id":"tenant_001","till_id":"till_001","amount_minor":100,"currency":"KES","phone_number":"254708374149","idempotency_key":"tenant_001:till_001:sale_011"}'

Response: `{"payment_id":"pay_ws_CO_290920260126013708374149",...,"state":"pending"}`

**Step 2 - the payment is kept pending, not guessed at.** Daraja's
callback eventually arrived with ResultCode 1037 ("No response from
user"). The system classified this as `timed_out`, explicitly NOT
`failed` - an earlier implementation bug (treating all non-zero codes
as failed) was caught and fixed during this exact testing, because a
timeout is not a decline and must not be treated as one:

    2026/09/29 01:26:28 callback: payment pay_ws_CO_290920260126013708374149 transitioned to timed_out (checkout_id=ws_CO_290920260126013708374149, result_code=1037, result_desc="No response from user.")

**Step 3 - query/reconcile.** The transaction status query endpoint
was called directly against Daraja to independently confirm the state:

    curl "localhost:8080/payments/query?checkout_id=ws_CO_290920260126013708374149"

Response: `{"reconciled":true,"state_changed":false,"payment":{...,"state":"timed_out"},...}`

`state_changed: false` proves reconciliation did not overwrite or
reinterpret the already-correct `timed_out` state - it independently
confirmed the same outcome Daraja's callback had already established.

**Step 4 - prove a retry cannot create another charge.** The original
STK Push request was repeated with the identical idempotency key:

    curl -X POST localhost:8080/payments \
      -H "Content-Type: application/json" \
      -d '{"sale_id":"sale_011","tenant_id":"tenant_001","till_id":"till_001","amount_minor":100,"currency":"KES","phone_number":"254708374149","idempotency_key":"tenant_001:till_001:sale_011"}'

The exact same `payment_id` was returned instantly, with no new STK
prompt sent and no new call to Daraja logged - the retry was recognized
as a duplicate of the already-known transaction, not a new charge.

**Result: PASS.** The payment was kept in an honest uncertain/timed-out
state throughout, reconciliation confirmed it independently without
corrupting it, and a retry was proven incapable of creating a second
charge.

## Drill 2: Callback replay

**Requirement:** Replay and reorder callbacks, prove one legal
transition, one ledger effect, and a trace that explains the duplicate.

This is covered by two unit tests in `callback_test.go`, since the
Daraja sandbox does not offer a way to force real duplicate or
reordered callback delivery on demand - these use directly-constructed
callback bodies against the same `applyCallback` logic the live
callback handler uses.

**Duplicate callback (identical callback delivered twice):**

    func TestApplyCallback_DuplicateCallback(t *testing.T) {
        ...
        first, firstChanged := store.applyCallback("checkout_dup", 0)
        second, secondChanged := store.applyCallback("checkout_dup", 0)
        // firstChanged == true, secondChanged == false
        // both first.State and second.State == "confirmed"
    }

Result: PASS. One legal transition (pending -> confirmed) occurred on
the first delivery; the second, duplicate delivery was recognized and
produced no further state change - one ledger effect, not two.

**Reordered callback (a stale timeout arrives after confirmation):**

    func TestApplyCallback_ReorderedCallback(t *testing.T) {
        ...
        confirmed, confirmedChanged := store.applyCallback("checkout_reordered", 0)
        stale, staleChanged := store.applyCallback("checkout_reordered", 1037)
        // confirmedChanged == true, staleChanged == false
        // stale.State remains "confirmed" - NOT overwritten to timed_out
    }

Result: PASS. The correct, earlier-arriving confirmation was not
overwritten by a stale, later-arriving timeout callback for the same
transaction - the system's terminal-state check
(`processedTerminal[checkoutID]`) is what prevents this.

**The trace explaining the duplicate:** every callback, whether it
causes a change or not, is logged with the outcome explicitly stated:

    log.Printf("callback: duplicate/reordered callback for checkout_id=%s, already terminal, ignored", ...)

This line is what a responder or reviewer sees in logs to understand
that a specific checkout_id received more than one callback and why
only the first was acted on.

Test run confirming both drills pass:

    go test -v ./...
    === RUN   TestApplyCallback_DuplicateCallback
    --- PASS: TestApplyCallback_DuplicateCallback (0.00s)
    === RUN   TestApplyCallback_ReorderedCallback
    --- PASS: TestApplyCallback_ReorderedCallback (0.00s)
    PASS

## Scope note

These two drills are Payments + Integrity's ownership per
`docs/ownership.md`. The remaining three G4 drills (platform failure,
broken release, restore) belong to Reliability + Operations and have
not yet been executed by anyone.