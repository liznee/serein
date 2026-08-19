import { randomUUID } from "node:crypto";

const DEFAULT_TTL_MS = 30_000;

/**
 * In-process ownership gate for a Codex Thread.
 *
 * The lease is intentionally volatile: relay restart releases ownership.
 * A later phase can move the same contract to the backend for multi-device
 * coordination without changing the caller-facing checks.
 */
export class CodexThreadLeaseManager {
  constructor({ ttlMs = DEFAULT_TTL_MS, now = () => Date.now(), idGenerator = randomUUID } = {}) {
    this.ttlMs = ttlMs;
    this.now = now;
    this.idGenerator = idGenerator;
    this.leases = new Map();
  }

  acquire(threadId, ownerDeviceId) {
    this.#validate(threadId, ownerDeviceId);
    this.#removeExpired();
    const existing = this.leases.get(threadId);
    if (existing && existing.ownerDeviceId !== ownerDeviceId) {
      return {
        granted: false,
        reason: "thread_owned_by_other_client",
        expiresAt: existing.expiresAt,
      };
    }

    const now = this.now();
    const lease = existing || {
      threadId,
      ownerDeviceId,
      leaseId: this.idGenerator(),
      acquiredAt: now,
    };
    lease.expiresAt = now + this.ttlMs;
    this.leases.set(threadId, lease);
    return { granted: true, ...lease };
  }

  renew(threadId, leaseId, ownerDeviceId) {
    this.#validate(threadId, ownerDeviceId);
    this.#removeExpired();
    const lease = this.leases.get(threadId);
    if (!lease || lease.leaseId !== leaseId || lease.ownerDeviceId !== ownerDeviceId) {
      return { granted: false, reason: "invalid_or_expired_lease" };
    }
    lease.expiresAt = this.now() + this.ttlMs;
    return { granted: true, ...lease };
  }

  release(threadId, leaseId, ownerDeviceId) {
    this.#validate(threadId, ownerDeviceId);
    const lease = this.leases.get(threadId);
    if (!lease || lease.leaseId !== leaseId || lease.ownerDeviceId !== ownerDeviceId) {
      return { released: false, reason: "invalid_or_expired_lease" };
    }
    this.leases.delete(threadId);
    return { released: true, threadId };
  }

  assertOwner(threadId, leaseId, ownerDeviceId) {
    this.#validate(threadId, ownerDeviceId);
    this.#removeExpired();
    const lease = this.leases.get(threadId);
    if (!lease || lease.leaseId !== leaseId || lease.ownerDeviceId !== ownerDeviceId) {
      return { granted: false, reason: "invalid_or_expired_lease" };
    }
    return { granted: true, ...lease };
  }

  get(threadId) {
    this.#removeExpired();
    const lease = this.leases.get(threadId);
    return lease ? { ...lease } : null;
  }

  #validate(threadId, ownerDeviceId) {
    if (!String(threadId || "").trim()) throw new TypeError("threadId is required");
    if (!String(ownerDeviceId || "").trim()) throw new TypeError("ownerDeviceId is required");
  }

  #removeExpired() {
    const now = this.now();
    for (const [threadId, lease] of this.leases) {
      if (lease.expiresAt <= now) this.leases.delete(threadId);
    }
  }
}
