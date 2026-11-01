#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT="${SCRIPT_DIR}/../scripts/current.sh"
EVENTS_CLI="${SCRIPT_DIR}/../scripts/events.rb"
ARTIFACTS_CLI="${SCRIPT_DIR}/../scripts/artifacts.rb"
FAILURES_CLI="${SCRIPT_DIR}/../scripts/failures.rb"
COORDINATE="${SCRIPT_DIR}/../scripts/coordinate.rb"
SCRIPTS="${SCRIPT_DIR}/../scripts"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

export PR_GRAPH_STATE_ROOT="${TEST_ROOT}/state"
export PR_GRAPH_ALLOW_RAW_EVENTS=1

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

record() {
  ruby -I "$SCRIPTS" -r failure_log -r json -e '
    PrGraph::FailureLog.new.record(
      ARGV.fetch(0),
      execution_path: ARGV.fetch(1),
      run_id: ARGV.fetch(2),
      session: ARGV.fetch(3),
      finding: JSON.parse(ARGV.fetch(4))
    )
  ' "$failures" "$events" "$run_id" "$session" "$1"
}

session="51111111-1111-4111-8111-111111111111"
events=$("$CURRENT" init DEMO-765 "$session")
failures="${events%.jsonl}.failures.jsonl"
run_id=$(sed -n 's/^run_id=//p' "${PR_GRAPH_STATE_ROOT}/active/${session}")
verify_attempt="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
self_attempt="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
sha="1111111111111111111111111111111111111111"

emit "$session" '{"e":"run_start","ticket":"DEMO-765","entry":"ticket"}'
emit "$session" "{\"e\":\"node\",\"node\":\"VERIFY\",\"phase\":\"start\",\"attempt_id\":\"${verify_attempt}\",\"iteration\":1}"
emit "$session" "{\"e\":\"node\",\"node\":\"SELF-REVIEW\",\"phase\":\"start\",\"attempt_id\":\"${self_attempt}\",\"iteration\":1}"
verify_metadata="{\"family\":\"verification\",\"node\":\"VERIFY\",\"attempt_id\":\"${verify_attempt}\",\"producer\":\"failure-test\",\"input_sha\":\"${sha}\",\"candidate_sha\":\"${sha}\",\"content_type\":\"application/json\",\"wake_id\":null,\"perspective\":\"automated_check\",\"covered_outcomes\":[\"outcome:test\"]}"
self_metadata="{\"family\":\"self_review\",\"node\":\"SELF-REVIEW\",\"attempt_id\":\"${self_attempt}\",\"producer\":\"failure-test\",\"input_sha\":\"${sha}\",\"candidate_sha\":\"${sha}\",\"content_type\":\"application/json\",\"wake_id\":null,\"perspective\":\"independent_review\",\"covered_outcomes\":[\"outcome:test\"]}"
artifact_one=$(printf '{"failed":true}' | "$ARTIFACTS_CLI" put "$session" "$verify_metadata" - | ruby -r json -e 'puts JSON.parse($stdin.read).fetch("artifact_id")')
artifact_two=$(printf '{"failed":true}' | "$ARTIFACTS_CLI" put "$session" "$self_metadata" - | ruby -r json -e 'puts JSON.parse($stdin.read).fetch("artifact_id")')

verify_finding="{\"failure_id\":\"failure:shared\",\"source_node\":\"VERIFY\",\"source_attempt_id\":\"${verify_attempt}\",\"candidate_sha\":\"${sha}\",\"revision\":\"spec-run-1\",\"reason\":\"shared regression\",\"artifact_ids\":[\"${artifact_one}\"]}"
record "$verify_finding" &
record "$verify_finding" &
wait
[ "$(wc -l < "$failures" | tr -d ' ')" = 1 ] || fail "concurrent duplicate failure revisions were appended twice"
ok "serializes concurrent queue writes and deduplicates an immutable source revision"

before=$(wc -c < "$failures" | tr -d ' ')
conflict="{\"failure_id\":\"failure:shared\",\"source_node\":\"VERIFY\",\"source_attempt_id\":\"${verify_attempt}\",\"candidate_sha\":\"${sha}\",\"revision\":\"spec-run-1\",\"reason\":\"conflicting reason\",\"artifact_ids\":[\"${artifact_one}\"]}"
if output=$(record "$conflict" 2>&1); then
  fail "conflicting duplicate revision was accepted"
fi
[ "$before" = "$(wc -c < "$failures" | tr -d ' ')" ] || fail "conflicting duplicate mutated the queue"
printf '%s' "$output" | grep -Fq "conflicts with persisted finding" || fail "duplicate conflict was hidden"
ok "rejects a conflicting duplicate without mutating the journal"

self_finding="{\"failure_id\":\"failure:shared\",\"source_node\":\"SELF-REVIEW\",\"source_attempt_id\":\"${self_attempt}\",\"candidate_sha\":\"${sha}\",\"revision\":\"review-1\",\"reason\":\"same regression\",\"artifact_ids\":[\"${artifact_two}\"]}"
record "$self_finding" >/dev/null
[ "$(wc -l < "$failures" | tr -d ' ')" = 2 ] || fail "distinct source occurrence was lost"
ok "preserves source and revision identity for concurrent reports of one failure"

ruby -I "$SCRIPTS" -r failure_log -e '
  log = PrGraph::FailureLog.new
  sha = "1" * 40
  pending = [
    {"failure_id" => "failure:shared", "occurrence_id" => "1" * 8 + "-1111-4111-8111-111111111111", "candidate_sha" => sha, "revision" => "one"},
    {"failure_id" => "failure:shared", "occurrence_id" => "2" * 8 + "-2222-4222-8222-222222222222", "candidate_sha" => sha, "revision" => "two"},
    {"failure_id" => "failure:other", "occurrence_id" => "3" * 8 + "-3333-4333-8333-333333333333", "candidate_sha" => sha, "revision" => "three"}
  ]
  batch = log.build_batch(pending: pending, candidate_sha: sha, batch_id: "4" * 8 + "-4444-4444-8444-444444444444")
  groups = batch.fetch("failures").to_h { |failure| [failure.fetch("failure_id"), failure.fetch("occurrence_ids")] }
  abort unless groups.keys.sort == %w[failure:other failure:shared]
  abort unless groups.fetch("failure:shared").length == 2
'
ok "coalesces pending occurrences into one batch per stable failure identity"

ruby -I "$SCRIPTS" -r failure_log -e '
  log = PrGraph::FailureLog.new
  batches = 3.times.map do |index|
    {
      "batch_id" => format("%08d-1111-4111-8111-111111111111", index + 1),
      "done_seq" => index + 1,
      "failures" => [{"failure_id" => "failure:recurring", "occurrence_ids" => []}]
    }
  end
  history = log.stop_history(processed_batches: batches, failure_id: "failure:recurring")
  abort unless history.fetch("batch_ids") == batches.map { |batch| batch.fetch("batch_id") }
  reset = batches + [{"batch_id" => "99999999-9999-4999-8999-999999999999", "done_seq" => 4, "failures" => [{"failure_id" => "failure:other", "occurrence_ids" => []}]}]
  abort unless log.stop_history(processed_batches: reset, failure_id: "failure:recurring").nil?
'
ok "stops after three consecutive cycles and resets recurrence after an unrelated batch"

batch_ids='["11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222","33333333-3333-4333-8333-333333333333"]'
third_finding="{\"failure_id\":\"failure:recurring\",\"source_node\":\"VERIFY\",\"source_attempt_id\":\"${verify_attempt}\",\"candidate_sha\":\"${sha}\",\"revision\":\"spec-run-2\",\"reason\":\"recurred after three builds\",\"artifact_ids\":[\"${artifact_one}\"]}"
record "$third_finding" >/dev/null
ruby -I "$SCRIPTS" -r failure_log -r json -e '
  result = PrGraph::FailureLog.new.record(
    ARGV.fetch(0),
    execution_path: ARGV.fetch(1),
    run_id: ARGV.fetch(2),
    session: ARGV.fetch(3),
    finding: JSON.parse(ARGV.fetch(4)),
    stop_history: {"batch_ids" => JSON.parse(ARGV.fetch(5))}
  )
  abort unless result.fetch("deduplicated") && result.fetch("stop")
' "$failures" "$events" "$run_id" "$session" "$third_finding" "$batch_ids"
replay=$("$FAILURES_CLI" replay "$failures" "$events")
printf '%s' "$replay" | ruby -r json -e 'value=JSON.parse($stdin.read); abort unless value.fetch("stopped") && value.fetch("stops").one?' || fail "durable stop was not replayed"
ok "repairs a missing recurrence stop during an idempotent finding retry"

if output=$("$COORDINATE" start "$session" TRIAGE 2>&1); then
  fail "coordinator authorized work after a recurrence stop"
fi
printf '%s' "$output" | grep -Fq "run stopped by recurring failure(s): failure:recurring" || fail "coordinator stop diagnostic was hidden"
resume=$("$COORDINATE" resume "$session")
printf '%s' "$resume" | ruby -r json -e 'value=JSON.parse($stdin.read); abort unless value.dig("failure_queue", "stopped")' || fail "resume lost durable stop state"
ok "prevents further node starts and preserves stopped state across resume"

readonly_dir="${TEST_ROOT}/readonly"
readonly_failures="${readonly_dir}/queue.failures.jsonl"
mkdir -p "$readonly_dir"
chmod 500 "$readonly_dir"
set +e
output=$(ruby -I "$SCRIPTS" -r failure_log -r json -e '
  PrGraph::FailureLog.new.record(
    ARGV.fetch(0),
    execution_path: ARGV.fetch(1),
    run_id: ARGV.fetch(2),
    session: ARGV.fetch(3),
    finding: JSON.parse(ARGV.fetch(4))
  )
' "$readonly_failures" "$events" "$run_id" "$session" "$verify_finding" 2>&1)
readonly_status=$?
set -e
chmod 700 "$readonly_dir"
[ "$readonly_status" -ne 0 ] || fail "unwritable queue accepted a finding"
[ ! -e "$readonly_failures" ] || fail "unwritable queue left a partial journal"
printf '%s' "$output" | grep -Fq "Permission denied" || fail "queue persistence failure was hidden"
ok "fails closed without a memory-only queue when persistence is unavailable"

missing="${TEST_ROOT}/absent.failures.jsonl"
offline=$("$FAILURES_CLI" replay "$missing" "$events")
printf '%s' "$offline" | ruby -r json -e 'value=JSON.parse($stdin.read); abort unless value.fetch("findings").empty? && !value.fetch("stopped")' || fail "absent local queue did not replay empty"
ok "replays an absent queue locally without an optional service"

echo "1..${tests}"
