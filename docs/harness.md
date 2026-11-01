# Giraffe: code delivers the PR, models judge

Status: target design. The first executable slice is documented in [running.md](running.md).
That implementation uses local journals with live Temper mirroring; it stops at a reviewed draft PR.
Later sections here describe the full target, including stages not yet implemented.

## Problem

A pr-graph run is a model following SKILL.md. The coordinator scripts check and record transitions,
but the model decides when to call them, which steps to run, and when the run is finished. A model
that decides the process is too heavy for the ticket runs a subset of it, and nothing in the
plugin can make it run a step it skipped.

- **pr-graph.** In one benchmark ticket the run never ran the ticket's repro. One program's
  children finished their work outside the coordinator when it had no edge for it. In the 2.13.1
  fixture evals with a Sonnet orchestrator, every failed assertion came from the orchestrator
  bypassing the process, such as running VERIFY's command by hand or writing code itself, and none
  from spec quality. Later versions add guards to hold a non-Opus orchestrator to the graph's process.
- **A phase-gate skill.** In a five-run comparison the skill loaded
  every time, and in two runs the model never chose a tier or wrote the run manifest. The phase gate
  enforces only once the manifest exists, so those two runs did the same work as the baseline.
  Asked why, the model said it had judged the process too heavy for the ticket.
- **Guards don't fix it.** `push_guard.rb`, the phase gate, and the orchestrator guards are hooks
  that catch a model after it acts. They cover the actions someone thought of, and they cannot make
  a model take a step.
- **Cost.** The orchestrator's context grows from about 50K to 190K tokens per run and is about 63%
  of the Opus spend (eval fixtures, four runs per arm). Most of that context is lane reports it
  never reads again. Fresh contexts re-send shared inputs such as the ticket and the plan to several
  steps, so the harness saves less than that share; rollout step 4 measures it.
- **Location.** Run state lives in `~/.claude/pr-graph` on one laptop. The app runs in the cloud
  only on Cursor's VMs (`.cursor/environment.json`), and a VM's disk does not outlive it.

## Decision

1. **Giraffe, a harness program, owns the run.** It is Ruby, lives in its own repo, decides what runs next,
   runs every required step as code, and calls a model only for judgment or for writing code.
2. **A model call is a function.** It gets a fresh context built from the step's inputs, a fixed
   tool list, and a required output schema. The harness validates the output and records it. Missing
   or invalid output fails the step. The model never sees the graph, SKILL.md, or the run's other
   steps.
3. **Local journals and live Temper mirroring store a run.** Every local durable write is mirrored
   during execution. Outages leave visible pending writes for retry, and complete checkpoints delimit
   safe remote recovery. Tests use the fake Temper in `evals/fixtures`.
4. **A capability the model should not use is absent, not guarded.** Pushing, opening and editing
   PRs, labels, Linear, and Temper writes are harness code. Model calls get none of them, so there
   is no push guard.
5. **Runs execute where the app runs.** That is a local worktree or a Cursor cloud VM. The harness
   is the same program in both places; only the model runner differs.
6. **Models never message each other.** Steps pass data through Temper. A question for a person is
   part of a step's output, and the harness parks that step until the answer is in Temper.

## Design

### Pieces

| Piece | What it does | Where it runs |
| --- | --- | --- |
| Controller | `bin/giraffe start`, `status`, `answer`, `cancel`, and program scheduling | Laptop first; see Open questions |
| Harness | `bin/giraffe harness <run>`: the loop below | Inside the worktree or VM where the app runs |
| Runner | Makes one model call and returns its validated output | Beside the harness |
| Store | The run's Temper resource, its data artifacts, and their declared shapes | Temper |

### Repository

| Path | Holds |
| --- | --- |
| `bin/giraffe` | The controller commands and `harness <run>` (rollout 3) |
| `lib/giraffe/harness.rb`, `lib/giraffe/steps/` | The loop, and one file per code step (rollout 3) |
| `lib/giraffe/runners/` | `claude.rb` (rollout 4), `cursor.rb` (rollout 5), and the scripted runner the tests use (rollout 3) |
| `lib/giraffe/store.rb` | The run's Temper resource, the stored event, artifact, and failure logs and coordinator, and `hydrate`, all through `scripts/temper_cli.rb` (rollout 2) |
| `lib/giraffe/shapes.rb` | Builds the Temper shapes from `references/*-v1.json` when a store opens (rollout 2) |
| `prompts/<step>.md`, `schemas/` | Each call's instructions, and the output schemas built from `references/*-v1.json` (rollout 4) |
| `scripts/` | pr-graph's coordinator, contract, CI, feedback, seed, metrics, run record, and Temper scripts |
| `references/` | The v1 contracts, the coordinator policy, the automated feedback authors, and their docs |
| `tests/` | A shell test per script |
| `evals/` | The graph eval suite with its fixtures and fake Temper, and the build suite in `evals/build/` |
| `bin/test` | Runs `tests/*_test.sh` and the graders' tests; CI runs it on every PR |

- Harness code calls `scripts/` as subprocesses with JSON in and out, the way the skill does. A
  script moves into `lib/giraffe/` when the harness needs it in process.
- `scripts/` and `references/` keep the plugin's relative paths, so a fix ports between this repo
  and the plugin as the same diff. Until `/giraffe` calls this repo, the pr-graph plugin runs its
  own copy, and a fix to a shared script lands in both.
- `push_guard.rb`, `program_driver.sh`, and the plugin's Cursor installer are not here; What stays
  and what goes covers the first two.

### Releases and installs

- A release is a `vX.Y.Z` tag on `main`.
- Locally, `/giraffe` runs `bin/giraffe` from a checkout of a release in `GIRAFFE_HOME`, default
  `~/.giraffe`, and refuses a release older than the one the plugin names.
- A Cursor VM checks out the commit the controller names (Running in Cursor's cloud).
- Credentials come only from the environment: the engineer's Claude Code, `gh`, and Temper logins
  locally, and Cursor team secrets in a VM. The repo holds none.

### The loop

1. Load the run from Temper and take its lease (Open questions).
2. Ask the coordinator what is runnable (`coordinate.rb check`). The coordinator policy, red edges,
   and fix-round limit stay as they are.
3. Start every runnable step. Code steps run as subprocesses. Model calls go to the runner, and a
   step may make several.
4. Record each outcome with `finish` or `fail`, and write it to Temper as the Temper store section
   describes.
5. Repeat until DONE passes, a cap or budget stops the run, or only steps waiting on answers remain.

### Steps

| Step | Code does | Model does (output schema) |
| --- | --- | --- |
| WORKTREE | Creates the worktree, branch, and test DB | Nothing |
| TRIAGE | Fetches the ticket | Reads it, names a stacked base and any proof beyond specs, and raises questions (triage) |
| INVESTIGATE | Fetches the ticket's links, linked PRs, the Temper read block, and the knowledge blocks (`docs/knowledge.md`) before any model runs | Three calls: the ticket and prior art on Haiku, the codebase on Sonnet (investigation) |
| REPRODUCE | Reruns the probe on the base, fails the step if the result differs from the report, and checks the worktree is unchanged | Writes and runs a throwaway probe in the run's state directory (repro) |
| PLAN | Posts the plan to the Linear ticket; a failed post leaves it in the run record and the DONE report | The test plan and the grounded plan, with the surveyed `ui` and the outcome clauses (outcome, plan) |
| BUILD | Runs autocorrecting lint and the specs, commits, and finishes only with `build_manifest` and `self_review` for HEAD | A fresh writer call per batch (build); review and simplify (review); judging their findings (judgment) |
| VERIFY | Runs specs and lint, the regression spec on base and on the fix, and the mutation audit | The acceptance audit against the ticket, without the plan, and the spec audit (audit); judging their findings (judgment) |
| PUBLISH | Pushes, opens the draft PR, adds the Review Bot label when the repo has one, and adds `review-app` when PLAN surveyed `ui=yes` | Writes the PR body to the repo's template, or to Description and Notes sections when it has none (pr_body) |
| PR-RISK | After PUBLISH, and again after a push that changed the diff: posts the risk comment and sets the one `pr-risk:<level>` label | Runs `/pr-risk` read-only on the draft PR and returns the level, verdict, sub-scores, and Verify first (risk); DONE's report carries Verify first |
| CI-WATCH | `pr_ci.rb` waits on CI and reconciles | Digests a red build (ci_digest) |
| BOT-FEEDBACK | `github_feedback.rb` collects threads and resolves fixed bot threads | Judges bot findings and human review comments (judgment) |
| VALIDATE | Runs the proof command TRIAGE or PLAN named and records a `scoring` outcome; skipped when none was named | Nothing |
| DESC-SYNC | Edits the PR body after a push that changed the diff | Rewrites the affected sections (pr_body) |
| REVIEW-APP | Deploys, and runs the seed script once after a person approves its exact bytes | Prepares the seed, and runs one browser scenario per call with a verdict (seed, scenario) |
| DONE | Checks every gate, validates the outcome coverage and passes it to `finish`, and writes the DONE report | Gives every outcome clause a terminal status from the test plan, the audits, and PLAN's gaps (outcome_coverage), drafts the Temper candidates (temper_candidates), and proposes the knowledge to save (knowledge) |

SELF-REVIEW stays retired. Review is BUILD's phase, as the policy has it: BUILD repeats write,
review, and judge until the review closes clean or the fix-round limit stops it.

Each call runs on the model SKILL.md's Lanes table pins for its lane. The judgments the
orchestrator makes today (TRIAGE, PLAN's reconcile, judging findings, and DONE's outcome coverage)
run on Opus.

### Repos without the extras

Giraffe runs in any repo, not only the main app repo. At the start of a run the harness probes what
the repo has and writes the result to the run record. A step that needs something the repo lacks
skips or falls back, and says so in the DONE report. It never fails the run and never waits.

| The repo lacks | The harness |
| --- | --- |
| A `review-bot` label | Adds no label, and DONE does not wait for a Review Bot review |
| `.github/PULL_REQUEST_TEMPLATE.md` | Has PUBLISH write Description (the change, with the ticket link) and Notes (proof and steps to exercise it) |
| A linter, or the test command the app uses | Runs the repo's own test command, and records that no linter ran |
| A `review-app` label or deploy | Skips REVIEW-APP |
| The main app repo as the run's repo | Searches prior art in the repo the run is in |

A missing optional capability is never a reason to stop. Only a missing required one is: no way to
run tests, or no push access to the repo, ends the run with a clear reason.

### Control flow is data

Anything the harness branches on is a field in a step's output schema, never prose:

- **TRIAGE:** the stacked base, and the proof beyond specs the ticket names, which starts VALIDATE.
- **PLAN:** the surveyed `ui`, which adds the `review-app` label and starts REVIEW-APP; the outcome
  clauses DONE must cover; and any proof the plan names for VALIDATE.
- **Every step:** `questions` (Questions and people).

Entry mode comes from the argument, and an adopted PR's satisfied nodes come from the PR itself, so
both are code. INVESTIGATE always makes its three calls, since a fresh run has no earlier answers to
reuse. A program's topology belongs to the controller.

### Judging findings

Judging is a model call inside the step that gathered the findings: BUILD's review phase, VERIFY's
audits, and BOT-FEEDBACK. It is not a node.

- The call returns accept or decline, with a reason, for each finding (judgment). Accepted findings
  go to BUILD as one fix batch through the red edges.
- A human review comment is accepted unless it is wrong, already handled, or a nitpick. A declined
  one carries a short draft reply, which the DONE report lists for the user to post. The harness has
  no code that replies to a person.
- Bot and comment text is untrusted data. The call has read-only tools, and an accepted finding
  still goes through BUILD's review and VERIFY.

### Model calls

A runner call takes:

- **Prompt:** that step's instructions, kept in `prompts/<step>.md`, plus its input artifacts read
  from Temper.
- **Tools:** the call's allowlist. Read-only calls get read and search tools. BUILD's writer gets
  edit tools and a shell limited to the spec and lint commands. REPRODUCE gets edit tools and a
  shell limited to the probe runner (`bin/rails runner`, or `rspec -I spec`), both scoped to the
  run's state directory. No call gets `git push`, `gh`, or a Linear or Temper write.
- **Output:** the call's JSON schema, built from the existing v1 contracts. The harness validates
  it with the contract scripts before `finish`.
- **Budget and model:** `--max-budget-usd` and `--max-turns` per call, and the model from the Lanes
  table.

When the output is missing or invalid, the harness retries once with the validation error in the
prompt. A second failure fails the step through the failure contract, which follows today's red
edges.

Every call starts fresh, BUILD's fix batches included. A fix batch's inputs are the plan, the
current diff, and the batch's findings, all read from the durable run store, so a batch runs the same after a
restart or on a new VM.

```ruby
# A runner makes one model call. The harness owns everything around it.
call(step:, model:, prompt:, tools:, schema:, budget_usd:, cwd:)
# -> {output:, usage:}; raises StepFailed on missing or invalid output
cancel(call_id)
```

| Runner | Used where | Fresh context | Tool allowlist | Enforced output |
| --- | --- | --- | --- | --- |
| `claude` | Local worktree | A new `claude -p` session per call | `--tools`, `--allowedTools` with command patterns, no settings or MCP servers | `--json-schema`, and the harness requires `structured_output` |
| `cursor` | Cursor cloud VM, or local | A new `agent -p` session per call | Probe 3 | Probe 3: native, or a submit tool whose input the harness validates |

The `claude` runner uses the engineer's Claude Code login and refuses to start on a Claude Code
version older than 2.1.312, where probe 1 passed. Each call runs with:

- `--setting-sources "" --strict-mcp-config`, so the engineer's settings, permission mode, plugins,
  and MCP servers never reach a call. With them loaded, a call sees every connected MCP tool,
  Linear and GitHub writes included.
- `--tools` naming the only tools the call can see. `--allowedTools` patterns approve calls among
  those tools, and a shell command outside them is denied without a prompt. On their own they
  restrict nothing: under the engineer's auto mode, a call given only `--allowedTools Read` ran a
  shell command.
- `--json-schema`, which rejects output that fails the schema. A call that never returns
  structured output, or hits `--max-turns` first, still exits 0 with `subtype: success`, so the
  harness fails any call whose result has no `structured_output`.
- stdin closed, so the CLI does not wait on it.

The `cursor` runner reads `CURSOR_API_KEY` from Cursor team secrets, never from the repo.

### Running in Cursor's cloud

A Cursor VM exists only behind a Cursor cloud agent, so the cloud agent is a launcher:

- The controller creates one cloud agent per run with the Cloud Agents API
  (`POST https://api.cursor.com/v1/agents`). It sets `repos[].startingRef` to the run's base,
  `workOnCurrentBranch` to true, `autoCreatePR` to false, and `agentId` from the run ID so a retried
  create does not start a second VM.
- The agent's prompt is to run `bin/giraffe harness <run>` and report its exit status.
- `.cursor/environment.json` already installs Ruby, Postgres, Redis, and the EJSON keys. Its install
  script needs one addition in the app repo: check out the giraffe repo at the commit the
  controller names (probe 7). The run records that commit and a relaunch uses the same one, so a
  relaunched VM never runs a different version, and an unmerged commit runs the same way a release
  does.
- The harness writes its first heartbeat to Temper before it bootstraps anything, then one a minute
  from a thread of its own, so a schema load or a long spec run cannot hold it up. Each heartbeat
  names the running steps.
- The controller allows a launch window for the first heartbeat, which probe 2 sets from a cold
  boot, and then ten minutes between heartbeats. When either runs out, it cancels the agent's run
  (`POST .../runs/{runId}/cancel`) and launches again with the same run ID. The new harness resumes
  from Temper.
- Liveness comes from that heartbeat, not from the launcher model doing what it was asked.

### Local journals and live Temper

The executable storage contract is in [running.md](running.md#local-files-and-live-temper).
Local JSONL journals, evidence blobs, coordinator manifests, and state revisions are durable first.
Each committed change is mirrored immediately, including a node's start, model-call progress,
questions, and answers. An unavailable Temper leaves visible pending work; step boundaries and
`sync` reconcile the journals rather than relying on a separate volatile queue.

The harness uses schema-digested physical kinds in a shared context and a live-run resource identity
that cannot be mistaken for a finished-run record. Live metadata is separate from recoverable
checkpoint metadata. A checkpoint names exact log lengths and manifest digests, and is published only
after its referenced evidence and transitions are present. Hydration refuses missing, corrupt, or
conflicting history and validates coordinator manifests before installing files.

`PrGraph::Store` and its `Stored*` classes retain the earlier remote-first primitive for existing
callers. The harness's `LocalStore` uses local-first observer classes instead. A run's configured
mode is explicit: `mirrored` or `local`. Do not run two hosts against the same run: distributed fencing
remains a prerequisite for automatic cloud failover. Proposed Temper additions are described in
[temper-capabilities.md](temper-capabilities.md).

### Questions and people

- A step's output can carry `questions`. The harness writes each one to Temper and parks that step.
  Steps that do not depend on it keep running, so CI-WATCH keeps watching while a BOT-FEEDBACK
  question waits.
- When only parked steps remain, the harness records its state and exits.
- `bin/giraffe status` lists open questions, and `bin/giraffe answer <run> <question> "<text>"`
  writes the answer to Temper. The controller then resumes the harness from its local journal or a validated remote checkpoint.
- People answer questions; no model answers another's. A step whose question the plan or the
  project context would settle gets those as inputs.
- Approvals that exist today, such as the seed script and declined findings that need a call, are
  questions.

### The DONE report

DONE writes a report artifact to Temper: metrics, declined findings with their draft replies, the
outcome coverage, the Temper candidates, and the knowledge the run saved, reinforced, or refused.
`bin/giraffe status` renders it, and session mode shows it in chat.

### Session mode

`/giraffe <ticket>` in Claude Code or Cursor calls the installed controller (Releases and
installs). It starts a run on the local runner, or in the cloud with `--cloud`, then shows status
and open questions and passes answers back. The chat model relays; it does not run steps. SKILL.md
becomes this entry point plus the per-step prompts.

### What stays and what goes

- **Stays:** the coordinator policy and `coordinate.rb`; the artifact, failure, outcome, and lineage
  contracts, which become output schemas and Temper shapes; `pr_ci.rb`, `github_feedback.rb`,
  `spec_audit.rb`, the seed scripts, and `metrics.rb`; and `program.rb` as the controller's
  scheduler, with its stacked bases, reopens and rebases when a parent pushes, and
  `TEST_ENV_NUMBER` offsets for local children.
- **Goes:** `push_guard.rb`; the orchestrator role in SKILL.md; the supervisor session that answers
  program children's questions; `program_driver.sh` and the tmux launch; and the headless-children design, since no model runs a graph.

## Alternatives

| Option | Why not |
| --- | --- |
| Keep the skill and add hooks | A hook catches an action; it cannot force a skipped step. A phase-gate skill is this approach, and it allowed everything when the model never wrote the manifest. |
| Pi as the agent | Pi replaces Claude Code and Cursor instead of being called by a harness, and it is not what runs in Cursor's cloud. Owning the loop is its draw, and the harness gives us that in Ruby. It would also add TypeScript and API-key billing. |
| Claude Agent SDK | It wraps the same CLI the `claude` runner calls, and every control the runner needs is a CLI flag. It adds a Python or TypeScript runtime and needs API-key auth. |
| Cursor TypeScript SDK | The Cloud Agents API is REST and SSE, which Ruby calls directly. Revisit if the `cursor` runner needs something only the SDK has. |
| Each step as its own Cursor cloud run, driven from outside the VM | Code steps would become requests to a model ("run the specs"), which is the failure this design removes. A fresh context per step would also need a new VM per step. |
| Messaging between sessions (SendMessage, agent teams, Cursor steer) | Nothing durable records the message, and delivery depends on session names. No session outlives its step, so there is nothing to message. |
| Independent local and remote stores | Chosen instead: one local journal with live mirroring, visible pending writes, and explicit recovery checkpoints. |
| Resuming BUILD's writer session across fix batches | A relaunched VM cannot resume a session the old VM's disk held, so BUILD would behave one way locally and another in the cloud. Fresh calls with inputs from Temper behave the same everywhere. |
| A model that answers questions the plan settles | The asking step can be given the plan instead, and a person's answer is one the run can cite. |

## Rollout

| # | Change | Verified when |
| --- | --- | --- |
| 0 | This design | Review |
| 1 | Rename the plugin to giraffe: the plugin, skill, and command names, the state directory, environment variables, and Temper names | Lint and `tests/*.sh` pass, a fresh install loads `/giraffe`, and a run journaled under `~/.claude/pr-graph` still resumes |
| 2 | Temper store: `store.rb`, the runs context, declared shapes built from the v1 contracts, and the fake Temper in tests | `tests/*.sh` pass against the fake; a shape refuses a known-bad artifact and accepts every fixture artifact; a repeated transition write reads back once, and a sequence gap fails closed; a live run is readable in Temper's web UI |
| 3 | Harness loop, every code step, and the controller's `start`, `status`, `answer`, and `cancel`, with a scripted runner in tests | A fixture run reaches DONE with scripted model outputs; a run killed mid-step, or between an artifact write and its transition, resumes with the same runnable steps; a question parks only its step, and `answer` resumes it |
| 4 | `claude` runner, per-step prompts, tool lists, and schemas | Graph and build eval suites, four runs per arm, against the Opus orchestrator, with the Lanes table's models in both arms. Passes when every harness run's events show every required step, and each suite's mean score is at most one assertion below the orchestrator arm's. Cost is reported, not gated. |
| 5 | `cursor` runner, the cloud launcher, and the controller's heartbeat check | Probes pass; a fixture run reaches DONE in a Cursor VM, including after its VM is killed mid-run |
| 6 | Session mode and program scheduling on the controller | A two-ticket stacked program runs from the controller, and `/giraffe` shows status and takes an answer |
| 7 | PR-RISK step: the `risk` schema from `/pr-risk`'s output, and the harness posting the comment and label | A fixture run's draft PR gets one risk comment and one `pr-risk:` label; a push that changes the diff swaps the label, and a push that leaves it unchanged runs nothing |
| 8 | Knowledge tiers (`docs/knowledge.md`): personal, team, and meta blocks as step inputs, and DONE's `knowledge` call with code-checked writes | The Evaluation section of `docs/knowledge.md` passes against the fake Temper |

## Probes

1. Passed on Claude Code 2.1.312: one `claude -p` call enforces `--json-schema` and `--tools`
   together, and denies a shell command outside its `--allowedTools` patterns without prompting.
   Model calls lists the flags and checks it requires.
2. A Cursor cloud agent keeps a multi-hour harness process alive (the run reports
   `WAITING_FOR_BACKGROUND_WORK`), and the controller sees the process end. The time a cold boot
   takes to write its first heartbeat sets the launch window.
3. `agent -p` inside the VM: restricting tools, enforcing an output schema, and authenticating
   with `CURSOR_API_KEY` from team secrets.
4. With `workOnCurrentBranch` true and `autoCreatePR` false, the agent pushes nothing the harness
   did not commit.
5. Temper accepts writes from the VM with a machine credential, at a full run's write volume.
6. `envVars` on agent creation is enabled for our account. It is in beta and silently ignored when
   it is off.
7. A cloud agent started on the app repo can clone the giraffe repo at a commit, which needs
   Cursor's GitHub access to include this repo.

## Open questions

- **Lease.** Temper has no conditional writes, so it cannot guarantee one harness per run. Until it
  does, the controller is the only thing that launches a harness, and `agentId` keeps it to one VM.
  The Temper team decides between conditional writes and a lease primitive.
- **CI rounds.** Today a run stops after three failed fix rounds on the same failure, so different
  failures can keep it pushing. Stripe caps a run at two CI rounds after local checks pass, then
  hands it to a person.
- **Where the controller runs** for unattended programs.
- **Where questions reach people.** The CLI first; Slack or Linear later.
- **Who can read run records.** They carry ticket text, plans, and review findings, so the runs
  context's team decides their visibility.
