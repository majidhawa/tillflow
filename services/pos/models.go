package main

import "time"

type Tenant struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	CommissionRate int64     `json:"commission_rate"`
	CreatedAt      time.Time `json:"created_at"`
}

type Till struct {
	ID        string    `json:"id"`
	TenantID  string    `json:"tenant_id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

type Attendant struct {
	ID        string    `json:"id"`
	TenantID  string    `json:"tenant_id"`
	Name      string    `json:"name"`
	Role      string    `json:"role"`
	CreatedAt time.Time `json:"created_at"`
}

type SaleItem struct {
	ID         string `json:"id"`
	SaleID     string `json:"sale_id"`
	ProductID  string `json:"product_id"`
	Name       string `json:"name"`
	Quantity   int64  `json:"quantity"`
	UnitAmount int64  `json:"unit_amount_minor"`
	Total      int64  `json:"total_minor"`
}

type Sale struct {
	ID             string     `json:"id"`
	TenantID       string     `json:"tenant_id"`
	TillID         string     `json:"till_id"`
	AttendantID    string     `json:"attendant_id"`
	Items          []SaleItem `json:"items"`
	AmountMinor    int64      `json:"amount_minor"`
	Currency       string     `json:"currency"`
	Status         string     `json:"status"`
	IdempotencyKey string     `json:"idempotency_key"`
	CreatedAt      time.Time  `json:"created_at"`
}
