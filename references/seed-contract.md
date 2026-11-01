# Seed execution contract v1

`scripts/seed.rb` is the fail-closed boundary around REVIEW-APP mutations. The plan is declarative
metadata plus approved Ruby bodies; the rendered runner is self-contained so the target does not
need the plugin installed.

The contract has four identities:

1. `run_id` identifies the durable pr-graph run.
2. `candidate_sha` prevents evidence from drifting to a different build.
3. `target.kind` + `target.locator` identify the environment.
4. Each scenario ID supplies the PLAN witness that requested the data.

`seed.stable_key(label)` hashes those identities with the label. Rerunning the same approved plan
therefore finds the same records. Changing the candidate, scenario, or run creates a different
namespace instead of colliding silently.

The manifest records the approved script hash, sanitized runner argv, invocation count (zero or
one), exit status, output hashes, scenario states, created or reused record identities, changed
flags and fields, previous and current values, cleanup instructions, residuals, and the first
error. Valid terminal states are:

- `no_op`: no scenario requested mutation and no runner was called;
- `succeeded`: the remote script committed and cleanup instructions are durable;
- `failed`: the remote script reported failure after database rollback and nontransactional
  restore attempts;
- `uncertain`: the wrapper cannot prove what the remote target did.

`prepared` and `running` are recoverable intermediate states. A `running` manifest after process
interruption is not success; resume must reconcile the target before deciding whether to retry.
An existing successful manifest with the same script hash is used to retain the original cleanup
baseline when a retry reports that the stable record or flag already exists.

The validator rejects unknown fields, invalid run/SHA/scenario identities, duplicate scenarios or
mutation identities, inconsistent no-op state, more than one runner invocation, and manifests
whose scenario set does not exactly match the approved plan:

```sh
ruby scripts/seed.rb validate plan /tmp/pr-graph-seed-plan.json
ruby scripts/seed.rb validate manifest /tmp/pr-graph-seed-manifest.json
```

The seed manifest is evidence owned by REVIEW-APP, not an independent graph node. Store it beside
the browser report and bind its content reference and SHA-256 in the `browser_review` artifact.
