# Running the Ruby harness

This is the first executable slice of the design: ticket → triage → isolated worktree → investigation
→ reproduction → plan → build with independent review → verification → draft PR. The existing
coordinator remains the authority for dependencies, mutation leases, evidence, candidate invalidation,
and red edges. Model calls cannot select transitions, execute project commands, commit, or publish.

A successful invocation returns `draft_pr`, **not** terminal DONE. CI-WATCH, BOT-FEEDBACK, VALIDATE,
REVIEW-APP, DESC-SYNC, PR-RISK, cloud launching, programs, and knowledge writes remain follow-up work.
The existing scripts for these gates remain available. The harness does not mark them passed.
Linear integration reads tickets; posting plans or changing ticket state is not implemented yet.
Investigation uses three fresh perspectives over the supplied ticket and local repository; fetching
linked private documents and remote prior art is not implemented yet.

## Configuration

Needs Ruby 3.4+, Git, Claude Code 2.1.312+, `gh`, and a Temper CLI login for mirrored mode. No gems
or TypeScript runtime are needed. Configure Git author identity and fetch the target repository's
base ref before starting. Paths below resolve relative to the configuration file.

```json
{
  "repo": "../your-app",
  "github_repo": "your-org/your-app",
  "base": "origin/main",
  "pr_base": "main",
  "runs_dir": "./.giraffe/runs",
  "store": "mirrored",
  "context": "+your-team/giraffe-runs",
  "checks": [["bundle", "exec", "rspec"]],
  "lint": [["bundle", "exec", "rubocop"]],
  "spec_command": ["bundle", "exec", "rspec", "{spec}:{line}"],
  "runner": "claude",
  "model": "sonnet",
  "models": {"plan": "opus", "review": "opus", "audit": "opus"},
  "call_budget_usd": 3.0,
  "run_budget_usd": 25.0,
  "instructions": ["../your-app/CLAUDE.md"],
  "skills": {
    "build": ["../your-skill/SKILL.md"],
    "review": ["../your-review-skill/SKILL.md"]
  }
}
```

Commands are argument arrays. At least one executable check is mandatory. `spec_command` selects the
spec or example named by an audit; `{spec}` and `{line}` are substitutions in those arguments, never
shell interpolation. For frameworks without line filtering, configure the command to run the named
spec file. The harness checks coverage of changed spec **files** and validates cited lines; exhaustive
discovery of every example is not yet enforced. The model is asked to audit every example.

On macOS, checks default to a filesystem/network sandbox with controller credentials removed from
the environment. It permits writes in the worktree and temporary directories, so lint and builds can
work. This is not a multi-tenant isolation boundary. On Linux, use a disposable isolated execution
host and explicitly configure `"sandbox_checks": false`; a Linux sandbox backend is not implemented.
Repositories needing databases or external services need an execution environment that provides them.
The current macOS profile denies network access, including network-based database connections.

Instruction and skill files are explicitly selected, snapshotted with hashes, and supplied only to the
named roles. Arbitrary user/project settings, hooks, commands, MCP servers, and session history are
not loaded. The Claude process receives Read/Grep/Glob and, for BUILD only, scoped Edit/Write. The
harness runs all checks. CLI permissions are defense in depth, not isolation from hostile source code.

## Commands

```sh
bin/giraffe start ENG-123 --config giraffe.json
bin/giraffe start --ticket-file ticket.json --config giraffe.json
bin/giraffe start ENG-123 --config giraffe.json --dry-run
bin/giraffe status /absolute/path/to/run.jsonl
bin/giraffe answer /absolute/path/to/run.jsonl QUESTION_ID 'Your answer'
bin/giraffe resume /absolute/path/to/run.jsonl
bin/giraffe cancel /absolute/path/to/run.jsonl
bin/giraffe sync /absolute/path/to/run.jsonl
```

Linear reads `LINEAR_API_KEY`. A ticket file contains `id`, `title`, and `description`, and optionally
`url`. `--dry-run` fetches/validates the ticket and configuration and prints the proposed stages and
checks; it creates no run or worktree, makes no model call, and performs no external writes.

`status` and graph reads use local state without refreshing remote services. An answer is stored
before resuming the asking step in a fresh context. Cancel writes a local request which the active
command supervisor checks; it terminates the subprocess group. Cancellation leaves evidence and
unfinished files for inspection. Cancellation is local to the execution host.

There is one writer per run. Worktree branches include a UUID; pre-existing unrelated branches and
dirty source/worktrees are refused. A killed writer with uncommitted edits pauses for inspection.
Completed commits carry a run/attempt/unit trailer so a restart can recover a commit made just before
its checkpoint. A lost model result retains its full budget reservation. A known successful or failed
structured result records its reported cost. A malformed response or lost process retains the
reservation conservatively. No automatic invalid-output retry is currently attempted.

BUILD runs each plan assignment in a fresh context, commits its files, then repeats executable checks
and independent review within the configured round limit. VERIFY runs checks again, refuses any
candidate/worktree mutation, and audits acceptance criteria without giving the auditor the plan.
Unmet or unverifiable criteria cannot publish. Changed specs require real production mutation patches;
the harness executes each mutation in a disposable candidate worktree and records the command result.
For reproduced bugs, it executes the new regression spec on the base and candidate, requiring red then
green. Those proofs are executable evidence, while the model still judges their meaning and quality.

Publishing pushes the verified clean candidate and uses GitHub's returned repository, PR identity,
head SHA, and draft state. A compare URL is not a PR. Retries reuse a matching existing draft. Running
a real ticket performs that push and draft creation; tests use temporary bare repositories and fakes.

## Local files and live Temper

The local event, artifact, failure, manifest, and state journals are durable first. Every journal
append, artifact, coordinator manifest, question, answer, and status update is then mirrored to Temper
**during execution**, including node starts before a model returns. A Temper outage does not discard
local progress. Journal history itself is the durable retry queue; no separate queue entry can be
lost between writing evidence and scheduling its upload. `sync` and step boundaries reconcile missing
writes and refuse divergent remote history. A live write failure is visible in sync status.

Live runs use their own resource identity (`giraffe_run_id` and `giraffe-live-run`), distinct from
finished-run records. Physical artifact kind names include a schema digest, so different releases
sharing a context do not overwrite each other's shapes. A run records its kind mapping and refuses a
writer using different contracts. Resource creation reconciles a lost response by looking up the run;
ambiguous duplicate resources fail closed. Existing pre-harness store resources are not automatically
migrated to the new identity.

Temper keeps two logical state kinds: `giraffe-harness-live` for current status/questions, and
`giraffe-harness-state` for fully synced recovery checkpoints. A checkpoint names exact log lengths
and coordinator manifest digests. Live data beyond it can be displayed but is not silently adopted
when restoring. Evidence is uploaded before transitions that refer to it, and checkpoint state is
uploaded last. Transition IDs are deterministic, so lost acknowledgements can be retried safely.

```sh
bin/giraffe restore RUN_UUID --context +your-team/giraffe-runs --ticket ENG-123 --destination ./restored-run
```

Restore validates journals, evidence hashes, sequence continuity, and coordinator manifests before
installing files. Repository/worktree paths must still exist: relocating an active worktree onto a
new machine is not implemented. `"store": "local"` disables Temper completely for local development.
Local mode is explicit; a mirrored run does not silently switch its durability promise.

Host file locks prevent concurrent harnesses on that host. There is no distributed lease/fencing or
safe simultaneous multi-host writer. Resuming the same run on two hosts is unsupported.

## Frontend boundary

```sh
bin/giraffe graph /absolute/path/to/run.jsonl
bin/giraffe events /absolute/path/to/run.jsonl --after 12
```

See [graph-api.md](graph-api.md) for the versioned public read model and the intended editing contract.
No web server, frontend, or graph editing is included in this slice.
