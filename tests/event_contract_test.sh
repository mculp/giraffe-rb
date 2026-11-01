#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT="${SCRIPT_DIR}/../scripts/current.sh"
EVENTS_CLI="${SCRIPT_DIR}/../scripts/events.rb"
CONTRACT="${SCRIPT_DIR}/../references/execution-contract-v1.json"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

export PR_GRAPH_STATE_ROOT="${TEST_ROOT}/state"
export HOME="${TEST_ROOT}/home"
mkdir -p "$HOME"

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

assert_rejected_without_append() {
  local session="$1"
  local events="$2"
  local payload="$3"
  local expected="$4"
  local before
  local after

  before=$(wc -c < "$events" | tr -d ' ')
  if output=$("$EVENTS_CLI" emit "$session" "$payload" 2>&1); then
    fail "$expected"
  fi
  after=$(wc -c < "$events" | tr -d ' ')
  [ "$before" = "$after" ] || fail "$expected mutated the log"
  printf '%s' "$output" | grep -q "$expected" || fail "$expected error was not reported"
}

ruby -r json -e '
  contract = JSON.parse(File.read(ARGV.fetch(0)))
  abort unless contract.fetch("contract_version") == 1
  nodes = contract.dig("graph", "nodes")
  abort unless %w[TRIAGE BUILD VERIFY SELF-REVIEW PUBLISH DONE].all? { |node| nodes.include?(node) }
  abort unless contract.dig("graph", "dependencies").keys.sort == nodes.sort
' "$CONTRACT"
ok "encodes the complete graph in one versioned contract"

session="11111111-1111-4111-8111-111111111111"
events=$("$CURRENT" init DEMO-763 "$session")
run_id=$(sed -n 's/^run_id=//p' "${PR_GRAPH_STATE_ROOT}/active/${session}")
emit "$session" '{"e":"run_start","ticket":"DEMO-763","entry":"ticket","branch":"dev/demo-763"}'
[ "$(ruby -r json -e 'e=JSON.parse(File.open(ARGV.fetch(0), &:gets)); puts [e["v"],e["seq"],e["run_id"],e["session"]].join("|")' "$events")" = "1|1|${run_id}|${session}" ] || fail "run_start envelope is wrong"
ok "assigns an authoritative version, sequence, run, timestamp, and session envelope"

assert_rejected_without_append "$session" "$events" '{"e":"node","node":"TRIAGE","phase":"start","attempt_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","iteration":1}' "protected lifecycle event"
ok "routes lifecycle transitions through the deterministic coordinator"
export PR_GRAPH_ALLOW_RAW_EVENTS=1

assert_rejected_without_append "$session" "$events" '{"e":"surprise"}' "unknown event type"
ok "rejects unknown event vocabulary before append"

attempt_verify="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
assert_rejected_without_append "$session" "$events" "{\"e\":\"node\",\"node\":\"VERIFY\",\"phase\":\"done\",\"attempt_id\":\"${attempt_verify}\",\"iteration\":1}" "unknown attempt"
ok "rejects an illegal attempt transition before append"

emit "$session" "{\"e\":\"node\",\"node\":\"VERIFY\",\"phase\":\"start\",\"attempt_id\":\"${attempt_verify}\",\"iteration\":1}"
emit "$session" "{\"e\":\"outcome\",\"kind\":\"verify\",\"attempt_id\":\"${attempt_verify}\",\"pass\":false,\"n\":2}"
emit "$session" "{\"e\":\"edge\",\"from\":\"VERIFY\",\"to\":\"BUILD\",\"from_attempt_id\":\"${attempt_verify}\",\"reason\":\"two failing specs\"}"
emit "$session" "{\"e\":\"node\",\"node\":\"VERIFY\",\"phase\":\"done\",\"attempt_id\":\"${attempt_verify}\",\"iteration\":1}"
"$EVENTS_CLI" validate "$events" >/dev/null
ok "accepts a legal attempt, outcome, and red-edge lifecycle"

attempt_review="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
emit "$session" "{\"e\":\"node\",\"node\":\"SELF-REVIEW\",\"phase\":\"start\",\"attempt_id\":\"${attempt_review}\",\"iteration\":1}"
assert_rejected_without_append "$session" "$events" "{\"e\":\"outcome\",\"kind\":\"verify\",\"attempt_id\":\"${attempt_review}\",\"pass\":true,\"n\":0}" "belongs to VERIFY"
assert_rejected_without_append "$session" "$events" "{\"e\":\"edge\",\"from\":\"SELF-REVIEW\",\"to\":\"DONE\",\"from_attempt_id\":\"${attempt_review}\",\"reason\":\"skip gates\"}" "illegal graph edge"
emit "$session" "{\"e\":\"node\",\"node\":\"SELF-REVIEW\",\"phase\":\"done\",\"attempt_id\":\"${attempt_review}\",\"iteration\":1}"
ok "binds outcomes and legal edges to their source attempts"

attempt_ci="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
wake_id="dddddddd-dddd-4ddd-8ddd-dddddddddddd"
emit "$session" "{\"e\":\"node\",\"node\":\"CI-WATCH\",\"phase\":\"start\",\"attempt_id\":\"${attempt_ci}\",\"iteration\":1}"
assert_rejected_without_append "$session" "$events" "{\"e\":\"wake\",\"node\":\"CI-WATCH\",\"attempt_id\":\"${attempt_ci}\",\"wake_id\":\"${wake_id}\",\"kind\":\"ci\",\"state\":\"armed\"}" "illegal wake transition"
emit "$session" "{\"e\":\"wake\",\"node\":\"CI-WATCH\",\"attempt_id\":\"${attempt_ci}\",\"wake_id\":\"${wake_id}\",\"kind\":\"ci\",\"state\":\"registered\"}"
emit "$session" "{\"e\":\"wake\",\"node\":\"CI-WATCH\",\"attempt_id\":\"${attempt_ci}\",\"wake_id\":\"${wake_id}\",\"kind\":\"ci\",\"state\":\"armed\"}"
assert_rejected_without_append "$session" "$events" "{\"e\":\"done\",\"candidate_sha\":\"1111111111111111111111111111111111111111\"}" "open attempt"
emit "$session" "{\"e\":\"wake\",\"node\":\"CI-WATCH\",\"attempt_id\":\"${attempt_ci}\",\"wake_id\":\"${wake_id}\",\"kind\":\"ci\",\"state\":\"fired\"}"
emit "$session" "{\"e\":\"node\",\"node\":\"CI-WATCH\",\"phase\":\"done\",\"attempt_id\":\"${attempt_ci}\",\"iteration\":1}"
ok "enforces wake-source registration and terminal lifecycle"

candidate_sha="1111111111111111111111111111111111111111"
emit "$session" "{\"e\":\"publish\",\"pr\":63067,\"candidate_sha\":\"${candidate_sha}\"}"
emit "$session" "{\"e\":\"done\",\"candidate_sha\":\"${candidate_sha}\"}"
assert_rejected_without_append "$session" "$events" '{"e":"usage","node":"DONE","source":"late","calls":0}' "event after terminal done"
ok "makes done terminal and pins it to the latest published candidate"

replay_a=$("$EVENTS_CLI" replay "$events")
replay_b=$("$EVENTS_CLI" replay "$events")
[ "$replay_a" = "$replay_b" ] || fail "replay projections differed"
printf '%s' "$replay_a" | grep -q '"terminal": true' || fail "terminal projection missing"
ok "replays a deterministic disposable projection"

legacy="${TEST_ROOT}/legacy.jsonl"
printf '%s\n' '{"e":"run_start","ticket":"DEMO-709"}' > "$legacy"
if output=$("$EVENTS_CLI" validate "$legacy" 2>&1); then
  fail "legacy log was accepted"
fi
printf '%s' "$output" | grep -q "preserve it read-only and start a new v1 UUID run" || fail "legacy recovery was not explicit"
ok "labels legacy runs unsupported with a deterministic recovery path"

unknown_version="${TEST_ROOT}/unknown-version.jsonl"
printf '%s\n' "{\"v\":2,\"run_id\":\"${run_id}\",\"seq\":1,\"ts\":\"2026-09-08T10:00:00Z\",\"session\":\"${session}\",\"e\":\"run_start\",\"ticket\":\"DEMO-763\",\"entry\":\"ticket\"}" > "$unknown_version"
if output=$("$EVENTS_CLI" validate "$unknown_version" 2>&1); then
  fail "unknown contract version was accepted"
fi
printf '%s' "$output" | grep -q "v must equal 1" || fail "unknown version error was hidden"
ok "rejects unknown contract versions"

torn="${TEST_ROOT}/torn.jsonl"
printf '%s' '{"v":1' > "$torn"
before=$(wc -c < "$torn" | tr -d ' ')
if output=$(ruby -I "${SCRIPT_DIR}/../scripts" -r event_log -e 'PrGraph::EventLog.new.emit(ARGV.fetch(0), run_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", session: "ffffffff-ffff-4fff-8fff-ffffffffffff", payload: {"e"=>"run_start","ticket"=>"DEMO-763","entry"=>"ticket"})' "$torn" 2>&1); then
  fail "torn log was accepted"
fi
[ "$before" = "$(wc -c < "$torn" | tr -d ' ')" ] || fail "torn log was modified"
printf '%s' "$output" | grep -q "torn final event" || fail "torn-write error was not reported"
ok "rejects a torn log without mutating it"

concurrent_session="22222222-2222-4222-8222-222222222222"
concurrent_events=$("$CURRENT" init DEMO-763 "$concurrent_session")
emit "$concurrent_session" '{"e":"run_start","ticket":"DEMO-763","entry":"ticket"}'
for n in 1 2 3 4 5 6 7 8; do
  "$EVENTS_CLI" emit "$concurrent_session" "{\"e\":\"usage\",\"node\":\"ORCHESTRATOR\",\"source\":\"test-${n}\",\"calls\":0,\"generation_id\":\"generation-${n}\"}" >/dev/null &
done
wait
"$EVENTS_CLI" validate "$concurrent_events" >/dev/null
[ "$(wc -l < "$concurrent_events" | tr -d ' ')" = 9 ] || fail "concurrent append lost an event"
last_seq=$(ruby -r json -e 'puts JSON.parse(File.readlines(ARGV.fetch(0)).last).fetch("seq")' "$concurrent_events")
[ "$last_seq" = 9 ] || fail "concurrent sequence is not contiguous"
ok "serializes concurrent appends with contiguous sequence numbers"

echo "1..${tests}"
