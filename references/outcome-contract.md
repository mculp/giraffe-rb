# PR Graph outcome contract v1

## Purpose

The outcome register preserves why the change matters before a technical plan commits to a
mechanism. `outcome-contract-v1.json` is the machine-readable content policy and
`scripts/outcome_contract.rb` is its executable interpretation. It validates the JSON bodies
already stored under the immutable artifact contract; it does not add another state authority.

## TRIAGE register

The `triage_brief` may contain ticket and branch facts, but it must embed this structure:

```json
{
  "outcome_register": {
    "why": "Developers need interrupted work to resume without losing valid progress.",
    "actors": [
      {
        "id": "actor:developer",
        "situation": "A developer continuing a change after an interrupted session."
      }
    ],
    "positive_postconditions": [
      {
        "id": "outcome:valid-next-work",
        "statement": "The developer can identify the next permitted work from completed evidence."
      }
    ],
    "negative_face": [
      {
        "id": "constraint:no-stale-proof",
        "statement": "Evidence from an earlier candidate must never authorize completion."
      }
    ],
    "declared_gaps": [
      {
        "id": "gap:human-approval",
        "reason": "Final human approval remains deliberately outside draft completion."
      }
    ]
  }
}
```

Actors, positive postconditions, and negative face must be non-empty. The gaps array is required
but may be empty, which explicitly declares that TRIAGE found no deliberate gap. IDs are stable
across planning and evidence. Register prose cannot name code identifiers, paths, commands,
framework components, storage structures, or similar implementation mechanisms.

## Grounded implementation plan

The `implementation_plan` body contains one or more classified steps:

```json
{
  "steps": [
    {
      "id": "step:enforce-transition",
      "classification": "AMEND",
      "intent": "Validate the accepted transition before work begins.",
      "outcome_ids": ["outcome:valid-next-work", "constraint:no-stale-proof"],
      "evidence": [
        {
          "role": "existing_mechanism",
          "kind": "codebase",
          "ref": "skills/pr-graph/SKILL.md:20",
          "claim": "The current transition is expressed as model-interpreted guidance."
        },
        {
          "role": "authorization",
          "kind": "ticket",
          "ref": "linear:DEMO-771",
          "claim": "The ticket authorizes deterministic outcome validation."
        }
      ]
    }
  ]
}
```

CONFORM follows an existing pattern and normally cites `existing_pattern`. When no evidence is
available after a bounded search, it may instead record a `gap` item with a reason and non-empty
`searched` list. EXTEND requires actual `adjacent_mechanism` and `authorization` evidence. AMEND
requires actual `existing_mechanism` and `authorization` evidence. A gap never satisfies those
EXTEND or AMEND roles.

## Planned coverage

The `test_plan` body maps every positive and negative outcome ID exactly once:

```json
{
  "coverage": [
    {
      "outcome_id": "outcome:valid-next-work",
      "status": "planned",
      "planned_node": "VERIFY",
      "strategy": "An automated check attempts invalid work and observes rejection."
    },
    {
      "outcome_id": "constraint:no-stale-proof",
      "status": "uncovered",
      "reason": "External human judgment is deliberately outside this run."
    }
  ]
}
```

Planned strategies state the observable proof, not a concrete witness. Artifact IDs, candidate
SHAs, result paths, screenshots, and other witness identities are rejected in PLAN. The node that
executes the strategy later records real evidence through its artifact `covered_outcomes` field.
That evidence is interpreted only by the separate `outcome-coverage-v1.json` policy described in
`outcome-coverage.md`; PLAN never predicts whether a later witness supports or contradicts a clause.

## Validation

Validate the register or all PLAN content before storing it:

```bash
ruby "$PR_GRAPH_SCRIPTS/outcomes.rb" register triage-brief.json
ruby "$PR_GRAPH_SCRIPTS/outcomes.rb" plan triage-brief.json implementation-plan.json test-plan.json
```

The PLAN projection lists `planned_outcome_ids` and `uncovered_outcome_ids`. The coordinator reads
the immutable blobs and repeats the same checks at TRIAGE and PLAN completion, so a hand-edited or
unvalidated file cannot authorize BUILD.

Executable evidence:

```bash
plugins/pr-graph/skills/pr-graph/tests/outcome_contract_test.sh
```
