package store

import (
	"context"
	"testing"
)

func TestMonitoringAlertLifecycleDeduplicatesOneHundredReports(t *testing.T) {
	db, err := Open(":memory:")
	if err != nil { t.Fatal(err) }
	defer db.Close()
	repo := NewMonitoringAlertRepo(db)
	ctx := context.Background()

	for i := 0; i < 100; i++ {
		opened, err := repo.Observe(ctx, []MonitoringObservation{{Metric: "gpu_temp", Value: 80 + float64(i%20), Threshold: 80, Active: true}})
		if err != nil { t.Fatalf("report %d: %v", i, err) }
		if i == 0 && len(opened) != 1 { t.Fatalf("first report opened=%d, want 1", len(opened)) }
		if i > 0 && len(opened) != 0 { t.Fatalf("duplicate report %d opened=%d", i, len(opened)) }
	}
	summary, err := repo.Summary(ctx)
	if err != nil { t.Fatal(err) }
	if summary.Active != 1 || summary.Total != 1 { t.Fatalf("summary=%+v", summary) }
	if _, err := repo.Observe(ctx, []MonitoringObservation{{Metric: "gpu_temp", Value: 70, Threshold: 80, Active: false}}); err != nil { t.Fatal(err) }
	summary, err = repo.Summary(ctx)
	if err != nil { t.Fatal(err) }
	if summary.Active != 0 || summary.Total != 1 { t.Fatalf("resolved summary=%+v", summary) }
	opened, err := repo.Observe(ctx, []MonitoringObservation{{Metric: "gpu_temp", Value: 91, Threshold: 80, Active: true}})
	if err != nil { t.Fatal(err) }
	if len(opened) != 1 { t.Fatalf("reopened=%d, want 1", len(opened)) }
	summary, err = repo.Summary(ctx)
	if err != nil { t.Fatal(err) }
	if summary.Active != 1 || summary.Total != 2 { t.Fatalf("reopened summary=%+v", summary) }
}
