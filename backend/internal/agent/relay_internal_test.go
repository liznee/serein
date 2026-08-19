package agent

import (
	"context"
	"sync"
	"testing"
	"time"
)

// ── helpers ──

func newTestQueue() *Queue {
	return NewQueue(20)
}

func mustDequeue(t *testing.T, q *Queue) *Command {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := q.Dequeue(ctx, 2*time.Second)
	if cmd == nil {
		t.Fatal("Dequeue returned nil, expected a command")
	}
	return cmd
}

// ═══════════════════════════════════════════
// NotifyResult — 身份绑定守卫
// ═══════════════════════════════════════════

func TestNotifyResult_DuplicateReport_Rejected(t *testing.T) {
	q := newTestQueue()
	cmdID := q.EnqueueOnly(&Command{Action: ActionExec, Project: "test", Command: "echo hello"})

	// 第一次 report 应成功
	q.NotifyResult(cmdID, true, "output1")
	if !q.reported[cmdID] {
		t.Fatal("expected cmdID to be marked as reported after first NotifyResult")
	}

	// 第二次 report 同一 cmd_id 应被拒绝（reported map 守卫）
	// 验证方式是检查第二次 report 不会覆盖第一次的结果
	q.NotifyResult(cmdID, false, "output2")

	r := q.LastStatus()
	if r == nil {
		t.Fatal("expected at least one result in history")
	}
	if r.Success != true {
		t.Fatal("expected duplicate report to be rejected; history should retain first result (success=true)")
	}
	if r.Output != "output1" {
		t.Fatalf("expected output 'output1', got '%v'", r.Output)
	}
}

func TestNotifyResult_ExpiredReport_Rejected(t *testing.T) {
	q := newTestQueue()

	// 使用 EnqueueCmd 入队，然后让 context 取消触发 removeCmd
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan *Result, 1)

	go func() {
		_ = q.EnqueueCmd(ctx, &Command{Action: ActionExec, Project: "test", Command: "echo hi"}, 10*time.Second)
		done <- &Result{}
	}()

	// 等待命令入队
	time.Sleep(50 * time.Millisecond)

	// 获取入队命令 ID
	q.mu.Lock()
	var cmdID string
	if len(q.pending) > 0 {
		cmdID = q.pending[0].ID
	}
	q.mu.Unlock()
	if cmdID == "" {
		t.Fatal("no pending command found")
	}

	// 在 EnqueueCmd 返回前取消 context -> removeCmd 会被调用
	cancel()
	<-done

	// 验证命令已被 removeCmd 清理
	q.mu.Lock()
	_, cmdExists := q.commands[cmdID]
	q.mu.Unlock()
	if cmdExists {
		t.Fatal("expected cmd to be removed after ctx.Done()")
	}

	// 尝试 report 已经不存在的命令，应被静默拒绝
	q.NotifyResult(cmdID, true, "stale output")

	// 验证历史中只有取消结果（ctx.Done 分支现在写入 recordResult），且不包含过期 NotifyResult
	history := q.History(10)
	if len(history) != 1 {
		t.Fatalf("expected exactly 1 history entry (cancel result), got %d", len(history))
	}
	if history[0].Output != "request cancelled" {
		t.Fatalf("expected cancel result in history, got %v", history[0].Output)
	}
}

func TestNotifyResult_ConcurrentReport_Guard(t *testing.T) {
	q := newTestQueue()
	cmdID := q.EnqueueOnly(&Command{Action: ActionExec, Project: "test", Command: "echo concurrent"})

	var wg sync.WaitGroup
	const workers = 10
	reports := make(chan struct{}, workers)

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			output := "report from " + string(rune('A'+id))
			q.NotifyResult(cmdID, id == 0, output)
			reports <- struct{}{}
		}(i)
	}

	// 等待所有 goroutine 完成
	wg.Wait()
	close(reports)

	// 历史中应只有一条 result（第一个 report 成功，后续被拒绝）
	history := q.History(10)
	if len(history) == 0 {
		t.Fatal("expected at least one result in history")
	}

	// 验证成功只有一条结果（count results for this cmdID）
	count := 0
	for _, h := range history {
		if h.CmdID == cmdID {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("expected exactly 1 result for cmdID, got %d", count)
	}
}

// ═══════════════════════════════════════════
// EnqueueCmd — ctx.Done() / timeout 清理
// ═══════════════════════════════════════════

func TestEnqueueCmd_CtxDone_RemovesCmd(t *testing.T) {
	q := newTestQueue()

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan *Result, 1)

	go func() {
		r := q.EnqueueCmd(ctx, &Command{Action: ActionExec, Project: "test", Command: "echo cancel"}, 10*time.Second)
		done <- r
	}()

	time.Sleep(50 * time.Millisecond)
	cancel()
	r := <-done

	if r.Success != false || r.Output != "request cancelled" {
		t.Fatalf("expected cancelled result, got success=%v output=%v", r.Success, r.Output)
	}

	// 验证 removeCmd 已清理 commands 和 reported map
	q.mu.Lock()
	_, cmdExists := q.commands[r.CmdID]
	_, reportedExists := q.reported[r.CmdID]
	q.mu.Unlock()

	if cmdExists {
		t.Fatal("expected cmd to be removed from commands map after ctx.Done()")
	}
	if reportedExists {
		t.Fatal("expected cmd to be removed from reported map after ctx.Done()")
	}
}

func TestEnqueueCmd_Timeout_RemovesCmd(t *testing.T) {
	q := newTestQueue()

	r := q.EnqueueCmd(context.Background(), &Command{Action: ActionExec, Project: "test", Command: "echo timeout"}, 100*time.Millisecond)

	if r.Success != false {
		t.Fatal("expected timeout result (success=false)")
	}
	if r.Output != "timeout waiting for agent" {
		t.Fatalf("expected timeout message, got %v", r.Output)
	}

	// 验证 removeCmd 已清理
	q.mu.Lock()
	_, cmdExists := q.commands[r.CmdID]
	_, reportedExists := q.reported[r.CmdID]
	q.mu.Unlock()

	if cmdExists {
		t.Fatal("expected cmd to be removed from commands map after timeout")
	}
	if reportedExists {
		t.Fatal("expected cmd to be removed from reported map after timeout")
	}
}

// ═══════════════════════════════════════════
// evictCompletedCommands — reported map 清理
// ═══════════════════════════════════════════

func TestEvictCompletedCommands_ClearsReportedMap(t *testing.T) {
	q := newTestQueue()

	// 直接设置命令状态（绕过 EnqueueOnly 避免 pending 干扰）
	q.mu.Lock()
	ids := make([]string, 3)
	for i := 0; i < 3; i++ {
		id := generateID()
		ids[i] = id
		q.commands[id] = &Command{ID: id, Action: ActionExec, Project: "test", Command: "echo cmd", CreatedAt: time.Now()}
		q.reported[id] = true
	}
	// 往 history 添加对应 result（模拟已完成命令）
	for _, id := range ids {
		q.history = append(q.history, &Result{CmdID: id, Success: true, Output: "done"})
	}

	// pending 命令（不应被清理）
	pendingID := generateID()
	q.commands[pendingID] = &Command{ID: pendingID, Action: ActionExec, Project: "test", Command: "echo pending", CreatedAt: time.Now()}
	q.pending = append(q.pending, q.commands[pendingID])

	// 僵尸 dummy（命令存在但不在 history，应被清理）
	dummyID := generateID()
	q.commands[dummyID] = &Command{ID: dummyID, Action: ActionExec, Project: "test", Command: "echo dummy", CreatedAt: time.Now().Add(-31 * time.Minute)}

	q.mu.Unlock()

	// 触发 evictCompletedCommands
	// 注意：此函数只在 len(q.commands) > maxStoredCommands 时由 EnqueueCmd/EnqueueOnly 自动调用，
	// 此处直接调用以隔离测试逻辑
	q.mu.Lock()
	q.evictCompletedCommands()
	q.mu.Unlock()

	// 验证 completed 命令及其 reported 条目已被清理
	q.mu.Lock()
	for _, id := range ids {
		if _, exists := q.commands[id]; exists {
			t.Errorf("completed cmd %s should have been evicted from commands map", id)
		}
		if _, exists := q.reported[id]; exists {
			t.Errorf("completed cmd %s should have reported entry evicted", id)
		}
	}
	// pending 命令不应被清理
	if _, exists := q.commands[pendingID]; !exists {
		t.Fatal("pending command should remain in commands map after eviction")
	}
	// 僵尸命令应被清理
	if _, exists := q.commands[dummyID]; exists {
		t.Fatal("zombie command (>30min, no report) should be evicted")
	}
	q.mu.Unlock()
}

func TestEvictCompletedCommands_ZombieCmd(t *testing.T) {
	q := newTestQueue()

	// 入队命令后直接模拟超过 30 分钟的僵尸命令
	oldCmd := &Command{Action: ActionExec, Project: "test", Command: "echo zombie"}
	oldCmd.ID = generateID()
	oldCmd.CreatedAt = time.Now().Add(-31 * time.Minute)

	q.mu.Lock()
	q.commands[oldCmd.ID] = oldCmd
	// 不在 pending 队列中
	q.mu.Unlock()

	// 触发清理
	q.mu.Lock()
	q.evictCompletedCommands()
	q.mu.Unlock()

	// 僵尸命令应被清理
	q.mu.Lock()
	_, exists := q.commands[oldCmd.ID]
	_, reported := q.reported[oldCmd.ID]
	q.mu.Unlock()

	if exists {
		t.Fatal("expected zombie command (>30min, no report) to be evicted")
	}
	if reported {
		t.Fatal("expected zombie command's reported entry to be evicted")
	}
}

// ═══════════════════════════════════════════
// generateID — 格式 + 随机后缀
// ═══════════════════════════════════════════

func TestGenerateID_Format(t *testing.T) {
	id := generateID()
	// 格式：YYYYMMDD-HHMMSS-N-HEX16
	if len(id) < 20 {
		t.Fatalf("generateID result too short: %q (len=%d)", id, len(id))
	}
	// 应包含至少两个连字符（日期-序号-随机）
	hyphenCount := 0
	for _, c := range id {
		if c == '-' {
			hyphenCount++
		}
	}
	if hyphenCount < 2 {
		t.Fatalf("generateID %q: expected at least 2 hyphens, got %d", id, hyphenCount)
	}
}

func TestGenerateID_SequentialUniqueness(t *testing.T) {
	seen := make(map[string]bool)
	for i := 0; i < 100; i++ {
		id := generateID()
		if seen[id] {
			t.Fatalf("duplicate generateID: %q", id)
		}
		seen[id] = true
	}
}

// ═══════════════════════════════════════════
// removeCmd — 完整清理
// ═══════════════════════════════════════════

func TestRemoveCmd_CleansAllMaps(t *testing.T) {
	q := newTestQueue()

	// 使用正常路径入队
	cmdID := q.EnqueueOnly(&Command{Action: ActionExec, Project: "test", Command: "echo remove"})

	// 标记为已报告
	q.mu.Lock()
	q.reported[cmdID] = true
	q.mu.Unlock()

	// 调用 removeCmd
	q.removeCmd(cmdID)

	q.mu.Lock()
	_, cmdExists := q.commands[cmdID]
	_, reportedExists := q.reported[cmdID]
	q.mu.Unlock()

	if cmdExists {
		t.Fatal("removeCmd did not delete from commands map")
	}
	if reportedExists {
		t.Fatal("removeCmd did not delete from reported map")
	}
}
