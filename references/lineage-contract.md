# PR Graph candidate lineage contract v1

## Decision

`lineage-contract-v1.json` declares candidate dependency for every artifact family in artifact
v1. It is a policy layer over immutable artifact events, not a replacement or in-place schema
change. `scripts/lineage_contract.rb` validates that the family map is exhaustive and agrees with
the execution and artifact contract versions.

Candidate-dependent families require a full Git SHA before their output can complete a node:

- BUILD manifest;
- verification and self-review;
- publish manifest and synchronized description;
- CI, bot, validation, and browser evidence;
- DONE manifest.

TRIAGE, investigation, implementation plan, test plan, and worktree manifest are declared
SHA-independent. Their metadata may still record an input or base SHA for provenance, but a later
candidate does not invalidate their content.

## Invalidation and re-arming

The contract declares BUILD as the lineage trigger and `build_manifest` as the invalidation
source. When BUILD completes with a new candidate SHA, the coordinator:

1. supersedes the prior BUILD manifest;
2. finds every current artifact whose family is candidate-dependent and whose candidate differs;
3. appends immutable invalidation links in one locked artifact batch;
4. replays the canonical graph and current evidence to calculate runnable nodes.

There is no separate list of VERIFY, CI, browser, or other nodes to re-arm. Adding an artifact
family without adding lineage policy makes the contract fail closed. Missing or partial candidate
identity blocks node completion with a diagnostic. Except for BUILD's lineage source, whose input
is the prior candidate, a candidate-dependent artifact must also consume the same SHA it names.

The invalidated artifact and blob remain auditable. Replay reports their status as `invalidated`,
and coverage no longer counts them. A fresh artifact for the new SHA must land before its gate can
be green again.

## Stale callbacks and resume

BUILD cannot start while a candidate-protected reader holds an open lease. Once that reader closes,
the artifact writer rejects any late output for the closed attempt. Together these rules prevent a
stale external callback from racing a new BUILD into current evidence.

Resume validates the lineage policy, both immutable logs, content checksums, and current candidate
before it reports runnable nodes. It does not reuse evidence merely because the producing node ran
once.

## Executable evidence

Run:

```bash
plugins/pr-graph/skills/pr-graph/tests/lineage_contract_test.sh
plugins/pr-graph/skills/pr-graph/tests/coordinator_test.sh
```

The tests cover exhaustive family policy, missing SHA rejection, explicit independence, unknown
families, broad invalidation, preserved planning artifacts, canonical re-arming, and completion on
the new SHA.
