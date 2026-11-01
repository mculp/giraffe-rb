# PR Graph failure journal contract v1

## Authority and identity

Each run has a third append-only stream:

```text
runs/<ticket>-<date>-<run-uuid>.failures.jsonl
```

`failure-contract-v1.json` defines its envelope, finding occurrences, recurrence stops, and the
three-cycle cap. `scripts/failure_log.rb` validates and appends it under a sidecar lock.
`scripts/failures.rb` validates or replays it. The journal is the queue authority; execution JSONL
still owns graph transitions and artifact JSONL still owns evidence.

Every occurrence records:

- a stable `failure_id` for the cause across candidates;
- an immutable occurrence UUID;
- source node and attempt UUID;
- the candidate Git SHA;
- an immutable source revision, such as a spec-run digest, CI build ID, bot comment ID, or review
  finding ID;
- reason and source evidence artifact UUIDs.

Timestamps and reason text are not identity. Repeating the same failure, source, candidate, and
revision is an idempotent retry. Changing its persisted reason or evidence is a conflict.

## BUILD batches

After the initial forward BUILD, a later BUILD requires a non-empty journal queue. Its immutable
coordinator lease records one batch UUID and groups every pending occurrence by `failure_id`.
Multiple CI, bot, or review reports of the same cause remain auditable occurrences but produce one
batch item. The lease claims each occurrence exactly once.

Queue state is derived by replay:

- `pending`: journaled but not claimed by a BUILD lease;
- `processing`: claimed by an open BUILD attempt;
- `processed`: claimed by a completed BUILD attempt.

An empty queue never creates a repair BUILD. A missing or corrupt lease, duplicate claim,
non-current candidate, journal write failure, malformed identity, or unsupported contract version
fails closed.

## Recurrence cap

For a new occurrence, replay walks completed BUILD batches backward. Batches containing the same
failure identity count until a batch without it resets the streak. If three consecutive batches
contain the identity, the next report appends both the occurrence and a `stop` event with the three
batch UUIDs. The reporting attempt can close, but the coordinator rejects all future node starts.

This history survives interruption and does not depend on chat memory. A user may inspect it with:

```bash
ruby "$PR_GRAPH_SCRIPTS/failures.rb" replay "$FAILURES" "$EVENTS"
```

## Executable evidence

Run:

```bash
plugins/pr-graph/skills/pr-graph/tests/failure_queue_test.sh
plugins/pr-graph/skills/pr-graph/tests/coordinator_test.sh
```

The tests cover concurrent writes, revision deduplication and conflict, cross-source occurrences,
batch grouping, in-process resume, recurrence reset, durable stop, coordinator refusal, broad
candidate invalidation, and local replay without an optional service.
