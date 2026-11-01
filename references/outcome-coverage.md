# PR Graph outcome coverage contract v1

## Purpose

The outcome register says what must become true and what must never become true. PLAN says where
each clause will be exercised. Outcome coverage records what every completed execution node
actually changed, with durable witnesses, and makes gaps visible after loops and resume.

`outcome-coverage-v1.json` defines the impact and terminal vocabularies.
`scripts/outcome_coverage.rb` validates and projects them. Impacts and the final disposition live in
immutable coordinator result manifests, so they share node, attempt, lease, and recovery identity.

## Node impact

Before completing a node, put its required output artifacts. An artifact that exercised an outcome
must list the exact TRIAGE clause ID in `covered_outcomes`. The coordinator records every clause in
the node result as one of:

- `advanced`: a successful node produced explicit supporting evidence;
- `contradicted`: a failed node produced explicit contrary evidence;
- `unchanged`: current evidence already existed and this node did not affect it;
- `uncovered`: no current evidence existed and this node did not add any.

Advanced and contradicted entries include the actual artifact UUID and its evidence perspective.
Unchanged and uncovered entries contain no evidence. An undeclared clause, evidence from another
attempt, mismatched perspective, missing clause impact, or evidence inferred from an empty field is
invalid.

Execution nodes can contribute evidence, including INVESTIGATE, WORKTREE, REPRODUCE, BUILD, VERIFY, CI, bot
feedback, validation, and REVIEW-APP after its deployment and seed preflight. TRIAGE defines the
clauses, PLAN declares intended coverage without concrete witnesses, and DONE reports disposition;
those three nodes record impact but cannot introduce actual outcome evidence.

## Replay and conflicts

Replay retains every historical node impact but only current artifacts contribute to the current
clause projection. A superseded or BUILD-invalidated artifact therefore stops covering its clause
without erasing the old witness. The current state is:

- `covered` for support without contradiction;
- `contradicted` for contradiction without support;
- `conflicting` when both current forms exist;
- `uncovered` when neither exists.

Conflicting evidence is returned with both witness lists. It is never resolved by event order.
Resume returns this projection as `outcome_coverage`.

## DONE disposition

DONE completion requires a JSON file with every positive and negative clause exactly once:

```json
{
  "clauses": [
    {"outcome_id": "outcome:valid-next-work", "status": "covered"},
    {
      "outcome_id": "constraint:human-approval",
      "status": "deliberately_excluded",
      "reason": "PLAN explicitly bounded final approval outside this run."
    }
  ]
}
```

Pass it to:

```bash
ruby "$PR_GRAPH_SCRIPTS/coordinate.rb" finish "$SESSION_ID" DONE "$ATTEMPT_ID" \
  --disposition "$DISPOSITION"
```

Allowed statuses are:

- `covered`, only when current evidence is covered and non-conflicting;
- `deliberately_excluded`, only when PLAN marked the clause uncovered, with a reason;
- `inexpressible`, with a reason;
- `explicitly_unexamined`, with a reason.

The persisted disposition binds current evidence UUIDs and perspectives. A missing clause, silent
gap, undeclared exclusion, stale witness, or claim of coverage over contradictory or conflicting
evidence blocks DONE. Explicit non-coverage remains visible rather than being converted to success.

## Recovery

The result manifest is written before execution completion. A crash in that prefix retains the
exact impact and requested DONE disposition in recovery arguments. Resume validates but does not
count the impact until its node completion event is durable. Retrying the exact transition closes
the attempt; different arguments conflict with the immutable result.

## Executable evidence

Run:

```bash
plugins/pr-graph/skills/pr-graph/tests/outcome_coverage_test.sh
plugins/pr-graph/skills/pr-graph/tests/coordinator_test.sh
```

The fixtures cover BUILD support, VERIFY contradiction, conflict surfacing, lineage invalidation,
browser perspective, deliberate PLAN exclusion, silent DONE gaps, all-node integration, and
fresh-process replay.
