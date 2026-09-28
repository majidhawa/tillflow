package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strconv"
	"time"
)

// darajaQueryRequest matches the STK Push Query API — checks the status
// of an STK Push we already initiated, keyed by CheckoutRequestID.
type darajaQueryRequest struct {
	BusinessShortCode string `json:"BusinessShortCode"`
	Password          string `json:"Password"`
	Timestamp         string `json:"Timestamp"`
	CheckoutRequestID string `json:"CheckoutRequestID"`
}

type darajaQueryResponse struct {
	ResponseCode        string `json:"ResponseCode"`
	ResponseDescription string `json:"ResponseDescription"`
	MerchantRequestID   string `json:"MerchantRequestID"`
	CheckoutRequestID   string `json:"CheckoutRequestID"`
	ResultCode          string `json:"ResultCode"`
	ResultDesc          string `json:"ResultDesc"`
}

// queryHandler asks Daraja directly for the current status of a
// CheckoutRequestID and, if Daraja has a definitive answer, applies it
// through the exact same idempotent state transition the callback
// handler uses. This is deliberate: reconciliation and the callback
// path must never be allowed to disagree about a payment's state or
// apply conflicting transitions — routing both through applyCallback
// is what guarantees that.
func queryHandler(auth *darajaAuth, callbacks *callbackStore, cfg stkPushConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		checkoutID := r.URL.Query().Get("checkout_id")
		if checkoutID == "" {
			http.Error(w, "checkout_id query param required", http.StatusBadRequest)
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

		queryReq := darajaQueryRequest{
			BusinessShortCode: cfg.shortcode,
			Password:          password,
			Timestamp:         timestamp,
			CheckoutRequestID: checkoutID,
		}

		body, err := json.Marshal(queryReq)
		if err != nil {
			http.Error(w, "failed to build query request: "+err.Error(), http.StatusInternalServerError)
			return
		}

		httpReq, err := http.NewRequest(
			http.MethodPost,
			cfg.baseURL+"/mpesa/stkpushquery/v1/query",
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
			http.Error(w, "daraja query failed: "+err.Error(), http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()

		rawBody, err := io.ReadAll(resp.Body)
		if err != nil {
			http.Error(w, "failed to read daraja response: "+err.Error(), http.StatusBadGateway)
			return
		}
		log.Printf("query: raw daraja response (status=%d): %s", resp.StatusCode, string(rawBody))

		var queryResp darajaQueryResponse
		if err := json.Unmarshal(rawBody, &queryResp); err != nil {
			http.Error(w, "failed to decode daraja response: "+err.Error(), http.StatusBadGateway)
			return
		}

		// ResponseCode != "0" here means the QUERY ITSELF was rejected —
		// most commonly Daraja saying the transaction is still being
		// processed and there's nothing to reconcile yet. That's not an
		// error from our side; it just means "check again later."
		if queryResp.ResponseCode != "0" {
			writeJSON(w, http.StatusOK, map[string]interface{}{
				"reconciled":      false,
				"daraja_response": queryResp,
			})
			return
		}

		resultCode, err := strconv.Atoi(queryResp.ResultCode)
		if err != nil {
			http.Error(w, "unexpected non-numeric ResultCode: "+queryResp.ResultCode, http.StatusBadGateway)
			return
		}

		payment, changed := callbacks.applyCallback(checkoutID, resultCode)

		writeJSON(w, http.StatusOK, map[string]interface{}{
			"reconciled":      true,
			"state_changed":   changed,
			"payment":         payment,
			"daraja_response": queryResp,
		})
	}
}