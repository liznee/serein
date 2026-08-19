package store

import (
	"context"
	"database/sql"
	"errors"
	"testing"
)

// openTestDB 打开内存 SQLite 并返回 db + 所有 repo。
// 所有测试共享此 fixture。
func openTestDB(t *testing.T) (*sql.DB, *DeviceRepo, *WhitelistRepo, *BlacklistRepo, *SessionRepo) {
	t.Helper()
	db, err := Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db,
		NewDeviceRepo(db),
		NewWhitelistRepo(db),
		NewBlacklistRepo(db),
		NewSessionRepo(db)
}

// ── DeviceRepo ──

func TestDevicePair(t *testing.T) {
	_, dr, _, _, _ := openTestDB(t)
	dev, err := dr.Pair("d1", "my-phone", "tok-abc")
	if err != nil {
		t.Fatal(err)
	}
	if dev.ID != "d1" || dev.DeviceName != "my-phone" || dev.ClientToken != "tok-abc" {
		t.Errorf("unexpected device: %+v", dev)
	}
	if dev.PairedAt.IsZero() {
		t.Error("paired_at should not be zero")
	}
}

func TestDeviceByClientTokenFound(t *testing.T) {
	_, dr, _, _, _ := openTestDB(t)
	_, _ = dr.Pair("d1", "phone", "tok-xyz")
	dev, err := dr.ByClientToken(context.Background(), "tok-xyz")
	if err != nil {
		t.Fatal(err)
	}
	if dev == nil || dev.DeviceName != "phone" {
		t.Errorf("want phone, got %+v", dev)
	}
}

func TestDeviceByClientTokenNotFound(t *testing.T) {
	_, dr, _, _, _ := openTestDB(t)
	dev, err := dr.ByClientToken(context.Background(), "tok-none")
	if err != nil {
		t.Fatal(err)
	}
	if dev != nil {
		t.Error("want nil for unknown token")
	}
}

func TestDevicePairAllowsOnlyOneDeviceUntilUnpaired(t *testing.T) {
	_, dr, _, _, _ := openTestDB(t)
	if _, err := dr.Pair("d1", "a", "tok-a"); err != nil {
		t.Fatal(err)
	}
	if _, err := dr.Pair("d2", "b", "tok-b"); !errors.Is(err, ErrDeviceAlreadyPaired) {
		t.Fatalf("second device err=%v, want ErrDeviceAlreadyPaired", err)
	}
	list, err := dr.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].ID != "d1" {
		t.Errorf("want only d1, got %+v", list)
	}
	if err := dr.Unpair("tok-a"); err != nil {
		t.Fatal(err)
	}
	if _, err := dr.Pair("d2", "b", "tok-b"); err != nil {
		t.Fatalf("pair after unpair: %v", err)
	}
}

func TestDeviceUnpair(t *testing.T) {
	_, dr, _, _, _ := openTestDB(t)
	_, _ = dr.Pair("d1", "phone", "tok-del")
	if err := dr.Unpair("tok-del"); err != nil {
		t.Fatal(err)
	}
	dev, _ := dr.ByClientToken(context.Background(), "tok-del")
	if dev != nil {
		t.Error("want nil after unpair")
	}
}

// ── WhitelistRepo ──

func TestWhitelistCRUD(t *testing.T) {
	_, _, wr, _, _ := openTestDB(t)
	e, err := wr.Add(`^git status$`, "git status")
	if err != nil {
		t.Fatal(err)
	}
	if e.ID == 0 {
		t.Error("want non-zero id")
	}

	list, err := wr.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 {
		t.Fatalf("want 1, got %d", len(list))
	}

	ok, err := wr.Remove(e.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Error("want removed")
	}

	list, _ = wr.List()
	if len(list) != 0 {
		t.Errorf("want 0 after remove, got %d", len(list))
	}
}

func TestWhitelistRemoveNotFound(t *testing.T) {
	_, _, wr, _, _ := openTestDB(t)
	ok, err := wr.Remove(999)
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Error("want false for non-existent id")
	}
}

func TestWhitelistMatch(t *testing.T) {
	_, _, wr, _, _ := openTestDB(t)
	_, _ = wr.Add(`^go test`, "go test whitelisted")

	desc, ok := wr.Match("go test ./...")
	if !ok {
		t.Fatal("want match")
	}
	if desc != "go test whitelisted" {
		t.Errorf("want 'go test whitelisted', got %q", desc)
	}

	// 不匹配
	_, ok = wr.Match("rm -rf /")
	if ok {
		t.Error("want no match for rm -rf")
	}
}

// ── BlacklistRepo ──

func TestBlacklistCRUD(t *testing.T) {
	_, _, _, br, _ := openTestDB(t)
	e, err := br.Add(`^rm\b`, "any rm")
	if err != nil {
		t.Fatal(err)
	}
	if e.ID == 0 {
		t.Error("want non-zero id")
	}

	list, err := br.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 {
		t.Fatalf("want 1, got %d", len(list))
	}

	ok, err := br.Remove(e.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Error("want removed")
	}
}

func TestBlacklistMatch(t *testing.T) {
	_, _, _, br, _ := openTestDB(t)
	_, _ = br.Add(`^scp\b`, "scp blocked")

	desc, ok := br.Match("scp file remote:/tmp")
	if !ok {
		t.Fatal("want match")
	}
	if desc != "scp blocked" {
		t.Errorf("want 'scp blocked', got %q", desc)
	}
}

// ── SessionRepo ──

func TestSessionRememberAndIsKnown(t *testing.T) {
	_, _, _, _, sr := openTestDB(t)
	if err := sr.Remember("s1", "echo hello"); err != nil {
		t.Fatal(err)
	}

	known, err := sr.IsKnown("s1", "echo hello")
	if err != nil {
		t.Fatal(err)
	}
	if !known {
		t.Error("want known")
	}

	// 不同 session 未知
	known, err = sr.IsKnown("s2", "echo hello")
	if err != nil {
		t.Fatal(err)
	}
	if known {
		t.Error("want unknown for different session")
	}

	// 同 session 不同命令未知
	known, err = sr.IsKnown("s1", "echo goodbye")
	if err != nil {
		t.Fatal(err)
	}
	if known {
		t.Error("want unknown for different command")
	}
}

func TestSessionRememberIdempotent(t *testing.T) {
	_, _, _, _, sr := openTestDB(t)
	if err := sr.Remember("s1", "cmd"); err != nil {
		t.Fatal(err)
	}
	// 第二次 Remember 不应报错
	if err := sr.Remember("s1", "cmd"); err != nil {
		t.Fatalf("duplicate remember should not error: %v", err)
	}
}

func TestSessionForgetSession(t *testing.T) {
	_, _, _, _, sr := openTestDB(t)
	_ = sr.Remember("s1", "cmd1")
	_ = sr.Remember("s2", "cmd2")

	if err := sr.ForgetSession("s1"); err != nil {
		t.Fatal(err)
	}

	known, _ := sr.IsKnown("s1", "cmd1")
	if known {
		t.Error("s1 should be forgotten")
	}
	known, _ = sr.IsKnown("s2", "cmd2")
	if !known {
		t.Error("s2 should still exist")
	}
}

func TestHashCommand(t *testing.T) {
	h1 := HashCommand("echo hello")
	h2 := HashCommand("echo hello")
	h3 := HashCommand("echo world")
	if h1 != h2 {
		t.Error("same command should have same hash")
	}
	if h1 == h3 {
		t.Error("different commands should have different hashes")
	}
	if len(h1) != 64 {
		t.Errorf("want 64-char hex, got %d", len(h1))
	}
}

// ── CommandRepo ──

// openTestDBWithCmdRepo 打开内存 SQLite 并返回 CommandRepo。
func openTestDBWithCmdRepo(t *testing.T) (*sql.DB, *CommandRepo) {
	t.Helper()
	db, err := Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db, NewCommandRepo(db)
}

func TestCommandRepoStatsByProject(t *testing.T) {
	_, cr := openTestDBWithCmdRepo(t)
	// 写入两个项目的命令记录
	if err := cr.Save("c1", "chat", "serein", "session-1", true, 100); err != nil {
		t.Fatal(err)
	}
	if err := cr.Save("c2", "exec", "serein", "session-1", false, 200); err != nil {
		t.Fatal(err)
	}
	if err := cr.Save("c3", "chat", "environment", "session-2", true, 50); err != nil {
		t.Fatal(err)
	}

	stats, err := cr.StatsByProject(7)
	if err != nil {
		t.Fatal(err)
	}
	if len(stats) != 2 {
		t.Fatalf("want 2 projects, got %d", len(stats))
	}
	// serein 应排第一（2 条 > 1 条）
	if stats[0].Project != "serein" {
		t.Errorf("want serein first, got %s", stats[0].Project)
	}
	if stats[0].Count != 2 || stats[0].SuccessCnt != 1 || stats[0].FailCnt != 1 {
		t.Errorf("serein stats mismatch: %+v", stats[0])
	}
	if stats[0].AvgMs != 150 { // (100+200)/2
		t.Errorf("serein avg_ms want 150, got %d", stats[0].AvgMs)
	}
}

func TestCommandRepoDailyStats(t *testing.T) {
	_, cr := openTestDBWithCmdRepo(t)
	if err := cr.Save("c1", "chat", "serein", "session-1", true, 100); err != nil {
		t.Fatal(err)
	}
	if err := cr.Save("c2", "exec", "serein", "session-1", false, 200); err != nil {
		t.Fatal(err)
	}

	daily, err := cr.DailyStats(7)
	if err != nil {
		t.Fatal(err)
	}
	if len(daily) != 1 {
		t.Fatalf("want 1 day, got %d", len(daily))
	}
	if daily[0].Total != 2 || daily[0].SuccessCnt != 1 || daily[0].FailCnt != 1 {
		t.Errorf("daily stats mismatch: %+v", daily[0])
	}
}

func TestCommandRepoStatsByProjectEmpty(t *testing.T) {
	_, cr := openTestDBWithCmdRepo(t)
	stats, err := cr.StatsByProject(7)
	if err != nil {
		t.Fatal(err)
	}
	if stats != nil {
		t.Errorf("want nil for empty, got %v", stats)
	}
}

func TestActivityRepoRecentIncludesProjectAndSession(t *testing.T) {
	db, cr := openTestDBWithCmdRepo(t)
	if err := cr.Save("c1", "chat", "environment", "session-42", true, 125); err != nil {
		t.Fatal(err)
	}

	items, err := NewActivityRepo(db).Recent(5)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("want 1 activity, got %d", len(items))
	}
	if items[0].Project != "environment" || items[0].SessionID != "session-42" {
		t.Fatalf("activity identity mismatch: %+v", items[0])
	}
	if items[0].Action != "chat" || !items[0].Success {
		t.Fatalf("activity result mismatch: %+v", items[0])
	}
}

func TestActivityRepoReturnsFinalSessionEventsWithoutDuplicates(t *testing.T) {
	db, _ := openTestDBWithCmdRepo(t)
	repo := NewActivityRepo(db)
	if err := repo.SaveSessionEvent("session-1", 42, "serein", "completed", "end_turn"); err != nil {
		t.Fatal(err)
	}
	if err := repo.SaveSessionEvent("session-1", 42, "serein", "completed", "end_turn"); err != nil {
		t.Fatal(err)
	}
	items, err := repo.Recent(10)
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, item := range items {
		if item.Type == "session" {
			count++
			if item.Action != "completed" || item.Project != "serein" || item.SessionID != "session-1" || !item.Success {
				t.Fatalf("unexpected session event: %+v", item)
			}
		}
	}
	if count != 1 {
		t.Fatalf("session event count = %d, want 1", count)
	}
}
