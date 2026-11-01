# Automated feedback identity contract

BOT-FEEDBACK uses `scripts/feedback.rb`. It reconciles remote state; counts, array positions,
display names, and timestamps alone never decide whether the gate is clean.

## Remote projection

Every reconciliation paginates GitHub issue comments, reviews, review comments, and review
threads. A feedback item retains its GraphQL node ID, kind, intrinsic revision, body hash, exact
author identity, thread identity when applicable, resolution and remote state, and the commit SHA
GitHub supplies. General issue comments have no commit binding, so their `relevant_sha` is null;
the manifest still binds the observation to one candidate SHA.

Review-thread pagination is fail-closed. GitHub exposes nested comments separately from thread
pages, so a thread with more nested comments than were returned cannot produce evidence. Duplicate
IDs, a missing ID, a moved PR head, or a non-draft/closed PR also fail before a manifest is emitted.

`baseline_at` identifies the start of the PR feedback watch. It is stable across wake and candidate
changes and is never a time filter. Unresolved content that arrived before the baseline is still
projected and processed.

## Authors and decisions

Every author whose actor type is `Bot` with a stable ID and login is automated: Review Bot, Codex,
claude[bot], Copilot, Snyk, Linear, GitHub Actions, or any other GitHub App. Only a GitHub App can
act as a `Bot`, so a human cannot land in this class. `automated-feedback-authors-v1.json` lists
the automation that posts as a `User` account, as an exact allowlist over stable ID, login, and
actor type; all three fields must match. Any other `User` is recorded as human and is
automatically ignored by this gate. Missing, organization, or other identity is unknown and leaves
the gate blocked. The adapter is read-only: it never replies to or resolves
human content.

The processing ledger is keyed by feedback ID and revision. It retains prior revisions while the
current item points to its immediately preceding revision. Unchanged revisions reuse their original
decision and `processed_at`; an edit creates a new pending revision. Remote deletion, thread
resolution, outdated state, human authorship, and empty automated content receive deterministic
terminal decisions. Active automated text requires an explicit decision: `clean` or `finding`, or
one of the settled finding decisions below.

An automated review comment, or an automated review with a body, is a finding surface. `clean` is
refused on it; it takes `fixed` (the ledger entry also carries the fixing `candidate_sha`),
`declined` (a reason the human can judge), or `not_actionable` (summaries, link-backs, CODEOWNERS
posts). A `finding` on the same revision may later be settled by `fixed`, `declined`, or
`not_actionable`, which replaces that ledger entry. The manifest is `clean` only when every finding
surface is settled or terminal.

## Reconciliation procedure

Register and arm a BOT-FEEDBACK wake. After it fires, write the first result to a temporary file:

```text
feedback.rb reconcile --repo OWNER/NAME --pr NUMBER --candidate-sha SHA \
  --wake-id UUID --baseline-at TIME [--previous PRIOR.json]
```

If the result is `pending`, inspect only active automated items without a current ledger entry.
Create a decisions file using the exact `feedback_id` and `revision` from that observation:

```json
{"decisions":[{"feedback_id":"issue_comment:IC_x","revision":"<sha256>","decision":"clean","reason":"reviewed; no actionable finding"},
 {"feedback_id":"review_comment:PRRC_x","revision":"<sha256>","decision":"fixed","reason":"guarded the nil branch","candidate_sha":"<40-hex>"}]}
```

Then reconcile again with the temporary observation as `--previous` and the decisions file as
`--decisions`. Never persist a `pending` observation as the node's one current output. Persist only
the terminal `clean` or `findings` result as `bot_feedback`, using the same candidate and fired wake
in the artifact metadata. Complete a clean node; route findings to BUILD with a stable failure ID
and the feedback revision.

After BUILD or a later watch, pass the last terminal feedback manifest as `--previous`. Repository,
PR, baseline, and author-policy identity must remain stable; candidate and wake identity advance in
the new manifest. Unchanged remote revisions are not reprocessed. A later edit, resolution, or
deletion is recorded once as a new revision.

When DONE discovers feedback newer than the stored clean artifact, re-open the lane explicitly:

```text
coordinate.rb start "$SESSION_ID" BOT-FEEDBACK --worktree "$WORKTREE" --refresh
```

`--refresh` is accepted only when BOT-FEEDBACK already has current green evidence. The open refresh
attempt prevents DONE while the replacement artifact is being reconciled and then supersedes the
older artifact on completion or failure.

An API denial or timeout emits no evidence. Keep the BOT-FEEDBACK attempt open, register and arm a
new retry wake, and record the unavailable gate in status. Unknown author identity remains blocked
until remote deletion/resolution or an explicit author-policy change; do not guess that it is a bot
or a human.

DONE performs one fresh read using the current clean manifest as the prior ledger. It rejects new or
edited automated content, unknown authors, changed external identity, and any finding that remains
current. It then reads every review thread live (resolution, outdated state, and the first comment's
author) and rejects any thread whose first comment is automated and that is neither resolved nor
outdated, unless that comment's current decision is `declined`. The error names each thread's path
and comment ID. A deletion or thread resolution produces terminal ledger state and no longer blocks DONE.
