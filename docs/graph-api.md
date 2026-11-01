# Live graph boundary, v1

`GraphView` separates a workflow definition from a run's progress and evidence. A future HTTP/SSE
service can wrap these read methods without teaching a browser how private journals work.

`graph` returns `schema_version`, `run_id`, metadata `revision`, execution-event `cursor`,
`graph_version` (SHA-256 of the definition), `definition`, node states, attempt identities, artifact
identities and hashes, open questions, candidate SHA, errors, and terminal status. Node states are
`blocked`, `runnable`, `active`, `waiting_for_answers`, `completed`, `failed`, `paused`, `cancelled`, and `retired`. Completion
of PUBLISH is separate from terminal DONE. Evidence retains its `current`, `invalidated`, or
`superseded` status; the UI must not paint an old candidate's proof green for a new candidate.

`events --after N` returns ordered existing execution envelopes with stable sequence numbers and the
next cursor. Reconnecting clients request their last cursor; an ahead-of-history cursor is refused.
Metadata revisions and execution cursors are different: an answer or model-cost update can change
metadata without adding an execution event. For now clients refresh the snapshot when either changes;
a future SSE service should carry both cursors. Temper's live metadata and event kinds can provide
remote readers with the same information; checkpoints additionally indicate recoverable durability.
The CLI snapshot currently reads the execution host's local journals.

Future authenticated command endpoints should expose `answer`, `resume`, `cancel`, and `sync` as
explicit commands with request IDs and expected revisions, rather than allowing raw journal writes.
Do not serve arbitrary run paths, full configuration, prompt snapshots, or local file contents to a
browser. Authentication, authorization, streaming transport, command idempotency, and remote-reader
indexing belong in that service and are not implemented by these local CLI commands.

Graph editing needs a separate definition command. Before accepting an edit, validate the graph's
node/edge schema, required gates, dependency cycles, allowed mutation capabilities, evidence contracts,
and compatibility with open attempts. An accepted edit must create an immutable new definition
version with a parent version and audit trail. Running work should keep its pinned definition unless
an explicit migration proves which evidence can remain valid. A rejected edit changes nothing.

The current harness uses the existing checked-in coordinator policy and execution contract; it does
not yet implement per-run definition versions, migrations, or an edit command. `graph_editing` is
therefore false. The definition digest lets a frontend detect code/policy changes; it is not itself
an authorization or migration mechanism.
