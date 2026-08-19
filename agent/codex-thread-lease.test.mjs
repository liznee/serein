import assert from "node:assert/strict";
import test from "node:test";

import { CodexThreadLeaseManager } from "./codex-thread-lease.mjs";

test("allows one owner to acquire and renew a thread lease", () => {
  let now = 1000;
  const manager = new CodexThreadLeaseManager({
    ttlMs: 100,
    now: () => now,
    idGenerator: () => "lease-1",
  });

  const acquired = manager.acquire("thread-1", "phone-1");
  assert.equal(acquired.granted, true);
  assert.equal(acquired.leaseId, "lease-1");
  assert.equal(acquired.expiresAt, 1100);

  now = 1050;
  const renewed = manager.renew("thread-1", "lease-1", "phone-1");
  assert.equal(renewed.granted, true);
  assert.equal(renewed.expiresAt, 1150);
});

test("rejects a second owner and invalid release", () => {
  const manager = new CodexThreadLeaseManager({ idGenerator: () => "lease-1" });
  const acquired = manager.acquire("thread-1", "phone-1");

  assert.equal(manager.acquire("thread-1", "phone-2").granted, false);
  assert.equal(manager.release("thread-1", acquired.leaseId, "phone-2").released, false);
  assert.equal(manager.assertOwner("thread-1", acquired.leaseId, "phone-1").granted, true);
});

test("expires leases without exposing the previous owner", () => {
  let now = 0;
  const manager = new CodexThreadLeaseManager({ ttlMs: 10, now: () => now });
  manager.acquire("thread-1", "phone-1");
  now = 11;

  const result = manager.acquire("thread-1", "phone-2");
  assert.equal(result.granted, true);
  assert.equal(result.ownerDeviceId, "phone-2");
});
