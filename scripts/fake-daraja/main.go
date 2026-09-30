// Fake Daraja server — deterministic M-Pesa sandbox stand-in for load
// testing. Per the capstone brief: "CI and k6 must use a deterministic
// fake adapter — never real money or customer data." This mimics the
// exact JSON shapes services/payments/*.go already expects from the
// real Daraja sandbox, so no payments code changes are needed — only
// DARAJA_BASE_URL needs to point here instead.
package main
import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"
)


type stkState struct {
	merchantRequestID string
	checkoutRequestID string
	callbackURL       string
	accountReference  string
}

var (
	mu        sync.Mutex
	stkByID   = make(map[string]*stkState)
	counter   = 0
)

func nextID(prefix string) string {
	mu.Lock()
	defer mu.Unlock()
	counter++
	return fmt.Sprintf("%s_%d_%d", prefix, time.Now().UnixNano(), counter)
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

// oauthHandler mimics Daraja's token endpoint — always succeeds.
func oauthHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{
		"access_token": "fake-token-" + nextID("tok"),
		"expires_in":   "3599",
	})
}

// stkPushHandler mimics Daraja's STK Push endpoint. Always accepts,
// then fires a deterministic success callback shortly after — the
// same async pattern the real sandbox uses.
func stkPushHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		CallBackURL      string `json:"CallBackURL"`
		AccountReference string `json:"AccountReference"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	merchantID := nextID("merchant")
	checkoutID := nextID("ws_CO")

	mu.Lock()
	stkByID[checkoutID] = &stkState{
		merchantRequestID: merchantID,
		checkoutRequestID: checkoutID,
		callbackURL:       req.CallBackURL,
		accountReference:  req.AccountReference,
	}
	mu.Unlock()

	writeJSON(w, map[string]string{
		"MerchantRequestID":   merchantID,
		"CheckoutRequestID":   checkoutID,
		"ResponseCode":        "0",
		"ResponseDescription": "Success. Request accepted for processing",
		"CustomerMessage":     "Success. Request accepted for processing",
	})

	// Fire the callback asynchronously, deterministically — every STK
	// push here succeeds, so k6 load results reflect real code path
	// performance, not sandbox flakiness.
	go func() {
		time.Sleep(200 * time.Millisecond)
		fireCallback(merchantID, checkoutID, req.CallBackURL)
	}()
}

func fireCallback(merchantID, checkoutID, callbackURL string) {
	body := map[string]interface{}{
		"Body": map[string]interface{}{
			"stkCallback": map[string]interface{}{
				"MerchantRequestID": merchantID,
				"CheckoutRequestID": checkoutID,
				"ResultCode":        0,
				"ResultDesc":        "The service request is processed successfully.",
				"CallbackMetadata": map[string]interface{}{
					"Item": []map[string]interface{}{
						{"Name": "Amount", "Value": 1},
						{"Name": "MpesaReceiptNumber", "Value": nextID("FAKE")},
						{"Name": "PhoneNumber", "Value": 254708374149},
					},
				},
			},
		},
	}
	b, _ := json.Marshal(body)
	resp, err := http.Post(callbackURL, "application/json", bytes.NewReader(b))
	if err != nil {
		log.Printf("fake-daraja: callback POST failed: %v", err)
		return
	}
	defer resp.Body.Close()
}

// queryHandler mimics the transaction status query endpoint — looks
// up whatever STK push was made and reports it as successful.
func queryHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		CheckoutRequestID string `json:"CheckoutRequestID"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)

	mu.Lock()
	state, found := stkByID[req.CheckoutRequestID]
	mu.Unlock()

	merchantID := "unknown"
	if found {
		merchantID = state.merchantRequestID
	}

	writeJSON(w, map[string]string{
		"ResponseCode":        "0",
		"ResponseDescription": "The service request has been accepted successfully",
		"MerchantRequestID":   merchantID,
		"CheckoutRequestID":   req.CheckoutRequestID,
		"ResultCode":          "0",
		"ResultDesc":          "The service request is processed successfully.",
	})
}

// b2cHandler mimics the B2C payout endpoint — always accepts, then
// fires a deterministic success result callback.
func b2cHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ResultURL string `json:"ResultURL"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	conversationID := nextID("AG")
	originatorID := nextID("orig")

	writeJSON(w, map[string]string{
		"ConversationID":           conversationID,
		"OriginatorConversationID": originatorID,
		"ResponseCode":             "0",
		"ResponseDescription":      "Accept the service request successfully.",
	})

	go func() {
		time.Sleep(200 * time.Millisecond)
		body := map[string]interface{}{
			"Result": map[string]interface{}{
				"ConversationID":           conversationID,
				"OriginatorConversationID": originatorID,
				"ResultCode":               0,
				"ResultDesc":               "The service request is processed successfully.",
			},
		}
		b, _ := json.Marshal(body)
		resp, err := http.Post(req.ResultURL, "application/json", bytes.NewReader(b))
		if err != nil {
			log.Printf("fake-daraja: b2c callback POST failed: %v", err)
			return
		}
		defer resp.Body.Close()
	}()
}




func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/oauth/v1/generate", oauthHandler)
	mux.HandleFunc("/mpesa/stkpush/v1/processrequest", stkPushHandler)
	mux.HandleFunc("/mpesa/stkpushquery/v1/query", queryHandler)
	mux.HandleFunc("/mpesa/b2c/v1/paymentrequest", b2cHandler)

	log.Println("fake-daraja listening on :9090")
	log.Fatal(http.ListenAndServe(":9090", mux))
}