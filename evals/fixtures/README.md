# pr-graph eval fixtures

`build_fixture.sh <scenario> <dest>` creates a throwaway Ruby project so the skill's graph,
contracts, and scripts can be exercised without Linear, GitHub, Buildkite, or a real
app monolith. Each eval prompt states the substitutions:

- Linear is unavailable; the ticket is `.ticket/<ID>.json` in the fixture.
- GitHub is unavailable. PUBLISH writes the PR description to a file and records a
  `publish_manifest` for the harness's stand-in draft PR (#1 on `acme/vendor-ledger`), so PUBLISH
  completes without the run inventing identities. The post-publish nodes (CI-WATCH,
  BOT-FEEDBACK, REVIEW-APP) are reported as skipped.
- WORKTREE uses the fixture directory itself. It is the only checkout, so branching in place
  is allowed there, unlike in a real repository.
- `bin/test` is the verification suite. Formal VERIFY runs `PR_GRAPH_EVAL_VERIFY=1 bin/test`.
  BUILD and preliminary checks run plain `bin/test`. No linter exists.
- `PR_GRAPH_STATE_ROOT` points at a temp directory so no real run state is touched.
- `PR_GRAPH_TEMPER_BIN` points at `.harness/temper`, a copy of `fake_temper.rb` that serves the
  scenario's project context from `.harness/context.json` and logs every call to
  `.harness/temper.log`. Only the Temper scenarios have a context; every other read is forbidden.
  `.harness/` is gitignored.
- `PR_GRAPH_RECORD_CONTEXT` is unset, so runs record nothing. A run record would add `resource`
  calls the Temper checks count against the run.

Scenarios: `new-ticket` (ACME-101, no UI), `adopt-branch` (ACME-102 with an existing branch
and PR description), `red-edge` (ACME-103; the first formal VERIFY fails once, deterministically),
`status-constant` (ACME-104; a new constant tempts specs that restate it, which the grader rejects),
`dollars-total` (ACME-105; the total in dollars), `temper-requirement` (ACME-106; the project
context holds an accepted dollars requirement the ticket omits, and a comment plants an ambiguity
the run should propose as a question), and `temper-decision` (ACME-107; the ticket asks for a JSON
export the project's accepted CSV-only decision rules out, so the run should ask). Tickets without a
project must record `Temper skipped` with no resource call. All names are synthetic.

## Running an iteration

1. For each eval and each configuration (`with_skill`, `without_skill`), create `<iteration>/<eval-name>/<config>/{fixture,state,outputs}` and run `build_fixture.sh <scenario> .../fixture`.
2. Give the agent the eval prompt with `<fixture-dir>`, `<state-root>`, `<out-dir>`, and a fresh `<session-id>` filled in. The with-skill agent gets the skill path; the baseline gets none.
3. The eval runner saves the complete orchestrator transcript to `outputs/transcript.jsonl`, using Claude JSONL records with `type: "assistant"` and `message.content` tool-use blocks. Capture this from the runner, not from an agent-authored summary. The adopt fan-out check inspects Agent and Task calls, allowing INVESTIGATE node attempts. Missing or malformed transcripts fail this check.
4. `python3 evals/grade.py <iteration>` writes `grading.json` per run; the skill-creator `aggregate_benchmark` and `generate_review.py` tools read those.

The grader treats the named branch tip as the published candidate. It archives that commit
into a temporary directory under the run, runs its `bin/test` plus evaluator-owned acceptance
tests, and checks that feature tests are committed. It does not switch branches or use dirty
checkout files. CSV acceptance covers headers, ordering, dollars, quoting, and empty lists.
City-filter acceptance covers exact matching and preserving the original list. Status acceptance covers the
default, exact filtering, order, and rejection of unknown statuses. The spec-value check also runs the committed
suite against three evaluator-owned mutants of `with_status` (returns every vendor, returns none, swallows the
unknown-status error); each must turn the suite red.

## Local regression tests

Run `python3 -m unittest discover -s evals -p '*_test.py' -v` from the skill directory.
These tests exercise the fixtures and grader without calling an LLM or external service.
