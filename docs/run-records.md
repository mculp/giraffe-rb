# Run records: each run records itself for a steward to learn from

Status: ships in `scripts/run_record.rb` and the DONE section of SKILL.md. Off unless
`PR_GRAPH_RECORD_CONTEXT` is set.

## Problem

A run's event log, failure log, and artifacts stay on the machine that ran it, and nothing learns
across runs. The same process miss (a malformed manifest, a file that blocks BUILD) recurs run after
run, and finding it means reading local logs by hand.

## Decision

1. After DONE completes, or when a run stops early, the orchestrator records the run in the Temper
   context named by `PR_GRAPH_RECORD_CONTEXT`. With the variable unset, the step makes no Temper call.
2. A steward pass distills the records into a cognitive map whose telos asks what recurs across
   runs, where the workflow breaks and which harness change prevents it, and what is settled or
   still open. A rule every run must follow still ships in this repository; the map holds the
   evidence and the open fixes.
3. The coordinator never reads or writes Temper, the event log stays the transition store, and
   resume never reads a record. Giraffe's run store (`docs/harness.md`, Temper store) is separate: its
   stored coordinator and logs write each transition through Temper, and `hydrate` resumes from it.
   Its kinds start with `giraffe-run-`, so its enforcing shapes never apply to the `pr-graph-` kinds below.
4. Project contexts keep the rule in `docs/temper-grounding.md`: read at TRIAGE, propose at DONE,
   and write only through the human gate.

## What a record holds

One `research` resource per run, titled `pr-graph run <ticket> <run UUID>`. Its open meta carries
`tags: ["pr-graph-run"]`, `pr_graph_run`, `ticket`, `status` (`done` or `stopped`), and `pr` once
the run published. Its body summarizes the nodes and their attempts, the red edges with their
reasons, the failure findings and stops, and what was attached or withheld.

| Data artifact kind | Intent | Content |
| --- | --- | --- |
| `pr-graph-event-log` | `current` | `{"events": [...]}` |
| `pr-graph-failure-log` | `current` | `{"events": [...]}`, when the run has a failure log |
| `pr-graph-<artifact family>` | `member`, ordered by the artifact's sequence | `{"record": <artifact metadata>, "content": <the artifact>}` |

## Turning it on

Set the variable in the harness's environment, for example in Claude Code's `settings.json`:

```json
{"env": {"PR_GRAPH_RECORD_CONTEXT": "@me/pr-graph-runs"}}
```

Use a context you own. Records name tickets and carry plans and review findings, so the context's
visibility is the records' visibility. A steward reads the contexts of the team its map is bound
to, so share the context into that team (`temper context share <context> +<team>`). If writes fail
with `embedding model not found`, point `TEMPER_ONNX_MODEL_PATH` at the CLI's model file.

## Guardrails

- Only the orchestrator runs the step, after DONE or an early stop. A skip or a failure never
  reopens DONE.
- One resource per run. A state file beside the event log (`<run>.temper-record.json`) lets a rerun
  resume. When the context already holds a record of the run and the state file is gone, the step
  skips rather than write a second record.
- A run recorded after an early stop and again after it finishes gets a new summary, and its new
  logs supersede the old ones. Artifacts never change, so each is committed once.
- Content matching a secret pattern (cloud, GitHub, Slack, Anthropic, Stripe, Linear, Buildkite, and
  Google keys, and private keys) is withheld whole and named in the summary. So is anything over 1 MB. The scan reads each
  string unescaped, and a failure or edge reason that matches reads `[withheld]` in the summary.
- An artifact is read only from the blob path its artifact log row must name, and only when the blob
  matches the row's checksum. Anything else is withheld.
- The step edits only the record it wrote.

## Evaluation

`tests/run_record_test.sh` runs the step against `evals/fixtures/fake_temper.rb`:

- Recording off, or a context that is not a ref, makes no Temper call.
- A record is one resource with both logs and each artifact, and a planted token never reaches
  Temper, including one after a newline, one cut by the reason length limit, and a private key.
- An artifact row pointing outside the run, or a blob failing its checksum, is withheld.
- An unchanged rerun makes no call, and a run that finished later updates its summary and
  supersedes its event log.
- A failed write resumes without a duplicate resource or artifact, and a lost state file never
  produces a second record.
- An unreadable context fails with the CLI's reason and writes nothing.
