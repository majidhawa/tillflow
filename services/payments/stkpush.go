package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"
)

// stkPushRequest is what POS sends us to initiate a payment, matching
// the sale/payment contract in docs/contracts/sale-payment.md.
type stkPushRequest struct {
	SaleID         string `json:"sale_id"`
	TenantID       string `json:"tenant_id"`
	TillID         string `json:"till_id"`
	AmountMinor    int64  `json:"amount_minor"`
	Currency       string `json:"currency"`
	PhoneNumber    string `json:"phone_number"`
	IdempotencyKey string `json:"idempotency_key"`
}

// paymentResponse is what we hand back to POS.
type paymentResponse struct {
	PaymentID   string `json:"payment_id"`
	SaleID      string `json:"sale_id"`
	State       string `json:"state"`
	AmountMinor int64  `json:"amount_minor"`
	Currency    string `json:"currency"`
}

// darajaSTKPushRequest is the shape Daraja expects on the wire.
type darajaSTKPushRequest struct {
	BusinessShortCode string `json:"BusinessShortCode"`
	Password          string `json:"Password"`
	Timestamp         string `json:"Timestamp"`
	TransactionType   string `json:"TransactionType"`
	Amount            int64  `json:"Amount"`
	PartyA            string `json:"PartyA"`
	PartyB            string `json:"PartyB"`
	PhoneNumber       string `json:"PhoneNumber"`
	CallBackURL       string `json:"CallBackURL"`
	AccountReference  string `json:"AccountReference"`
	TransactionDesc   string `json:"TransactionDesc"`
}

type darajaSTKPushResponse struct {
	MerchantRequestID   string `json:"MerchantRequestID"`
	CheckoutRequestID   string `json:"CheckoutRequestID"`
	ResponseCode        string `json:"ResponseCode"`
	ResponseDescription string `json:"ResponseDescription"`
	CustomerMessage     string `json:"CustomerMessage"`
}

// paymentStore is a minimal in-memory store keyed by idempotency key,
// so a retried initiation request returns the existing payment instead
// of creating a duplicate. Swap for Postgres once RDS is live — the
// interface (get/put by idempotency key) stays the same.
type paymentStore struct {
	mu               sync.Mutex
	byIdempotencyKey map[string]*paymentResponse
}

func newPaymentStore() *paymentStore {
	return &paymentStore{byIdempotencyKey: make(map[string]*paymentResponse)}
}

func (s *paymentStore) get(idempotencyKey string) (*paymentResponse, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.byIdempotencyKey[idempotencyKey]
	return p, ok
}

func (s *paymentStore) put(idempotencyKey string, p *paymentResponse) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.byIdempotencyKey[idempotencyKey] = p
}

// stkPushHandler initiates an STK Push for a sale. Idempotent: a retry
// with the same idempotency_key returns the existing payment rather
// than triggering a second STK prompt.
func stkPushHandler(auth *darajaAuth, store *paymentStore, callbacks *callbackStore, cfg stkPushConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, span := tracer.Start(r.Context(), "stk_push")
		defer span.End()
		traceID, spanID := spanAttrs(ctx)

		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var req stkPushRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid request body: "+err.Error(), http.StatusBadRequest)
			return
		}

		if req.IdempotencyKey == "" || req.SaleID == "" || req.AmountMinor <= 0 || req.PhoneNumber == "" {
			http.Error(w, "missing required fields", http.StatusBadRequest)
			return
		}

		// Idempotent retry: same key returns the same payment, no second STK prompt.
		if existing, ok := store.get(req.IdempotencyKey); ok {
			writeJSON(w, http.StatusOK, existing)
			return
		}

		token, err := auth.getToken()
		if err != nil {
			http.Error(w, "auth failed: "+err.Error(), http.StatusBadGateway)
			return
		}

		timestamp := time.Now().Format("20060102150405")
		password := base64.StdEncoding.EncodeToString(
			[]byte(cfg.shortcode + cfg.passkey + timestamp),
		)

		darajaReq := darajaSTKPushRequest{
			BusinessShortCode: cfg.shortcode,
			Password:          password,
			Timestamp:         timestamp,
			TransactionType:   "CustomerPayBillOnline",
			Amount:            req.AmountMinor / 100, // Daraja sandbox expects whole KES, not minor units
			PartyA:            req.PhoneNumber,
			PartyB:            cfg.shortcode,
			PhoneNumber:       req.PhoneNumber,
			CallBackURL:       cfg.callbackURL,
			AccountReference:  req.SaleID,
			TransactionDesc:   "TillFlow sale " + req.SaleID,
		}

		body, err := json.Marshal(darajaReq)
		if err != nil {
			http.Error(w, "failed to build daraja request: "+err.Error(), http.StatusInternalServerError)
			return
		}

		httpReq, err := http.NewRequest(
			http.MethodPost,
			cfg.baseURL+"/mpesa/stkpush/v1/processrequest",
			bytes.NewReader(body),
		)
		if err != nil {
			http.Error(w, "failed to build request: "+err.Error(), http.StatusInternalServerError)
			return
		}
		httpReq.Header.Set("Authorization", "Bearer "+token)
		httpReq.Header.Set("Content-Type", "application/json")

		resp, err := http.DefaultClient.Do(httpReq)
		if err != nil {
			http.Error(w, "daraja request failed: "+err.Error(), http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()

		var darajaResp darajaSTKPushResponse
		if err := json.NewDecoder(resp.Body).Decode(&darajaResp); err != nil {
			http.Error(w, "failed to decode daraja response: "+err.Error(), http.StatusBadGateway)
			return
		}

		// ResponseCode "0" means Daraja accepted the request and will push
		// the prompt. It does NOT mean the payment is confirmed — that only
		// happens via callback, which is the next piece to build.
		state := "pending"
		if darajaResp.ResponseCode != "0" {
			state = "failed"
		}

		payment := &paymentResponse{
			PaymentID:   fmt.Sprintf("pay_%s", darajaResp.CheckoutRequestID),
			SaleID:      req.SaleID,
			State:       state,
			AmountMinor: req.AmountMinor,
			Currency:    req.Currency,
		}

		store.put(req.IdempotencyKey, payment)
		callbacks.registerPending(darajaResp.CheckoutRequestID, payment)
		log.Printf("stk_push: payment=%s sale_id=%s state=%s trace_id=%s span_id=%s",
			payment.PaymentID, payment.SaleID, payment.State, traceID, spanID)
		writeJSON(w, http.StatusOK, payment)
	}
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// stkPushConfig holds the Daraja-specific settings needed for STK Push,
// separate from OAuth so each piece stays independently testable.
type stkPushConfig struct {
	baseURL     string
	shortcode   string
	passkey     string
	callbackURL string
}	