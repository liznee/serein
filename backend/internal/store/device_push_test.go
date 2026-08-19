package store

import (
	"context"
	"testing"
)

func TestDevicePushTokenIsWriteOnlyTargetData(t *testing.T) {
	db, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	repo := NewDeviceRepo(db)
	device, err := repo.Pair("device-1", "phone", "client-token")
	if err != nil {
		t.Fatal(err)
	}
	const pushToken = "push-token-abcdefghijklmnopqrstuvwxyz"
	if err := repo.SetPushToken(device.ID, pushToken); err != nil {
		t.Fatal(err)
	}

	targets, err := repo.PushTargets(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(targets) != 1 || targets[0].DeviceID != device.ID || targets[0].Token != pushToken {
		t.Fatalf("unexpected push targets: %#v", targets)
	}

	listed, err := repo.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 1 || listed[0].ID != device.ID {
		t.Fatalf("unexpected devices: %#v", listed)
	}
}

func TestSetPushTokenRejectsUnknownDevice(t *testing.T) {
	db, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := NewDeviceRepo(db).SetPushToken("missing", "push-token-abcdefghijklmnopqrstuvwxyz"); err != ErrDeviceNotFound {
		t.Fatalf("got %v, want ErrDeviceNotFound", err)
	}
}
