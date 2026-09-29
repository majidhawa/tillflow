package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"
)

type paymentsClient struct {
	baseURL    string
	httpClient *http.Client
}

func newPaymentsClient() *paymentsClient {
	baseURL := os.Getenv("PAYMENTS_BASE_URL")

	if baseURL == "" {
		baseURL = "http://localhost:8081"
	}

	return &paymentsClient{
		baseURL: strings.TrimRight(baseURL, "/"),
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

func (c *paymentsClient) createPayment(req PaymentRequest) (*PaymentResponse, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("failed to encode payment request: %w", err)
	}

	httpReq, err := http.NewRequest(
		http.MethodPost,
		c.baseURL+"/payments",
		bytes.NewReader(body),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create payment request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("payments service request failed: %w", err)
	}

	defer resp.Body.Close()

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("payments service returned status %d", resp.StatusCode)
	}

	var payment PaymentResponse

	if err := json.NewDecoder(resp.Body).Decode(&payment); err != nil {
		return nil, fmt.Errorf("failed to decode payment response: %w", err)
	}

	return &payment, nil
}
