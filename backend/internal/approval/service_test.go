package approval

import (
	"context"
	"testing"
	"time"

	"serein/internal/store"
)

func newTestService(t *testing.T, timeoutSec int) *Service {
	t.Helper()
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return NewService(db, timeoutSec)
}

func TestCreateAndGet(t *testing.T) {
	svc := newTestService(t, 300)
	rec, err := svc.Create(context.Background(), CreateReq{
		SessionID: "s1", ToolName: "Bash", Command: "rm -rf x",
		RiskLevel: LevelRed, RuleReason: "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if rec.Decision != DecisionPending {
		t.Errorf("want pending, got %s", rec.Decision)
	}
	if rec.ID == "" {
		t.Error("want non-empty id")
	}
	got, err := svc.Get(context.Background(), rec.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Command != "rm -rf x" {
		t.Errorf("command mismatch: %s", got.Command)
	}
}

func TestStatusPending(t *testing.T) {
	svc := newTestService(t, 300)
	rec, err := svc.Create(context.Background(), CreateReq{
		SessionID: "s1", ToolName: "Bash", Command: "rm", RiskLevel: LevelRed, RuleReason: "test"})
	if err != nil {
		t.Fatal(err)
	}
	decision, _, err := svc.Status(context.Background(), rec.ID)
	if err != nil {
		t.Fatal(err)
	}
	if decision != DecisionPending {
		t.Errorf("want pending, got %s", decision)
	}
}

func TestDecideAllow(t *testing.T) {
	svc := newTestService(t, 300)
	rec, _ := svc.Create(context.Background(), CreateReq{
		SessionID: "s1", ToolName: "Bash", Command: "rm -rf x", RiskLevel: LevelRed})
	updated, err := svc.Decide(context.Background(), rec.ID, DecisionAllow, "iPhone")
	if err != nil {
		t.Fatal(err)
	}
	if !updated {
		t.Error("want updated=true")
	}
	decision, _, err := svc.Status(context.Background(), rec.ID)
	if err != nil {
		t.Fatal(err)
	}
	if decision != DecisionAllow {
		t.Errorf("want allow, got %s", decision)
	}
}

func TestDecideDeny(t *testing.T) {
	svc := newTestService(t, 300)
	rec, _ := svc.Create(context.Background(), CreateReq{
		SessionID: "s1", ToolName: "Bash", Command: "rm", RiskLevel: LevelRed})
	updated, _ := svc.Decide(context.Background(), rec.ID, DecisionDeny, "iPhone")
	if !updated {
		t.Error("want updated=true")
	}
	decision, _, _ := svc.Status(context.Background(), rec.ID)
	if decision != DecisionDeny {
		t.Errorf("want deny, got %s", decision)
	}
}

func TestDecideIdempotent(t *testing.T) {
	svc := newTestService(t, 300)
	rec, _ := svc.Create(context.Background(), CreateReq{
		SessionID: "s1", ToolName: "Bash", Command: "rm", RiskLevel: LevelRed})
	updated1, _ := svc.Decide(context.Background(), rec.ID, DecisionAllow, "iPhone")
	updated2, _ := svc.Decide(context.Background(), rec.ID, DecisionDeny, "iPhone")
	if !updated1 {
		t.Error("first decide should update")
	}
	if updated2 {
		t.Error("second decide should be idempotent (no update)")
	}
	// 最终应为 allow(第一次)
	decision, _, _ := svc.Status(context.Background(), rec.ID)
	if decision != DecisionAllow {
		t.Errorf("want allow (first decision wins), got %s", decision)
	}
}

func TestTimeout(t *testing.T) {
	svc := newTestService(t, 1) // 1 秒超时
	rec, _ := svc.Create(context.Background(), CreateReq{
		SessionID: "s1", ToolName: "Bash", Command: "rm", RiskLevel: LevelRed})
	time.Sleep(1500 * time.Millisecond) // 等超时
	decision, _, err := svc.Status(context.Background(), rec.ID)
	if err != nil {
		t.Fatal(err)
	}
	if decision != DecisionDeny {
		t.Errorf("want deny(timeout), got %s", decision)
	}
}

func TestDecideAfterTimeout(t *testing.T) {
	svc := newTestService(t, 1)
	rec, _ := svc.Create(context.Background(), CreateReq{
		SessionID: "s1", ToolName: "Bash", Command: "rm", RiskLevel: LevelRed})
	time.Sleep(1500 * time.Millisecond)
	svc.Status(context.Background(), rec.ID) // 触发 timeout 标记
	updated, _ := svc.Decide(context.Background(), rec.ID, DecisionAllow, "iPhone")
	if updated {
		t.Error("decide after timeout should not update")
	}
}

func TestStatusNotFound(t *testing.T) {
	svc := newTestService(t, 300)
	_, _, err := svc.Status(context.Background(), "nonexistent")
	if err != ErrNotFound {
		t.Errorf("want ErrNotFound, got %v", err)
	}
}

func TestList(t *testing.T) {
	svc := newTestService(t, 300)
	for i := 0; i < 3; i++ {
		svc.Create(context.Background(), CreateReq{
			SessionID: "s1", ToolName: "Bash", Command: "rm", RiskLevel: LevelRed})
	}
	items, total, err := svc.List(context.Background(), 10, 0, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if total != 3 || len(items) != 3 {
		t.Errorf("want 3 items, got total=%d len=%d", total, len(items))
	}
}

// TestListTimedOutPendingFindsTimeoutRecords 验证核心修复：
// hook 每 1s 轮询 Status 会将 pending→timeout，扫描器（30s 间隔）运行时
// 记录已经是 timeout 状态。ListTimedOutPending 必须能找到这些记录，
// 否则超时通知永远不会被推送。
func TestListTimedOutPendingFindsTimeoutRecords(t *testing.T) {
	svc := newTestService(t, 1) // 1 秒超时
	rec, _ := svc.Create(context.Background(), CreateReq{
		SessionID: "s1", ToolName: "Bash", Command: "rm -rf x", RiskLevel: LevelRed})
	time.Sleep(1500 * time.Millisecond) // 等超时

	// 模拟 hook 轮询 Status —— 这会将 pending 标记为 timeout
	decision, _, _ := svc.Status(context.Background(), rec.ID)
	if decision != DecisionDeny {
		t.Fatalf("want deny(timeout), got %s", decision)
	}

	// 扫描器查询：必须能找到已被标记为 timeout 的记录
	records, err := svc.ListTimedOutPending(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 {
		t.Fatalf("want 1 timed-out record (already marked timeout by Status), got %d", len(records))
	}
	if records[0].ID != rec.ID {
		t.Errorf("record ID mismatch: want %s, got %s", rec.ID, records[0].ID)
	}
}

// TestMarkTimeoutNotifiedDedup 验证 DB 持久化去重：
// 标记 notified 后，再次查询不应返回该记录。
func TestMarkTimeoutNotifiedDedup(t *testing.T) {
	svc := newTestService(t, 1)
	rec, _ := svc.Create(context.Background(), CreateReq{
		SessionID: "s1", ToolName: "Bash", Command: "rm", RiskLevel: LevelRed})
	time.Sleep(1500 * time.Millisecond)
	svc.Status(context.Background(), rec.ID) // 触发 timeout

	// 第一次查询：应找到记录
	records, _ := svc.ListTimedOutPending(context.Background())
	if len(records) != 1 {
		t.Fatalf("want 1 record before notify, got %d", len(records))
	}

	// 标记已通知
	if err := svc.MarkTimeoutNotified(context.Background(), rec.ID); err != nil {
		t.Fatal(err)
	}

	// 第二次查询：不应再返回该记录（已标记 notified）
	records, _ = svc.ListTimedOutPending(context.Background())
	if len(records) != 0 {
		t.Errorf("want 0 records after notify mark, got %d", len(records))
	}
}
