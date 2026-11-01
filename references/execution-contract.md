# PR Graph execution contract v1

## Decision

The newline-delimited event log is the only execution authority. Every event carries the
v1 envelope defined in `execution-contract-v1.json`: contract version, run UUID, contiguous
sequence number, UTC timestamp, parent conversation identity, and event type. A projection
is always disposable and is rebuilt by replaying the log from sequence 1.

`scripts/event_log.rb` is the executable interpretation of that data contract. Producers
must not append JSON by hand. The public `scripts/events.rb` CLI accepts initialization and
telemetry only; protected lifecycle transitions go through `scripts/coordinate.rb`, which
uses the same Ruby API after checking graph policy. The writer takes a sidecar advisory lock,
validates the existing stream and proposed events, assigns sequence numbers while holding the
lock, appends complete newline-terminated records, flushes, and calls `fsync` before releasing
the lock.

The per-conversation file under `active/` is only an ephemeral hook-routing registry. It may
point telemetry at a run and label the current node, but it must never grant graph permission
or override replayed event state.

This design has no service dependency and uses only the Ruby standard library. It therefore
works offline in Claude Code and Cursor. Temper may project these events later, but neither
Temper nor any materialized database can become runtime authority.

## Contract boundary

The v1 contract encodes:

- the complete graph, dependencies, and legal forward and red edges;
- node-attempt identity and structural lifecycle (`start`, `partial`, `done`);
- outcomes and red edges bound to a known source attempt;
- parent conversation, run, candidate SHA, and PR identities;
- wake-source registration, arming, and terminal lifecycle;
- usage telemetry, including product-specific evidence sources;
- terminal `done`, pinned to the latest published candidate SHA.

The validator enforces structural transitions before append. The coordinator is responsible for
graph readiness, BUILD-only mutation authorization, evidence freshness, optional-node policy,
and gate decisions. The separate artifact v1 contract owns immutable payloads, checksums,
lineage, wake binding, and evidence coverage. Keeping those policies outside execution v1
prevents the event vocabulary from silently becoming an incomplete coordinator.

The diagram in the skill and the dependency map had one ambiguity: the VALIDATE prose said
"first green VERIFY" while the graph placed VALIDATE after PUBLISH. V1 chooses the drawn graph:
VALIDATE depends on PUBLISH and can run concurrently with the other post-publish readers.

The node list keeps `SELF-REVIEW`, and the outcome kinds keep `self_review`, so that logs written
by earlier runs replay unchanged. No dependency or forward edge leads through that node: PUBLISH
depends on VERIFY, DONE does not list it, and the coordinator policy marks it retired. Review
evidence is a BUILD output.

## Crash consistency

An incomplete final line is a torn write. Replay and append both reject it and make no change
to the authoritative log. They do not truncate or guess at repair. The recovery procedure is
to preserve the damaged file, copy it for forensic repair if needed, and start a new UUID run.
The same fail-closed rule applies to malformed JSON, non-contiguous sequence numbers, unknown
event fields, unknown contract versions, and illegal structural transitions.

The sidecar lock can remain after a crash because it carries no execution state. Operating
system advisory locks are released with the dead process. A subsequent process validates the
event log itself before appending.

## Version and legacy policy

There is no implicit v0. Existing date-named JSONL runs have useful experimental evidence but
lack stable run identity, contiguous sequences, attempt IDs, and wake lifecycle. Inferring
those fields would create false evidence. V1 therefore labels them unsupported and read-only.
The validator returns a deterministic recovery message: preserve the legacy log and start a
new v1 UUID run.

A future contract version must ship with a new contract file and an explicit pure migration.
Unknown versions are rejected. No producer may reinterpret a published version in place.

## Rejected alternatives

- A mutable state file as authority. A crash can leave state ahead of evidence, and resume
  cannot explain how it arrived there.
- A database or Temper as authority. That breaks offline operation and turns an optional
  learning projection into a workflow dependency.
- Best-effort repair of malformed or legacy rows. The missing identities cannot be recovered
  without guesses.
- Prose-only event conventions. Early run logs show that
  prose permits orphan outcomes, unmatched attempts, and mutation outside BUILD.

## Executable evidence

Run:

```bash
plugins/pr-graph/skills/pr-graph/tests/event_contract_test.sh
```

The test covers contract completeness, envelope assignment, unknown vocabulary, attempt and
edge binding, wake transitions, terminal rules, deterministic replay, legacy recovery, torn
writes, no-mutation failures, and concurrent contiguous appends.
