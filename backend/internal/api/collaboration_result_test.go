package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"serein/internal/agent"
	"serein/internal/session"
	"serein/internal/store"
)

func TestParseCollaborationSummaryRequiresMarkersAndValidJSON(t *testing.T) {
	valid := `ordinary text
[SEREIN_RESULT]
{"reproduced":true,"cause":"nil access","code_changed":true,"change_summary":"guarded the value","tests_run":["go test ./..."],"test_result":"passed","unresolved":[],"suggested_reply":"Fixed in the next release."}
[/SEREIN_RESULT]`
	summary := parseCollaborationSummary(valid)
	if summary == nil || !summary.Reproduced || summary.Cause != "nil access" || summary.SuggestedReply == "" {
		t.Fatalf("failed to parse real structured result: %#v", summary)
	}
	if parseCollaborationSummary(`{"reproduced":true}`) != nil {
		t.Fatal("unmarked text must not be presented as a structured result")
	}
	if parseCollaborationSummary(`[SEREIN_RESULT]{bad}[/SEREIN_RESULT]`) != nil {
		t.Fatal("invalid JSON must remain unavailable")
	}
}

func TestCollaborationResultSurvivesRelayRestart(t *testing.T) {
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	repo := store.NewCollaborationRunRepo(db)
	queue := agent.NewQueue(10)
	manager := session.NewSessionManager(queue, nil)
	defer manager.Stop()
	transport := manager.GetOrCreateScopedSession("repo", "collab:persisted")
	first := &AgentRelay{SessionManager: manager, collaborationRepo: repo}
	first.registerCollaborationRun("collab:persisted", transport.ID, validHandoffRequest(), "")
	first.recordCollaborationStep(transport.ID, map[string]interface{}{"event": "turn_start", "content": ""})
	first.recordCollaborationStep(transport.ID, map[string]interface{}{
		"event": "text", "content": `[SEREIN_RESULT]
{"reproduced":true,"cause":"persisted","code_changed":false,"change_summary":"","tests_run":[],"test_result":"passed","unresolved":[],"suggested_reply":"done"}
[/SEREIN_RESULT]`,
	})
	first.recordCollaborationStep(transport.ID, map[string]interface{}{"event": "turn_end", "content": "end_turn"})

	restarted := &AgentRelay{collaborationRepo: repo}
	req := httptest.NewRequest(http.MethodGet, "/collaboration/result?scope=collab:persisted", nil)
	recorder := httptest.NewRecorder()
	restarted.CollaborationResult(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response["status"] != "completed" || response["structured_available"] != true ||
		!strings.Contains(response["raw_result"].(string), "persisted") {
		t.Fatalf("persisted response missing: %v", response)
	}
}

func TestDeleteCollaborationResultRemovesMemoryAndPersistence(t *testing.T) {
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	repo := store.NewCollaborationRunRepo(db)
	relay := &AgentRelay{
		collaborationRepo: repo,
		collaborationRuns: map[string]*collaborationRun{
			"collab:delete": {Scope: "collab:delete", Status: "completed", UpdatedAt: time.Now()},
		},
	}
	relay.persistCollaborationRun(relay.collaborationRuns["collab:delete"])
	req := httptest.NewRequest(http.MethodDelete, "/collaboration/result?scope=collab:delete", nil)
	recorder := httptest.NewRecorder()
	relay.DeleteCollaborationResult(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if relay.collaborationRuns["collab:delete"] != nil {
		t.Fatal("in-memory run was not removed")
	}
	stored, err := repo.Get("collab:delete")
	if err != nil || stored != nil {
		t.Fatalf("persisted run was not removed: %#v err=%v", stored, err)
	}
}

func TestRecordCollaborationStepIsScopedAndQueryable(t *testing.T) {
	queue := agent.NewQueue(10)
	manager := session.NewSessionManager(queue, nil)
	defer manager.Stop()
	transport := manager.GetOrCreateScopedSession("repo", "collab:abc")
	relay := &AgentRelay{SessionManager: manager}
	relay.registerCollaborationRun("collab:abc", transport.ID, validHandoffRequest(), "")
	relay.recordCollaborationStep(transport.ID, map[string]interface{}{"event": "turn_start", "content": ""})
	relay.recordCollaborationStep(transport.ID, map[string]interface{}{
		"event": "agent_session", "name": "codex", "content": "123e4567-e89b-42d3-a456-426614174000",
	})
	relay.recordCollaborationStep(transport.ID, map[string]interface{}{
		"event": "text", "content": `[SEREIN_RESULT]
{"reproduced":false,"cause":"not enough data","code_changed":false,"change_summary":"","tests_run":[],"test_result":"not run","unresolved":["need logs"],"suggested_reply":"Please attach the startup log."}
[/SEREIN_RESULT]`,
	})
	relay.recordCollaborationStep(transport.ID, map[string]interface{}{"event": "turn_end", "content": "end_turn"})

	req := httptest.NewRequest(http.MethodGet, "/collaboration/result?scope=collab:abc", nil)
	recorder := httptest.NewRecorder()
	relay.CollaborationResult(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response["status"] != "completed" || response["structured_available"] != true {
		t.Fatalf("unexpected response: %v", response)
	}
	if response["agent_session_id"] != "123e4567-e89b-42d3-a456-426614174000" {
		t.Fatalf("session id was not captured: %v", response)
	}
}
