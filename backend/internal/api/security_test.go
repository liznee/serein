package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	rdplog "serein/internal/log"
	"serein/internal/store"
)

// setupTestServerTLS creates a test server with the specified TLS and devMode flags.
// Used for security header and debug-headers visibility tests.
func setupTestServerTLS(t *testing.T, tlsEnabled, devMode bool) http.Handler {
	t.Helper()
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return NewRouter(RouterConfig{
		HookToken:         "hook-secret",
		GlobalClientToken: "",
		DevMode:           devMode,
		TLS:               tlsEnabled,
		Svc:               nil,
		Pub:               nil,
		Engine:            nil,
		SessionRepo:       store.NewSessionRepo(db),
		DeviceRepo:        store.NewDeviceRepo(db),
		DevHandler:        NewDeviceHandler(store.NewDeviceRepo(db), "test-pair-code"),
		CfgHandler:        nil,
		Logger:            rdplog.NoOp(),
		Version:           "test-version",
		SysInfoRepo:       store.NewSysInfoRepo(db),
	})
}

// ── Security Headers tests ──

func TestSecurityHeaders_NoTLS(t *testing.T) {
	handler := setupTestServerTLS(t, false, true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	// Standard security headers should always be present
	if v := resp.Header.Get("X-Content-Type-Options"); v != "nosniff" {
		t.Errorf("X-Content-Type-Options = %q, want nosniff", v)
	}
	if v := resp.Header.Get("X-Frame-Options"); v != "DENY" {
		t.Errorf("X-Frame-Options = %q, want DENY", v)
	}
	if v := resp.Header.Get("Referrer-Policy"); v != "strict-origin-when-cross-origin" {
		t.Errorf("Referrer-Policy = %q, want strict-origin-when-cross-origin", v)
	}
	if v := resp.Header.Get("X-XSS-Protection"); v != "0" {
		t.Errorf("X-XSS-Protection = %q, want 0", v)
	}
	// HSTS should NOT be present when TLS is disabled
	if v := resp.Header.Get("Strict-Transport-Security"); v != "" {
		t.Errorf("Strict-Transport-Security should be empty without TLS, got %q", v)
	}
}

func TestSecurityHeaders_WithTLS(t *testing.T) {
	handler := setupTestServerTLS(t, true, true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	// HSTS should be present when TLS is enabled
	if v := resp.Header.Get("Strict-Transport-Security"); v == "" {
		t.Error("Strict-Transport-Security should be set when TLS is enabled")
	} else {
		if v != "max-age=31536000; includeSubDomains" {
			t.Errorf("Strict-Transport-Security = %q, want max-age=31536000; includeSubDomains", v)
		}
	}
	// Standard headers should still be present
	if v := resp.Header.Get("X-Content-Type-Options"); v != "nosniff" {
		t.Errorf("X-Content-Type-Options = %q, want nosniff", v)
	}
}

func TestSecurityHeaders_OnAllRoutes(t *testing.T) {
	handler := setupTestServerTLS(t, false, true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// Check headers on different routes
	routes := []string{"/healthz", "/version", "/pair"}
	for _, route := range routes {
		resp, err := http.Get(srv.URL + route)
		if err != nil {
			t.Errorf("GET %s: %v", route, err)
			continue
		}
		resp.Body.Close()
		if v := resp.Header.Get("X-Content-Type-Options"); v != "nosniff" {
			t.Errorf("%s: X-Content-Type-Options = %q, want nosniff", route, v)
		}
	}
}

// ── /debug-headers protection tests ──

func TestDebugHeaders_DevModeAccessible(t *testing.T) {
	handler := setupTestServerTLS(t, false, true) // devMode=true
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/debug-headers")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Errorf("debug-headers in dev mode want 200, got %d", resp.StatusCode)
	}
}

func TestDebugHeaders_ProductionMode404(t *testing.T) {
	handler := setupTestServerTLS(t, false, false) // devMode=false (production)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/debug-headers")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Errorf("debug-headers in production mode want 404, got %d (should not be registered)", resp.StatusCode)
	}
}
