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
  "screen_checks": [],
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

Commands are argument arrays. At least one executable check is mandatory, and so is `spec_command`, which
selects the spec or example named by an audit. It must name `{spec}`; `{spec}` and `{line}` are
substitutions in those arguments, never shell interpolation. For a whole-file run, `{spec}:{line}` becomes
just the path, an argument carrying `{line}` without `{spec}` is dropped, and one carrying both keeps the
spec with an empty line. A flag and its value as two arguments, `--line {line}`, is refused: a whole-file
run could only drop half of it, so write `--line={line}`. For frameworks without line filtering, configure
the command to run the named spec file. Each proof runs in its own new checkout, so `spec_command` must
work without anything a check generated or installed in the worktree: a post-checkout hook's files are
there, but when specs need dependencies otherwise, make the command install them.

That hook runs on every checkout, on the checked-out commit's files and outside the check sandbox, so keep
it to what you would run on unreviewed code. It gets 600 seconds and the same reduced environment as a
check, so it reads any credentials it needs from its own files. If it fails, the run pauses with the hook's
error and resuming tries again; a worktree the run never finished making is removed and made again, so BUILD
cannot be paid to work in one that lacks what the hook provides. BUILD may not edit `.husky` or a
`core.hooksPath` inside the tree, though a hook calling other project files will run BUILD's versions of
them. Harness commits and pushes run no hooks.

A changed file counts as a spec, and owes a mutation audit, by each language's naming convention: `*_spec.rb`;
`*_test.rb` and `test_*.rb` under `test/` or `tests/`; `*.test.*`, `*.spec.*`, `*_test.*`, `*.cy.*` and anything
in `__tests__/` for JavaScript and TypeScript; `*_test.go`, `*_test.py`, `test_*.py`, `*_test.exs`; `FooTest` or
`FooTests` for Java, Kotlin, PHP and Swift; and top-level files in Rust's `tests/`. A spec named anything else
is not audited. There is one `spec_command`, so a repository with specs in two languages needs one that
dispatches on the file. The harness checks coverage of changed spec **files** and validates cited lines; exhaustive discovery of every
example is not yet enforced. The model is asked to audit every example the diff adds or changes. A check that passes its time or
output limit counts as failed, with exit 124. Anything in a check's output that looks like a secret reaches
state and prompts as `[REDACTED]`.

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

### Screen checks

Nothing else in a run can see layout, so a repository with a screen declares what can:

```json
"screen_checks": [
  ["/bin/sh", "-c", "npm_config_cache=\"$TMPDIR/npm\" npm i --no-audit --no-fund && npm run horde -- --shots {shots}"]
]
```

VERIFY runs them after the ordinary checks pass, on every ticket, each in a new checkout of the candidate with
`{shots}` replaced by a directory for its screenshots. They run in the same sandbox as any check, with one difference:
the network is open, because a browser suite needs it. So this is the candidate's code with the network: it can reach
anything on localhost and send what it can read to anywhere. That is why it reads nothing in the home directory but the
tools on its PATH, the `lib` and `libexec` beside them and git's configuration, and never the credential stores listed
in `lib/giraffe/checks.rb`. A suite that needs more of home fails, such as one using Playwright's own browsers rather
than the system Chrome, or a version manager's shims rather than its tool's own directory on PATH. No check can reach
the keychain, and Chrome depends on that here: with that rule removed, Chrome in the fixture's check cannot draw. Writes
stay in the checkout and temporary directories, which is why the command above moves npm's cache. Chrome cannot start
its own sandbox inside this one, so it needs `--no-sandbox`, which Playwright passes by default. An ordinary check can
still read the rest of home and leave it in a temporary directory for a screen check to send, so this narrows what can
leave by accident, and is no boundary against hostile code.

A screen check that exits nonzero sends VERIFY red, and BUILD gets its output in the fix batch. Otherwise every `.png`
left under `{shots}` is kept in the run's `screenshots/<attempt>/`, with its digest in the verification artifact, and
the auditor must open each one and rule it `fits` or `broken` by name. A picture ruled `broken` sends VERIFY red. If
BUILD then finds no edit to make, the question to a person names the pictures, and their answer reaches the next audit.

PLAN's rule for a change people can see is that a step extends these commands to reach each state it adds, at its
longest and tallest, on the narrowest screen the repository supports, to take a screenshot there and to fail if its
text ends past the screen's edge. [The fixture's check](../tests/fixtures/screens/fit_check.rb) shows one way to measure that.
A ticket that TRIAGE or PLAN marks `ui` goes red if the commands leave no screenshot.

With no `screen_checks` declared, a `ui` ticket asks a person to look at each candidate before its audit, and their
answer is the audit's evidence. Pictures stay on the execution host: only their digests reach Temper or a restored run.

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
reservation conservatively. An invalid output, or one the contracts refuse, such as a plan or a mutation
patch, stays billed and pauses the run; `resume` asks again with the refusal in the prompt. No automatic
invalid-output retry is currently attempted. Outputs of finished attempts leave the state, whose cap is 1 MB;
a single attempt's outputs past that are refused the same way. A diff past 2 MB reaches a model as a summary of
changed files, which it can read for itself.

BUILD runs each plan assignment in a fresh context, commits its files, then repeats executable checks
and independent review within the configured round limit. A red edge from VERIFY re-enters BUILD as one
fix batch carrying the failed verification, not a replay of the plan. If that batch changes nothing, the run asks a person instead of paying to repeat the same red, and the answer reaches the next audit, so what anything the harness cannot run printed on that candidate can count as evidence. VERIFY runs checks and [screen checks](#screen-checks) again, refuses any
candidate/worktree mutation, and audits acceptance criteria without giving the auditor the plan.
Unmet or unverifiable criteria cannot publish. Changed specs require mutations of existing production
source or view files, never data or config files such as YAML, or scripts with no extension; the harness runs each spec unmutated and then mutated in disposable candidate worktrees and
records the command result in the verification artifact. A spec that fails unmutated sends VERIFY red.
For reproduced bugs, it executes the new regression spec on the base and candidate, requiring red then
green; a candidate without that spec goes red too, and one a `.gitignore` would hide is refused when
reproducing. A spec a clean checkout cannot run, for want of dependencies only the worktree has, also goes red;
BUILD can ask a question about that, and if it recurs the stop message carries the reason. A regression spec that loads a file only the candidate adds is red on the base for that
reason alone, which the harness cannot tell from the bug being red. Those proofs are executable evidence,
while the model still judges their meaning and quality.

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
