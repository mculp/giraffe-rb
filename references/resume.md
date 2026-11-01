# PR Graph recovery and resume contract v1

## Authority

Resume starts from the exact execution JSONL path. The active pointer under `active/<session>` is
disposable hook-routing state and is never an input to replay. The coordinator validates and
combines these durable local records:

- the versioned execution stream and its run and conversation UUIDs;
- the artifact stream, immutable blobs, checksums, lineage links, and current statuses;
- the failure journal and BUILD batch claims;
- every coordinator-issued authority lease and result manifest;
- the current Git worktree fingerprint and candidate SHA.

The resulting projection identifies terminal state, the current candidate, open attempts, runnable
nodes, blocked nodes and reasons, live wakes, failure queue state, and interrupted transitions. CI,
bot, validation, deployment, browser, description, and DONE state come from the same current
artifact and execution projection. Their dedicated identity tickets add live service reconciliation
without changing this local recovery authority.

Every result's outcome impact is replayed as part of the same projection. Evidence whose artifact
is now superseded or invalidated remains in history but no longer contributes current support or
contradiction. Missing impacts, undeclared clause IDs, mismatched perspectives, and terminal
dispositions inconsistent with current evidence refuse resume.

## Fresh-process recovery

Run from any process that can access the durable files:

```bash
ruby "$PR_GRAPH_SCRIPTS/coordinate.rb" resume-run "$EVENTS" --worktree "$WORKTREE"
```

The worktree option is required once a candidate exists unless its path can be recovered from the
latest BUILD lease. After successful replay, `resume-run` atomically restores only this run's
conversation-scoped active pointer so Claude or Cursor usage hooks can continue attribution.
`check-run` is read-only and does not restore it.

For local-only operation:

```bash
ruby "$PR_GRAPH_SCRIPTS/coordinate.rb" resume-run "$EVENTS" \
  --worktree "$WORKTREE" --offline
```

Offline mode still performs every contract, artifact, manifest, failure, and Git check. It skips
only the optional live PR refresh and labels that state `not_refreshed`; it never converts missing
external evidence into a pass. In live mode an unavailable GitHub CLI is reported as unavailable
without preventing valid local recovery.

## Git reconciliation

Outside an open BUILD attempt, the resumed worktree must be clean, its HEAD must equal the latest
current BUILD candidate, and its common Git directory must match the repository recorded by BUILD.
An open protected reader must still have the exact HEAD, index, tracked content, and untracked
content fingerprint from its lease. Any mismatch refuses resume because non-BUILD mutation cannot
be attributed safely.

An open BUILD retains its write lease and is returned as `write_in_progress`; dirty state is
expected there. Its journal batch remains `processing`, so it is not claimed again. A worktree at an
older candidate is rejected rather than silently re-running evidence against the wrong SHA.

## Interrupted transitions

The coordinator writes its immutable result manifest before artifact lifecycle links and execution
completion events. A process can therefore stop at a valid commit prefix with an open execution
attempt and a completed or failed result. Replay returns each such item under
`recovery.partial_results`, including the node, attempt UUID, result state, and exact retry
arguments persisted in the result manifest.

For `retry.command = "complete"`, invoke `coordinate.rb finish` with the same session, node,
attempt UUID, and persisted retry arguments. `complete` is an equivalent CLI alias; the persisted
operation stays `"complete"`. Pass `findings` as `--findings`, `pr` as `--pr`, and `candidate_sha`
as `--candidate-sha` when present. If `disposition` is present, write that exact JSON value to a
file and pass it with `--disposition`. For `retry.command = "fail"`, use `coordinate.rb fail`
with its exact persisted arguments.

Manifest writes are idempotent only when byte-identical, artifact lifecycle is derived again from current status,
failure journal writes deduplicate by immutable revision, and the execution batch is revalidated
before append. Different retry arguments conflict instead of silently changing the completed
operation.

## Completed BUILD without review evidence

If a legacy BUILD result is persisted as completed but its execution attempt is still open, retry
`coordinate.rb finish` with the recorded arguments before starting review. When that attempt has
no review output, the retry requires only its build manifest. The worktree fingerprint and candidate
must match the persisted result, and the reconstructed result must remain byte-identical. The retry
closes the attempt without inventing review evidence. Fresh BUILD completion still requires review.

A v1 run can contain a completed BUILD attempt with no `self_review` output. The coordinator keeps
that attempt and its result immutable. After green VERIFY, resume offers SELF-REVIEW for that
candidate as a read-only recovery lane:

```bash
ruby "$PR_GRAPH_SCRIPTS/coordinate.rb" start "$SESSION_ID" SELF-REVIEW --worktree "$WORKTREE"
```

Perform the independent review without editing the worktree. Persist its `self_review` artifact
for the current candidate and complete the returned attempt through `coordinate.rb finish`.
PUBLISH and DONE require a closed review attempt with a green outcome for the current candidate.
An open attempt with a pass outcome is insufficient. A completed, green SELF-REVIEW for the same
candidate already satisfies this requirement.

If review finds changes to apply, persist the finding and use `coordinate.rb fail` with a stable
failure identity and revision. Its red edge queues a normal BUILD. That BUILD must produce its own
review evidence before completion, even when the candidate SHA stays the same. Its review
invalidates standalone review evidence through an appended lifecycle link. Historical execution
records, artifacts, leases, and results are never rewritten or backfilled.

## Refusal policy

Resume refuses malformed or torn JSONL, unsupported contract versions, run or conversation drift,
missing or corrupt coordinator manifests, lease/result identity mismatch, artifact checksum or
lineage failure, failure-queue conflicts, dirty or stale Git state outside BUILD, and protected
reader mutation. It does not truncate, synthesize, or reinterpret evidence. Preserve the files for
diagnosis and repair the source of the mismatch or start a new UUID run.

## Executable evidence

Run:

```bash
plugins/pr-graph/skills/pr-graph/tests/coordinator_test.sh
plugins/pr-graph/skills/pr-graph/tests/legacy_review_resume_test.sh
```

The real-Git test covers resume after completed VERIFY, missing and corrupt durable state, an
interruption between result persistence and execution completion, in-process BUILD queue recovery,
stale candidate refusal, active-pointer restoration, and live-service offline fallback.
