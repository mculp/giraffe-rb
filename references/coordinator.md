# PR Graph coordinator policy v1

## Authority

`coordinator-policy-v1.json` is the machine-readable readiness and mutation policy.
`scripts/coordinator_runtime.rb` is its executable interpretation, and
`scripts/coordinate.rb` is the supported lifecycle CLI. The execution JSONL remains the
append-only graph authority and the artifact JSONL remains the immutable evidence authority.
Coordinator lease and result manifests record what authority an attempt received and the Git
state it observed; they do not replace either stream.

The public `events.rb emit` command cannot append `node`, `outcome`, `edge`, `wake`, `publish`,
or `done`. Those transitions require the coordinator. The environment escape hatch used by
contract fixtures is not a supported production interface.

## Lifecycle

Start a node only after its dependencies and required current artifacts exist:

```bash
ruby "$PR_GRAPH_SCRIPTS/coordinate.rb" start "$SESSION_ID" BUILD --worktree "$WORKTREE"
```

The command persists an immutable authority lease before it emits node start. Pre-build read
lanes do not need a worktree. BUILD and all quality or post-publish lanes require the exact Git
worktree path so mutation can be detected. BUILD is the sole writer; guarded readers may run in
parallel with each other but never with BUILD. The lease pins the exact artifact IDs, input SHAs,
candidate SHAs, and content checksums consumed by the attempt. Completion fails if that input set
has changed.

Persist every required output with `artifacts.rb put` before completing the attempt. Then use:

```bash
ruby "$PR_GRAPH_SCRIPTS/coordinate.rb" finish "$SESSION_ID" VERIFY "$ATTEMPT_ID" --findings 0
ruby "$PR_GRAPH_SCRIPTS/coordinate.rb" fail "$SESSION_ID" BOT-FEEDBACK "$ATTEMPT_ID" \
  --reason "finding requires a build change" --findings 1 \
  --failure-id "bot:stable-cause" --revision "comment:immutable-id"
```

`finish` is the canonical completion command. `complete` is a compatibility alias with the same
arguments, evidence requirements, and authority checks.

A successful quality completion emits its green outcome and node completion together. A failure
emits its red outcome, legal edge to BUILD, and node completion together. BUILD itself stays open
until it has committed or removed every worktree change and produced both a build manifest and a
`self_review` artifact for HEAD; the review phase runs inside the BUILD lease, so its evidence is a
BUILD output rather than a separate node.

`SELF-REVIEW` is retired except for recovery of a current, completed BUILD attempt that never
produced a `self_review` artifact. That recovery lane requires green VERIFY evidence, retains read
authority, and must complete green before PUBLISH or DONE can consume its review. Findings use its
red edge to BUILD. A BUILD-produced review retires the recovery lane and invalidates standalone
review evidence, including evidence for the same SHA. Policies cannot make another node depend on
SELF-REVIEW. See `resume.md` for the recovery commands.
TRIAGE and PLAN completion additionally validate their structured content against
`outcome-contract-v1.json`; an incomplete register, ungrounded plan, or undeclared coverage clause
leaves the attempt open and cannot authorize its dependent node.

Every completion also writes an immutable outcome impact into the coordinator result before the
execution completion event. Each registered clause is marked advanced, contradicted, unchanged, or
uncovered. Advanced and contradicted entries must reference output artifacts that explicitly name
the clause, and the evidence perspective is retained. See `outcome-coverage.md`.

Every failure transition first appends an immutable occurrence to the failure journal. The next
BUILD lease groups all pending occurrences by stable failure identity and claims the resulting
batch. A repeated callback with the same source revision is deduplicated; a conflicting duplicate
is rejected. Resume derives pending, processing, and processed batches from the journal plus BUILD
leases. If an identity is reported after three consecutive processed batches, the journal records
a stop and the coordinator refuses every subsequent start.

## Evidence freshness

Every BUILD completion makes its build manifest current and invalidates current quality evidence
for older candidate SHAs. The affected families come from `lineage-contract-v1.json`, which also
marks publish and description state as candidate-dependent while preserving explicitly independent
investigation and planning artifacts. VERIFY must then establish green evidence for that exact
candidate before PUBLISH can start. A guarded reader cannot complete after changing HEAD, the
index, tracked content, or untracked content; use `fail` to record the violation and return the
finding to BUILD.

Output replacement and BUILD invalidation use one locked artifact append batch. All old blobs and
link history remain available for audit and replay. Output cannot be added after its attempt has
closed, and the public artifact-link command is reserved for contract fixtures; production
supersession and invalidation belong to the coordinator.

## Wakes and recovery

Wait nodes require a registered and armed wake UUID. Register first, retain the returned UUID,
then arm and terminate it through the same CLI:

```bash
ruby "$PR_GRAPH_SCRIPTS/coordinate.rb" wake "$SESSION_ID" CI-WATCH "$ATTEMPT_ID" ci registered
ruby "$PR_GRAPH_SCRIPTS/coordinate.rb" wake "$SESSION_ID" CI-WATCH "$ATTEMPT_ID" ci armed \
  --wake-id "$WAKE_ID"
```

`coordinate.rb check` fails when an open wait gate has no live wake or when the graph is stalled.
`coordinate.rb resume-run <events.jsonl>` starts with no active pointer: it validates the execution,
artifact, and failure streams plus every coordinator lease and result, reconciles Git and optional
live PR state, reports open, runnable, blocked, live-wake, queue, and interrupted transitions, then
atomically restores the conversation-scoped hook pointer. `--offline` disables optional refresh
without weakening local validation. `check-run` performs the same checks without restoring the
pointer. See `resume.md` for the recovery contract.

## DONE policy

DONE requires current green VERIFY, CI, and bot evidence, plus current publish, description, and
BUILD review artifacts. VALIDATE and REVIEW-APP become required if their node has been activated.
Both DONE start and completion query the live PR, CI, and automated feedback. They reject a
non-draft PR, a head SHA that no longer matches the current BUILD candidate, a newer CI run, or
feedback that is pending, blocked, or contains findings. When late or edited feedback invalidates a
stored clean result, `coordinate.rb start ... BOT-FEEDBACK --refresh` opens an explicit replacement
attempt; refresh is available only for current green bot evidence. Completion also requires
`--disposition <json>` with exactly one terminal status for every outcome clause. The coordinator
does not ready, merge, or otherwise mutate the PR.

## Executable evidence

Run:

```bash
plugins/pr-graph/skills/pr-graph/tests/coordinator_test.sh
```

The test uses a real temporary Git repository and covers skipped dependencies, missing output,
parallel readers, writer contention, stale-evidence invalidation, non-BUILD mutation, red edges,
lost wakes, draft/head gates, outcome conflicts and invalidation, complete DONE disposition,
fresh-process and interrupted-transition resume, offline fallback, corrupt manifests, stale
worktrees, and persistence failure before node start.
