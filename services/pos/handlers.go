package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type server struct {
	store          *store
	paymentsClient *paymentsClient
}

type createTenantRequest struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	CommissionRate int64  `json:"commission_rate"`
}

type createTillRequest struct {
	ID       string `json:"id"`
	TenantID string `json:"tenant_id"`
	Name     string `json:"name"`
}

type createAttendantRequest struct {
	ID       string `json:"id"`
	TenantID string `json:"tenant_id"`
	Name     string `json:"name"`
	Role     string `json:"role"`
}

type createSaleRequest struct {
	ID             string     `json:"id"`
	TenantID       string     `json:"tenant_id"`
	TillID         string     `json:"till_id"`
	AttendantID    string     `json:"attendant_id"`
	Currency       string     `json:"currency"`
	IdempotencyKey string     `json:"idempotency_key"`
	Items          []SaleItem `json:"items"`
}

func (s *server) createTenant(w http.ResponseWriter, r *http.Request) {
	var req createTenantRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	if strings.TrimSpace(req.ID) == "" ||
		strings.TrimSpace(req.Name) == "" ||
		req.CommissionRate < 0 {
		writeError(w, http.StatusBadRequest, "invalid tenant")
		return
	}

	tenant := &Tenant{
		ID:             req.ID,
		Name:           req.Name,
		CommissionRate: req.CommissionRate,
		CreatedAt:      time.Now().UTC(),
	}

	if err := s.store.createTenant(tenant); err != nil {
		if err == ErrDuplicate {
			writeError(w, http.StatusConflict, "tenant already exists")
			return
		}

		writeError(w, http.StatusInternalServerError, "failed to create tenant")
		return
	}

	writeJSON(w, http.StatusCreated, tenant)
}

func (s *server) createTill(w http.ResponseWriter, r *http.Request) {
	var req createTillRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	if strings.TrimSpace(req.ID) == "" ||
		strings.TrimSpace(req.TenantID) == "" ||
		strings.TrimSpace(req.Name) == "" {
		writeError(w, http.StatusBadRequest, "invalid till")
		return
	}

	till := &Till{
		ID:        req.ID,
		TenantID:  req.TenantID,
		Name:      req.Name,
		CreatedAt: time.Now().UTC(),
	}

	if err := s.store.createTill(till); err != nil {
		switch err {
		case ErrDuplicate:
			writeError(w, http.StatusConflict, "till already exists")
		case ErrNotFound:
			writeError(w, http.StatusNotFound, "tenant not found")
		default:
			writeError(w, http.StatusInternalServerError, "failed to create till")
		}
		return
	}

	writeJSON(w, http.StatusCreated, till)
}

func (s *server) createAttendant(w http.ResponseWriter, r *http.Request) {
	var req createAttendantRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	if strings.TrimSpace(req.ID) == "" ||
		strings.TrimSpace(req.TenantID) == "" ||
		strings.TrimSpace(req.Name) == "" ||
		strings.TrimSpace(req.Role) == "" {
		writeError(w, http.StatusBadRequest, "invalid attendant")
		return
	}

	attendant := &Attendant{
		ID:        req.ID,
		TenantID:  req.TenantID,
		Name:      req.Name,
		Role:      req.Role,
		CreatedAt: time.Now().UTC(),
	}

	if err := s.store.createAttendant(attendant); err != nil {
		switch err {
		case ErrDuplicate:
			writeError(w, http.StatusConflict, "attendant already exists")
		case ErrNotFound:
			writeError(w, http.StatusNotFound, "tenant not found")
		default:
			writeError(w, http.StatusInternalServerError, "failed to create attendant")
		}
		return
	}

	writeJSON(w, http.StatusCreated, attendant)
}

func (s *server) createSale(w http.ResponseWriter, r *http.Request) {
	var req createSaleRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	if strings.TrimSpace(req.ID) == "" ||
		strings.TrimSpace(req.TenantID) == "" ||
		strings.TrimSpace(req.TillID) == "" ||
		strings.TrimSpace(req.AttendantID) == "" ||
		strings.TrimSpace(req.Currency) == "" ||
		strings.TrimSpace(req.IdempotencyKey) == "" ||
		len(req.Items) == 0 {
		writeError(w, http.StatusBadRequest, "invalid sale")
		return
	}

	tenant, exists := s.store.getTenant(req.TenantID)
	if !exists {
		writeError(w, http.StatusNotFound, "tenant not found")
		return
	}

	till, exists := s.store.getTill(req.TillID)
	if !exists {
		writeError(w, http.StatusNotFound, "till not found")
		return
	}

	if till.TenantID != req.TenantID {
		writeError(w, http.StatusBadRequest, "till does not belong to tenant")
		return
	}

	attendant, exists := s.store.getAttendant(req.AttendantID)
	if !exists {
		writeError(w, http.StatusNotFound, "attendant not found")
		return
	}

	if attendant.TenantID != req.TenantID {
		writeError(w, http.StatusBadRequest, "attendant does not belong to tenant")
		return
	}

	var total int64

	for i := range req.Items {
		item := &req.Items[i]

		if strings.TrimSpace(item.ProductID) == "" ||
			strings.TrimSpace(item.Name) == "" ||
			item.Quantity <= 0 ||
			item.UnitAmount <= 0 {
			writeError(w, http.StatusBadRequest, "invalid sale item")
			return
		}

		item.ID = req.ID + "-item-" + strconv.Itoa(i+1)
		item.SaleID = req.ID
		item.Total = item.Quantity * item.UnitAmount

		if item.Total <= 0 {
			writeError(w, http.StatusBadRequest, "invalid item total")
			return
		}

		total += item.Total

		if total <= 0 {
			writeError(w, http.StatusBadRequest, "invalid sale total")
			return
		}
	}

	sale := &Sale{
		ID:             req.ID,
		TenantID:       req.TenantID,
		TillID:         req.TillID,
		AttendantID:    req.AttendantID,
		Items:          req.Items,
		AmountMinor:    total,
		Currency:       req.Currency,
		Status:         "pending_payment",
		IdempotencyKey: req.IdempotencyKey,
		CreatedAt:      time.Now().UTC(),
	}

	createdSale, existing, err := s.store.createSale(sale)
	if err != nil {
		switch err {
		case ErrDuplicate:
			writeError(w, http.StatusConflict, "sale already exists")
		case ErrIdempotencyConflict:
			writeError(w, http.StatusConflict, "idempotency key already used with different sale")
		default:
			writeError(w, http.StatusInternalServerError, "failed to create sale")
		}
		return
	}

	if existing {
		writeJSON(w, http.StatusOK, createdSale)
		return
	}

	_ = tenant

	writeJSON(w, http.StatusCreated, createdSale)
}

func (s *server) getSale(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/sales/")

	if strings.TrimSpace(id) == "" {
		writeError(w, http.StatusBadRequest, "sale id is required")
		return
	}

	sale, exists := s.store.getSale(id)
	if !exists {
		writeError(w, http.StatusNotFound, "sale not found")
		return
	}

	writeJSON(w, http.StatusOK, sale)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)

	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{
		"error": message,
	})
}

func (s *server) createPaymentRequest(w http.ResponseWriter, r *http.Request) {
	saleID := strings.TrimPrefix(r.URL.Path, "/sales/")
	saleID = strings.TrimSuffix(saleID, "/payment")

	if strings.TrimSpace(saleID) == "" {
		writeError(w, http.StatusBadRequest, "sale id is required")
		return
	}

	sale, exists := s.store.getSale(saleID)
	if !exists {
		writeError(w, http.StatusNotFound, "sale not found")
		return
	}

	var req struct {
		PhoneNumber    string `json:"phone_number"`
		IdempotencyKey string `json:"idempotency_key"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	if strings.TrimSpace(req.PhoneNumber) == "" ||
		strings.TrimSpace(req.IdempotencyKey) == "" {
		writeError(w, http.StatusBadRequest, "phone_number and idempotency_key are required")
		return
	}

	paymentRequest := PaymentRequest{
		SaleID:         sale.ID,
		TenantID:       sale.TenantID,
		TillID:         sale.TillID,
		AmountMinor:    sale.AmountMinor,
		Currency:       sale.Currency,
		PhoneNumber:    req.PhoneNumber,
		IdempotencyKey: req.IdempotencyKey,
	}

	payment, err := s.paymentsClient.createPayment(paymentRequest)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, payment)
}
