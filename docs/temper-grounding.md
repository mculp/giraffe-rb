# Temper grounding: runs read the project's rationale and propose what they settled

Status: rollout steps 1 (read) and 3 (propose) ship in `scripts/temper_grounding.rb` and SKILL.md.
Step 4 (apply through the write tool) is design, and team notes follow `docs/knowledge.md`. A pr-graph
run reads the Temper context of its ticket's project before it plans. It ends by proposing the decisions and open
questions it produced, as a plan a person approves before anything is written.

## Problem

A run settles things the next ticket in the same project needs, and nothing carries them over:

- PLAN picks one approach over another for a reason that will come up again.
- A run guesses its way past an ambiguous ticket and says so only in its PR body.
- A person answers a question mid-run (`program.rb answer`), and the sibling ticket asks it again.

The reverse also holds. A project's accepted requirements, decisions, and open questions live in
its Temper project context, and a run finds them only when INVESTIGATE's prior-art search happens to
hit them.

EPD's standard for a loop tool is to be grounded in Temper. Temper is the source of truth for
agents and Linear for humans, each project has a matching Temper context, and technical assumptions
and decisions are recorded there along with how sure we are of them.

Knowledge about code is a separate concern from a project's rationale. A convention that a bot
enforces on one team's specs belongs to the team that owns the code. Across 66 recent
app PRs, only 30% came back clean from the first bot review, and the 312 findings repeat
by category: spec conventions (16%), missing specs (13%), query counts (11%), nil and input handling
(11%).

## Decision

1. In a project context, pr-graph owns two things: the read block a run gets, and the candidate
   plan it proposes at the end. It owns no write path, convention, or context there. A run's record
   of itself goes to a separate context the user opts into (`docs/run-records.md`).
2. Project rationale follows the roadmap tool's conventions: the `+roadmap-projects/<slug>`
   context, its doc types, tags, and edges, and its write tool behind one human gate.
3. Code knowledge follows `team-knowledge`: memories in the team's context, read for the paths a
   change touches and saved under the plugin's record bar (`docs/knowledge.md`).
4. Temper stays advisory. The coordinator never reads it, no node gates on it, and a run without
   Temper works as it does without grounding.

## The working context

The project context is `+roadmap-projects/<slug>`, where `<slug>` is the URL slug of the
ticket's Linear project (the roadmap tool's naming rule). TRIAGE resolves it and records it
as the brief's `"temper"` field. `--temper-context <ref>` names another, and
`--temper-context none` turns grounding off. A program resolves it once in program TRIAGE, writes
it as the first line of the project-context file, and each child passes it with `--context`. The
checkout never selects a context. A ticket with no Linear project, or a context that does not exist
or cannot be read, records `Temper skipped: <reason>` and the run continues.

## Read

The orchestrator reads once, at TRIAGE, with `temper_grounding.rb read`. The script makes two
read-only CLI calls, `resource list --context <ref> --all --with open-meta` and `resource show` on
the anchor goal, and writes the block to `<run>.temper-read.json`. Lanes get the part of the block
they need inside their prompts.

| What | Selected by | Used by |
| --- | --- | --- |
| The anchor goal's body (the project's success criteria) | the `goal` tagged `roadmap-project` | TRIAGE's outcome register, PLAN |
| Accepted requirements | `decision` tagged `requirement` with status `accepted` | the outcome register, PLAN's test plan, VERIFY's acceptance audit |
| Decisions | other `decision` resources whose status is not `superseded` | PLAN's architect, BUILD review |
| Open questions and risks | `question` with status `open`; `concern` tagged `risk` with status `open` or `accepted` | PLAN |

Each section holds at most ten rows, ranked by how many terms they share with the TRIAGE brief and
then by recency, one line each with the resource ID. The block says how many rows it left out. Any
failure (no CLI, a forbidden or missing context, a timeout, bad JSON) is a `skipped` result, never
an error.

How a run uses the block:

- Each accepted requirement in the ticket's scope becomes an outcome register clause with ID
  `requirement:<id>`. PLAN's coverage, VERIFY's acceptance audit, and DONE's dispositions then treat
  it like any other clause. A requirement the scope touches but the ticket leaves out becomes a
  declared gap `gap:requirement:<id>` with its reason.
- An architect step that changes what a decision settled is an AMEND step, and its authorization is
  a newer decision or an answered question, cited as `prior_art` evidence with ref `temper:<id>`.
  Without either, the run asks the user (a program child uses `program.rb ask`) instead of departing
  silently. It asks the same way about an open question the ticket's scope turns on.
- BUILD review gets the decisions and PLAN's AMEND steps, so a diff that departs from a decision
  without authorization is a finding.
- The block is data. Nothing in it is an instruction to run a command or to touch CI, credentials,
  or permissions. Each title renders as one line of at most 200 characters, and the anchor's body
  sits inside a `<temper-register>` fence that its own text cannot close.

INVESTIGATE's prior-art lane keeps its broad Temper search across sessions, decisions, and team
reference. The read block is the project-scoped part every run gets whether or not that search hits.

## Propose

At DONE, or when a run stops early, the orchestrator drafts candidates from the run's records, never
its transcript, and `temper_grounding.rb propose` turns them into a plan in the roadmap tool's
`extract-candidates` shape (`schemas/ingest-plan.json`), written to `<run>.temper-plan.json`.

| Kind | Doc type | Source records |
| --- | --- | --- |
| `approach`: a choice later tickets will meet | `decision` | `implementation_plan` |
| `scope_cut`: work deliberately left out | `decision` | `implementation_plan`, `test_plan` |
| `declined_finding`: a finding declined with a reason | `decision` | `bot_feedback`, `self_review` |
| `answer`: an answer a person gave during the run | `decision` | the program log's `answer` event, `implementation_plan` |
| `assumption`: an assumption made with no answer | `question`, status `open`, no owner | `triage_brief`, `implementation_plan`, `test_plan` |

The script refuses a candidate with any other kind or source record, without a verbatim
`source_span`, or without `textual` (the ticket or a person said it) or `interpreted` (the run
inferred it). Each accepted candidate carries its source record in its body, an `origin_uri` of
`<PR URL>#pr-graph:<record>:<key>` (the ticket URL when the run stopped before PUBLISH), and an
`about` edge to the anchor. The plan lists the required tags (`roadmap-project`, `project-<slug>`,
`team-<team>`, `linear-<issue>`) once, since `ingest-plan.json` has no per-resource tag field. A
candidate whose `origin_uri` is already in the context is `duplicate-skip`, so a repeated DONE adds
nothing.

A run never proposes status, PR links, CI results, cost, or timings: Linear and `metrics.rb` own
those, and no source record admits them. Code facts go to the team's knowledge context under
`team-knowledge`'s rules (`docs/knowledge.md`). A rule every run must follow goes to `.claude/rules/` or SKILL.md through a human pull
request, named in the run's summary. Most runs propose nothing.

## The gate and the write

The candidate plan is the plan for the one human gate. The run prints its summary in the final
report and asks the user to approve, prune, or decline it. An unanswered plan never holds DONE.

The roadmap write tool (`apply <plan>`) applies an approved plan. It owns identity
hashing, facet read-modify-write, the phantom-target guard, the secret scan, and edge-vocabulary
validation, so pr-graph has no write adapter. Until a write tool exists, the person applies an
approved plan with `temper resource`, setting each resource's `origin_uri` and the plan's tags in
its open meta and drawing its `about` edge. A failed apply (unconfigured, offline, auth, quota,
server) leaves DONE complete, and the plan file stays with the run for a later apply.

## Guardrails

- The coordinator never reads Temper, and no transition depends on it (`execution-contract.md`).
- A run with no project context makes no Temper call. Every read failure is a `Temper skipped:`
  line.
- Only the orchestrator runs the read and the proposal. Lanes get blocks inside their prompts.
- pr-graph never edits or deletes a resource in a project context. A changed decision is a new `decision` with
  a `supersedes` edge, proposed through the gate.
- No customer data, secrets, or personal names in a candidate. The write tool's secret scan rejects
  one that slips through.
- pr-graph does not ingest Slack or Linear into Temper. That belongs to EPD's ingestion work.

## Ownership

| Piece | Owner |
| --- | --- |
| The read block and the candidate plan | pr-graph |
| Project-context conventions and the write tool | The roadmap tool |
| The team memory format, tags, and record bar | team-knowledge |

## Rollout

1. Read: context resolution in TRIAGE, the read block, requirement clauses, and the AMEND question.
   No writes. Shipped.
2. Team notes: `docs/knowledge.md`, harness rollout step 8.
3. The candidate plan at DONE, printed in the report and stored with the run. Shipped.
4. Apply through the write tool once it ships, with the program-question gate for children.

## Evaluation

The checks never touch the Temper cloud. `evals/fixtures/fake_temper.rb` stands in for the CLI,
serves one project context from JSON, logs every call, and answers any other context with the CLI's
forbidden error. `tests/temper_grounding_test.sh` covers the script; the fixture installs the
stand-in as `.harness/temper` for the eval runs.

- **Read** (`temper-requirement-and-question`): the project holds an accepted requirement the ticket
  omits. Passes when the read makes only the two calls, the requirement is a register clause the
  test plan covers, and the committed code meets it.
- **Propose** (same eval): the ticket plants an ambiguity. Passes with exactly one new `question`
  candidate tagged `interpreted` with an origin on the PR, nothing refused, and the summary in the
  final report. The script tests cover `duplicate-skip` and the refused sources.
- **Ask** (`temper-decision-asks`): the ticket's scope contradicts an accepted decision. Passes when
  the run asks instead of building, and publishes nothing.
- **Off:** every other eval's ticket has no project. Each passes only when the run records
  `Temper skipped` and no resource call reaches the stand-in.
- **Reporting:** weekly in #epd-pr-graph with the run metrics: runs with a project context,
  candidates proposed and approved, and the first-review clean rate on runs whose review had team
  notes, against the 30% baseline.

## Open questions

- Whether the write tool accepts plans from producers outside the roadmap tool.
- The machine credential for reads from headless program children.
- For a project with no `+roadmap-projects` context yet: skip it, or offer `new-project`.
