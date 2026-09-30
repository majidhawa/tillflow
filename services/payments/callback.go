package main

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
)

// darajaCallbackBody mirrors the exact shape Daraja sends to the
// callback URL after an STK Push completes (success or failure).
type darajaCallbackBody struct {
	Body struct {
		StkCallback struct {
			MerchantRequestID string `json:"MerchantRequestID"`
			CheckoutRequestID string `json:"CheckoutRequestID"`
			ResultCode        int    `json:"ResultCode"`
			ResultDesc        string `json:"ResultDesc"`
			CallbackMetadata  struct {
				Item []struct {
					Name  string      `json:"Name"`
					Value interface{} `json:"Value"`
				} `json:"Item"`
			} `json:"CallbackMetadata"`
		} `json:"stkCallback"`
	} `json:"Body"`
}

// callbackStore tracks payments by CheckoutRequestID so the callback
// handler can find the pending payment it belongs to, and tracks which
// CheckoutRequestIDs have already been processed to terminal state —
// this second part is what makes duplicate/reordered callbacks safe.
type callbackStore struct {
	mu                sync.Mutex
	byCheckoutID      map[string]*paymentResponse
	processedTerminal map[string]bool
}

func newCallbackStore() *callbackStore {
	return &callbackStore{
		byCheckoutID:      make(map[string]*paymentResponse),
		processedTerminal: make(map[string]bool),
	}
}

// registerPending links a CheckoutRequestID to its payment record, so the
// callback handler can find it later. Called right after STK Push accepts.
func (c *callbackStore) registerPending(checkoutID string, p *paymentResponse) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.byCheckoutID[checkoutID] = p
}

// applyCallback idempotently transitions a payment to its terminal state.
// If this CheckoutRequestID was already processed to a terminal state,
// this is a no-op — protects against duplicate and reordered callbacks.
// Returns the payment and whether this call actually caused a change.
func (c *callbackStore) applyCallback(checkoutID string, resultCode int) (*paymentResponse, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	payment, found := c.byCheckoutID[checkoutID]
	if !found {
		return nil, false
	}

	// Already terminal — duplicate or reordered callback, ignore.
	if c.processedTerminal[checkoutID] {
		return payment, false
	}

	switch resultCode {
	case 0:
		payment.State = "confirmed"
	case 1037:
		// "DS timeout user cannot be reached" — the STK prompt was never
		// answered. This is NOT a decline; the true outcome is unknown
		// until reconciliation queries Daraja directly.
		payment.State = "timed_out"
	case 1032:
		// User explicitly cancelled/declined the prompt — this IS a
		// genuine decline, safe to mark failed.
		payment.State = "failed"
	default:
		// Any other non-zero code: treat conservatively as uncertain
		// rather than assuming failure, until reconciliation confirms.
		payment.State = "uncertain"
	}
	c.processedTerminal[checkoutID] = true

	return payment, true
}

// callbackHandler processes Daraja's STK callback. Always returns 200 to
// Daraja regardless of outcome — Daraja retries on non-200, and retrying
// doesn't help us here since our own idempotency already handles repeats.
func callbackHandler(store *callbackStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, span := tracer.Start(r.Context(), "stk_callback")
		defer span.End()
		traceID, spanID := spanAttrs(ctx)
		_ = traceID
		_ = spanID

		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var body darajaCallbackBody
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			log.Printf("callback: failed to decode body: %v", err)
			writeJSON(w, http.StatusOK, map[string]string{"ResultDesc": "invalid body, ignored"})
			return
		}

		cb := body.Body.StkCallback
		payment, changed := store.applyCallback(cb.CheckoutRequestID, cb.ResultCode)

		if payment == nil {
			log.Printf("callback: unknown CheckoutRequestID %s, ignoring", cb.CheckoutRequestID)
				} else if changed {
			log.Printf("callback: payment %s transitioned to %s (checkout_id=%s, result_code=%d, result_desc=%q, trace_id=%s, span_id=%s)",
				payment.PaymentID, payment.State, cb.CheckoutRequestID, cb.ResultCode, cb.ResultDesc, traceID, spanID)
		} else {
			log.Printf("callback: duplicate/reordered callback for checkout_id=%s, already terminal, ignored",
				cb.CheckoutRequestID)
		}

		// Daraja just wants acknowledgement — the real result lives in our own state.
		writeJSON(w, http.StatusOK, map[string]string{"ResultDesc": "accepted"})
	}
}