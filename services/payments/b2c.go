package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"sync"
)

// b2cRequest is what Commission sends us to disburse a payout. Commission
// never calls Daraja directly — this is the only door into B2C, per the
// contract boundary in docs/contracts/sale-payment.md.
type b2cRequest struct {
	PayoutID       string `json:"payout_id"`
	TenantID       string `json:"tenant_id"`
	PhoneNumber    string `json:"phone_number"`
	AmountMinor    int64  `json:"amount_minor"`
	Currency       string `json:"currency"`
	IdempotencyKey string `json:"idempotency_key"`
	Remarks        string `json:"remarks"`
}

type payoutResponse struct {
	PayoutID    string `json:"payout_id"`
	State       string `json:"state"`
	AmountMinor int64  `json:"amount_minor"`
	Currency    string `json:"currency"`
}

// darajaB2CRequest is the shape Daraja's B2C API expects on the wire.
type darajaB2CRequest struct {
	InitiatorName      string `json:"InitiatorName"`
	SecurityCredential string `json:"SecurityCredential"`
	CommandID          string `json:"CommandID"`
	Amount             int64  `json:"Amount"`
	PartyA             string `json:"PartyA"`
	PartyB             string `json:"PartyB"`
	Remarks            string `json:"Remarks"`
	QueueTimeOutURL    string `json:"QueueTimeOutURL"`
	ResultURL          string `json:"ResultURL"`
	Occasion           string `json:"Occasion"`
}

type darajaB2CResponse struct {
	ConversationID           string `json:"ConversationID"`
	OriginatorConversationID string `json:"OriginatorConversationID"`
	ResponseCode             string `json:"ResponseCode"`
	ResponseDescription      string `json:"ResponseDescription"`
}

// b2cConfig holds the B2C-specific Daraja settings, kept separate from
// stkPushConfig since B2C uses a different shortcode and credential type
// (SecurityCredential, not the STK password scheme).
type b2cConfig struct {
	baseURL            string
	initiatorName      string
	securityCredential string
	shortcode          string
	resultURL          string
	timeoutURL         string
}

// payoutStore is keyed by idempotency key, same pattern as paymentStore —
// a retried disbursement request must never pay someone twice.
type payoutStore struct {
	mu               sync.Mutex
	byIdempotencyKey map[string]*payoutResponse
	// byConversationID lets the B2C result callback find the payout it
	// belongs to, mirroring how callbackStore tracks CheckoutRequestID.
	byConversationID map[string]*payoutResponse
	processedTerminal map[string]bool
}

func newPayoutStore() *payoutStore {
	return &payoutStore{
		byIdempotencyKey:  make(map[string]*payoutResponse),
		byConversationID:  make(map[string]*payoutResponse),
		processedTerminal: make(map[string]bool),
	}
}

func (s *payoutStore) get(idempotencyKey string) (*payoutResponse, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.byIdempotencyKey[idempotencyKey]
	return p, ok
}

func (s *payoutStore) registerPending(idempotencyKey, conversationID string, p *payoutResponse) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.byIdempotencyKey[idempotencyKey] = p
	s.byConversationID[conversationID] = p
}

// applyResult idempotently transitions a payout to its terminal state,
// exactly mirroring callbackStore.applyCallback — a duplicate or
// reordered B2C result callback must never double-process a payout.
func (s *payoutStore) applyResult(conversationID string, resultCode int) (*payoutResponse, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	payout, found := s.byConversationID[conversationID]
	if !found {
		return nil, false
	}

	if s.processedTerminal[conversationID] {
		return payout, false
	}

	if resultCode == 0 {
		payout.State = "confirmed"
	} else {
		payout.State = "failed"
	}
	s.processedTerminal[conversationID] = true

	return payout, true
}

// b2cHandler initiates a commission payout. Idempotent: a retry with the
// same idempotency_key returns the existing payout rather than paying
// the attendant twice.
func b2cHandler(auth *darajaAuth, store *payoutStore, cfg b2cConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var req b2cRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid request body: "+err.Error(), http.StatusBadRequest)
			return
		}

		if req.IdempotencyKey == "" || req.PhoneNumber == "" || req.AmountMinor <= 0 {
			http.Error(w, "missing required fields", http.StatusBadRequest)
			return
		}

		if existing, ok := store.get(req.IdempotencyKey); ok {
			writeJSON(w, http.StatusOK, existing)
			return
		}

		token, err := auth.getToken()
		if err != nil {
			http.Error(w, "auth failed: "+err.Error(), http.StatusBadGateway)
			return
		}

		darajaReq := darajaB2CRequest{
			InitiatorName:      cfg.initiatorName,
			SecurityCredential: cfg.securityCredential,
			CommandID:          "BusinessPayment",
			Amount:             req.AmountMinor / 100, // sandbox expects whole KES, not minor units
			PartyA:             cfg.shortcode,
			PartyB:             req.PhoneNumber,
			Remarks:            req.Remarks,
			QueueTimeOutURL:    cfg.timeoutURL,
			ResultURL:          cfg.resultURL,
			Occasion:           "Commission",
		}

		body, err := json.Marshal(darajaReq)
		if err != nil {
			http.Error(w, "failed to build daraja request: "+err.Error(), http.StatusInternalServerError)
			return
		}

		httpReq, err := http.NewRequest(
			http.MethodPost,
			cfg.baseURL+"/mpesa/b2c/v1/paymentrequest",
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

		rawBody, err := io.ReadAll(resp.Body)
		if err != nil {
			http.Error(w, "failed to read daraja response: "+err.Error(), http.StatusBadGateway)
			return
		}
		log.Printf("b2c: raw daraja response (status=%d): %s", resp.StatusCode, string(rawBody))

		var darajaResp darajaB2CResponse
		if err := json.Unmarshal(rawBody, &darajaResp); err != nil {
			http.Error(w, "failed to decode daraja response: "+err.Error(), http.StatusBadGateway)
			return
		}

		state := "pending"
		if darajaResp.ResponseCode != "0" {
			state = "failed"
		}

		payout := &payoutResponse{
			PayoutID:    req.PayoutID,
			State:       state,
			AmountMinor: req.AmountMinor,
			Currency:    req.Currency,
		}

		store.registerPending(req.IdempotencyKey, darajaResp.ConversationID, payout)
		writeJSON(w, http.StatusOK, payout)
	}
}

// b2cCallbackHandler processes Daraja's B2C result callback, using the
// exact same idempotent-transition shape as the STK callback handler.
func b2cCallbackHandler(store *payoutStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rawBody, err := io.ReadAll(r.Body)
		if err != nil {
			log.Printf("b2c callback: failed to read body: %v", err)
			writeJSON(w, http.StatusOK, map[string]string{"ResultDesc": "invalid body, ignored"})
			return
		}
		log.Printf("b2c callback: raw body: %s", string(rawBody))

		var body struct {
			Result struct {
				ConversationID           string `json:"ConversationID"`
				OriginatorConversationID string `json:"OriginatorConversationID"`
				ResultCode               int    `json:"ResultCode"`
				ResultDesc               string `json:"ResultDesc"`
			} `json:"Result"`
		}
		if err := json.Unmarshal(rawBody, &body); err != nil {
			log.Printf("b2c callback: failed to decode: %v", err)
			writeJSON(w, http.StatusOK, map[string]string{"ResultDesc": "invalid body, ignored"})
			return
		}

		payout, changed := store.applyResult(body.Result.ConversationID, body.Result.ResultCode)
		if payout == nil {
			log.Printf("b2c callback: unknown ConversationID %s, ignoring", body.Result.ConversationID)
		} else if changed {
			log.Printf("b2c callback: payout %s transitioned to %s (result_code=%d, result_desc=%q)",
				payout.PayoutID, payout.State, body.Result.ResultCode, body.Result.ResultDesc)
		} else {
			log.Printf("b2c callback: duplicate/reordered callback for conversation_id=%s, already terminal, ignored",
				body.Result.ConversationID)
		}

		writeJSON(w, http.StatusOK, map[string]string{"ResultDesc": "accepted"})
	}
}

// b2cTimeoutHandler handles Daraja's QueueTimeOutURL callback — fired if
// the B2C request itself times out in Daraja's queue (distinct from the
// STK "user didn't respond" timeout; this is a queueing failure).
func b2cTimeoutHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rawBody, _ := io.ReadAll(r.Body)
		log.Printf("b2c timeout: raw body: %s", string(rawBody))
		writeJSON(w, http.StatusOK, map[string]string{"ResultDesc": "accepted"})
	}
}