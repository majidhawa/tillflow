package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sync"
	"time"
)

// darajaAuth caches the Daraja OAuth access token and refreshes it only
// when it's missing or close to expiry, so we don't hit the token endpoint
// on every request.
type darajaAuth struct {
	consumerKey    string
	consumerSecret string
	baseURL        string

	mu          sync.Mutex
	accessToken string
	expiresAt   time.Time
}

func newDarajaAuth() *darajaAuth {
	return &darajaAuth{
		consumerKey:    os.Getenv("DARAJA_CONSUMER_KEY"),
		consumerSecret: os.Getenv("DARAJA_CONSUMER_SECRET"),
		baseURL:        os.Getenv("DARAJA_BASE_URL"), // https://sandbox.safaricom.co.ke
	}
}

type oauthResponse struct {
	AccessToken string `json:"access_token"`
	ExpiresIn   string `json:"expires_in"`
}

// getToken returns a valid access token, fetching a new one only when the
// cached token is missing or about to expire.
func (d *darajaAuth) getToken() (string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()

	if d.accessToken != "" && time.Now().Before(d.expiresAt) {
		return d.accessToken, nil
	}

	url := d.baseURL + "/oauth/v1/generate?grant_type=client_credentials"
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return "", fmt.Errorf("building oauth request: %w", err)
	}

	credentials := base64.StdEncoding.EncodeToString(
		[]byte(d.consumerKey + ":" + d.consumerSecret),
	)
	req.Header.Set("Authorization", "Basic "+credentials)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("calling daraja oauth: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("daraja oauth returned status %d", resp.StatusCode)
	}

	var parsed oauthResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return "", fmt.Errorf("decoding oauth response: %w", err)
	}

	d.accessToken = parsed.AccessToken
	d.expiresAt = time.Now().Add(50 * time.Minute)

	return d.accessToken, nil
}
