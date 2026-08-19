package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
)

const collaborationOAuthTTL = 10 * time.Minute

type collaborationOAuthConfig struct {
	PublicURL          string
	GitHubClientID     string
	GitHubClientSecret string
	GiteeClientID      string
	GiteeClientSecret  string
}

type collaborationOAuthFlow struct {
	Provider  string
	Access    string
	CreatedAt time.Time
	Status    string
	Token     string
	Scopes    []string
	Error     string
}

// CollaborationOAuthHandler only keeps authorization codes/tokens in memory.
// A successful token is returned exactly once to an authenticated phone and is
// then removed. Provider tokens are never written to SQLite or logs.
type CollaborationOAuthHandler struct {
	mu     sync.Mutex
	flows  map[string]*collaborationOAuthFlow
	config collaborationOAuthConfig
	client *http.Client
	now    func() time.Time
}

func newCollaborationOAuthHandlerFromEnv() *CollaborationOAuthHandler {
	return &CollaborationOAuthHandler{
		flows: make(map[string]*collaborationOAuthFlow),
		config: collaborationOAuthConfig{
			PublicURL:          strings.TrimRight(strings.TrimSpace(os.Getenv("SEREIN_PUBLIC_URL")), "/"),
			GitHubClientID:     strings.TrimSpace(os.Getenv("SEREIN_GITHUB_CLIENT_ID")),
			GitHubClientSecret: strings.TrimSpace(os.Getenv("SEREIN_GITHUB_CLIENT_SECRET")),
			GiteeClientID:      strings.TrimSpace(os.Getenv("SEREIN_GITEE_CLIENT_ID")),
			GiteeClientSecret:  strings.TrimSpace(os.Getenv("SEREIN_GITEE_CLIENT_SECRET")),
		},
		client: &http.Client{Timeout: 15 * time.Second},
		now:    time.Now,
	}
}

func (h *CollaborationOAuthHandler) providerConfigured(provider string) bool {
	if h.config.PublicURL == "" {
		return false
	}
	switch provider {
	case "github":
		return h.config.GitHubClientID != "" && h.config.GitHubClientSecret != ""
	case "gitee":
		return h.config.GiteeClientID != "" && h.config.GiteeClientSecret != ""
	default:
		return false
	}
}

func (h *CollaborationOAuthHandler) Config(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"github": map[string]interface{}{
			"available":           h.providerConfigured("github"),
			"mode":                "authorization_code",
			"read_scope":          []string{"read:user", "notifications"},
			"public_write_scope":  []string{"read:user", "notifications", "public_repo"},
			"private_write_scope": []string{"read:user", "notifications", "repo"},
		},
		"gitee": map[string]interface{}{
			"available":           h.providerConfigured("gitee"),
			"mode":                "authorization_code",
			"read_scope":          []string{"user_info", "projects", "issues", "notes", "pull_requests"},
			"public_write_scope":  []string{"user_info", "projects", "issues", "notes", "pull_requests"},
			"private_write_scope": []string{"user_info", "projects", "issues", "notes", "pull_requests"},
		},
	})
}

func (h *CollaborationOAuthHandler) Start(w http.ResponseWriter, r *http.Request) {
	provider := strings.ToLower(chi.URLParam(r, "provider"))
	if !h.providerConfigured(provider) {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "provider OAuth is not configured"})
		return
	}
	access := "read"
	if r.Body != nil && r.ContentLength != 0 {
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		var input struct {
			Access string `json:"access"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
			return
		}
		if input.Access != "" {
			access = input.Access
		}
	}
	if access != "read" && access != "public_write" && access != "private_write" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid access mode"})
		return
	}
	state, err := randomOAuthState()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to initialize authorization"})
		return
	}
	now := h.now()
	h.mu.Lock()
	h.cleanupLocked(now)
	h.flows[state] = &collaborationOAuthFlow{Provider: provider, Access: access, CreatedAt: now, Status: "pending"}
	h.mu.Unlock()

	authURL, err := h.authorizationURL(provider, state, access)
	if err != nil {
		h.mu.Lock()
		delete(h.flows, state)
		h.mu.Unlock()
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "provider OAuth is not configured"})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"provider":          provider,
		"access":            access,
		"state":             state,
		"authorization_url": authURL,
		"expires_in":        int(collaborationOAuthTTL.Seconds()),
	})
}

func (h *CollaborationOAuthHandler) Status(w http.ResponseWriter, r *http.Request) {
	provider := strings.ToLower(chi.URLParam(r, "provider"))
	state := chi.URLParam(r, "state")
	if !validOAuthState(state) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid authorization state"})
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupLocked(h.now())
	flow := h.flows[state]
	if flow == nil || flow.Provider != provider {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "authorization not found or expired"})
		return
	}
	resp := map[string]interface{}{"provider": provider, "status": flow.Status, "access": flow.Access}
	switch flow.Status {
	case "complete":
		resp["access_token"] = flow.Token
		resp["scopes"] = flow.Scopes
		delete(h.flows, state) // one-time delivery
	case "failed":
		resp["error"] = flow.Error
		delete(h.flows, state)
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *CollaborationOAuthHandler) Callback(w http.ResponseWriter, r *http.Request) {
	provider := strings.ToLower(chi.URLParam(r, "provider"))
	state := r.URL.Query().Get("state")
	code := r.URL.Query().Get("code")
	providerError := r.URL.Query().Get("error")
	if !validOAuthState(state) || code == "" && providerError == "" {
		h.renderOAuthResult(w, false, "授权请求无效或已经过期")
		return
	}

	h.mu.Lock()
	h.cleanupLocked(h.now())
	flow := h.flows[state]
	valid := flow != nil && flow.Provider == provider && flow.Status == "pending"
	h.mu.Unlock()
	if !valid {
		h.renderOAuthResult(w, false, "授权请求无效或已经过期")
		return
	}
	if providerError != "" {
		h.finishFlow(state, "failed", "", nil, "用户取消了授权")
		h.renderOAuthResult(w, false, "授权已取消，可以返回 Serein")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	token, scopes, err := h.exchangeCode(ctx, provider, code)
	if err != nil {
		h.finishFlow(state, "failed", "", nil, "平台授权失败，请重试")
		h.renderOAuthResult(w, false, "平台授权失败，可以返回 Serein 后重试")
		return
	}
	h.finishFlow(state, "complete", token, scopes, "")
	h.renderOAuthResult(w, true, "授权完成，现在可以返回 Serein")
}

func (h *CollaborationOAuthHandler) finishFlow(state, status, token string, scopes []string, errorText string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if flow := h.flows[state]; flow != nil {
		flow.Status = status
		flow.Token = token
		flow.Scopes = scopes
		flow.Error = errorText
	}
}

func (h *CollaborationOAuthHandler) authorizationURL(provider, state, access string) (string, error) {
	callback := h.config.PublicURL + "/collaboration/oauth/" + provider + "/callback"
	values := url.Values{"redirect_uri": {callback}, "response_type": {"code"}, "state": {state}}
	var endpoint string
	switch provider {
	case "github":
		endpoint = "https://github.com/login/oauth/authorize"
		values.Set("client_id", h.config.GitHubClientID)
		scope := "read:user notifications"
		if access == "public_write" {
			scope += " public_repo"
		} else if access == "private_write" {
			scope += " repo"
		}
		values.Set("scope", scope)
	case "gitee":
		endpoint = "https://gitee.com/oauth/authorize"
		values.Set("client_id", h.config.GiteeClientID)
		values.Set("scope", "user_info projects issues notes pull_requests")
	default:
		return "", errors.New("unsupported provider")
	}
	return endpoint + "?" + values.Encode(), nil
}

func (h *CollaborationOAuthHandler) exchangeCode(ctx context.Context, provider, code string) (string, []string, error) {
	callback := h.config.PublicURL + "/collaboration/oauth/" + provider + "/callback"
	values := url.Values{"code": {code}, "redirect_uri": {callback}, "grant_type": {"authorization_code"}}
	endpoint := ""
	switch provider {
	case "github":
		endpoint = "https://github.com/login/oauth/access_token"
		values.Set("client_id", h.config.GitHubClientID)
		values.Set("client_secret", h.config.GitHubClientSecret)
	case "gitee":
		endpoint = "https://gitee.com/oauth/token"
		values.Set("client_id", h.config.GiteeClientID)
		values.Set("client_secret", h.config.GiteeClientSecret)
	default:
		return "", nil, errors.New("unsupported provider")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(values.Encode()))
	if err != nil {
		return "", nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	resp, err := h.client.Do(req)
	if err != nil {
		return "", nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil || resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", nil, errors.New("provider token exchange failed")
	}
	var data struct {
		AccessToken string `json:"access_token"`
		Scope       string `json:"scope"`
		Error       string `json:"error"`
	}
	if json.Unmarshal(body, &data) != nil || data.AccessToken == "" || data.Error != "" {
		return "", nil, errors.New("provider token response invalid")
	}
	return data.AccessToken, splitScopes(data.Scope), nil
}

func splitScopes(value string) []string {
	parts := strings.FieldsFunc(value, func(r rune) bool { return r == ' ' || r == ',' })
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

func randomOAuthState() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

func validOAuthState(state string) bool {
	if len(state) < 32 || len(state) > 64 {
		return false
	}
	for _, r := range state {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_') {
			return false
		}
	}
	return true
}

func (h *CollaborationOAuthHandler) cleanupLocked(now time.Time) {
	for state, flow := range h.flows {
		if now.Sub(flow.CreatedAt) > collaborationOAuthTTL {
			delete(h.flows, state)
		}
	}
}

func (h *CollaborationOAuthHandler) renderOAuthResult(w http.ResponseWriter, success bool, message string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	status := http.StatusOK
	color := "#D97757"
	if !success {
		status = http.StatusBadRequest
		color = "#C8A487"
	}
	w.WriteHeader(status)
	_, _ = fmt.Fprintf(w, `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Serein 协作授权</title><style>body{margin:0;background:#0b0e12;color:#e1e2e8;font:15px system-ui;display:grid;place-items:center;min-height:100vh}.card{max-width:360px;margin:24px;padding:28px;border:1px solid rgba(217,119,87,.22);border-radius:16px;background:#1d2024}.mark{color:%s;font-size:28px}p{color:#a9acb7;line-height:1.7}</style></head><body><main class="card"><div class="mark">%s</div><h2>Serein 协作中心</h2><p>%s</p></main></body></html>`, color, map[bool]string{true: "✓", false: "!"}[success], html.EscapeString(message))
}
