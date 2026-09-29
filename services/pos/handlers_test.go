package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func testServer() *server {
	return &server{
		store: newStore(),
	}
}

func performJSONRequest(t *testing.T, s *server, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()

	payload, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("failed to marshal request: %v", err)
	}

	req := httptest.NewRequest(
		method,
		path,
		bytes.NewReader(payload),
	)

	req.Header.Set("Content-Type", "application/json")

	recorder := httptest.NewRecorder()

	switch path {
	case "/tenants":
		s.createTenant(recorder, req)
	case "/tills":
		s.createTill(recorder, req)
	case "/attendants":
		s.createAttendant(recorder, req)
	case "/sales":
		s.createSale(recorder, req)
	default:
		t.Fatalf("unsupported test path: %s", path)
	}

	return recorder
}

func TestCreateSaleGoldenPath(t *testing.T) {
	s := testServer()

	tenantResponse := performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/tenants",
		createTenantRequest{
			ID:             "tenant-001",
			Name:           "Demo Shop",
			CommissionRate: 5,
		},
	)

	if tenantResponse.Code != http.StatusCreated {
		t.Fatalf("expected tenant creation status %d, got %d",
			http.StatusCreated,
			tenantResponse.Code,
		)
	}

	tillResponse := performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/tills",
		createTillRequest{
			ID:       "till-001",
			TenantID: "tenant-001",
			Name:     "Main Till",
		},
	)

	if tillResponse.Code != http.StatusCreated {
		t.Fatalf("expected till creation status %d, got %d",
			http.StatusCreated,
			tillResponse.Code,
		)
	}

	attendantResponse := performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/attendants",
		createAttendantRequest{
			ID:       "attendant-001",
			TenantID: "tenant-001",
			Name:     "Jane",
			Role:     "attendant",
		},
	)

	if attendantResponse.Code != http.StatusCreated {
		t.Fatalf("expected attendant creation status %d, got %d",
			http.StatusCreated,
			attendantResponse.Code,
		)
	}

	saleRequest := createSaleRequest{
		ID:             "sale-001",
		TenantID:       "tenant-001",
		TillID:         "till-001",
		AttendantID:    "attendant-001",
		Currency:       "KES",
		IdempotencyKey: "sale-001-request",
		Items: []SaleItem{
			{
				ProductID:  "product-001",
				Name:       "Coffee",
				Quantity:   2,
				UnitAmount: 15000,
			},
			{
				ProductID:  "product-002",
				Name:       "Cake",
				Quantity:   1,
				UnitAmount: 25000,
			},
		},
	}

	firstResponse := performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/sales",
		saleRequest,
	)

	if firstResponse.Code != http.StatusCreated {
		t.Fatalf("expected first sale status %d, got %d",
			http.StatusCreated,
			firstResponse.Code,
		)
	}

	var firstSale Sale

	if err := json.NewDecoder(firstResponse.Body).Decode(&firstSale); err != nil {
		t.Fatalf("failed to decode first sale: %v", err)
	}

	expectedTotal := int64(55000)

	if firstSale.AmountMinor != expectedTotal {
		t.Fatalf(
			"expected sale total %d, got %d",
			expectedTotal,
			firstSale.AmountMinor,
		)
	}

	if firstSale.Status != "pending_payment" {
		t.Fatalf(
			"expected sale status pending_payment, got %s",
			firstSale.Status,
		)
	}

	if len(firstSale.Items) != 2 {
		t.Fatalf(
			"expected 2 sale items, got %d",
			len(firstSale.Items),
		)
	}

	secondResponse := performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/sales",
		saleRequest,
	)

	if secondResponse.Code != http.StatusOK {
		t.Fatalf(
			"expected idempotent retry status %d, got %d",
			http.StatusOK,
			secondResponse.Code,
		)
	}

	var secondSale Sale

	if err := json.NewDecoder(secondResponse.Body).Decode(&secondSale); err != nil {
		t.Fatalf("failed to decode retry sale: %v", err)
	}

	if secondSale.ID != firstSale.ID {
		t.Fatalf(
			"expected retry to return sale %s, got %s",
			firstSale.ID,
			secondSale.ID,
		)
	}

	if secondSale.AmountMinor != firstSale.AmountMinor {
		t.Fatalf(
			"expected retry amount %d, got %d",
			firstSale.AmountMinor,
			secondSale.AmountMinor,
		)
	}

	if secondSale.IdempotencyKey != firstSale.IdempotencyKey {
		t.Fatalf(
			"expected same idempotency key %s, got %s",
			firstSale.IdempotencyKey,
			secondSale.IdempotencyKey,
		)
	}
}

func TestCreateSaleRejectsCrossTenantTill(t *testing.T) {
	s := testServer()

	performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/tenants",
		createTenantRequest{
			ID:             "tenant-001",
			Name:           "Tenant One",
			CommissionRate: 5,
		},
	)

	performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/tenants",
		createTenantRequest{
			ID:             "tenant-002",
			Name:           "Tenant Two",
			CommissionRate: 10,
		},
	)

	performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/tills",
		createTillRequest{
			ID:       "till-002",
			TenantID: "tenant-002",
			Name:     "Tenant Two Till",
		},
	)

	performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/attendants",
		createAttendantRequest{
			ID:       "attendant-001",
			TenantID: "tenant-001",
			Name:     "Jane",
			Role:     "attendant",
		},
	)

	response := performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/sales",
		createSaleRequest{
			ID:             "sale-cross-tenant",
			TenantID:       "tenant-001",
			TillID:         "till-002",
			AttendantID:    "attendant-001",
			Currency:       "KES",
			IdempotencyKey: "cross-tenant-request",
			Items: []SaleItem{
				{
					ProductID:  "product-001",
					Name:       "Coffee",
					Quantity:   1,
					UnitAmount: 10000,
				},
			},
		},
	)

	if response.Code != http.StatusBadRequest {
		t.Fatalf(
			"expected cross-tenant sale to return %d, got %d",
			http.StatusBadRequest,
			response.Code,
		)
	}
}

func TestCreateSaleRejectsInvalidQuantity(t *testing.T) {
	s := testServer()

	performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/tenants",
		createTenantRequest{
			ID:             "tenant-001",
			Name:           "Demo Shop",
			CommissionRate: 5,
		},
	)

	performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/tills",
		createTillRequest{
			ID:       "till-001",
			TenantID: "tenant-001",
			Name:     "Main Till",
		},
	)

	performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/attendants",
		createAttendantRequest{
			ID:       "attendant-001",
			TenantID: "tenant-001",
			Name:     "Jane",
			Role:     "attendant",
		},
	)

	response := performJSONRequest(
		t,
		s,
		http.MethodPost,
		"/sales",
		createSaleRequest{
			ID:             "sale-invalid",
			TenantID:       "tenant-001",
			TillID:         "till-001",
			AttendantID:    "attendant-001",
			Currency:       "KES",
			IdempotencyKey: "invalid-sale-request",
			Items: []SaleItem{
				{
					ProductID:  "product-001",
					Name:       "Coffee",
					Quantity:   0,
					UnitAmount: 10000,
				},
			},
		},
	)

	if response.Code != http.StatusBadRequest {
		t.Fatalf(
			"expected invalid quantity to return %d, got %d",
			http.StatusBadRequest,
			response.Code,
		)
	}
}
