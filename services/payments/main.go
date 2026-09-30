// Payments service — Daraja OAuth, STK Push, callback handling,
// transaction status query, and B2C payouts.
package main

import (
	"context"
	"log"
	"net/http"
	"os"
)

func ok(body string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(body + "\n"))
	}
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	name := os.Getenv("SERVICE_NAME")
	if name == "" {
		name = "unknown"
	}

	shutdown, err := setupTracing(name)
	if err != nil {
		log.Fatalf("failed to set up tracing: %v", err)
	}
	defer shutdown(context.Background())

	auth := newDarajaAuth()
	store := newPaymentStore()
	callbacks := newCallbackStore()
	cfg := stkPushConfig{
		baseURL:     os.Getenv("DARAJA_BASE_URL"),
		shortcode:   os.Getenv("DARAJA_SHORTCODE"),
		passkey:     os.Getenv("DARAJA_PASSKEY"),
		callbackURL: os.Getenv("DARAJA_CALLBACK_URL"),
	}

	payouts := newPayoutStore()
	b2cCfg := b2cConfig{
		baseURL:            os.Getenv("DARAJA_BASE_URL"),
		initiatorName:      os.Getenv("DARAJA_INITIATOR_NAME"),
		securityCredential: os.Getenv("DARAJA_B2C_SECURITY_CREDENTIAL"),
		shortcode:          os.Getenv("DARAJA_B2C_SHORTCODE"),
		resultURL:          os.Getenv("DARAJA_B2C_RESULT_URL"),
		timeoutURL:         os.Getenv("DARAJA_B2C_TIMEOUT_URL"),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", ok(name+": ok"))
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "simulated failure for G4 broken-release drill (v2 - actually deployed this time)", http.StatusInternalServerError)
	})
	mux.HandleFunc("/ready", ok("ready"))
	mux.HandleFunc("/payments", stkPushHandler(auth, store, callbacks, cfg))
	mux.HandleFunc("/payments/callback", callbackHandler(callbacks))
	mux.HandleFunc("/payments/query", queryHandler(auth, callbacks, cfg))
	mux.HandleFunc("/payments/b2c", b2cHandler(auth, payouts, b2cCfg))
	mux.HandleFunc("/payments/b2c/callback", b2cCallbackHandler(payouts))
	mux.HandleFunc("/payments/b2c/timeout", b2cTimeoutHandler())

	log.Printf("%s listening on :%s", name, port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}