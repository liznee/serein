package pushkit

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"serein/internal/store"
)

func newPushTestRepo(t *testing.T) *store.DeviceRepo {
	t.Helper()
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	repo := store.NewDeviceRepo(db)
	device, err := repo.Pair("device-1", "phone", "client-token")
	if err != nil {
		t.Fatal(err)
	}
	if err := repo.SetPushToken(device.ID, "push-token-abcdefghijklmnopqrstuvwxyz"); err != nil {
		t.Fatal(err)
	}
	return repo
}

func TestSendApprovalUsesMinimalPayload(t *testing.T) {
	var mu sync.Mutex
	var pushBody string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/oauth":
			if err := r.ParseForm(); err != nil {
				t.Error(err)
			}
			if r.Form.Get("client_secret") != "server-only-secret" {
				t.Error("OAuth secret missing")
			}
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"access_token":"access-token","expires_in":3600}`)
		case "/v1/client-id/messages:send":
			if r.Header.Get("Authorization") != "Bearer access-token" {
				t.Errorf("unexpected authorization header")
			}
			raw, _ := io.ReadAll(r.Body)
			mu.Lock()
			pushBody = string(raw)
			mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"code":"80000000","msg":"Success"}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	dispatcher := New(Config{
		ClientID:     "client-id",
		ClientSecret: "server-only-secret",
		OAuthURL:     server.URL + "/oauth",
		APIBaseURL:   server.URL + "/v1",
	}, newPushTestRepo(t))
	if err := dispatcher.sendApproval(context.Background(), approvalJob{
		ID: "approval-1", RiskLevel: "red", Project: "test1",
	}); err != nil {
		t.Fatal(err)
	}

	mu.Lock()
	body := pushBody
	mu.Unlock()
	if body == "" {
		t.Fatal("push request was not sent")
	}
	for _, forbidden := range []string{"server-only-secret", "access-token", "rm -rf", `C:\\workspace`} {
		if strings.Contains(body, forbidden) {
			t.Fatalf("push payload leaked forbidden value %q", forbidden)
		}
	}
	var payload map[string]interface{}
	if err := json.Unmarshal([]byte(body), &payload); err != nil {
		t.Fatalf("invalid JSON payload: %v", err)
	}
	message := payload["message"].(map[string]interface{})
	tokens := message["token"].([]interface{})
	if len(tokens) != 1 || tokens[0] != "push-token-abcdefghijklmnopqrstuvwxyz" {
		t.Fatalf("unexpected targets: %#v", tokens)
	}
	data, ok := message["data"].(string)
	if !ok || !strings.Contains(data, `"id":"approval-1"`) {
		t.Fatalf("unexpected data field: %#v", message["data"])
	}
}

func TestProjectNotificationTextIsBoundedAndSingleLine(t *testing.T) {
	project := "  test1\r\n" + strings.Repeat("very-long-project-name-", 8)
	got := sanitizeProjectForNotification(project)
	if strings.ContainsAny(got, "\r\n\t") {
		t.Fatalf("project notification contains control whitespace: %q", got)
	}
	if len([]rune(got)) > 49 {
		t.Fatalf("project notification is too long: %d runes", len([]rune(got)))
	}
	if !strings.HasSuffix(got, "…") {
		t.Fatalf("truncated project notification should end with ellipsis: %q", got)
	}
}

func TestEnqueueApprovalDeduplicates(t *testing.T) {
	requests := make(chan struct{}, 4)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/oauth" {
			io.WriteString(w, `{"access_token":"access-token","expires_in":3600}`)
			return
		}
		requests <- struct{}{}
		io.WriteString(w, `{"code":"80000000"}`)
	}))
	defer server.Close()
	dispatcher := New(Config{
		ClientID: "client-id", ClientSecret: "secret",
		OAuthURL: server.URL + "/oauth", APIBaseURL: server.URL + "/v1",
	}, newPushTestRepo(t))
	if !dispatcher.EnqueueApproval("approval-1", "red", "test1") || !dispatcher.EnqueueApproval("approval-1", "red", "test1") {
		t.Fatal("enqueue failed")
	}
	select {
	case <-requests:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for push")
	}
	select {
	case <-requests:
		t.Fatal("duplicate approval produced a second push")
	case <-time.After(150 * time.Millisecond):
	}
}

func TestDeliveryRetriesTransientFailureWithoutDuplicatingSuccess(t *testing.T) {
	var mu sync.Mutex
	pushRequests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/oauth" {
			io.WriteString(w, `{"access_token":"access-token","expires_in":3600}`)
			return
		}
		mu.Lock()
		pushRequests++
		attempt := pushRequests
		mu.Unlock()
		if attempt == 1 {
			http.Error(w, "temporary", http.StatusServiceUnavailable)
			return
		}
		io.WriteString(w, `{"code":"80000000"}`)
	}))
	defer server.Close()
	dispatcher := New(Config{
		ClientID: "client-id", ClientSecret: "secret",
		OAuthURL: server.URL + "/oauth", APIBaseURL: server.URL + "/v1",
	}, newPushTestRepo(t))
	dispatcher.retryBase = time.Millisecond

	if !dispatcher.EnqueueApproval("approval-retry", "red", "test1") {
		t.Fatal("enqueue failed")
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		count := pushRequests
		mu.Unlock()
		if count == 2 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !dispatcher.EnqueueApproval("approval-retry", "red", "test1") {
		t.Fatal("deduplicated enqueue should report accepted")
	}
	time.Sleep(30 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if pushRequests != 2 {
		t.Fatalf("push requests = %d, want exactly 2 (one retry and one success)", pushRequests)
	}
}

func TestPermanentFailureCanBeEnqueuedAgain(t *testing.T) {
	requests := make(chan struct{}, 8)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/oauth" {
			io.WriteString(w, `{"access_token":"access-token","expires_in":3600}`)
			return
		}
		requests <- struct{}{}
		http.Error(w, "bad request", http.StatusBadRequest)
	}))
	defer server.Close()
	dispatcher := New(Config{
		ClientID: "client-id", ClientSecret: "secret",
		OAuthURL: server.URL + "/oauth", APIBaseURL: server.URL + "/v1",
	}, newPushTestRepo(t))
	dispatcher.retryBase = time.Millisecond

	if !dispatcher.EnqueueApproval("approval-permanent", "red", "test1") {
		t.Fatal("first enqueue failed")
	}
	select {
	case <-requests:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for first attempt")
	}
	time.Sleep(20 * time.Millisecond)
	if !dispatcher.EnqueueApproval("approval-permanent", "red", "test1") {
		t.Fatal("second enqueue failed")
	}
	select {
	case <-requests:
	case <-time.After(2 * time.Second):
		t.Fatal("permanent failure remained deduplicated")
	}
}
