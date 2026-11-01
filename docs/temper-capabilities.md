# Temper capabilities for later phases

These are proposed semantics, not claims about existing Temper APIs. Giraffe currently uses ordinary
artifact commits, local host locks, deterministic transition IDs, and complete sync checkpoints.
We can contribute upstream when the multi-worker/controller/frontend work needs stronger guarantees.

1. **Conditional append / compare-and-swap.** Accept `expected_revision` and an append atomically.
   Exactly one of two concurrent writers at the same revision succeeds. A stale revision returns a
   conflict without any write. This is useful for graph edits, answers, and ownership transitions.
2. **Fenced leases.** Acquiring ownership returns a monotonically increasing fencing token. Every
   mutation checks that token atomically; an expired worker cannot write after reassignment, even if
   it wakes after a long pause. TTL plus a client-side heartbeat alone is insufficient.
3. **Cursor reads and subscriptions.** Ordered committed events after an opaque cursor, a stable
   reconnect/resume contract, bounded pages, and an explicit signal for an invalid/expired cursor.
   A stream can be at-least-once if event identities remain stable for client deduplication. Access
   checks apply to each stream/read. Snapshot + cursor should have a consistent handoff boundary.
4. **Server-side idempotency keys.** Repeating the same key/payload after a lost acknowledgement
   returns the same accepted write. Reusing the key with different bytes fails. This avoids storing
   physical duplicates that consumers otherwise have to deduplicate logically.

Acceptance probes should include concurrent appenders, lease expiry/reacquisition followed by an old
worker's write, a lost success response followed by retry, disconnect/reconnect during appends, and
revoked access on a long-lived subscription. The API's ordering scope and consistency guarantees must
be explicit. These additions can stay small and independently useful to Temper consumers.
