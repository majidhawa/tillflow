package main

type PaymentRequest struct {
	SaleID         string `json:"sale_id"`
	TenantID       string `json:"tenant_id"`
	TillID         string `json:"till_id"`
	AmountMinor    int64  `json:"amount_minor"`
	Currency       string `json:"currency"`
	PhoneNumber    string `json:"phone_number"`
	IdempotencyKey string `json:"idempotency_key"`
}

type PaymentResponse struct {
	PaymentID   string `json:"payment_id"`
	SaleID      string `json:"sale_id"`
	State       string `json:"state"`
	AmountMinor int64  `json:"amount_minor"`
	Currency    string `json:"currency"`
}
