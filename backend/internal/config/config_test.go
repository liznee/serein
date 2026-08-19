package config

import (
	"os"
	"testing"
)

func TestLoad_Defaults(t *testing.T) {
	// Clear all SEREIN_ env vars to test defaults
	os.Unsetenv("SEREIN_LISTEN")
	os.Unsetenv("SEREIN_DB")
	os.Unsetenv("SEREIN_HOOK_TOKEN")
	os.Unsetenv("SEREIN_CLIENT_TOKEN")
	os.Unsetenv("SEREIN_PAIR_CODE")
	os.Unsetenv("SEREIN_NTFY_URL")
	os.Unsetenv("SEREIN_NTFY_TOPIC")
	os.Unsetenv("SEREIN_APPROVAL_TIMEOUT")
	os.Unsetenv("SEREIN_LOG")
	os.Unsetenv("SEREIN_TLS_CERT")
	os.Unsetenv("SEREIN_TLS_KEY")

	cfg := Load()
	if cfg.Listen != ":8080" {
		t.Errorf("Listen = %q, want :8080", cfg.Listen)
	}
	if cfg.DBPath != "serein.db" {
		t.Errorf("DBPath = %q, want serein.db", cfg.DBPath)
	}
	if cfg.PairCode != "" {
		t.Errorf("PairCode = %q, want empty (must be explicitly configured)", cfg.PairCode)
	}
	if cfg.ApprovalTimeoutSec != 300 {
		t.Errorf("ApprovalTimeoutSec = %d, want 300", cfg.ApprovalTimeoutSec)
	}
	if cfg.TLSCert != "" || cfg.TLSKey != "" {
		t.Errorf("TLS fields should be empty by default, got cert=%q key=%q", cfg.TLSCert, cfg.TLSKey)
	}
}

func TestLoad_TLSConfig(t *testing.T) {
	os.Setenv("SEREIN_TLS_CERT", "/etc/ssl/cert.pem")
	os.Setenv("SEREIN_TLS_KEY", "/etc/ssl/key.pem")
	defer os.Unsetenv("SEREIN_TLS_CERT")
	defer os.Unsetenv("SEREIN_TLS_KEY")

	cfg := Load()
	if cfg.TLSCert != "/etc/ssl/cert.pem" {
		t.Errorf("TLSCert = %q, want /etc/ssl/cert.pem", cfg.TLSCert)
	}
	if cfg.TLSKey != "/etc/ssl/key.pem" {
		t.Errorf("TLSKey = %q, want /etc/ssl/key.pem", cfg.TLSKey)
	}
}

func TestLoad_CustomValues(t *testing.T) {
	os.Setenv("SEREIN_LISTEN", ":9090")
	os.Setenv("SEREIN_DB", "/tmp/test.db")
	os.Setenv("SEREIN_HOOK_TOKEN", "my-hook-token")
	os.Setenv("SEREIN_APPROVAL_TIMEOUT", "600")
	defer os.Unsetenv("SEREIN_LISTEN")
	defer os.Unsetenv("SEREIN_DB")
	defer os.Unsetenv("SEREIN_HOOK_TOKEN")
	defer os.Unsetenv("SEREIN_APPROVAL_TIMEOUT")

	cfg := Load()
	if cfg.Listen != ":9090" {
		t.Errorf("Listen = %q, want :9090", cfg.Listen)
	}
	if cfg.DBPath != "/tmp/test.db" {
		t.Errorf("DBPath = %q, want /tmp/test.db", cfg.DBPath)
	}
	if cfg.HookToken != "my-hook-token" {
		t.Errorf("HookToken = %q, want my-hook-token", cfg.HookToken)
	}
	if cfg.ApprovalTimeoutSec != 600 {
		t.Errorf("ApprovalTimeoutSec = %d, want 600", cfg.ApprovalTimeoutSec)
	}
}
