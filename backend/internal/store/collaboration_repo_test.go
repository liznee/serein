package store

import (
	"testing"
	"time"
)

func TestCollaborationRunRepoRoundTripAndCleanup(t *testing.T) {
	db, _, _, _, _ := openTestDB(t)
	repo := NewCollaborationRunRepo(db)
	now := time.Now().UTC().Truncate(time.Second)
	value := CollaborationRunRecord{
		WorkScope: "collab:abc", TransportID: "transport", Provider: "github",
		RepositoryID: "repo", ItemKind: "issue", ItemNumber: "12", Project: "serein",
		AgentType: "codex", AgentSessionID: "123e4567-e89b-42d3-a456-426614174000",
		Status: "completed", RawText: "real output", SummaryJSON: `{"cause":"root"}`, UpdatedAt: now,
	}
	if err := repo.Upsert(value); err != nil {
		t.Fatal(err)
	}
	got, err := repo.Get(value.WorkScope)
	if err != nil || got == nil {
		t.Fatalf("get: value=%#v err=%v", got, err)
	}
	if got.RawText != value.RawText || got.AgentSessionID != value.AgentSessionID || got.Status != "completed" {
		t.Fatalf("unexpected record: %#v", got)
	}
	value.Status = "working"
	value.RawText = ""
	value.UpdatedAt = now.Add(time.Hour)
	if err := repo.Upsert(value); err != nil {
		t.Fatal(err)
	}
	got, err = repo.Get(value.WorkScope)
	if err != nil || got == nil || got.Status != "working" || got.RawText != "" {
		t.Fatalf("upsert did not replace record: %#v err=%v", got, err)
	}
	if err := repo.DeleteOlderThan(now.Add(2 * time.Hour)); err != nil {
		t.Fatal(err)
	}
	got, err = repo.Get(value.WorkScope)
	if err != nil || got != nil {
		t.Fatalf("cleanup failed: %#v err=%v", got, err)
	}
	if err := repo.Upsert(value); err != nil {
		t.Fatal(err)
	}
	if err := repo.Delete(value.WorkScope); err != nil {
		t.Fatal(err)
	}
	got, err = repo.Get(value.WorkScope)
	if err != nil || got != nil {
		t.Fatalf("explicit delete failed: %#v err=%v", got, err)
	}
}
