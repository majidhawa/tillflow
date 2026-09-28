# G2 — Payment Integrity Evidence

Owner: Glory (Payments + Integrity)
Date: 2026-09-29
Environment: Daraja sandbox, local dev (Go 1.23.4, ngrok tunnel)

## What this covers

Sale to STK Push to callback to confirmed/timed_out, plus reconciliation
and B2C payout initiation, per `docs/contracts/sale-payment.md`.

## 1. OAuth token acquisition

Confirmed working via temporary `/debug/token` endpoint. Real access
token returned from `https://sandbox.safaricom.co.ke/oauth/v1/generate`.

## 2. STK Push - successful initiation

Request:

    curl -X POST localhost:8080/payments \
      -H "Content-Type: application/json" \
      -d '{"sale_id":"sale_001","tenant_id":"tenant_001","till_id":"till_001","amount_minor":100,"currency":"KES","phone_number":"254708374149","idempotency_key":"tenant_001:till_001:sale_001"}'

Response:

    {"payment_id":"pay_ws_CO_290920260017579708374149","sale_id":"sale_001","state":"pending","amount_minor":100,"currency":"KES"}

## 3. Idempotent retry

Same request repeated with identical idempotency_key returned the exact
same payment_id. No duplicate STK prompt, no duplicate charge. Confirms
contract requirement: repeated requests with the same idempotency key
must not create duplicate financial effects.

## 4. Timeout classification, not treated as decline

Sandbox test number 254708374149 does not respond to the STK prompt.
Daraja's callback returned:

    {"ResultCode": 1037, "ResultDesc": "No response from user."}

Server log:

    2026/09/29 01:26:28 callback: payment pay_ws_CO_290920260126013708374149 transitioned to timed_out (checkout_id=ws_CO_290920260126013708374149, result_code=1037, result_desc="No response from user.")

This confirms the contract requirement that a timeout is preserved as
timed_out, not converted to failed. An earlier implementation bug
(treating all non-zero codes as failed) was caught and fixed during
testing, precisely because this distinction matters for real money
correctness.

## 5. Reconciliation of an uncertain/timed-out payment

Querying an already-resolved payment via the transaction status query
endpoint:

    curl "localhost:8080/payments/query?checkout_id=ws_CO_290920260126013708374149"

Response:

    {"reconciled":true,"state_changed":false,"payment":{"payment_id":"pay_ws_CO_290920260126013708374149","sale_id":"sale_011","state":"timed_out","amount_minor":100,"currency":"KES"},"daraja_response":{"ResponseCode":"0","ResultCode":"1037","ResultDesc":"No response from user."}}

state_changed: false confirms reconciliation does not double-process or
corrupt an already-terminal payment. The query and callback paths share
the same idempotent state-transition logic (applyCallback), guaranteeing
they can never disagree.

## 6. B2C payout - initiation and idempotency

Request:

    curl -X POST localhost:8080/payments/b2c \
      -H "Content-Type: application/json" \
      -d '{"payout_id":"payout_001","tenant_id":"tenant_001","phone_number":"254708374149","amount_minor":5000,"currency":"KES","idempotency_key":"tenant_001:payout_001","remarks":"Daily commission"}'

Daraja response (server log):

    {"ConversationID": "AG_20260929_0100100304dxxmatucq8", "ResponseCode": "0", "ResponseDescription": "Accept the service request successfully."}

Response to caller:

    {"payout_id":"payout_001","state":"pending","amount_minor":5000,"currency":"KES"}

Repeating the identical request returned the same response instantly,
with no second call to Daraja logged. Confirms idempotency on the
disbursement path, same as STK Push.

## 7. Commission daily close - tenant isolation, aggregation, and replay-safety

Request (one attendant with two sales under the correct tenant, one sale
deliberately under a different tenant):

    curl -X POST localhost:8081/commission/close \
      -H "Content-Type: application/json" \
      -d '{"tenant_id":"tenant_001","close_date":"2026-09-29","commission_pct":10,"sales":[{"sale_id":"sale_a","tenant_id":"tenant_001","attendant_id":"att_1","attendant_phone":"254708374149","amount_minor":10000,"currency":"KES"},{"sale_id":"sale_b","tenant_id":"tenant_001","attendant_id":"att_1","attendant_phone":"254708374149","amount_minor":5000,"currency":"KES"},{"sale_id":"sale_c","tenant_id":"tenant_002","attendant_id":"att_1","attendant_phone":"254708374149","amount_minor":99999,"currency":"KES"}]}'

Commission service log:

    commission: skipping sale sale_c - tenant mismatch (sale tenant=tenant_002, close tenant=tenant_001)

Response:

    {"close_date":"2026-09-29","ledger":[{"attendant_id":"att_1","close_date":"2026-09-29","total_sales_minor":15000,"commission_minor":1500,"currency":"KES","payout_state":"requested","idempotency_key":"tenant_001:att_1:2026-09-29"}],"tenant_id":"tenant_001"}

This confirms: tenant isolation (sale_c excluded from the total),
correct per-attendant aggregation (15000 = sale_a + sale_b only), and
correct commission math (1500 = 10% of 15000). Payments' log confirmed
the B2C call reached Daraja and was accepted (ResponseCode: 0).

Replay-safety: the identical close request was repeated. The response
was identical and returned instantly, and Payments' log showed no
second B2C call was made - confirming the brief's requirement that
"replay must never double-pay."

## 8. Provider-declined and idempotency unit tests

Since the shared sandbox test number auto-times-out rather than
producing a genuine decline, the following are covered by unit tests
in callback_test.go instead of live sandbox calls:

    go test -v ./...
    === RUN   TestApplyCallback_ProviderDeclined
    --- PASS: TestApplyCallback_ProviderDeclined (0.00s)
    === RUN   TestApplyCallback_Timeout
    --- PASS: TestApplyCallback_Timeout (0.00s)
    === RUN   TestApplyCallback_Success
    --- PASS: TestApplyCallback_Success (0.00s)
    === RUN   TestApplyCallback_Idempotent
    --- PASS: TestApplyCallback_Idempotent (0.00s)
    PASS

These confirm ResultCode 1032 (genuine decline) is classified as
failed, distinct from 1037 (timeout, classified timed_out), and that a
second callback on an already-terminal payment is a safe no-op.

## Known limitations

- B2C result callback: Daraja's B2C result callback did not arrive
  during testing (waited several minutes) against the sandbox's shared
  test shortcode (600000). Initiation was confirmed accepted by Daraja
  (ResponseCode: 0). The result-callback handler (b2cCallbackHandler) is
  implemented with the identical idempotent logic proven against the
  STK Push callback path, but has not been exercised end-to-end against
  a live callback due to sandbox reliability.
- Provider-declined payment (ResultCode 1032, genuine user cancellation)
  has not been exercised against the live sandbox. The shared test
  number auto-times-out rather than declining. The code path exists and
  is unit-testable with a mocked callback body.
- In-memory storage: paymentStore, callbackStore, and payoutStore are
  in-memory only and reset on service restart. This is expected until
  Postgres/RDS is available (per G1 dependency).

## Reproduction

All commands above are copy-pasteable against a running local instance
with valid Daraja sandbox credentials in .env (see .env.example) and an
active ngrok tunnel pointed at port 8080.