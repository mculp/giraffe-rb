# Seeding test data

Flags first, records second. If the change only needs feature flags flipped, use the Flipper
admin UI at `/admin/flipper` (the admin login is in `review-app.md`) and record
the old values before changing them. Use the runner only when a scenario needs records or a
flag change must be atomic with record creation.

Before writing seed code, search Temper for a seed recipe covering the feature area
(`temper search "<feature> seed recipe"`; recipes live in the owning team's reference context),
then search `lib/factories/`, interactors, and `db/seeds/`. Call those existing paths from the
seed body instead of reproducing their behavior with raw model writes.

## Durable seed plan

Create one plan for the whole REVIEW-APP seed stage. It binds every mutation to the durable
pr-graph run, candidate SHA, target, and PLAN scenario identity:

```json
{
  "schema_version": 1,
  "run_id": "11111111-1111-4111-8111-111111111111",
  "candidate_sha": "0123456789abcdef0123456789abcdef01234567",
  "target": {"kind": "review_app", "locator": "pr:1234"},
  "scenarios": [
    {
      "id": "invoice-approval",
      "description": "create the invoice used by browser scenario 1",
      "ruby": "seed.ensure_record(label: \"invoice\", find: ->(key) { Invoice.find_by(number: key) }, create: ->(key) { SeedInvoice.call(number: key) })"
    }
  ]
}
```

Scenario IDs must be unique and stable. Set `ruby` to `null` when the scenario needs no seed
mutation. If every scenario is null, the stage records `no_op`: it does not ask for approval and
does not call a runner. Invalid or duplicate scenarios fail during `prepare`, before any remote
access.

The body receives `seed`, whose supported mutation methods are:

- `seed.stable_key(label)` derives the same `prg-...` key from run + scenario + label on every
  retry. Do not use timestamps, random values, or a new run ID to make a retry unique.
- `seed.ensure_record(label:, find:, create:, cleanup: nil)` passes the stable key to both
  callables, reuses an existing record, verifies that a created record persisted, and records its
  identity. The `create` callable should invoke the existing factory, interactor, or seed path.
- `seed.update(label:, record:, attributes:)` snapshots the previous values and checks a
  non-bang `save`. The manifest retains that baseline across successful reruns.
- `seed.enable_flag(label:, name:, actor: nil)` snapshots the prior state and restores it if a
  later mutation fails. Actor-scoped flags must receive the actor.
- `seed.nontransactional(label:, kind:, identity:, previous:, cleanup:, apply:, restore:)`
  registers the restore callable before applying an external mutation. Use it for any effect that
  is not rolled back by the Rails database transaction.

All database work runs in one transaction. A failure exits nonzero, rolls the transaction back,
then invokes registered nontransactional restorers in reverse order. Restore failures remain in
`cleanup.residuals`; they are never reduced to a successful result.

## Approval and the one runner call

Render the exact self-contained script and initial manifest first:

```sh
ruby "$PR_GRAPH_SKILL/scripts/seed.rb" prepare \
  --plan /tmp/pr-graph-seed-plan.json \
  --script /tmp/pr-graph-seed-runner.rb \
  --manifest /tmp/pr-graph-seed-manifest.json
```

Show the user the complete `/tmp/pr-graph-seed-runner.rb` and its `script_sha256` from the
manifest. Explicit approval must name that hash. Approval of an earlier draft, the JSON plan, or
"seeding in general" is not approval of different runner bytes.

After approval, invoke the wrapper once:

```sh
ruby "$PR_GRAPH_SKILL/scripts/seed.rb" execute \
  --plan /tmp/pr-graph-seed-plan.json \
  --script /tmp/pr-graph-seed-runner.rb \
  --manifest /tmp/pr-graph-seed-manifest.json \
  --approved-sha "$APPROVED_SCRIPT_SHA" -- \
  bin/ops review-app runner --pr 1234
```

The wrapper appends the approved script as one argument without shell interpolation. Do not make
separate check, create, or verify runner calls. The script performs its own lookups, mutations,
checks, and summary in that one Rails boot. Local targets use `bin/rails runner` as the command;
the same approval and single-call rule applies.

The wrapper writes the manifest before attempting the runner and updates it atomically. A
kubectl/EKS denial, missing app authorization, runner crash, malformed result, or contradictory
exit leaves a nonzero command and a `failed` or `uncertain` manifest. `uncertain` means the remote
mutation state is unknown: inspect the target and follow `cleanup.residuals` before retrying.
Never infer "nothing ran" from absent stdout.

Persist the completed seed manifest with the REVIEW-APP evidence and include its content hash and
reference in the `browser_review` artifact. On shared targets, perform the pending cleanup actions
after browser testing and record whether each created record was removed and each prior value was
restored. Do not complete REVIEW-APP while cleanup residuals remain unexplained.

## Seed files committed to the app

A `db/seeds/` file only works on the review app if it is committed and pushed. Write a spec for
it (`expect { Seed.load(project) }.not_to raise_error`). Interactors often need `Current.user`;
wrap calls in a set/restore block. See `lib/factory_service/create_npas_project.rb` for the
pattern.
