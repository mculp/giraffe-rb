# PR and CI identity contract

PUBLISH and CI-WATCH use `scripts/pr_ci.rb`. They do not infer external state from check counts,
display names, or the last response in chat.

## Publish

Run `pr_ci.rb publish` with the exact repository, worktree, base ref, head ref, title, and body
file. Pass `--pr` when adopting a known pull request. Without `--pr`, the adapter lists all open
pull requests for the exact owner and head ref. It adopts the one match, creates one draft when
there is no match, and fails closed when identity is ambiguous. Retrying after creation adopts the
created pull request rather than creating another.

The JSON result is the `publish_manifest` artifact content. It persists the repository node ID and
name, pull request node ID and number, base and head refs, candidate SHA, draft/open state, URL,
observation time, and whether the adapter created or adopted it. Store that output before calling
`coordinate.rb finish ... PUBLISH --pr ... --candidate-sha ...`. The coordinator validates all
three identities against one another.

The adapter never marks a pull request ready, requests reviewers, or merges. It refuses to adopt a
non-draft or closed pull request as a successful PUBLISH result.

## CI reconciliation

Register and arm a CI-WATCH wake before starting a poll. After it fires, run:

```text
pr_ci.rb reconcile-ci --repo OWNER/NAME --pr NUMBER --candidate-sha SHA --wake-id UUID
```

The adapter rechecks the persisted PR identity and candidate SHA, then reads every page of GitHub
check runs and commit statuses for that SHA. Each row retains its provider identity, logical lane,
immutable run ID, content revision, state, timestamps, and details URL. A check run's lane is its
GitHub App plus check name. A commit status's lane is its context alone: GitHub keys the combined
status by context, and the creator is whichever token posted the row, so one provider can post its
pending and its success under different users. Older runs in the same lane are linked through
`supersedes_run_id`; only the newest run is authoritative.

An empty set or any nonterminal authoritative run is `pending`, never green. Do not store a pending
result or close CI-WATCH. Register and arm the next wake before yielding. When all authoritative
runs pass, store the returned JSON as the `ci_result` artifact using the same fired `wake_id`, then
complete CI-WATCH. When an authoritative run fails, store it and route the red edge with a stable
logical failure ID and a revision derived from the returned run ID and content revision.

If GitHub denies, times out, paginates incorrectly, returns a different SHA, or changes PR identity,
the adapter exits nonzero without producing evidence. Mark the attempted wake expired, then either
record a terminal failure or register and arm a retry wake before idling. A fired or expired wake is
not a live wake source.

DONE performs a fresh reconciliation. It blocks when the repository or PR node ID changed, the PR
is no longer open and draft, its head moved, CI is pending or red, or a rerun replaced the stored
authoritative run IDs.
