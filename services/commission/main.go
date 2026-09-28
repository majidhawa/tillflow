// Minimal G1 golden-path stub: proves the ECS/ALB/API Gateway deployment
// path works end to end. No business logic — just liveness/readiness.
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

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	name := os.Getenv("SERVICE_NAME")
	if name == "" {
		name = "unknown"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", ok(name+": ok"))
	mux.HandleFunc("/health", ok("healthy"))
	mux.HandleFunc("/ready", ok("ready"))

	log.Printf("%s listening on :%s", name, port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
