package session

import (
	"testing"

	"serein/internal/agent"
)

// TestGetHistory_FiltersActionChat verifies that
// GetHistory skips ActionChat results (relay mode noise).
func TestGetHistory_FiltersActionChat(t *testing.T) {
	q := agent.NewQueue(50)
	sm := NewSessionManager(q, nil)

	// Execute a full enqueue -> dequeue -> notify cycle for ActionChat.
	// The result should be filtered out by GetHistory.
	chatCmd := &agent.Command{Action: agent.ActionChat, Project: "test", Command: "hello", SessionID: "sess-1"}
	chatID := q.EnqueueOnly(chatCmd)
	q.NotifyResult(chatID, true, "chat output")

	// Execute a full cycle for ActionExec. This should appear in GetHistory.
	execCmd := &agent.Command{Action: agent.ActionExec, Project: "test", Command: "ls -la", SessionID: "sess-1"}
	execID := q.EnqueueOnly(execCmd)
	q.NotifyResult(execID, true, map[string]string{"stdout": "file1.txt\nfile2.txt\n"})

	// GetHistory should only return exec commands for the session
	history := sm.GetHistory("sess-1", 50)
	if history == nil {
		t.Fatal("expected non-nil history")
	}

	// Verify exec result is present
	var foundExec bool
	for _, msg := range history {
		if msg.Content == "ls -la" || msg.CmdID == execID {
			foundExec = true
		}
		// Chat result should NOT appear
		if msg.CmdID == chatID {
			t.Errorf("chat result cmd=%s should be filtered out but found in history", chatID)
		}
	}
	if !foundExec {
		t.Error("expected exec action to appear in history")
	}
}

// TestGetHistory_SessionIsolation verifies GetHistory only returns
// results for the requested session.
func TestGetHistory_SessionIsolation(t *testing.T) {
	q := agent.NewQueue(50)
	sm := NewSessionManager(q, nil)

	// Add results for different sessions
	cmdA := &agent.Command{Action: agent.ActionExec, Project: "test", Command: "echo a1", SessionID: "session-a"}
	idA := q.EnqueueOnly(cmdA)
	q.NotifyResult(idA, true, "a1 output")

	cmdB := &agent.Command{Action: agent.ActionExec, Project: "test", Command: "echo b1", SessionID: "session-b"}
	idB := q.EnqueueOnly(cmdB)
	q.NotifyResult(idB, true, "b1 output")

	// GetHistory for session A should only contain session A's commands
	history := sm.GetHistory("session-a", 50)
	if history == nil {
		t.Fatal("expected non-nil history for session-a")
	}
	for _, msg := range history {
		if msg.CmdID == idB {
			t.Errorf("expected session isolation: cmd=%s from session-b should not appear in session-a history", idB)
		}
	}

	// GetHistory for nonexistent session should return nil
	if h := sm.GetHistory("nonexistent", 50); h != nil {
		t.Error("expected nil history for nonexistent session")
	}
}

// TestGetHistory_EmptySessionID verifies results with empty SessionID are skipped.
func TestGetHistory_EmptySessionID(t *testing.T) {
	q := agent.NewQueue(50)
	sm := NewSessionManager(q, nil)

	cmd := &agent.Command{Action: agent.ActionExec, Project: "test", Command: "echo test", SessionID: ""}
	id := q.EnqueueOnly(cmd)
	q.NotifyResult(id, true, "test output")

	if h := sm.GetHistory("any-session", 50); h != nil {
		t.Error("expected nil history when no results match the session")
	}
}

// TestGetHistory_JSONSerializeFallback verifies the fallback text
// when Output cannot be JSON-marshaled.
func TestGetHistory_JSONSerializeFallback(t *testing.T) {
	q := agent.NewQueue(50)
	sm := NewSessionManager(q, nil)

	// Use a channel as Output (cannot be JSON-marshaled)
	ch := make(chan int)
	cmd := &agent.Command{Action: agent.ActionExec, Project: "test", Command: "bad output", SessionID: "sess-1"}
	id := q.EnqueueOnly(cmd)
	q.NotifyResult(id, true, ch)

	history := sm.GetHistory("sess-1", 50)
	if history == nil {
		t.Fatal("expected non-nil history even with bad Output")
	}

	var foundFallback bool
	for _, msg := range history {
		if msg.Content == "(content unavailable)" {
			foundFallback = true
		}
	}
	if !foundFallback {
		t.Error("expected '(content unavailable)' fallback text for non-JSON-serializable Output")
	}

	close(ch)
}

// TestSessionManager_CreateAndGetSession verifies session lifecycle.
func TestCreateAndGetSession(t *testing.T) {
	q := agent.NewQueue(20)
	sm := NewSessionManager(q, nil)

	s := sm.CreateSession("test-project")
	if s == nil {
		t.Fatal("expected non-nil session")
	}
	if s.Project != "test-project" {
		t.Errorf("expected project 'test-project', got '%s'", s.Project)
	}
	if s.ID == "" {
		t.Error("expected non-empty session ID")
	}

	// GetOrCreateSession should return the same session
	s2 := sm.GetOrCreateSession("test-project")
	if s2.ID != s.ID {
		t.Errorf("expected same session ID, got %s vs %s", s2.ID, s.ID)
	}

	// GetByProject
	s3 := sm.GetSessionByProject("test-project")
	if s3 == nil {
		t.Fatal("expected non-nil session from GetSessionByProject")
	}
	if s3.ID != s.ID {
		t.Errorf("expected same session, got different ID")
	}
}

func TestScopedSessionsAreIndependentAndRecoverable(t *testing.T) {
	sm := NewSessionManager(agent.NewQueue(20), nil)
	defer sm.Stop()

	issueOne := sm.GetOrCreateScopedSession("serein", "github:repo:issue:1")
	issueOneAgain := sm.GetOrCreateScopedSession("serein", "github:repo:issue:1")
	issueTwo := sm.GetOrCreateScopedSession("serein", "github:repo:issue:2")
	if issueOne.ID != issueOneAgain.ID {
		t.Fatal("same work item should recover the same scoped session")
	}
	if issueOne.ID == issueTwo.ID {
		t.Fatal("different work items must not share a session")
	}

	sm.JoinSession(issueOne.ID, "phone", "phone")
	sm.LeaveSession(issueOne.ID, "phone")
	if got := sm.GetSessionByID(issueOne.ID); got == nil || !got.PendingDeleteAt.IsZero() {
		t.Fatal("scoped session should survive ordinary disconnect without pending deletion")
	}
}

// TestSessionManager_JoinAndLeaveSession verifies client lifecycle.
func TestJoinAndLeaveSession(t *testing.T) {
	q := agent.NewQueue(20)
	sm := NewSessionManager(q, nil)

	s := sm.CreateSession("test")
	sm.JoinSession(s.ID, "client-1", "phone")
	sm.JoinSession(s.ID, "client-2", "terminal")

	if len(s.Clients) != 2 {
		t.Errorf("expected 2 clients, got %d", len(s.Clients))
	}

	sm.LeaveSession(s.ID, "client-1")
	if len(s.Clients) != 1 {
		t.Errorf("expected 1 client after leave, got %d", len(s.Clients))
	}

	// Leave the last client should mark session for pending deletion (not remove immediately)
	sm.LeaveSession(s.ID, "client-2")
	sAfter := sm.GetSessionByID(s.ID)
	if sAfter == nil {
		t.Fatal("expected session to still exist after last client leaves (pending delete)")
	}
	if sAfter.PendingDeleteAt.IsZero() {
		t.Error("expected PendingDeleteAt to be set after last client leaves")
	}
	// Also verify the project mapping still exists (for reconnection window)
	projSession := sm.GetSessionByProject("test")
	if projSession == nil || projSession.ID != s.ID {
		t.Error("expected project mapping to still exist after last client leaves")
	}
}

// TestIsValidChatOutput verifies the heuristic for detecting invalid chat outputs.
func TestIsValidChatOutput(t *testing.T) {
	tests := []struct {
		input    any
		expected bool
	}{
		{nil, false},
		{"", false},
		{`{"error":"previous chat still running"}`, false},
		{`{"error":"timeout"}`, false},
		{"timeout waiting for agent", false},
		{"request cancelled", false},
		{"valid output text", true},
		{map[string]string{"key": "value"}, true}, // non-string is always valid
		{42, true}, // non-string is always valid
	}

	for _, tc := range tests {
		result := isValidChatOutput(tc.input)
		if result != tc.expected {
			t.Errorf("isValidChatOutput(%v) = %v, want %v", tc.input, result, tc.expected)
		}
	}
}

// TestNextSeq_Monotonic verifies sequence numbers are monotonic.
func TestNextSeq_Monotonic(t *testing.T) {
	q := agent.NewQueue(20)
	sm := NewSessionManager(q, nil)

	seq1 := sm.NextSeq()
	seq2 := sm.NextSeq()
	seq3 := sm.NextSeq()

	if !(seq1 < seq2 && seq2 < seq3) {
		t.Errorf("expected monotonic sequence: %d, %d, %d", seq1, seq2, seq3)
	}
}
