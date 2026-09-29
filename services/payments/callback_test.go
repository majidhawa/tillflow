package main

import "testing"

// TestApplyCallback_ProviderDeclined verifies that a genuine user
// cancellation (ResultCode 1032) is classified as failed — a real
// decline, distinct from timed_out (1037, no response) and uncertain
// (any other non-zero code).
func TestApplyCallback_ProviderDeclined(t *testing.T) {
	store := newCallbackStore()
	payment := &paymentResponse{
		PaymentID:   "pay_test_declined",
		SaleID:      "sale_test",
		State:       "pending",
		AmountMinor: 100,
		Currency:    "KES",
	}
	store.registerPending("checkout_declined", payment)

	result, changed := store.applyCallback("checkout_declined", 1032)

	if !changed {
		t.Fatal("expected applyCallback to report a state change on first call")
	}
	if result.State != "failed" {
		t.Errorf("expected state 'failed' for ResultCode 1032, got %q", result.State)
	}
}

// TestApplyCallback_Timeout verifies 1037 is classified as timed_out,
// not failed — a timeout is not equivalent to a decline.
func TestApplyCallback_Timeout(t *testing.T) {
	store := newCallbackStore()
	payment := &paymentResponse{PaymentID: "pay_test_timeout", State: "pending"}
	store.registerPending("checkout_timeout", payment)

	result, _ := store.applyCallback("checkout_timeout", 1037)

	if result.State != "timed_out" {
		t.Errorf("expected state 'timed_out' for ResultCode 1037, got %q", result.State)
	}
}

// TestApplyCallback_Success verifies ResultCode 0 confirms the payment.
func TestApplyCallback_Success(t *testing.T) {
	store := newCallbackStore()
	payment := &paymentResponse{PaymentID: "pay_test_success", State: "pending"}
	store.registerPending("checkout_success", payment)

	result, _ := store.applyCallback("checkout_success", 0)

	if result.State != "confirmed" {
		t.Errorf("expected state 'confirmed' for ResultCode 0, got %q", result.State)
	}
}

// TestApplyCallback_Idempotent verifies a duplicate/reordered callback
// for an already-terminal payment is a safe no-op — the second call
// must not change state or report a change.
func TestApplyCallback_Idempotent(t *testing.T) {
	store := newCallbackStore()
	payment := &paymentResponse{PaymentID: "pay_test_idempotent", State: "pending"}
	store.registerPending("checkout_idempotent", payment)

	_, firstChanged := store.applyCallback("checkout_idempotent", 1032)
	result, secondChanged := store.applyCallback("checkout_idempotent", 0) // even a different code

	if !firstChanged {
		t.Fatal("expected first callback to change state")
	}
	if secondChanged {
		t.Error("expected second callback on already-terminal payment to report no change")
	}
	if result.State != "failed" {
		t.Errorf("expected state to remain 'failed' from first callback, got %q", result.State)
	}
}

// TestApplyCallback_DuplicateCallback verifies that the exact same
// callback body, delivered twice (Daraja's documented at-least-once
// delivery behavior), does not double-process — the payment must reach
// its terminal state exactly once, and the second delivery must report
// no change.
func TestApplyCallback_DuplicateCallback(t *testing.T) {
	store := newCallbackStore()
	payment := &paymentResponse{PaymentID: "pay_dup", State: "pending"}
	store.registerPending("checkout_dup", payment)

	first, firstChanged := store.applyCallback("checkout_dup", 0)
	second, secondChanged := store.applyCallback("checkout_dup", 0) // identical callback, delivered again

	if !firstChanged {
		t.Fatal("expected first delivery to change state")
	}
	if secondChanged {
		t.Error("expected duplicate delivery to report no change")
	}
	if first.State != "confirmed" || second.State != "confirmed" {
		t.Errorf("expected both to show state 'confirmed', got first=%q second=%q", first.State, second.State)
	}
}

// TestApplyCallback_ReorderedCallback verifies that callbacks arriving
// out of order — a timeout arriving after the payment was already
// confirmed by an earlier callback — does not overwrite the earlier,
// correct terminal state with a stale, later-arriving result.
func TestApplyCallback_ReorderedCallback(t *testing.T) {
	store := newCallbackStore()
	payment := &paymentResponse{PaymentID: "pay_reordered", State: "pending"}
	store.registerPending("checkout_reordered", payment)

	// The confirmation arrives first...
	confirmed, confirmedChanged := store.applyCallback("checkout_reordered", 0)
	// ...then a stale timeout callback for the same transaction arrives
	// late, out of order.
	stale, staleChanged := store.applyCallback("checkout_reordered", 1037)

	if !confirmedChanged {
		t.Fatal("expected the first (confirmation) callback to change state")
	}
	if staleChanged {
		t.Error("expected the stale, reordered callback to report no change")
	}
	if confirmed.State != "confirmed" {
		t.Errorf("expected state 'confirmed' after first callback, got %q", confirmed.State)
	}
	if stale.State != "confirmed" {
		t.Errorf("expected state to REMAIN 'confirmed' despite stale reordered timeout, got %q", stale.State)
	}
}