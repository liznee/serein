package api

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	"serein/internal/store"
)

const maxCollaborationResultText = 128 * 1024

type collaborationResultSummary struct {
	Reproduced     bool     `json:"reproduced"`
	Cause          string   `json:"cause"`
	CodeChanged    bool     `json:"code_changed"`
	ChangeSummary  string   `json:"change_summary"`
	TestsRun       []string `json:"tests_run"`
	TestResult     string   `json:"test_result"`
	Unresolved     []string `json:"unresolved"`
	SuggestedReply string   `json:"suggested_reply"`
}

type collaborationRun struct {
	Scope          string
	TransportID    string
	Provider       string
	RepositoryID   string
	ItemKind       string
	ItemNumber     string
	Project        string
	AgentType      string
	AgentSessionID string
	Status         string
	RawText        string
	Summary        *collaborationResultSummary
	UpdatedAt      time.Time
}

func (a *AgentRelay) registerCollaborationRun(scope, transportID string,
	req collaborationHandoffRequest, agentSessionID string) {
	a.mu.Lock()
	if a.collaborationRuns == nil {
		a.collaborationRuns = make(map[string]*collaborationRun)
	}
	run := a.collaborationRuns[scope]
	if run == nil {
		run = &collaborationRun{Scope: scope}
		a.collaborationRuns[scope] = run
	}
	run.TransportID = transportID
	run.Provider = req.Provider
	run.RepositoryID = req.RepositoryID
	run.ItemKind = req.ItemKind
	run.ItemNumber = req.ItemNumber
	run.Project = req.Project
	run.AgentType = req.AgentType
	if agentSessionID != "" {
		run.AgentSessionID = agentSessionID
	}
	if run.Status == "" || run.Status == "completed" || run.Status == "failed" {
		run.Status = "working"
	}
	run.UpdatedAt = time.Now()
	snapshot := *run
	a.mu.Unlock()
	a.persistCollaborationRun(&snapshot)
}

func validCollaborationEvent(value string) bool {
	switch value {
	case "turn_start", "turn_end", "text", "agent_session":
		return true
	default:
		return false
	}
}

func (a *AgentRelay) recordCollaborationStep(transportID string, payload any) {
	if a.SessionManager == nil || transportID == "" {
		return
	}
	transport := a.SessionManager.GetSession(transportID)
	if transport == nil || transport.Scope == "" {
		return
	}
	data, ok := payload.(map[string]interface{})
	if !ok {
		return
	}
	event, _ := data["event"].(string)
	content, _ := data["content"].(string)
	name, _ := data["name"].(string)
	if !validCollaborationEvent(event) || len(content) > maxStepContentLen || !isPrintable(content) {
		return
	}

	a.mu.Lock()
	if a.collaborationRuns == nil {
		a.collaborationRuns = make(map[string]*collaborationRun)
	}
	run := a.collaborationRuns[transport.Scope]
	if run == nil {
		run = &collaborationRun{
			Scope: transport.Scope, TransportID: transportID,
			Project: transport.Project, Status: "working",
		}
		a.collaborationRuns[transport.Scope] = run
	}
	switch event {
	case "turn_start":
		run.RawText = ""
		run.Summary = nil
		run.Status = "working"
	case "text":
		if content != "" {
			if run.RawText != "" {
				run.RawText += "\n"
			}
			run.RawText += content
			if len(run.RawText) > maxCollaborationResultText {
				run.RawText = run.RawText[len(run.RawText)-maxCollaborationResultText:]
			}
		}
	case "agent_session":
		if uuidPattern.MatchString(content) && (name == "codex" || name == "claude") {
			run.AgentSessionID = content
			run.AgentType = name
		}
	case "turn_end":
		if content == "end_turn" || content == "stop_sequence" {
			run.Status = "completed"
			run.Summary = parseCollaborationSummary(run.RawText)
		} else {
			run.Status = "failed"
		}
	}
	run.UpdatedAt = time.Now()
	shouldPersist := event == "turn_start" || event == "turn_end" || event == "agent_session"
	snapshot := *run
	a.mu.Unlock()
	if shouldPersist {
		a.persistCollaborationRun(&snapshot)
	}
}

func (a *AgentRelay) persistCollaborationRun(run *collaborationRun) {
	if a.collaborationRepo == nil || run == nil || !isSafeWorkScope(run.Scope) {
		return
	}
	summaryJSON := ""
	if run.Summary != nil {
		data, err := json.Marshal(run.Summary)
		if err != nil {
			log.Printf("collaboration result marshal failed: %v", err)
			return
		}
		summaryJSON = string(data)
	}
	record := store.CollaborationRunRecord{
		WorkScope: run.Scope, TransportID: run.TransportID, Provider: run.Provider,
		RepositoryID: run.RepositoryID, ItemKind: run.ItemKind, ItemNumber: run.ItemNumber,
		Project: run.Project, AgentType: run.AgentType, AgentSessionID: run.AgentSessionID,
		Status: run.Status, RawText: run.RawText, SummaryJSON: summaryJSON, UpdatedAt: run.UpdatedAt,
	}
	if err := a.collaborationRepo.Upsert(record); err != nil {
		log.Printf("collaboration result persistence failed: %v", err)
	}
}

func (a *AgentRelay) loadCollaborationRun(scope string) (*collaborationRun, error) {
	if a.collaborationRepo == nil {
		return nil, nil
	}
	record, err := a.collaborationRepo.Get(scope)
	if err != nil || record == nil {
		return nil, err
	}
	if len(record.RawText) > maxCollaborationResultText || !isSafeWorkScope(record.WorkScope) {
		return nil, nil
	}
	result := &collaborationRun{
		Scope: record.WorkScope, TransportID: record.TransportID, Provider: record.Provider,
		RepositoryID: record.RepositoryID, ItemKind: record.ItemKind, ItemNumber: record.ItemNumber,
		Project: record.Project, AgentType: record.AgentType, AgentSessionID: record.AgentSessionID,
		Status: record.Status, RawText: record.RawText, UpdatedAt: record.UpdatedAt,
	}
	if record.SummaryJSON != "" {
		var summary collaborationResultSummary
		if err := json.Unmarshal([]byte(record.SummaryJSON), &summary); err == nil {
			result.Summary = &summary
		}
	}
	return result, nil
}

func parseCollaborationSummary(value string) *collaborationResultSummary {
	const startMarker = "[SEREIN_RESULT]"
	const endMarker = "[/SEREIN_RESULT]"
	start := strings.LastIndex(value, startMarker)
	if start < 0 {
		return nil
	}
	start += len(startMarker)
	endOffset := strings.Index(value[start:], endMarker)
	if endOffset < 0 {
		return nil
	}
	block := strings.TrimSpace(value[start : start+endOffset])
	if len(block) == 0 || len(block) > 64*1024 {
		return nil
	}
	var summary collaborationResultSummary
	if err := json.Unmarshal([]byte(block), &summary); err != nil {
		return nil
	}
	if len(summary.Cause) > 16000 || len(summary.ChangeSummary) > 16000 ||
		len(summary.TestResult) > 16000 || len(summary.SuggestedReply) > 32000 ||
		len(summary.TestsRun) > 100 || len(summary.Unresolved) > 100 {
		return nil
	}
	return &summary
}

// CollaborationResult exposes only data produced by the real Agent session.
// If the marker is absent, structured_available remains false.
func (a *AgentRelay) CollaborationResult(w http.ResponseWriter, r *http.Request) {
	scope := strings.TrimSpace(r.URL.Query().Get("scope"))
	if !isSafeWorkScope(scope) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid work scope"})
		return
	}
	a.mu.RLock()
	run := a.collaborationRuns[scope]
	if run == nil {
		a.mu.RUnlock()
		loaded, err := a.loadCollaborationRun(scope)
		if err != nil {
			log.Printf("collaboration result load failed: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "collaboration result unavailable"})
			return
		}
		if loaded == nil {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "collaboration result not found"})
			return
		}
		a.mu.Lock()
		if a.collaborationRuns == nil {
			a.collaborationRuns = make(map[string]*collaborationRun)
		}
		if a.collaborationRuns[scope] == nil {
			a.collaborationRuns[scope] = loaded
		}
		run = a.collaborationRuns[scope]
		a.mu.Unlock()
		a.mu.RLock()
	}
	response := map[string]interface{}{
		"work_scope": run.Scope, "status": run.Status, "project": run.Project,
		"agent_type": run.AgentType, "agent_session_id": run.AgentSessionID,
		"raw_result": run.RawText, "structured_available": run.Summary != nil,
		"updated_at": run.UpdatedAt.Format(time.RFC3339Nano),
	}
	if run.Summary != nil {
		copyValue := *run.Summary
		response["summary"] = copyValue
	}
	a.mu.RUnlock()
	writeJSON(w, http.StatusOK, response)
}

func (a *AgentRelay) DeleteCollaborationResult(w http.ResponseWriter, r *http.Request) {
	scope := strings.TrimSpace(r.URL.Query().Get("scope"))
	if !isSafeWorkScope(scope) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid work scope"})
		return
	}
	a.mu.Lock()
	delete(a.collaborationRuns, scope)
	a.mu.Unlock()
	if a.collaborationRepo != nil {
		if err := a.collaborationRepo.Delete(scope); err != nil {
			log.Printf("collaboration result delete failed: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "collaboration result delete failed"})
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
