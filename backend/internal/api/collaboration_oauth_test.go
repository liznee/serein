package api

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
)

type oauthRoundTripFunc func(*http.Request) (*http.Response, error)

func (f oauthRoundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func testOAuthHandler() *CollaborationOAuthHandler {
	return &CollaborationOAuthHandler{
		flows: make(map[string]*collaborationOAuthFlow),
		config: collaborationOAuthConfig{
			PublicURL:          "https://serein.example",
			GitHubClientID:     "github-client",
			GitHubClientSecret: "github-secret",
			GiteeClientID:      "gitee-client",
			GiteeClientSecret:  "gitee-secret",
		},
		client: &http.Client{Transport: oauthRoundTripFunc(func(r *http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     make(http.Header),
				Body:       io.NopCloser(strings.NewReader(`{"access_token":"provider-token","scope":"read:user,notifications"}`)),
			}, nil
		})},
		now: time.Now,
	}
}

func testOAuthRouter(h *CollaborationOAuthHandler) http.Handler {
	r := chi.NewRouter()
	r.Post("/collaboration/oauth/{provider}/start", h.Start)
	r.Get("/collaboration/oauth/{provider}/callback", h.Callback)
	r.Get("/collaboration/oauth/{provider}/status/{state}", h.Status)
	return r
}

func TestCollaborationOAuthOneTimeTokenFlow(t *testing.T) {
	h := testOAuthHandler()
	router := testOAuthRouter(h)

	start := httptest.NewRecorder()
	router.ServeHTTP(start, httptest.NewRequest(http.MethodPost, "/collaboration/oauth/github/start", nil))
	if start.Code != http.StatusCreated {
		t.Fatalf("start status=%d body=%s", start.Code, start.Body.String())
	}
	var started struct {
		State            string `json:"state"`
		AuthorizationURL string `json:"authorization_url"`
	}
	if err := json.Unmarshal(start.Body.Bytes(), &started); err != nil {
		t.Fatalf("decode start response: %v", err)
	}
	if !validOAuthState(started.State) || !strings.Contains(started.AuthorizationURL, "github.com/login/oauth/authorize") {
		t.Fatalf("invalid start response: %+v", started)
	}
	if strings.Contains(started.AuthorizationURL, "github-secret") {
		t.Fatal("client secret leaked in authorization URL")
	}

	callback := httptest.NewRecorder()
	callbackURL := "/collaboration/oauth/github/callback?state=" + started.State + "&code=temporary-code"
	router.ServeHTTP(callback, httptest.NewRequest(http.MethodGet, callbackURL, nil))
	if callback.Code != http.StatusOK || strings.Contains(callback.Body.String(), "provider-token") {
		t.Fatalf("callback leaked token or failed: status=%d body=%s", callback.Code, callback.Body.String())
	}

	statusPath := "/collaboration/oauth/github/status/" + started.State
	status := httptest.NewRecorder()
	router.ServeHTTP(status, httptest.NewRequest(http.MethodGet, statusPath, nil))
	if status.Code != http.StatusOK || !strings.Contains(status.Body.String(), `"access_token":"provider-token"`) {
		t.Fatalf("status did not deliver token once: status=%d body=%s", status.Code, status.Body.String())
	}

	again := httptest.NewRecorder()
	router.ServeHTTP(again, httptest.NewRequest(http.MethodGet, statusPath, nil))
	if again.Code != http.StatusNotFound || strings.Contains(again.Body.String(), "provider-token") {
		t.Fatalf("token was not one-time: status=%d body=%s", again.Code, again.Body.String())
	}
}

func TestCollaborationOAuthExpiryAndProviderBinding(t *testing.T) {
	h := testOAuthHandler()
	now := time.Now()
	h.now = func() time.Time { return now }
	state, _ := randomOAuthState()
	h.flows[state] = &collaborationOAuthFlow{Provider: "github", Status: "pending", CreatedAt: now}
	router := testOAuthRouter(h)

	wrong := httptest.NewRecorder()
	router.ServeHTTP(wrong, httptest.NewRequest(http.MethodGet, "/collaboration/oauth/gitee/status/"+state, nil))
	if wrong.Code != http.StatusNotFound {
		t.Fatalf("provider mismatch status=%d", wrong.Code)
	}

	now = now.Add(collaborationOAuthTTL + time.Second)
	expired := httptest.NewRecorder()
	router.ServeHTTP(expired, httptest.NewRequest(http.MethodGet, "/collaboration/oauth/github/status/"+state, nil))
	if expired.Code != http.StatusNotFound {
		t.Fatalf("expired flow status=%d", expired.Code)
	}
}

func TestCollaborationOAuthWriteAccessIsExplicit(t *testing.T) {
	h := testOAuthHandler()
	router := testOAuthRouter(h)
	request := httptest.NewRequest(http.MethodPost, "/collaboration/oauth/github/start",
		strings.NewReader(`{"access":"public_write"}`))
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusCreated {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		Access           string `json:"access"`
		AuthorizationURL string `json:"authorization_url"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.Access != "public_write" || !strings.Contains(response.AuthorizationURL, "public_repo") {
		t.Fatalf("write scope was not explicit: %+v", response)
	}
	if strings.Contains(response.AuthorizationURL, "scope=repo+") || strings.Contains(response.AuthorizationURL, "scope=repo%20") {
		t.Fatalf("public write unexpectedly requested private repo scope: %s", response.AuthorizationURL)
	}
}
