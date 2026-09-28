// Payments service — G1 golden-path stub, extended with Daraja OAuth.
package main

import (
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

// tokenDebugHandler is temporary — confirms OAuth works end to end.
// Remove once STK Push is using getToken() directly.
func tokenDebugHandler(auth *darajaAuth) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, err := auth.getToken()
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("token acquired: " + token[:10] + "...\n"))
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

	auth := newDarajaAuth()

	mux := http.NewServeMux()
	mux.HandleFunc("/", ok(name+": ok"))
	mux.HandleFunc("/health", ok("healthy"))
	mux.HandleFunc("/ready", ok("ready"))
	mux.HandleFunc("/debug/token", tokenDebugHandler(auth))

	log.Printf("%s listening on :%s", name, port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}