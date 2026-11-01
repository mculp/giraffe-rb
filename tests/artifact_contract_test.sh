#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT="${SCRIPT_DIR}/../scripts/current.sh"
EVENTS_CLI="${SCRIPT_DIR}/../scripts/events.rb"
ARTIFACTS_CLI="${SCRIPT_DIR}/../scripts/artifacts.rb"
CONTRACT="${SCRIPT_DIR}/../references/artifact-contract-v1.json"
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

artifact_log_for() {
  printf '%s\n' "${1%.jsonl}.artifacts.jsonl"
}

blob_dir_for() {
  printf '%s\n' "${1%.artifacts.jsonl}.artifacts"
}

artifact_id_from() {
  ruby -r json -e 'puts JSON.parse(ARGV.fetch(0)).fetch("artifact_id")' "$1"
}

put_artifact() {
  local session="$1"
  local metadata="$2"
  local content="$3"

  printf '%s' "$content" | "$ARTIFACTS_CLI" put "$session" "$metadata" -
}

assert_put_rejected() {
  local session="$1"
  local artifacts="$2"
  local metadata="$3"
  local expected="$4"
  local before_lines=0
  local before_blobs=0

  [ ! -f "$artifacts" ] || before_lines=$(wc -l < "$artifacts" | tr -d ' ')
  blob_dir=$(blob_dir_for "$artifacts")
  [ ! -d "$blob_dir" ] || before_blobs=$(find "$blob_dir" -type f | wc -l | tr -d ' ')
  if output=$(printf 'rejected content' | "$ARTIFACTS_CLI" put "$session" "$metadata" - 2>&1); then
    fail "$expected"
  fi
  after_lines=0
  after_blobs=0
  [ ! -f "$artifacts" ] || after_lines=$(wc -l < "$artifacts" | tr -d ' ')
  [ ! -d "$blob_dir" ] || after_blobs=$(find "$blob_dir" -type f | wc -l | tr -d ' ')
  [ "$before_lines" = "$after_lines" ] || fail "$expected appended an event"
  [ "$before_blobs" = "$after_blobs" ] || fail "$expected left an orphan blob"
  printf '%s' "$output" | grep -q "$expected" || fail "$expected error was not reported"
}

ruby -r json -e '
  contract = JSON.parse(File.read(ARGV.fetch(0)))
  abort unless contract.fetch("artifact_contract_version") == 1
  abort unless contract.fetch("execution_contract_version") == 1
  families = contract.fetch("families")
  abort unless %w[investigation_report implementation_plan test_plan build_manifest verification self_review ci_result bot_feedback browser_review].all? { |name| families.key?(name) }
  abort unless families.fetch("verification").fetch("quality")
  abort unless families.fetch("ci_result").fetch("wake_required")
' "$CONTRACT"
ok "defines versioned artifact families and quality policy"

session="31111111-1111-4111-8111-111111111111"
events=$("$CURRENT" init DEMO-761 "$session")
artifacts=$(artifact_log_for "$events")
run_id=$(sed -n 's/^run_id=//p' "${PR_GRAPH_STATE_ROOT}/active/${session}")
sha_a="1111111111111111111111111111111111111111"
sha_b="2222222222222222222222222222222222222222"
plan_attempt="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
plan_attempt_two="abababab-abab-4bab-8bab-abababababab"
verify_attempt="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
build_attempt="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
ci_attempt="dddddddd-dddd-4ddd-8ddd-dddddddddddd"
wake_id="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"

emit "$session" '{"e":"run_start","ticket":"DEMO-761","entry":"ticket"}'
if output=$("$ARTIFACTS_CLI" link "$session" supersedes "$plan_attempt" "$verify_attempt" "raw link" 2>&1); then
  fail "raw artifact lifecycle link was accepted"
fi
printf '%s' "$output" | grep -q "artifact lifecycle links are protected" || fail "raw-link rejection was hidden"
ok "routes artifact lifecycle links through the deterministic coordinator"
export PR_GRAPH_ALLOW_RAW_ARTIFACT_LINKS=1
emit "$session" "{\"e\":\"node\",\"node\":\"PLAN\",\"phase\":\"start\",\"attempt_id\":\"${plan_attempt}\",\"iteration\":1}"
emit "$session" "{\"e\":\"node\",\"node\":\"PLAN\",\"phase\":\"start\",\"attempt_id\":\"${plan_attempt_two}\",\"iteration\":2}"
emit "$session" "{\"e\":\"node\",\"node\":\"VERIFY\",\"phase\":\"start\",\"attempt_id\":\"${verify_attempt}\",\"iteration\":1}"
emit "$session" "{\"e\":\"node\",\"node\":\"BUILD\",\"phase\":\"start\",\"attempt_id\":\"${build_attempt}\",\"iteration\":2}"
emit "$session" "{\"e\":\"node\",\"node\":\"CI-WATCH\",\"phase\":\"start\",\"attempt_id\":\"${ci_attempt}\",\"iteration\":1}"
emit "$session" "{\"e\":\"wake\",\"node\":\"CI-WATCH\",\"attempt_id\":\"${ci_attempt}\",\"wake_id\":\"${wake_id}\",\"kind\":\"ci\",\"state\":\"registered\"}"
emit "$session" "{\"e\":\"wake\",\"node\":\"CI-WATCH\",\"attempt_id\":\"${ci_attempt}\",\"wake_id\":\"${wake_id}\",\"kind\":\"ci\",\"state\":\"armed\"}"

closed_attempt="12121212-1212-4212-8212-121212121212"
emit "$session" "{\"e\":\"node\",\"node\":\"INVESTIGATE\",\"phase\":\"start\",\"attempt_id\":\"${closed_attempt}\",\"iteration\":1}"
emit "$session" "{\"e\":\"node\",\"node\":\"INVESTIGATE\",\"phase\":\"done\",\"attempt_id\":\"${closed_attempt}\",\"iteration\":1}"
closed_metadata="{\"family\":\"investigation_report\",\"node\":\"INVESTIGATE\",\"attempt_id\":\"${closed_attempt}\",\"producer\":\"pg-INVESTIGATE\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":null,\"content_type\":\"text/markdown\",\"wake_id\":null,\"perspective\":\"author\",\"covered_outcomes\":[]}"
assert_put_rejected "$session" "$artifacts" "$closed_metadata" "attempt ${closed_attempt} is already closed"
ok "rejects late output after a node attempt closes"

plan_metadata="{\"family\":\"implementation_plan\",\"node\":\"PLAN\",\"attempt_id\":\"${plan_attempt}\",\"producer\":\"pg-PLAN-architect\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":null,\"content_type\":\"text/markdown\",\"wake_id\":null,\"perspective\":\"author\",\"covered_outcomes\":[]}"
plan_event=$(put_artifact "$session" "$plan_metadata" "Plan version one")
plan_one=$(artifact_id_from "$plan_event")
blob_dir=$(blob_dir_for "$artifacts")
blob="${blob_dir}/${plan_one}.blob"
[ -f "$blob" ] || fail "artifact blob is missing"
[ "$(cat "$blob")" = "Plan version one" ] || fail "artifact content changed"
expected_checksum=$(printf 'Plan version one' | ruby -rdigest -e 'print Digest::SHA256.hexdigest($stdin.read)')
actual_checksum=$(ruby -r json -e 'puts JSON.parse(ARGV.fetch(0)).fetch("content_sha256")' "$plan_event")
[ "$expected_checksum" = "$actual_checksum" ] || fail "artifact checksum is wrong"
"$ARTIFACTS_CLI" validate "$artifacts" "$events" >/dev/null
ok "stores immutable content with run, attempt, SHA, producer, and checksum identity"

missing_sha="{\"family\":\"implementation_plan\",\"node\":\"PLAN\",\"attempt_id\":\"${plan_attempt}\",\"producer\":\"pg-PLAN\",\"candidate_sha\":null,\"content_type\":\"text/markdown\",\"wake_id\":null,\"perspective\":\"author\",\"covered_outcomes\":[]}"
assert_put_rejected "$session" "$artifacts" "$missing_sha" "missing required field(s): input_sha"
ok "rejects a missing input SHA without an event or orphan blob"

unknown_attempt="ffffffff-ffff-4fff-8fff-ffffffffffff"
wrong_attempt="{\"family\":\"implementation_plan\",\"node\":\"PLAN\",\"attempt_id\":\"${unknown_attempt}\",\"producer\":\"pg-PLAN\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":null,\"content_type\":\"text/markdown\",\"wake_id\":null,\"perspective\":\"author\",\"covered_outcomes\":[]}"
assert_put_rejected "$session" "$artifacts" "$wrong_attempt" "references unknown attempt"
ok "rejects an unknown attempt identity without mutation"

quality_without_candidate="{\"family\":\"verification\",\"node\":\"VERIFY\",\"attempt_id\":\"${verify_attempt}\",\"producer\":\"rspec\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":null,\"content_type\":\"application/json\",\"wake_id\":null,\"perspective\":\"automated_check\",\"covered_outcomes\":[\"criterion:one\"]}"
assert_put_rejected "$session" "$artifacts" "$quality_without_candidate" "requires candidate_sha"
ok "rejects quality evidence without a candidate SHA"

quality_without_coverage="{\"family\":\"verification\",\"node\":\"VERIFY\",\"attempt_id\":\"${verify_attempt}\",\"producer\":\"rspec\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":\"${sha_a}\",\"content_type\":\"application/json\",\"wake_id\":null,\"perspective\":\"automated_check\",\"covered_outcomes\":[]}"
assert_put_rejected "$session" "$artifacts" "$quality_without_coverage" "requires at least one covered outcome"
ok "rejects quality evidence that covers no outcome"

quality_wrong_lineage="{\"family\":\"verification\",\"node\":\"VERIFY\",\"attempt_id\":\"${verify_attempt}\",\"producer\":\"rspec\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":\"${sha_b}\",\"content_type\":\"application/json\",\"wake_id\":null,\"perspective\":\"automated_check\",\"covered_outcomes\":[\"criterion:one\"]}"
assert_put_rejected "$session" "$artifacts" "$quality_wrong_lineage" "candidate_sha must match input_sha"
ok "rejects quality evidence with conflicting SHA lineage"

verify_metadata="{\"family\":\"verification\",\"node\":\"VERIFY\",\"attempt_id\":\"${verify_attempt}\",\"producer\":\"rspec\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":\"${sha_a}\",\"content_type\":\"application/json\",\"wake_id\":null,\"perspective\":\"automated_check\",\"covered_outcomes\":[\"criterion:one\"]}"
verify_event=$(put_artifact "$session" "$verify_metadata" '{"examples":12,"failures":0}')
verify_id=$(artifact_id_from "$verify_event")
coverage=$("$ARTIFACTS_CLI" replay "$artifacts" "$events" '["criterion:one","criterion:two"]')
printf '%s' "$coverage" | ruby -r json -e '
  coverage = JSON.parse($stdin.read).fetch("coverage")
  abort unless coverage.fetch("covered") == ["criterion:one"]
  abort unless coverage.fetch("uncovered") == ["criterion:two"]
' || fail "coverage projection is wrong"
ok "reports criteria without current evidence as explicitly uncovered"

ci_without_wake="{\"family\":\"ci_result\",\"node\":\"CI-WATCH\",\"attempt_id\":\"${ci_attempt}\",\"producer\":\"buildkite\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":\"${sha_a}\",\"content_type\":\"application/json\",\"wake_id\":null,\"perspective\":\"external_service\",\"covered_outcomes\":[\"quality:ci\"]}"
assert_put_rejected "$session" "$artifacts" "$ci_without_wake" "requires a wake source"
ok "requires watcher evidence to identify its wake source"

ci_metadata="{\"family\":\"ci_result\",\"node\":\"CI-WATCH\",\"attempt_id\":\"${ci_attempt}\",\"producer\":\"buildkite\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":\"${sha_a}\",\"content_type\":\"application/json\",\"wake_id\":\"${wake_id}\",\"perspective\":\"external_service\",\"covered_outcomes\":[\"quality:ci\"]}"
assert_put_rejected "$session" "$artifacts" "$ci_metadata" "wake source has not fired"
emit "$session" "{\"e\":\"wake\",\"node\":\"CI-WATCH\",\"attempt_id\":\"${ci_attempt}\",\"wake_id\":\"${wake_id}\",\"kind\":\"ci\",\"state\":\"fired\"}"
put_artifact "$session" "$ci_metadata" '{"state":"passed"}' >/dev/null
"$ARTIFACTS_CLI" validate "$artifacts" "$events" >/dev/null
ok "binds watcher evidence to a fired wake and known attempt"

plan_two_metadata="{\"family\":\"implementation_plan\",\"node\":\"PLAN\",\"attempt_id\":\"${plan_attempt_two}\",\"producer\":\"pg-PLAN-architect\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":null,\"content_type\":\"text/markdown\",\"wake_id\":null,\"perspective\":\"author\",\"covered_outcomes\":[]}"
plan_two_event=$(put_artifact "$session" "$plan_two_metadata" "Plan version two")
plan_two=$(artifact_id_from "$plan_two_event")
"$ARTIFACTS_CLI" link "$session" supersedes "$plan_two" "$plan_one" "new PLAN attempt output" >/dev/null
projection=$("$ARTIFACTS_CLI" replay "$artifacts" "$events")
printf '%s' "$projection" | ruby -r json -e '
  projection = JSON.parse($stdin.read)
  statuses = projection.fetch("artifacts").to_h { |artifact| [artifact.fetch("artifact_id"), artifact.fetch("status")] }
  abort unless statuses.fetch(ARGV.fetch(0)) == "superseded"
  abort unless statuses.fetch(ARGV.fetch(1)) == "current"
' "$plan_one" "$plan_two" || fail "supersession projection is wrong"
[ -f "${blob_dir}/${plan_one}.blob" ] || fail "superseded content was deleted"
ok "keeps prior content and records immutable supersession"

before=$(wc -l < "$artifacts" | tr -d ' ')
if output=$("$ARTIFACTS_CLI" link "$session" invalidates "$plan_two" "$plan_one" "conflicting status" 2>&1); then
  fail "conflicting artifact status was accepted"
fi
[ "$before" = "$(wc -l < "$artifacts" | tr -d ' ')" ] || fail "conflicting link mutated the log"
printf '%s' "$output" | grep -q "already superseded" || fail "conflicting link error was hidden"
ok "rejects conflicting artifact status links before append"

build_metadata="{\"family\":\"build_manifest\",\"node\":\"BUILD\",\"attempt_id\":\"${build_attempt}\",\"producer\":\"pg-BUILD\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":\"${sha_b}\",\"content_type\":\"application/json\",\"wake_id\":null,\"perspective\":\"author\",\"covered_outcomes\":[]}"
build_event=$(put_artifact "$session" "$build_metadata" '{"changed":["app/model.rb"]}')
build_id=$(artifact_id_from "$build_event")
"$ARTIFACTS_CLI" link "$session" invalidates "$build_id" "$verify_id" "BUILD changed candidate SHA" >/dev/null
coverage=$("$ARTIFACTS_CLI" replay "$artifacts" "$events" '["criterion:one"]')
printf '%s' "$coverage" | ruby -r json -e '
  coverage = JSON.parse($stdin.read).fetch("coverage")
  abort unless coverage.fetch("covered").empty?
  abort unless coverage.fetch("uncovered") == ["criterion:one"]
' || fail "invalidated evidence still authorized coverage"
ok "invalidated quality evidence no longer covers an outcome"

tamper_dir="${TEST_ROOT}/tamper"
mkdir -p "$tamper_dir"
artifact_filename=$(basename "$artifacts")
blob_dirname=$(basename "$blob_dir")
cp "$artifacts" "$tamper_dir/$artifact_filename"
cp -R "$blob_dir" "$tamper_dir/$blob_dirname"
printf 'tamper' >> "$tamper_dir/$blob_dirname/${plan_two}.blob"
if output=$("$ARTIFACTS_CLI" validate "$tamper_dir/$artifact_filename" "$events" 2>&1); then
  fail "tampered content was accepted"
fi
printf '%s' "$output" | grep -q "content size does not match\|checksum does not match" || fail "tamper error was hidden"
ok "rejects corrupt content during replay"

torn="${TEST_ROOT}/torn.artifacts.jsonl"
printf '%s' '{"v":1' > "$torn"
before=$(wc -c < "$torn" | tr -d ' ')
if output=$(ruby -I "${SCRIPT_DIR}/../scripts" -r artifact_log -e 'PrGraph::ArtifactLog.new.validate_file!(ARGV.fetch(0), execution_path: ARGV.fetch(1))' "$torn" "$events" 2>&1); then
  fail "torn artifact log was accepted"
fi
[ "$before" = "$(wc -c < "$torn" | tr -d ' ')" ] || fail "torn artifact log was modified"
printf '%s' "$output" | grep -q "torn final artifact event" || fail "torn artifact error was hidden"
ok "rejects a torn artifact log without mutation"

unknown_version="${TEST_ROOT}/unknown-version.artifacts.jsonl"
printf '%s' "$plan_event" | ruby -r json -e '
  event = JSON.parse($stdin.read)
  event["v"] = 2
  event["seq"] = 1
  puts JSON.generate(event)
' > "$unknown_version"
unknown_blob_dir=$(blob_dir_for "$unknown_version")
mkdir -p "$unknown_blob_dir"
cp "$blob" "$unknown_blob_dir/${plan_one}.blob"
if output=$("$ARTIFACTS_CLI" validate "$unknown_version" "$events" 2>&1); then
  fail "unknown artifact version was accepted"
fi
printf '%s' "$output" | grep -q "v must equal 1" || fail "unknown artifact version error was hidden"
ok "rejects an unsupported artifact contract version"

unwritable_session="33333333-3333-4333-8333-333333333333"
unwritable_events=$("$CURRENT" init DEMO-761 "$unwritable_session")
unwritable_attempt="88888888-8888-4888-8888-888888888888"
emit "$unwritable_session" '{"e":"run_start","ticket":"DEMO-761","entry":"ticket"}'
emit "$unwritable_session" "{\"e\":\"node\",\"node\":\"PLAN\",\"phase\":\"start\",\"attempt_id\":\"${unwritable_attempt}\",\"iteration\":1}"
unwritable_metadata="{\"family\":\"implementation_plan\",\"node\":\"PLAN\",\"attempt_id\":\"${unwritable_attempt}\",\"producer\":\"pg-PLAN\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":null,\"content_type\":\"text/markdown\",\"wake_id\":null,\"perspective\":\"author\",\"covered_outcomes\":[]}"
unwritable_runs=$(dirname "$unwritable_events")
chmod 500 "$unwritable_runs"
set +e
output=$(printf 'cannot persist' | "$ARTIFACTS_CLI" put "$unwritable_session" "$unwritable_metadata" - 2>&1)
unwritable_status=$?
set -e
chmod 700 "$unwritable_runs"
[ "$unwritable_status" -ne 0 ] || fail "unwritable artifact storage was accepted"
[ ! -f "$(artifact_log_for "$unwritable_events")" ] || fail "unwritable storage appended an artifact event"
printf '%s' "$output" | grep -q "Permission denied" || fail "unwritable storage error was hidden"
ok "stops artifact-dependent execution when storage is unwritable"

concurrent_session="32222222-2222-4222-8222-222222222222"
concurrent_events=$("$CURRENT" init DEMO-761 "$concurrent_session")
concurrent_artifacts=$(artifact_log_for "$concurrent_events")
concurrent_attempt="99999999-9999-4999-8999-999999999999"
emit "$concurrent_session" '{"e":"run_start","ticket":"DEMO-761","entry":"ticket"}'
emit "$concurrent_session" "{\"e\":\"node\",\"node\":\"PLAN\",\"phase\":\"start\",\"attempt_id\":\"${concurrent_attempt}\",\"iteration\":1}"
concurrent_metadata="{\"family\":\"test_plan\",\"node\":\"PLAN\",\"attempt_id\":\"${concurrent_attempt}\",\"producer\":\"pg-PLAN-test\",\"input_sha\":\"${sha_a}\",\"candidate_sha\":null,\"content_type\":\"text/markdown\",\"wake_id\":null,\"perspective\":\"author\",\"covered_outcomes\":[]}"
concurrent_refusals="${TEST_ROOT}/concurrent-refusals"
: > "$concurrent_refusals"
for number in 1 2 3 4; do
  (printf 'scenario %s' "$number" | "$ARTIFACTS_CLI" put "$concurrent_session" "$concurrent_metadata" - >/dev/null 2>>"$concurrent_refusals" || true) &
done
wait
"$ARTIFACTS_CLI" validate "$concurrent_artifacts" "$concurrent_events" >/dev/null
[ "$(wc -l < "$concurrent_artifacts" | tr -d ' ')" = 1 ] || fail "concurrent puts of one family stored more than one artifact"
last_seq=$(ruby -r json -e 'puts JSON.parse(File.readlines(ARGV.fetch(0)).last).fetch("seq")' "$concurrent_artifacts")
[ "$last_seq" = 1 ] || fail "concurrent artifact sequence is not contiguous"
[ "$(grep -c 'already has current test_plan' "$concurrent_refusals")" = 3 ] || fail "concurrent duplicates were not refused by name"
ok "serializes concurrent puts and stores exactly one output per family and attempt"

printf '%s' "$run_id" | grep -Eq '^[0-9a-f-]{36}$' || fail "run id fixture is malformed"
echo "1..${tests}"
