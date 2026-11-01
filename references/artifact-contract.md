# PR Graph artifact contract v1

## Decision

Each execution run has a separate append-only artifact stream and immutable content directory:

```text
runs/<ticket>-<date>-<run-uuid>.jsonl
runs/<ticket>-<date>-<run-uuid>.artifacts.jsonl
runs/<ticket>-<date>-<run-uuid>.artifacts/<artifact-uuid>.blob
```

The execution stream remains the only graph authority. The artifact stream is the evidence
authority that a coordinator reads before authorizing an artifact-dependent transition. Both
streams bind to the same run UUID and parent conversation. Every artifact also binds to a known
execution node attempt.

`artifact-contract-v1.json` is the machine-readable schema. `scripts/artifact_log.rb` is its
executable interpretation, and `scripts/artifacts.rb` is the supported CLI. This is a separate
versioned contract instead of an in-place change to the published execution v1 vocabulary.

## Artifact identity and lineage

Every artifact records:

- artifact contract version, run, sequence, timestamp, and parent conversation;
- artifact UUID, family, execution node, and node-attempt UUID;
- producer and evidence perspective;
- input Git SHA and, for quality evidence, the same candidate SHA;
- immutable content reference, byte count, media type, and SHA-256 checksum;
- a wake UUID or explicit null; watcher families require a known wake from the same attempt;
- stable outcome IDs covered by the evidence.

The family map assigns every artifact type to its producing graph node and identifies quality
and wake-backed families. A quality artifact without a candidate SHA or covered outcome is
invalid. Evidence whose candidate differs from its input SHA is invalid. Candidate dependency
and BUILD invalidation are defined separately in `lineage-contract-v1.json`, so artifact v1 does
not silently acquire a hard-coded node list.

## Immutable lifecycle

Artifact content is never updated. A new artifact may link to a current older artifact with
`supersedes`, provided both have the same family and node. Any current artifact may link to a
current target with `invalidates`. Replay derives each target's status as `current`,
`superseded`, or `invalidated`; the old event and blob remain intact. A second or conflicting
status link is rejected before append. Production lifecycle links are coordinator-owned; the
raw link CLI exists only for contract fixtures.

The single-writer coordinator automatically supersedes prior output from the same node and
family. It uses a current `build_manifest` as the source that invalidates every
contract-declared candidate-dependent artifact for older candidates. Output must be stored
while its producing attempt is open; a late artifact is rejected before append and its orphan
blob is removed.

## Writing and replaying

Write metadata as JSON and content from a file or stdin. Generated identity, reference,
checksum, byte count, timestamp, and sequence fields cannot be supplied by the caller.

```bash
printf '%s' "$REPORT" | ruby "$PR_GRAPH_SCRIPTS/artifacts.rb" put "$SESSION_ID" \
  '{"family":"implementation_plan","node":"PLAN","attempt_id":"<uuid>","producer":"pg-PLAN-architect","input_sha":"<40-char-sha>","candidate_sha":null,"content_type":"text/markdown","wake_id":null,"perspective":"author","covered_outcomes":[]}' -
```

Validate or replay a completed stream with its execution stream:

```bash
ruby "$PR_GRAPH_SCRIPTS/artifacts.rb" validate "$ARTIFACTS" "$EVENTS"
ruby "$PR_GRAPH_SCRIPTS/artifacts.rb" replay "$ARTIFACTS" "$EVENTS" \
  '["ac:1","ac:2","quality:ci"]'
```

Replay counts only current quality artifacts as evidence. Every requested outcome without such
evidence appears in `coverage.uncovered`. The outcome register and grounded planning content
contract are defined separately in `outcome-contract-v1.json`; artifact v1 continues to own only
identity, lineage, immutable content, and evidence coverage IDs.

The coordinator's broader per-node outcome projection is defined in `outcome-coverage.md`. Any
artifact may explicitly name a registered clause in `covered_outcomes`; the immutable coordinator
result records whether that evidence advanced or contradicted it. This does not change artifact v1:
the artifact field identifies what was exercised, while the result records its interpreted impact.

## Failure and crash behavior

The writer creates the content blob exclusively, flushes and syncs it, validates both streams,
then appends and syncs the artifact event under a sidecar lock. A handled validation or append
failure removes only the unreferenced blob created by that call. A process crash may leave an
orphan blob, but no event references it, so it has no authority.

Missing blobs, byte mismatches, checksum mismatches, unsafe references, torn JSONL, unknown
versions, run/session drift, unknown attempts or wakes, and conflicting lifecycle links all
fail replay. Unwritable storage stops the write. No failure is converted into clean evidence.

## Rejected alternatives

- Mutable plan, report, or findings files. They erase the evidence a resumed run needs to
  explain supersession.
- Large artifact bodies inside execution notes. Notes are telemetry and cannot prove content
  identity or lineage.
- Treating a missing artifact as a clean result. Missing evidence is uncovered.
- Storing only checksums. Resume and audit require both the exact payload and its identity.
- Making Temper or another service the artifact authority. Local execution must work offline.

## Executable evidence

Run:

```bash
plugins/pr-graph/skills/pr-graph/tests/artifact_contract_test.sh
```

The test covers required identity and SHA lineage, immutable storage, checksum validation,
quality coverage, wake binding, supersession, invalidation, corrupt and torn input, unsupported
versions, unwritable storage, and concurrent ordered appends.
