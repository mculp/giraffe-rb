#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT="${SCRIPT_DIR}/../scripts/current.sh"
EVENTS_CLI="${SCRIPT_DIR}/../scripts/events.rb"
ARTIFACTS_CLI="${SCRIPT_DIR}/../scripts/artifacts.rb"
COORDINATE="${SCRIPT_DIR}/../scripts/coordinate.rb"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

export PR_GRAPH_STATE_ROOT="${TEST_ROOT}/state"
export PR_GRAPH_ALLOW_RAW_EVENTS=1
export FAKE_PR_DRAFT=true
export FAKE_PR_HEAD=""
export FAKE_PR_ID="pr-node-123"
export FAKE_CI_ID=1
export FAKE_CI_STATE=passed
export FAKE_FEEDBACK_STATE=clean
export FAKE_FEEDBACK_FAIL=false

FAKE_BIN="${TEST_ROOT}/fake-bin"
WORKTREE="${TEST_ROOT}/worktree"
mkdir -p "$FAKE_BIN" "$WORKTREE"

cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "${FAKE_GH_FAIL:-false}" = true ]; then
  echo "GitHub unavailable" >&2
  exit 1
fi
if [ "$1" = api ]; then
  if [ "${2:-}" = graphql ]; then
    if [ "$FAKE_FEEDBACK_FAIL" = true ]; then
      echo "GitHub denied the feedback request" >&2
      exit 1
    fi
    printf '[{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}]\n'
    exit 0
  fi
  endpoint="${@: -1}"
  case "$endpoint" in
    repos/acme/app)
      printf '{"node_id":"repo-node-1","full_name":"acme/app"}\n'
      ;;
    repos/acme/app/pulls/123)
      printf '{"node_id":"%s","number":123,"html_url":"https://github.com/acme/app/pull/123","base":{"ref":"main"},"head":{"ref":"feature/test","sha":"%s"},"draft":%s,"state":"open","updated_at":"2026-09-08T12:00:00Z"}\n' "$FAKE_PR_ID" "$FAKE_PR_HEAD" "$FAKE_PR_DRAFT"
      ;;
    repos/acme/app/commits/*/check-runs*)
      if [ "$FAKE_CI_STATE" = empty ]; then
        printf '[{"check_runs":[]}]\n'
      else
        if [ "$FAKE_CI_STATE" = passed ]; then
          conclusion=success
        else
          conclusion=failure
        fi
        printf '[{"check_runs":[{"id":%s,"name":"build","head_sha":"%s","status":"completed","conclusion":"%s","started_at":"2026-09-08T12:01:00Z","completed_at":"2026-09-08T12:10:00Z","details_url":"https://buildkite.com/acme/app/builds/1","app":{"node_id":"buildkite-app"}}]}]\n' "$FAKE_CI_ID" "$FAKE_PR_HEAD" "$conclusion"
      fi
      ;;
    repos/acme/app/commits/*/statuses*)
      printf '[[]]\n'
      ;;
    repos/acme/app/issues/123/comments*)
      if [ "$FAKE_FEEDBACK_FAIL" = true ]; then
        echo "GitHub denied the feedback request" >&2
        exit 1
      fi
      case "$FAKE_FEEDBACK_STATE" in
        clean)
          printf '[[]]\n'
          ;;
        automated)
          printf '[[{"node_id":"IC_NEW","id":91,"body":"New automated finding","updated_at":"2026-09-08T12:20:00Z","user":{"node_id":"BOT_kgDODIGtWg","login":"claude[bot]","type":"Bot"}}]]\n'
          ;;
        unknown)
          printf '[[{"node_id":"IC_UNKNOWN","id":92,"body":"Ambiguous automation","updated_at":"2026-09-08T12:21:00Z","user":{"node_id":"O_UNKNOWN","login":"acme-org","type":"Organization"}}]]\n'
          ;;
        *)
          exit 2
          ;;
      esac
      ;;
    repos/acme/app/pulls/123/reviews*|repos/acme/app/pulls/123/comments*)
      if [ "$FAKE_FEEDBACK_FAIL" = true ]; then
        echo "GitHub denied the feedback request" >&2
        exit 1
      fi
      printf '[[]]\n'
      ;;
    *)
      exit 2
      ;;
  esac
  exit 0
fi
exit 2
SH
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"

git -C "$WORKTREE" init -q
git -C "$WORKTREE" config user.name "PR Graph Test"
git -C "$WORKTREE" config user.email "pr-graph@example.test"
printf 'base\n' > "$WORKTREE/example.txt"
git -C "$WORKTREE" add example.txt
git -C "$WORKTREE" commit -qm "base"
base_sha=$(git -C "$WORKTREE" rev-parse HEAD)

tests=0

ok() {
  tests=$((tests + 1))
  echo "ok ${tests} - $1"
}

fail() {
  echo "not ok $((tests + 1)) - $1" >&2
  exit 1
}

emit() {
  "$EVENTS_CLI" emit "$1" "$2" >/dev/null
}

attempt_from() {
  ruby -r json -e 'puts JSON.parse($stdin.read).fetch("attempt_id")'
}

authority_from() {
  ruby -r json -e 'puts JSON.parse($stdin.read).fetch("authority")'
}

artifact_id_from() {
  ruby -r json -e 'puts JSON.parse($stdin.read).fetch("artifact_id")'
}

put_artifact() {
  local session="$1"
  local family="$2"
  local node="$3"
  local attempt_id="$4"
  local input_sha="$5"
  local candidate_sha="$6"
  local perspective="$7"
  local wake_id="$8"
  local outcomes="$9"
  local content="${10}"
  local metadata

  metadata=$(ruby -r json -e '
    candidate = ARGV.fetch(5) == "-" ? nil : ARGV.fetch(5)
    wake = ARGV.fetch(7) == "-" ? nil : ARGV.fetch(7)
    puts JSON.generate(
      "family" => ARGV.fetch(0),
      "node" => ARGV.fetch(1),
      "attempt_id" => ARGV.fetch(2),
      "producer" => "coordinator-test",
      "input_sha" => ARGV.fetch(3),
      "candidate_sha" => candidate,
      "content_type" => "application/json",
      "wake_id" => wake,
      "perspective" => ARGV.fetch(6),
      "covered_outcomes" => JSON.parse(ARGV.fetch(8))
    )
  ' "$family" "$node" "$attempt_id" "$input_sha" ignored "$candidate_sha" "$perspective" "$wake_id" "$outcomes")
  printf '%s' "$content" | "$ARTIFACTS_CLI" put "$session" "$metadata" -
}

verify_content() {
  printf '{"failures":0,"ac_audit":{"candidate_sha":"%s","inputs":["triage_brief","investigation_report"],"clauses":[{"clause_id":"outcome:valid-next-work","verdict":"met","evidence":[{"ref":"example.txt:1","note":"next work derives from evidence"}]},{"clause_id":"constraint:no-review-mutation","verdict":"met","evidence":[{"ref":"example.txt:1","note":"review never mutates"}]}],"missed":[]},"spec_audit":{"candidate_sha":"%s","base_sha":"%s","specs":[]}}' "$1" "$1" "$base_sha"
}

publish_content() {
  ruby -r json -e '
    puts JSON.generate(
      "schema_version" => 1,
      "action" => "adopted",
      "observed_at" => "2026-09-08T12:00:00Z",
      "repository" => {"id" => "repo-node-1", "name_with_owner" => "acme/app"},
      "pull_request" => {
        "id" => "pr-node-123", "number" => 123, "url" => "https://github.com/acme/app/pull/123",
        "base_ref" => "main", "head_ref" => "feature/test", "head_sha" => ARGV.fetch(0),
        "is_draft" => true, "state" => "open", "updated_at" => "2026-09-08T12:00:00Z"
      }
    )
  ' "$1"
}

ci_content() {
  ruby -r json -e '
    state = ARGV.fetch(2)
    puts JSON.generate(
      "schema_version" => 1,
      "observed_at" => "2026-09-08T12:10:00Z",
      "repository_id" => "repo-node-1",
      "pull_request_id" => "pr-node-123",
      "pr_number" => 123,
      "candidate_sha" => ARGV.fetch(0),
      "wake_id" => ARGV.fetch(1),
      "overall" => state == "passed" ? "passed" : "failed",
      "authoritative_run_ids" => ["check-run:1"],
      "checks" => [{
        "provider" => "github-check", "provider_identity" => "buildkite-app",
        "logical_id" => "check:buildkite-app:build", "run_id" => "check-run:1",
        "attempt" => 1, "revision" => "revision-1", "head_sha" => ARGV.fetch(0),
        "state" => state, "terminal" => true, "supersedes_run_id" => nil,
        "started_at" => "2026-09-08T12:01:00Z", "completed_at" => "2026-09-08T12:10:00Z",
        "details_url" => "https://buildkite.com/acme/app/builds/1"
      }]
    )
  ' "$1" "$2" "$3"
}

feedback_content() {
  ruby -r json -e '
    state = ARGV.fetch(2)
    feedback = []
    ledger = []
    if state == "findings"
      revision = "b" * 64
      feedback << {
        "feedback_id" => "issue_comment:IC_FAIL", "kind" => "issue_comment",
        "remote_id" => "IC_FAIL", "revision" => revision, "content_sha256" => "c" * 64,
        "body" => "Blocking automated finding",
        "author" => {"id" => "BOT_kgDODIGtWg", "login" => "claude[bot]", "type" => "Bot", "classification" => "automated"},
        "relevant_sha" => ARGV.fetch(0), "thread_id" => nil, "review_state" => nil,
        "resolution_state" => "not_applicable", "remote_state" => "active",
        "updated_at" => "2026-09-08T12:20:00Z", "previous_revision" => nil
      }
      ledger << {
        "feedback_id" => "issue_comment:IC_FAIL", "revision" => revision,
        "decision" => "finding", "reason" => "requires BUILD", "processed_at" => "2026-09-08T12:21:00Z"
      }
    end
    puts JSON.generate(
      "schema_version" => 1, "author_policy_version" => 2,
      "baseline_at" => "2026-09-08T12:00:00Z", "observed_at" => "2026-09-08T12:21:00Z",
      "repository_id" => "repo-node-1", "pull_request_id" => "pr-node-123", "pr_number" => 123,
      "candidate_sha" => ARGV.fetch(0), "wake_id" => ARGV.fetch(1), "overall" => state,
      "feedback" => feedback, "threads" => [], "ledger" => ledger
    )
  ' "$1" "$2" "$3"
}

assert_rejected() {
  local expected="$1"
  shift

  if output=$("$@" 2>&1); then
    fail "$expected"
  fi
  printf '%s' "$output" | grep -Fq "$expected" || fail "expected '$expected', got: $output"
}

assert_completion_rejected() {
  local expected="$1"
  shift
  local complete_output finish_output complete_status=0 finish_status=0

  complete_output=$("$COORDINATE" complete "$@" 2>&1) || complete_status=$?
  finish_output=$("$COORDINATE" finish "$@" 2>&1) || finish_status=$?
  [ "$complete_status" -eq 1 ] && [ "$finish_status" -eq "$complete_status" ] || fail "completion exit status differs"
  [ "$finish_output" = "$complete_output" ] || fail "completion error output differs"
  printf '%s' "$finish_output" | grep -Fq "$expected" || fail "expected '$expected', got: $finish_output"
}

session="41111111-1111-4111-8111-111111111111"
events=$("$CURRENT" init DEMO-764 "$session")
emit "$session" '{"e":"run_start","ticket":"DEMO-764","entry":"ticket"}'
assert_rejected "No such file" "$COORDINATE" resume-run "${TEST_ROOT}/missing.jsonl" --offline
ok "fails explicitly when a requested durable run is absent"

resume=$("$COORDINATE" resume "$session")
printf '%s' "$resume" | ruby -r json -e 'abort unless JSON.parse($stdin.read).fetch("runnable") == ["TRIAGE"]' || fail "initial runnable set is wrong"
assert_rejected "dependency BUILD is incomplete" "$COORDINATE" start "$session" VERIFY --worktree "$WORKTREE"
assert_rejected "SELF-REVIEW is retired" "$COORDINATE" start "$session" SELF-REVIEW --worktree "$WORKTREE"
ok "derives runnable nodes, rejects a skipped dependency, and refuses the retired review node"

triage_start=$("$COORDINATE" start "$session" TRIAGE)
triage_attempt=$(printf '%s' "$triage_start" | attempt_from)
assert_completion_rejected "Usage:"
assert_completion_rejected "Usage:" "$session"
assert_completion_rejected "Usage:" "$session" TRIAGE
assert_completion_rejected "Usage:" "$session" TRIAGE "$triage_attempt" extra
assert_completion_rejected "invalid option" "$session" TRIAGE "$triage_attempt" --unknown
assert_completion_rejected "invalid argument" "$session" TRIAGE "$triage_attempt" --findings invalid
assert_completion_rejected "missing argument" "$session" TRIAGE "$triage_attempt" --findings
ok "finish and complete reject missing, extra, and malformed arguments identically"

cp "$events" "${TEST_ROOT}/before-missing-output.jsonl"
assert_completion_rejected "requires one current triage_brief output" "$session" TRIAGE "$triage_attempt"
cmp -s "$events" "${TEST_ROOT}/before-missing-output.jsonl" || fail "missing output changed execution state"
[ ! -e "${events%.jsonl}.coordinator/${triage_attempt}.result.json" ] || fail "missing output produced a result"
ok "finish and complete require persisted output without closing the attempt"
put_artifact "$session" triage_brief TRIAGE "$triage_attempt" "$base_sha" - author - '[]' '{"ticket":"DEMO-764","outcome_register":{"why":"Developers need resumed pull request work to preserve valid progress and reject stale proof.","actors":[{"id":"actor:developer","situation":"A developer continuing work after an interruption."}],"positive_postconditions":[{"id":"outcome:valid-next-work","statement":"The next permitted work is derived from completed evidence."}],"negative_face":[{"id":"constraint:no-review-mutation","statement":"A review must never alter the candidate while claiming independent approval."}],"declared_gaps":[]}}' >/dev/null
"$COORDINATE" finish "$session" TRIAGE "$triage_attempt" --findings 0 >/dev/null
triage_result="${events%.jsonl}.coordinator/${triage_attempt}.result.json"
ruby -r json -e '
  result = JSON.parse(File.read(ARGV.fetch(0)))
  abort unless result.fetch("state") == "completed"
  abort unless result.fetch("recovery") == {"command" => "complete", "findings" => 0}
  events = File.readlines(ARGV.fetch(1)).map { |line| JSON.parse(line) }
  abort unless events.count { |event| event["e"] == "node" && event["phase"] == "done" && event["attempt_id"] == ARGV.fetch(2) } == 1
' "$triage_result" "$events" "$triage_attempt" || fail "finish did not persist the completion transition"
ok "finish completes an evidenced attempt and preserves the recovery operation"
cp "$triage_result" "${triage_result}.backup"
printf '{invalid\n' > "$triage_result"
assert_rejected "corrupt coordinator result" "$COORDINATE" resume-run "$events" --offline
mv "${triage_result}.backup" "$triage_result"
ok "refuses resume when a coordinator manifest is corrupt"

investigate_start=$("$COORDINATE" start "$session" INVESTIGATE)
investigate_attempt=$(printf '%s' "$investigate_start" | attempt_from)
worktree_start=$("$COORDINATE" start "$session" WORKTREE)
worktree_attempt=$(printf '%s' "$worktree_start" | attempt_from)
put_artifact "$session" investigation_report INVESTIGATE "$investigate_attempt" "$base_sha" - author - '[]' '{"findings":[]}' >/dev/null
put_artifact "$session" worktree_manifest WORKTREE "$worktree_attempt" "$base_sha" "$base_sha" automated_check - '[]' '{"path":"test"}' >/dev/null
investigate_lease="${events%.jsonl}.coordinator/${investigate_attempt}.lease.json"
investigate_result="${events%.jsonl}.coordinator/${investigate_attempt}.result.json"
ruby -r json -e '
  lease = JSON.parse(File.read(ARGV.fetch(0)))
  result = {
    "coordinator_policy_version" => lease.fetch("coordinator_policy_version"),
    "run_id" => lease.fetch("run_id"),
    "session" => lease.fetch("session"),
    "node" => lease.fetch("node"),
    "attempt_id" => lease.fetch("attempt_id"),
    "lease_id" => lease.fetch("lease_id"),
    "state" => "completed",
    "initial_fingerprint" => nil,
    "final_fingerprint" => nil,
    "recovery" => {"command" => "complete", "findings" => 0},
    "outcome_impact" => {
      "outcome_coverage_version" => 1,
      "node" => "INVESTIGATE",
      "attempt_id" => lease.fetch("attempt_id"),
      "clauses" => [
        {"outcome_id" => "outcome:valid-next-work", "status" => "uncovered", "evidence" => []},
        {"outcome_id" => "constraint:no-review-mutation", "status" => "uncovered", "evidence" => []}
      ]
    },
    "outcome_disposition" => nil
  }
  File.write(ARGV.fetch(1), JSON.pretty_generate(result) + "\n")
' "$investigate_lease" "$investigate_result"
resume=$("$COORDINATE" resume-run "$events" --offline)
printf '%s' "$resume" | ruby -r json -e '
  partial = JSON.parse($stdin.read).dig("recovery", "partial_results")
  abort unless partial == [{
    "attempt_id" => ARGV.fetch(0),
    "node" => "INVESTIGATE",
    "result_state" => "completed",
    "retry" => {"command" => "complete", "findings" => 0}
  }]
' "$investigate_attempt" || fail "resume did not expose the exact interrupted transition"
cp "$investigate_result" "${TEST_ROOT}/interrupted-result.json"
assert_completion_rejected "findings are valid only for a quality node" "$session" INVESTIGATE "$investigate_attempt" --findings 1
"$COORDINATE" finish "$session" INVESTIGATE "$investigate_attempt" --findings 0 >/dev/null
cmp -s "$investigate_result" "${TEST_ROOT}/interrupted-result.json" || fail "finish rewrote the interrupted result"
"$COORDINATE" complete "$session" WORKTREE "$worktree_attempt" >/dev/null
resume=$("$COORDINATE" resume-run "$events" --offline)
printf '%s' "$resume" | ruby -r json -e '
  value = JSON.parse($stdin.read)
  abort unless value.dig("recovery", "partial_results").empty?
  abort unless value.fetch("open_attempts").empty?
  abort unless value.fetch("runnable").include?("REPRODUCE")
  abort if value.fetch("runnable").include?("PLAN")
' || fail "completion aliases did not close the independent pre-build lanes"
ok "finish recovers the exact interrupted result and complete remains a working alias"

assert_rejected "dependency REPRODUCE is incomplete" "$COORDINATE" start "$session" PLAN
assert_rejected "REPRODUCE requires --worktree for mutation detection" "$COORDINATE" start "$session" REPRODUCE
reproduce_start=$("$COORDINATE" start "$session" REPRODUCE --worktree "$WORKTREE")
reproduce_attempt=$(printf '%s' "$reproduce_start" | attempt_from)
put_artifact "$session" repro_report REPRODUCE "$reproduce_attempt" "$base_sha" - author - '[]' "{\"status\":\"not_applicable\",\"base_sha\":\"${base_sha}\",\"reason\":\"Coordinator enforcement is new behavior, not a reported defect.\"}" >/dev/null
"$COORDINATE" complete "$session" REPRODUCE "$reproduce_attempt" >/dev/null
ok "REPRODUCE runs on the guarded worktree after INVESTIGATE and WORKTREE, and gates PLAN"

plan_start=$("$COORDINATE" start "$session" PLAN)
plan_attempt=$(printf '%s' "$plan_start" | attempt_from)
put_artifact "$session" implementation_plan PLAN "$plan_attempt" "$base_sha" - author - '[]' '{"steps":[{"id":"step:coordinator","classification":"AMEND","intent":"Add deterministic transition and mutation enforcement.","outcome_ids":["outcome:valid-next-work","constraint:no-review-mutation"],"evidence":[{"role":"existing_mechanism","kind":"codebase","ref":"skills/pr-graph/SKILL.md","claim":"The existing lifecycle is interpreted from workflow guidance."},{"role":"authorization","kind":"ticket","ref":"linear:DEMO-764","claim":"The ticket authorizes deterministic transition enforcement."}]}]}' >/dev/null
put_artifact "$session" test_plan PLAN "$plan_attempt" "$base_sha" - author - '[]' '{"coverage":[{"outcome_id":"outcome:valid-next-work","status":"planned","planned_node":"VERIFY","strategy":"An automated check attempts a skipped dependency and observes rejection."},{"outcome_id":"constraint:no-review-mutation","status":"planned","planned_node":"BUILD","strategy":"An independent review inside the build attempts a prohibited change and observes rejection."}]}' >/dev/null
"$COORDINATE" complete "$session" PLAN "$plan_attempt" >/dev/null

build_start=$("$COORDINATE" start "$session" BUILD --worktree "$WORKTREE")
build_attempt=$(printf '%s' "$build_start" | attempt_from)
[ "$(printf '%s' "$build_start" | authority_from)" = write ] || fail "BUILD did not receive write authority"
lease="${events%.jsonl}.coordinator/${build_attempt}.lease.json"
ruby -r json -e '
  families = JSON.parse(File.read(ARGV.fetch(0))).fetch("inputs").map { |input| input.fetch("family") }.sort
  abort unless families == %w[implementation_plan test_plan worktree_manifest]
' "$lease" || fail "BUILD lease did not pin exact input artifacts"
printf 'build one\n' >> "$WORKTREE/example.txt"
git -C "$WORKTREE" add example.txt
git -C "$WORKTREE" commit -qm "build one"
sha_one=$(git -C "$WORKTREE" rev-parse HEAD)
put_artifact "$session" build_manifest BUILD "$build_attempt" "$base_sha" "$sha_one" author - '["outcome:valid-next-work"]' '{"commit":"one"}' >/dev/null
assert_completion_rejected "BUILD attempt requires one current self_review output" "$session" BUILD "$build_attempt"
put_artifact "$session" self_review BUILD "$build_attempt" "$sha_one" "$sha_one" independent_review - '["constraint:no-review-mutation"]' '{"raised":1,"accepted":1,"applied":1,"chat":0}' >/dev/null
"$COORDINATE" complete "$session" BUILD "$build_attempt" >/dev/null
ok "grants mutation authority only to BUILD, pins its inputs and clean HEAD, and requires its review evidence"

verify_start=$("$COORDINATE" start "$session" VERIFY --worktree "$WORKTREE")
verify_attempt=$(printf '%s' "$verify_start" | attempt_from)
[ "$(printf '%s' "$verify_start" | authority_from)" = read ] || fail "VERIFY received write authority"
verify_one_event=$(put_artifact "$session" verification VERIFY "$verify_attempt" "$sha_one" "$sha_one" automated_check - '["outcome:valid-next-work"]' '{"failures":1}')
verify_one_id=$(printf '%s' "$verify_one_event" | artifact_id_from)
assert_rejected "Usage:" "$COORDINATE" fail "$session" VERIFY "$verify_attempt" --reason "spec failed" --findings 1 --revision spec-run-sha-one
ok "refuses automatic red-edge routing without a stable failure identity"
"$COORDINATE" fail "$session" VERIFY "$verify_attempt" --reason "spec failed" --findings 1 --failure-id failure:spec --revision spec-run-sha-one >/dev/null
resume=$("$COORDINATE" resume-run "$events" --worktree "$WORKTREE" --offline)
printf '%s' "$resume" | ruby -r json -e '
  coverage = JSON.parse($stdin.read).dig("outcome_coverage", "clauses", "outcome:valid-next-work")
  abort unless coverage.fetch("state") == "conflicting"
  abort unless coverage.fetch("supports").one? && coverage.fetch("contradictions").one?
' || fail "supporting and contradictory evidence was not surfaced"
assert_rejected "input artifact verification is not green" "$COORDINATE" start "$session" PUBLISH --worktree "$WORKTREE"
ok "surfaces conflicting outcome evidence and rejects PUBLISH when VERIFY is not green"

build_two_start=$("$COORDINATE" start "$session" BUILD --worktree "$WORKTREE")
build_two_attempt=$(printf '%s' "$build_two_start" | attempt_from)
build_two_lease="${events%.jsonl}.coordinator/${build_two_attempt}.lease.json"
ruby -r json -e '
  batch = JSON.parse(File.read(ARGV.fetch(0))).fetch("failure_batch")
  abort unless batch.fetch("failures").map { |failure| failure.fetch("failure_id") } == ["failure:spec"]
' "$build_two_lease" || fail "red-edge failure was not claimed by BUILD"
resume=$("$COORDINATE" resume-run "$events" --offline)
printf '%s' "$resume" | ruby -r json -e '
  value = JSON.parse($stdin.read)
  queue = value.fetch("failure_queue")
  abort unless queue.fetch("pending").empty?
  abort unless queue.fetch("processing").one?
  abort unless value.dig("git", "state") == "write_in_progress"
' || fail "resume did not recover the in-process BUILD batch"
printf 'build two\n' >> "$WORKTREE/example.txt"
git -C "$WORKTREE" add example.txt
git -C "$WORKTREE" commit -qm "build two"
sha_two=$(git -C "$WORKTREE" rev-parse HEAD)
put_artifact "$session" build_manifest BUILD "$build_two_attempt" "$sha_one" "$sha_two" author - '[]' '{"commit":"two"}' >/dev/null
put_artifact "$session" self_review BUILD "$build_two_attempt" "$sha_two" "$sha_two" independent_review - '["constraint:no-review-mutation"]' '{"raised":0,"accepted":0,"applied":0,"chat":0}' >/dev/null
"$COORDINATE" complete "$session" BUILD "$build_two_attempt" >/dev/null
artifact_log="${events%.jsonl}.artifacts.jsonl"
status=$("$ARTIFACTS_CLI" replay "$artifact_log" "$events" | ruby -r json -e '
  id = ARGV.fetch(0)
  artifact = JSON.parse($stdin.read).fetch("artifacts").find { |item| item.fetch("artifact_id") == id }
  puts artifact.fetch("status")
' "$verify_one_id")
[ "$status" = invalidated ] || fail "old verification stayed current"
resume=$("$COORDINATE" resume-run "$events" --worktree "$WORKTREE" --offline)
printf '%s' "$resume" | ruby -r json -e '
  coverage = JSON.parse($stdin.read).dig("outcome_coverage", "clauses", "outcome:valid-next-work")
  abort unless coverage.fetch("state") == "uncovered"
' || fail "invalidated evidence still covered its outcome"
ok "BUILD invalidation returns outcome coverage to uncovered"

verify_two_start=$("$COORDINATE" start "$session" VERIFY --worktree "$WORKTREE")
verify_two_attempt=$(printf '%s' "$verify_two_start" | attempt_from)
put_artifact "$session" verification VERIFY "$verify_two_attempt" "$sha_two" "$sha_two" automated_check - '["outcome:valid-next-work"]' '{"failures":0}' >/dev/null
printf 'unauthorized reader edit\n' >> "$WORKTREE/example.txt"
assert_completion_rejected "changed HEAD, index, or worktree without BUILD authority" "$session" VERIFY "$verify_two_attempt"
"$COORDINATE" fail "$session" VERIFY "$verify_two_attempt" --reason "reader mutated the candidate" --failure-id failure:reader-mutation --revision spec-run-sha-two --findings 1 >/dev/null
tail_events=$(tail -3 "$events")
printf '%s' "$tail_events" | grep -Fq '"from":"VERIFY","to":"BUILD"' || fail "verify red edge is missing"
printf '%s' "$tail_events" | grep -Fq 'unauthorized worktree mutation detected' || fail "mutation violation was not recorded"
ok "detects reader mutation and records a red edge without granting write authority"

build_three_start=$("$COORDINATE" start "$session" BUILD --worktree "$WORKTREE")
build_three_attempt=$(printf '%s' "$build_three_start" | attempt_from)
git -C "$WORKTREE" add example.txt
git -C "$WORKTREE" commit -qm "build three"
sha_three=$(git -C "$WORKTREE" rev-parse HEAD)
put_artifact "$session" build_manifest BUILD "$build_three_attempt" "$sha_two" "$sha_three" author - '[]' '{"commit":"three"}' >/dev/null
put_artifact "$session" self_review BUILD "$build_three_attempt" "$sha_three" "$sha_three" independent_review - '["constraint:no-review-mutation"]' '{"raised":0,"accepted":0,"applied":0,"chat":0}' >/dev/null
"$COORDINATE" complete "$session" BUILD "$build_three_attempt" >/dev/null

verify_three_start=$("$COORDINATE" start "$session" VERIFY --worktree "$WORKTREE")
verify_three_attempt=$(printf '%s' "$verify_three_start" | attempt_from)
put_artifact "$session" verification VERIFY "$verify_three_attempt" "$sha_three" "$sha_three" automated_check - '["outcome:valid-next-work"]' "$(verify_content "$sha_three")" >/dev/null
"$COORDINATE" complete "$session" VERIFY "$verify_three_attempt" >/dev/null

active_state="${PR_GRAPH_STATE_ROOT}/active/${session}"
mv "$active_state" "${active_state}.detached"
resume=$("$COORDINATE" resume-run "$events" --worktree "$WORKTREE" --offline)
printf '%s' "$resume" | ruby -r json -e '
  value = JSON.parse($stdin.read)
  abort unless value.fetch("runnable").include?("PUBLISH")
  abort if value.fetch("runnable").include?("SELF-REVIEW")
  abort if value.fetch("blocked").key?("SELF-REVIEW")
  abort unless value.dig("git", "state") == "current"
  abort unless File.file?(value.fetch("active_state"))
' || fail "fresh-process resume did not preserve completed predecessors"
assert_rejected "SELF-REVIEW is retired" "$COORDINATE" start "$session" SELF-REVIEW --worktree "$WORKTREE"
OLD_WORKTREE="${TEST_ROOT}/old-candidate"
git -C "$WORKTREE" worktree add -q --detach "$OLD_WORKTREE" "$sha_one"
assert_rejected "resume worktree HEAD does not match current candidate" "$COORDINATE" resume-run "$events" --worktree "$OLD_WORKTREE" --offline
ok "reconstructs from the run file, unlocks PUBLISH on green VERIFY, and rejects a stale worktree SHA"

publish_start=$("$COORDINATE" start "$session" PUBLISH --worktree "$WORKTREE")
publish_attempt=$(printf '%s' "$publish_start" | attempt_from)
publish_three=$(publish_content "$sha_three")
put_artifact "$session" publish_manifest PUBLISH "$publish_attempt" "$sha_three" "$sha_three" external_service - '[]' "$publish_three" >/dev/null
assert_rejected "publish manifest PR number does not match completion" "$COORDINATE" finish "$session" PUBLISH "$publish_attempt" --pr 124 --candidate-sha "$sha_three"
"$COORDINATE" finish "$session" PUBLISH "$publish_attempt" --pr 123 --candidate-sha "$sha_three" >/dev/null

ci_start=$("$COORDINATE" start "$session" CI-WATCH --worktree "$WORKTREE")
ci_attempt=$(printf '%s' "$ci_start" | attempt_from)
bot_start=$("$COORDINATE" start "$session" BOT-FEEDBACK --worktree "$WORKTREE")
bot_attempt=$(printf '%s' "$bot_start" | attempt_from)
validate_start=$("$COORDINATE" start "$session" VALIDATE --worktree "$WORKTREE")
validate_attempt=$(printf '%s' "$validate_start" | attempt_from)
[ "$(printf '%s' "$ci_start" | authority_from)" = read ] || fail "CI did not receive read authority"
[ "$(printf '%s' "$bot_start" | authority_from)" = read ] || fail "bot did not receive read authority"
assert_rejected "open gate(s) have no armed wake source" "$COORDINATE" check "$session"
assert_rejected "writer contention with open lane(s)" "$COORDINATE" start "$session" BUILD --worktree "$WORKTREE"
ok "allows parallel readers, prevents a second writer, and detects lost wake sources"

ci_wake=$("$COORDINATE" wake "$session" CI-WATCH "$ci_attempt" ci registered | ruby -r json -e 'puts JSON.parse($stdin.read).fetch("wake_id")')
"$COORDINATE" wake "$session" CI-WATCH "$ci_attempt" ci armed --wake-id "$ci_wake" >/dev/null
"$COORDINATE" wake "$session" CI-WATCH "$ci_attempt" ci fired --wake-id "$ci_wake" >/dev/null
ci_three=$(ci_content "$sha_three" "$ci_wake" failed)
put_artifact "$session" ci_result CI-WATCH "$ci_attempt" "$sha_three" "$sha_three" external_service "$ci_wake" '["outcome:valid-next-work"]' "$ci_three" >/dev/null
"$COORDINATE" fail "$session" CI-WATCH "$ci_attempt" --reason "shared regression" --failure-id failure:shared --revision ci-build-1 --findings 1 >/dev/null

bot_wake=$("$COORDINATE" wake "$session" BOT-FEEDBACK "$bot_attempt" bot registered | ruby -r json -e 'puts JSON.parse($stdin.read).fetch("wake_id")')
"$COORDINATE" wake "$session" BOT-FEEDBACK "$bot_attempt" bot armed --wake-id "$bot_wake" >/dev/null
"$COORDINATE" wake "$session" BOT-FEEDBACK "$bot_attempt" bot fired --wake-id "$bot_wake" >/dev/null
assert_rejected "open gate(s) have no armed wake source: BOT-FEEDBACK" "$COORDINATE" check "$session"
bot_three=$(feedback_content "$sha_three" "$bot_wake" findings)
put_artifact "$session" bot_feedback BOT-FEEDBACK "$bot_attempt" "$sha_three" "$sha_three" external_service "$bot_wake" '["constraint:no-review-mutation"]' "$bot_three" >/dev/null
"$COORDINATE" fail "$session" BOT-FEEDBACK "$bot_attempt" --reason "same shared regression" --failure-id failure:shared --revision bot-comment-1 --findings 1 >/dev/null

desc_start=$("$COORDINATE" start "$session" DESC-SYNC --worktree "$WORKTREE")
desc_attempt=$(printf '%s' "$desc_start" | attempt_from)
put_artifact "$session" description DESC-SYNC "$desc_attempt" "$sha_three" "$sha_three" author - '[]' '{"synced":true}' >/dev/null
"$COORDINATE" complete "$session" DESC-SYNC "$desc_attempt" >/dev/null

put_artifact "$session" validation VALIDATE "$validate_attempt" "$sha_three" "$sha_three" automated_check - '["outcome:valid-next-work"]' '{"pass":false}' >/dev/null
"$COORDINATE" fail "$session" VALIDATE "$validate_attempt" --reason "replay contradicted the outcome" --failure-id failure:validation --revision replay-1 --findings 1 >/dev/null

build_four_start=$("$COORDINATE" start "$session" BUILD --worktree "$WORKTREE")
build_four_attempt=$(printf '%s' "$build_four_start" | attempt_from)
build_four_lease="${events%.jsonl}.coordinator/${build_four_attempt}.lease.json"
ruby -r json -e '
  batch = JSON.parse(File.read(ARGV.fetch(0))).fetch("failure_batch")
  failures = batch.fetch("failures").to_h { |failure| [failure.fetch("failure_id"), failure.fetch("occurrence_ids")] }
  abort unless failures.keys.sort == %w[failure:shared failure:validation]
  abort unless failures.fetch("failure:shared").length == 2
  abort unless failures.fetch("failure:validation").length == 1
' "$build_four_lease" || fail "concurrent failures were not deduplicated into one BUILD batch"
printf 'build four\n' >> "$WORKTREE/example.txt"
git -C "$WORKTREE" add example.txt
git -C "$WORKTREE" commit -qm "build four"
sha_four=$(git -C "$WORKTREE" rev-parse HEAD)
put_artifact "$session" build_manifest BUILD "$build_four_attempt" "$sha_three" "$sha_four" author - '[]' '{"commit":"four"}' >/dev/null
put_artifact "$session" self_review BUILD "$build_four_attempt" "$sha_four" "$sha_four" independent_review - '["constraint:no-review-mutation"]' '{"raised":0,"accepted":0,"applied":0,"chat":0}' >/dev/null
"$COORDINATE" complete "$session" BUILD "$build_four_attempt" >/dev/null

"$ARTIFACTS_CLI" replay "$artifact_log" "$events" | ruby -r json -e '
  artifacts = JSON.parse($stdin.read).fetch("artifacts")
  stale_sha = ARGV.fetch(0)
  %w[verification publish_manifest ci_result bot_feedback validation description].each do |family|
    stale = artifacts.select { |item| item.fetch("family") == family && item["candidate_sha"] == stale_sha }
    abort "missing stale #{family}" if stale.empty?
    abort "current stale #{family}" unless stale.all? { |item| item.fetch("status") == "invalidated" }
  end
  stale_review = artifacts.select { |item| item.fetch("family") == "self_review" && item["candidate_sha"] == stale_sha }
  abort "missing stale self_review" if stale_review.empty?
  abort "current stale self_review" unless stale_review.all? { |item| item.fetch("status") == "superseded" }
  %w[triage_brief investigation_report implementation_plan test_plan worktree_manifest].each do |family|
    current = artifacts.select { |item| item.fetch("family") == family && item.fetch("status") == "current" }
    abort "lost independent #{family}" unless current.one?
  end
' "$sha_three" || fail "candidate lineage invalidation was incomplete"
ok "derives candidate-sensitive invalidation while preserving SHA-independent artifacts"

verify_four_start=$("$COORDINATE" start "$session" VERIFY --worktree "$WORKTREE")
verify_four_attempt=$(printf '%s' "$verify_four_start" | attempt_from)
put_artifact "$session" verification VERIFY "$verify_four_attempt" "$sha_four" "$sha_four" automated_check - '["outcome:valid-next-work"]' "$(verify_content "$sha_four")" >/dev/null
"$COORDINATE" complete "$session" VERIFY "$verify_four_attempt" >/dev/null

publish_two_start=$("$COORDINATE" start "$session" PUBLISH --worktree "$WORKTREE")
publish_two_attempt=$(printf '%s' "$publish_two_start" | attempt_from)
publish_four=$(publish_content "$sha_four")
put_artifact "$session" publish_manifest PUBLISH "$publish_two_attempt" "$sha_four" "$sha_four" external_service - '[]' "$publish_four" >/dev/null
"$COORDINATE" finish "$session" PUBLISH "$publish_two_attempt" --pr 123 --candidate-sha "$sha_four" >/dev/null

export FAKE_PR_HEAD="$sha_four"
export FAKE_GH_FAIL=true
resume=$("$COORDINATE" resume-run "$events" --worktree "$WORKTREE")
printf '%s' "$resume" | ruby -r json -e 'value=JSON.parse($stdin.read); abort unless value.dig("external", "pr", "state") == "unavailable"' || fail "optional PR outage blocked or disappeared from resume"
resume=$("$COORDINATE" resume-run "$events" --worktree "$WORKTREE" --offline)
printf '%s' "$resume" | ruby -r json -e 'value=JSON.parse($stdin.read); abort unless value.dig("external", "pr", "state") == "not_refreshed"' || fail "offline resume did not remain local"
export FAKE_GH_FAIL=false
ok "keeps local resume available when optional external refresh is offline"

ci_two_start=$("$COORDINATE" start "$session" CI-WATCH --worktree "$WORKTREE")
ci_two_attempt=$(printf '%s' "$ci_two_start" | attempt_from)
ci_two_wake=$("$COORDINATE" wake "$session" CI-WATCH "$ci_two_attempt" ci registered | ruby -r json -e 'puts JSON.parse($stdin.read).fetch("wake_id")')
"$COORDINATE" wake "$session" CI-WATCH "$ci_two_attempt" ci armed --wake-id "$ci_two_wake" >/dev/null
"$COORDINATE" wake "$session" CI-WATCH "$ci_two_attempt" ci fired --wake-id "$ci_two_wake" >/dev/null
ci_four=$(ci_content "$sha_four" "$ci_two_wake" passed)
put_artifact "$session" ci_result CI-WATCH "$ci_two_attempt" "$sha_four" "$sha_four" external_service "$ci_two_wake" '["outcome:valid-next-work"]' "$ci_four" >/dev/null
"$COORDINATE" complete "$session" CI-WATCH "$ci_two_attempt" >/dev/null

bot_two_start=$("$COORDINATE" start "$session" BOT-FEEDBACK --worktree "$WORKTREE")
bot_two_attempt=$(printf '%s' "$bot_two_start" | attempt_from)
bot_two_wake=$("$COORDINATE" wake "$session" BOT-FEEDBACK "$bot_two_attempt" bot registered | ruby -r json -e 'puts JSON.parse($stdin.read).fetch("wake_id")')
"$COORDINATE" wake "$session" BOT-FEEDBACK "$bot_two_attempt" bot armed --wake-id "$bot_two_wake" >/dev/null
"$COORDINATE" wake "$session" BOT-FEEDBACK "$bot_two_attempt" bot fired --wake-id "$bot_two_wake" >/dev/null
bot_four=$(feedback_content "$sha_four" "$bot_two_wake" clean)
put_artifact "$session" bot_feedback BOT-FEEDBACK "$bot_two_attempt" "$sha_four" "$sha_four" external_service "$bot_two_wake" '["constraint:no-review-mutation"]' "$bot_four" >/dev/null
"$COORDINATE" complete "$session" BOT-FEEDBACK "$bot_two_attempt" >/dev/null

validate_two_start=$("$COORDINATE" start "$session" VALIDATE --worktree "$WORKTREE")
validate_two_attempt=$(printf '%s' "$validate_two_start" | attempt_from)
put_artifact "$session" validation VALIDATE "$validate_two_attempt" "$sha_four" "$sha_four" automated_check - '["outcome:valid-next-work"]' '{"pass":true}' >/dev/null
"$COORDINATE" complete "$session" VALIDATE "$validate_two_attempt" >/dev/null

desc_two_start=$("$COORDINATE" start "$session" DESC-SYNC --worktree "$WORKTREE")
desc_two_attempt=$(printf '%s' "$desc_two_start" | attempt_from)
put_artifact "$session" description DESC-SYNC "$desc_two_attempt" "$sha_four" "$sha_four" author - '[]' '{"synced":true}' >/dev/null
"$COORDINATE" complete "$session" DESC-SYNC "$desc_two_attempt" >/dev/null

export FAKE_PR_ID="different-pr-node"
assert_rejected "live PR identity changed: pull request id" "$COORDINATE" start "$session" DONE --worktree "$WORKTREE"
export FAKE_PR_ID="pr-node-123"
export FAKE_CI_ID=2
assert_rejected "live CI identity changed: authoritative_run_ids" "$COORDINATE" start "$session" DONE --worktree "$WORKTREE"
export FAKE_CI_ID=1
export FAKE_CI_STATE=empty
assert_rejected "live CI is pending, not passed" "$COORDINATE" start "$session" DONE --worktree "$WORKTREE"
export FAKE_CI_STATE=passed
export FAKE_FEEDBACK_STATE=automated
assert_rejected "live automated feedback is pending, not clean" "$COORDINATE" start "$session" DONE --worktree "$WORKTREE"
assert_rejected "BOT-FEEDBACK is already current" "$COORDINATE" start "$session" BOT-FEEDBACK --worktree "$WORKTREE"
bot_refresh_start=$("$COORDINATE" start "$session" BOT-FEEDBACK --worktree "$WORKTREE" --refresh)
bot_refresh_attempt=$(printf '%s' "$bot_refresh_start" | attempt_from)
bot_refresh_wake=$("$COORDINATE" wake "$session" BOT-FEEDBACK "$bot_refresh_attempt" bot registered | ruby -r json -e 'puts JSON.parse($stdin.read).fetch("wake_id")')
"$COORDINATE" wake "$session" BOT-FEEDBACK "$bot_refresh_attempt" bot armed --wake-id "$bot_refresh_wake" >/dev/null
"$COORDINATE" wake "$session" BOT-FEEDBACK "$bot_refresh_attempt" bot fired --wake-id "$bot_refresh_wake" >/dev/null
export FAKE_FEEDBACK_STATE=clean
bot_refresh=$(feedback_content "$sha_four" "$bot_refresh_wake" clean)
put_artifact "$session" bot_feedback BOT-FEEDBACK "$bot_refresh_attempt" "$sha_four" "$sha_four" external_service "$bot_refresh_wake" '["constraint:no-review-mutation"]' "$bot_refresh" >/dev/null
"$COORDINATE" complete "$session" BOT-FEEDBACK "$bot_refresh_attempt" >/dev/null
export FAKE_FEEDBACK_STATE=unknown
assert_rejected "live automated feedback is blocked, not clean" "$COORDINATE" start "$session" DONE --worktree "$WORKTREE"
export FAKE_FEEDBACK_STATE=clean
export FAKE_FEEDBACK_FAIL=true
assert_rejected "GitHub denied the feedback request" "$COORDINATE" start "$session" DONE --worktree "$WORKTREE"
export FAKE_FEEDBACK_FAIL=false
done_start=$("$COORDINATE" start "$session" DONE --worktree "$WORKTREE")
done_attempt=$(printf '%s' "$done_start" | attempt_from)
put_artifact "$session" done_manifest DONE "$done_attempt" "$sha_four" "$sha_four" operator - '[]' '{"gates":"green"}' >/dev/null
disposition="${TEST_ROOT}/disposition.json"
printf '%s\n' '{"clauses":[{"outcome_id":"outcome:valid-next-work","status":"covered"},{"outcome_id":"constraint:no-review-mutation","status":"covered"}]}' > "$disposition"
incomplete_disposition="${TEST_ROOT}/incomplete-disposition.json"
printf '%s\n' '{"clauses":[{"outcome_id":"outcome:valid-next-work","status":"covered"}]}' > "$incomplete_disposition"
assert_rejected "terminal disposition leaves outcome clause(s) undeclared: constraint:no-review-mutation" "$COORDINATE" finish "$session" DONE "$done_attempt" --disposition "$incomplete_disposition"
# A PR a person marked ready still closes DONE; the run never flips it back to draft.
export FAKE_PR_DRAFT=false
"$COORDINATE" finish "$session" DONE "$done_attempt" --disposition "$disposition" >/dev/null
export FAKE_PR_DRAFT=true
"$EVENTS_CLI" validate "$events" >/dev/null
resume=$("$COORDINATE" resume-run "$events" --worktree "$WORKTREE" --offline)
printf '%s' "$resume" | ruby -r json -e '
  value = JSON.parse($stdin.read)
  abort unless value.fetch("terminal")
  coverage = value.fetch("outcome_coverage")
  abort unless coverage.fetch("conflicts").empty?
  abort unless coverage.fetch("uncovered").empty?
  abort unless coverage.fetch("clauses").values.all? { |item| item.fetch("state") == "covered" }
' || fail "terminal outcome disposition did not survive replay"
ok "checks the live draft PR and complete outcome disposition at DONE"

persistence_session="42222222-2222-4222-8222-222222222222"
persistence_events=$("$CURRENT" init DEMO-764 "$persistence_session")
emit "$persistence_session" '{"e":"run_start","ticket":"DEMO-764","entry":"ticket"}'
runs_dir=$(dirname "$persistence_events")
chmod 500 "$runs_dir"
set +e
output=$("$COORDINATE" start "$persistence_session" TRIAGE 2>&1)
persistence_status=$?
set -e
chmod 700 "$runs_dir"
[ "$persistence_status" -ne 0 ] || fail "unwritable coordinator storage allowed node start"
[ "$(wc -l < "$persistence_events" | tr -d ' ')" = 1 ] || fail "node start was appended after persistence failure"
printf '%s' "$output" | grep -Fq "Permission denied" || fail "persistence error was hidden"
ok "prevents node start when coordinator state cannot be persisted"

echo "1..${tests}"
