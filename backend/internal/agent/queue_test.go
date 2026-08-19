package agent

import (
	"context"
	"sync"
	"testing"
	"time"
)

// TestEnqueueCmd_Timeout verifies that EnqueueCmd returns a timeout result
// and that late NotifyResult cannot overwrite the timeout result.
func TestEnqueueCmd_Timeout(t *testing.T) {
	q := NewQueue(20)
	cmd := &Command{Action: ActionChat, Project: "test", Command: "hello"}

	// Very short timeout to trigger the timeout path
	ctx := context.Background()
	result := q.EnqueueCmd(ctx, cmd, 10*time.Millisecond)

	if result == nil {
		t.Fatal("expected a result, got nil")
	}
	if result.Success {
		t.Error("expected Success=false for timeout")
	}
	if result.Output != "timeout waiting for agent" {
		t.Errorf("expected 'timeout waiting for agent', got %v", result.Output)
	}
	if result.Action != ActionChat {
		t.Errorf("expected Action=%s, got %s", ActionChat, result.Action)
	}

	// Late NotifyResult should be rejected (cmd removed by removeCmd,
	// NotifyResult checks q.commands first and returns early if cmd not found).
	// Verify timeout result persists in history.
	notified := make(chan bool, 1)
	go func() {
		q.NotifyResult(cmd.ID, true, "late result")
		notified <- true
	}()
	select {
	case <-notified:
		// NotifyResult completed, verify history still shows timeout
		history := q.History(10)
		if len(history) == 0 {
			t.Fatal("expected at least 1 history entry")
		}
		if history[0].CmdID != cmd.ID {
			t.Errorf("expected cmd ID %s, got %s", cmd.ID, history[0].CmdID)
		}
		if history[0].Success {
			t.Error("expected history entry to show Success=false (timeout should not be overwritten)")
		}
	case <-time.After(time.Second):
		t.Fatal("NotifyResult blocked, possible deadlock")
	}
}

// TestEnqueueCmd_ContextCancel verifies that context cancellation returns a cancel result
// and that the command is properly cleaned up.
func TestEnqueueCmd_ContextCancel(t *testing.T) {
	q := NewQueue(20)
	cmd := &Command{Action: ActionExec, Project: "test", Command: "ls -la"}

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Cancel immediately

	result := q.EnqueueCmd(ctx, cmd, time.Minute)

	if result == nil {
		t.Fatal("expected a result, got nil")
	}
	if result.Success {
		t.Error("expected Success=false for cancelled context")
	}
	if result.Output != "request cancelled" {
		t.Errorf("expected 'request cancelled', got %v", result.Output)
	}
	if result.Action != ActionExec {
		t.Errorf("expected Action=%s, got %s", ActionExec, result.Action)
	}
}

// TestEnqueueCmd_NormalPath verifies normal command execution flow:
// enqueue -> dequeue -> notify result -> return result
func TestEnqueueCmd_NormalPath(t *testing.T) {
	q := NewQueue(20)
	cmd := &Command{Action: ActionExec, Project: "test", Command: "echo hi"}

	// Run EnqueueCmd in a goroutine since it blocks
	var wg sync.WaitGroup
	wg.Add(1)
	var result *Result
	go func() {
		defer wg.Done()
		ctx := context.Background()
		result = q.EnqueueCmd(ctx, cmd, 5*time.Second)
	}()

	// Dequeue and notify
	time.Sleep(50 * time.Millisecond)
	dequeued := q.Dequeue(context.Background(), time.Second)
	if dequeued == nil {
		t.Fatal("expected a dequeued command, got nil")
	}
	if dequeued.Action != ActionExec {
		t.Errorf("expected ActionExec, got %s", dequeued.Action)
	}

	q.NotifyResult(dequeued.ID, true, map[string]string{"stdout": "hi\n"})

	wg.Wait()
	if result == nil {
		t.Fatal("expected a result, got nil")
	}
	if !result.Success {
		t.Error("expected Success=true")
	}
}

// TestNotifyResult_DuplicateRejection verifies that duplicate NotifyResult
// calls for the same cmdID are rejected (identity binding).
func TestNotifyResult_DuplicateRejection(t *testing.T) {
	q := NewQueue(20)
	cmd := &Command{Action: ActionChat, Project: "test", Command: "hello"}
	cmd.ID = "test-cmd-1"
	cmd.CreatedAt = time.Now()

	// Directly register the command in the queue
	q.mu.Lock()
	q.commands[cmd.ID] = cmd
	q.mu.Unlock()

	// First NotifyResult should succeed
	q.NotifyResult(cmd.ID, true, "first result")

	// Second NotifyResult should be rejected
	q.NotifyResult(cmd.ID, false, "second result must not overwrite")

	// History should retain the first result
	history := q.History(10)
	if len(history) == 0 {
		t.Fatal("expected history entry")
	}
	if !history[0].Success {
		t.Error("expected first result (Success=true) to persist, not be overwritten")
	}
}

// TestGetCmd_NilForMissing verifies GetCmd returns nil for non-existent cmdID.
func TestGetCmd_NilForMissing(t *testing.T) {
	q := NewQueue(20)
	cmd := q.GetCmd("nonexistent-id")
	if cmd != nil {
		t.Error("expected nil for non-existent cmdID")
	}
}

// TestHistory_Order verifies history maintains FIFO order.
func TestHistory_Order(t *testing.T) {
	q := NewQueue(20)
	q.recordResult(&Result{CmdID: "cmd1", Success: true, Output: "first"})
	q.recordResult(&Result{CmdID: "cmd2", Success: true, Output: "second"})
	q.recordResult(&Result{CmdID: "cmd3", Success: false, Output: "third"})

	history := q.History(10)
	if len(history) != 3 {
		t.Fatalf("expected 3 history entries, got %d", len(history))
	}
	if history[0].CmdID != "cmd1" || history[2].CmdID != "cmd3" {
		t.Errorf("expected FIFO order: cmd1, cmd2, cmd3; got %s, %s, %s", history[0].CmdID, history[1].CmdID, history[2].CmdID)
	}
}

// TestEvictCompletedCommands verifies cleanup behavior.
func TestEvictCompletedCommands(t *testing.T) {
	q := NewQueue(20)

	// Add commands directly to the map
	cmd1 := &Command{ID: "cmd-completed", Action: ActionExec, CreatedAt: time.Now()}
	cmd2 := &Command{ID: "cmd-pending", Action: ActionChat, CreatedAt: time.Now()}

	q.mu.Lock()
	// Only cmd1 has a history entry
	q.commands[cmd1.ID] = cmd1
	q.commands[cmd2.ID] = cmd2
	q.history = append(q.history, &Result{CmdID: "cmd-completed", Success: true})
	q.mu.Unlock()

	q.evictCompletedCommands()

	if q.GetCmd("cmd-completed") != nil {
		t.Error("expected completed cmd to be evicted")
	}
	if q.GetCmd("cmd-pending") == nil {
		t.Error("expected pending cmd (no history) to remain in commands")
	}
}

// TestSteps_NoCrossContamination verifies Steps() returns only steps for the requested cmdID.
func TestSteps_NoCrossContamination(t *testing.T) {
	q := NewQueue(20)
	q.NotifyStep(&Step{CmdID: "cmd-a", Seq: 1, Event: "text", Content: "a1"})
	q.NotifyStep(&Step{CmdID: "cmd-b", Seq: 1, Event: "text", Content: "b1"})
	q.NotifyStep(&Step{CmdID: "cmd-a", Seq: 2, Event: "text", Content: "a2"})

	steps := q.Steps("cmd-a", 0)
	if len(steps) != 2 {
		t.Fatalf("expected 2 steps for cmd-a, got %d", len(steps))
	}
	for _, s := range steps {
		if s.CmdID != "cmd-a" {
			t.Errorf("expected step for cmd-a, got cmd=%s", s.CmdID)
		}
	}
}

// TestEnqueueOnly_DoesNotBlock verifies EnqueueOnly is non-blocking.
func TestEnqueueOnly_DoesNotBlock(t *testing.T) {
	q := NewQueue(20)
	done := make(chan bool, 1)
	go func() {
		id := q.EnqueueOnly(&Command{Action: ActionChat, Project: "test", Command: "non-blocking"})
		if id == "" {
			t.Error("expected non-empty cmd ID")
		}
		done <- true
	}()
	select {
	case <-done:
		// Success
	case <-time.After(time.Second):
		t.Fatal("EnqueueOnly blocked, but should be non-blocking")
	}
}
