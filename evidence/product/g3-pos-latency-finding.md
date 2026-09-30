# G3 — POS p95 Latency Finding

Flagged in the all-gates review: "POS worst observed p95 ~3.86s
breaches the 400ms target (most likely the synchronous Daraja wait)."

## Root cause

POS's `/sales/{id}/payment` endpoint calls Payments' `/payments`
endpoint synchronously and waits for its response before returning to
the caller. Payments' own STK Push handler, in turn, makes a real
network call to Daraja (sandbox or fake adapter) and waits for that
response too. This chains two synchronous HTTP calls, the outer one
(POS) inheriting the full latency of the inner one (Payments' Daraja
round-trip) plus its own overhead.

Against the real Daraja sandbox specifically, STK Push initiation
itself can take anywhere from under a second to several seconds
depending on Safaricom's sandbox load — this is exactly the kind of
external dependency latency that a synchronous chain fully absorbs
into the caller's own response time.

## Why this wasn't caught earlier

Every k6 capacity test run tonight (including the new money-path test,
`evidence/payments/g3-money-path-k6.md`) uses the deterministic fake
Daraja adapter, which responds in low single-digit milliseconds. The
p95 breach the review found came from real sandbox latency, which the
fake adapter — correctly, per the brief's requirement to never
load-test the real sandbox — does not reproduce. This is a real gap
between what local/fake-adapter testing can show and what the live
sandbox actually costs POS's response time.

## What would actually fix it (not implemented tonight)

POS's payment-initiation endpoint would need to become asynchronous:
accept the sale/payment request, return immediately with a `pending`
state, and let the client poll (or receive a webhook/event) for the
eventual STK Push outcome — rather than blocking the HTTP response on
Payments' full Daraja round-trip. This is a real architectural change
to POS, not a quick fix, and is out of scope to implement this close
to submission.

## Ownership

This finding spans two services: POS's synchronous call pattern
(Consolate's area) and Payments' STK Push latency, which is inherent
to Daraja itself, not something Payments' own code controls. Documented
here rather than in a single owner's evidence folder, since fixing it
requires a joint architectural decision, not a one-line patch.