// Commission service — calculates and disburses daily attendant
// commission from confirmed-paid sales. Never calls Daraja directly —
// always through the Payments service's B2C endpoint, per the contract
// boundary in docs/contracts/sale-payment.md.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
)

func ok(body string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(body + "\n"))
	}
}

// confirmedSale is what POS will eventually feed us — a sale already
// confirmed paid, ready to have commission calculated on it. Commission
// must only ever act on confirmed sales, per the contract.
type confirmedSale struct {
	SaleID        string `json:"sale_id"`
	TenantID      string `json:"tenant_id"`
	AttendantID   string `json:"attendant_id"`
	AttendantPhone string `json:"attendant_phone"`
	AmountMinor   int64  `json:"amount_minor"`
	Currency      string `json:"currency"`
}

// closeRequest is a daily-close batch: a tenant's confirmed sales for
// the day, plus the commission rate to apply.
type closeRequest struct {
	TenantID      string          `json:"tenant_id"`
	CloseDate     string          `json:"close_date"` // e.g. "2026-09-29" — part of the idempotency key
	CommissionPct float64         `json:"commission_pct"`
	Sales         []confirmedSale `json:"sales"`
}

// ledgerEntry records one attendant's computed commission for one close
// date — the payout ledger the brief requires.
type ledgerEntry struct {
	AttendantID    string  `json:"attendant_id"`
	CloseDate      string  `json:"close_date"`
	TotalSalesMinor int64  `json:"total_sales_minor"`
	CommissionMinor int64  `json:"commission_minor"`
	Currency       string  `json:"currency"`
	PayoutState    string  `json:"payout_state"`
	IdempotencyKey string  `json:"idempotency_key"`
}

// ledgerStore is keyed by idempotency key (tenant:attendant:close_date),
// so running the same daily close twice never recalculates or re-pays
// an already-processed attendant. This is the replay-safety the brief
// explicitly requires: "Replay must never double-pay."
type ledgerStore struct {
	mu      sync.Mutex
	entries map[string]*ledgerEntry
}

func newLedgerStore() *ledgerStore {
	return &ledgerStore{entries: make(map[string]*ledgerEntry)}
}

func (l *ledgerStore) get(key string) (*ledgerEntry, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	e, ok := l.entries[key]
	return e, ok
}

func (l *ledgerStore) put(key string, e *ledgerEntry) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.entries[key] = e
}

// paymentsB2CRequest mirrors the request shape the Payments service's
// /payments/b2c endpoint expects.
type paymentsB2CRequest struct {
	PayoutID       string `json:"payout_id"`
	TenantID       string `json:"tenant_id"`
	PhoneNumber    string `json:"phone_number"`
	AmountMinor    int64  `json:"amount_minor"`
	Currency       string `json:"currency"`
	IdempotencyKey string `json:"idempotency_key"`
	Remarks        string `json:"remarks"`
}

// closeHandler runs the daily commission close for one tenant. For each
// attendant, it sums their confirmed sales, calculates commission, and
// requests a B2C payout through the Payments service — never Daraja
// directly. Idempotent per (tenant, attendant, close_date): re-running
// the same close is a safe no-op for attendants already processed.
func closeHandler(paymentsBaseURL string) http.HandlerFunc {
	ledger := newLedgerStore()

	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var req closeRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid request body: "+err.Error(), http.StatusBadRequest)
			return
		}

		if req.TenantID == "" || req.CloseDate == "" || len(req.Sales) == 0 {
			http.Error(w, "tenant_id, close_date, and sales are required", http.StatusBadRequest)
			return
		}

		// Sum confirmed sales per attendant — this is the only aggregation
		// step; everything downstream operates per-attendant.
		totals := make(map[string]int64)
		phones := make(map[string]string)
		currency := "KES"
		for _, sale := range req.Sales {
			if sale.TenantID != req.TenantID {
				// Tenant isolation: a sale belonging to a different tenant
				// must never be folded into this close. Skip and log
				// rather than silently including it.
				log.Printf("commission: skipping sale %s — tenant mismatch (sale tenant=%s, close tenant=%s)",
					sale.SaleID, sale.TenantID, req.TenantID)
				continue
			}
			totals[sale.AttendantID] += sale.AmountMinor
			phones[sale.AttendantID] = sale.AttendantPhone
			if sale.Currency != "" {
				currency = sale.Currency
			}
		}

		results := make([]*ledgerEntry, 0, len(totals))

		for attendantID, totalMinor := range totals {
			idempotencyKey := fmt.Sprintf("%s:%s:%s", req.TenantID, attendantID, req.CloseDate)

			if existing, ok := ledger.get(idempotencyKey); ok {
				// Already processed this attendant for this close date —
				// return the existing entry, do not recalculate or re-pay.
				results = append(results, existing)
				continue
			}

			commissionMinor := int64(float64(totalMinor) * req.CommissionPct / 100)

			entry := &ledgerEntry{
				AttendantID:     attendantID,
				CloseDate:       req.CloseDate,
				TotalSalesMinor: totalMinor,
				CommissionMinor: commissionMinor,
				Currency:        currency,
				PayoutState:     "pending",
				IdempotencyKey:  idempotencyKey,
			}

			b2cReq := paymentsB2CRequest{
				PayoutID:       idempotencyKey,
				TenantID:       req.TenantID,
				PhoneNumber:    phones[attendantID],
				AmountMinor:    commissionMinor,
				Currency:       currency,
				IdempotencyKey: idempotencyKey,
				Remarks:        "Daily commission " + req.CloseDate,
			}

			if err := requestB2C(paymentsBaseURL, b2cReq); err != nil {
				log.Printf("commission: B2C request failed for attendant %s: %v", attendantID, err)
				entry.PayoutState = "failed"
			} else {
				entry.PayoutState = "requested"
			}

			ledger.put(idempotencyKey, entry)
			results = append(results, entry)
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"close_date": req.CloseDate,
			"tenant_id":  req.TenantID,
			"ledger":     results,
		})
	}
}

// requestB2C calls the Payments service's B2C endpoint. This is the ONLY
// place Commission talks to Payments — it never touches Daraja itself.
func requestB2C(paymentsBaseURL string, req paymentsB2CRequest) error {
	body, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("marshaling b2c request: %w", err)
	}

	resp, err := http.Post(paymentsBaseURL+"/payments/b2c", "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("calling payments b2c: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("payments b2c returned status %d", resp.StatusCode)
	}

	return nil
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

	paymentsBaseURL := os.Getenv("PAYMENTS_BASE_URL")
	if paymentsBaseURL == "" {
		paymentsBaseURL = "http://localhost:8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", ok(name+": ok"))
	mux.HandleFunc("/health", ok("healthy"))
	mux.HandleFunc("/ready", ok("ready"))
	mux.HandleFunc("/commission/close", closeHandler(paymentsBaseURL))

	log.Printf("%s listening on :%s", name, port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}