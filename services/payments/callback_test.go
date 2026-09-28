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