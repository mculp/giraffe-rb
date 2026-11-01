#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT="${SCRIPT_DIR}/../scripts/current.sh"
HOOK="${SCRIPT_DIR}/../scripts/usage_hook.rb"
EVENTS_CLI="${SCRIPT_DIR}/../scripts/events.rb"
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

json_value() {
  ruby -r json -e 'puts JSON.parse(File.readlines(ARGV.fetch(0)).last).fetch(ARGV.fetch(1), "")' "$1" "$2"
}

usage_count() {
  ruby -r json -e 'puts File.readlines(ARGV.fetch(0)).count { |line| JSON.parse(line)["e"] == "usage" }' "$1"
}

if "$CURRENT" init DEMO-762 "bad/session" >/dev/null 2>&1; then
  fail "rejects malformed conversation identities"
fi
[ ! -d "${PR_GRAPH_STATE_ROOT}/active" ] || fail "malformed init created active state"
ok "rejects malformed conversation identities before mutation"

session_a="11111111-1111-4111-8111-111111111111"
session_b="22222222-2222-4222-8222-222222222222"
events_a=$("$CURRENT" init DEMO-762 "$session_a")
events_b=$("$CURRENT" init DEMO-762 "$session_b")
"$EVENTS_CLI" emit "$session_a" '{"e":"run_start","ticket":"DEMO-762","entry":"ticket"}' >/dev/null
"$EVENTS_CLI" emit "$session_b" '{"e":"run_start","ticket":"DEMO-762","entry":"ticket"}' >/dev/null
[ "$events_a" != "$events_b" ] || fail "run event paths collided"
run_a=$(sed -n 's/^run_id=//p' "${PR_GRAPH_STATE_ROOT}/active/${session_a}")
run_b=$(sed -n 's/^run_id=//p' "${PR_GRAPH_STATE_ROOT}/active/${session_b}")
[[ "$run_a" =~ ^[0-9a-f-]{36}$ ]] || fail "first run id is not a UUID"
[[ "$run_b" =~ ^[0-9a-f-]{36}$ ]] || fail "second run id is not a UUID"
[ "$run_a" != "$run_b" ] || fail "run UUIDs collided"
ok "creates a unique UUID stream for every invocation"

"$CURRENT" node "$session_a" BUILD pg-BUILD
grep -q '^node=BUILD$' "${PR_GRAPH_STATE_ROOT}/active/${session_a}" || fail "session A node was not updated"
grep -q '^node=ORCHESTRATOR$' "${PR_GRAPH_STATE_ROOT}/active/${session_b}" || fail "session B node was contaminated"
ok "updates node state for only the named conversation"

printf '%s' '{"event":"stop","conversation_id":"11111111-1111-4111-8111-111111111111","generation_id":"gen-a","model":"cursor-model","input_tokens":120,"cache_read_tokens":80,"cache_write_tokens":10,"output_tokens":7}' | ruby "$HOOK"
printf '%s' '{"hook_event_name":"Stop","session_id":"22222222-2222-4222-8222-222222222222","message":{"id":"msg-b"},"model_id":"claude-model","input_tokens":50,"output_tokens":9}' | ruby "$HOOK"
[ "$(usage_count "$events_a")" = 1 ] || fail "session A event count is wrong"
[ "$(usage_count "$events_b")" = 1 ] || fail "session B event count is wrong"
[ "$(json_value "$events_a" session)" = "$session_a" ] || fail "session A hook was misrouted"
[ "$(json_value "$events_b" session)" = "$session_b" ] || fail "session B hook was misrouted"
[ "$(json_value "$events_a" node)" = "BUILD" ] || fail "session A node was not recorded"
[ "$(json_value "$events_b" node)" = "ORCHESTRATOR" ] || fail "session B node was contaminated"
[ "$(json_value "$events_a" input)" = "30" ] || fail "Cursor cache subtraction changed"
ok "routes Cursor and Claude hook events by conversation identity"

printf '%s' '{"event":"stop","conversation_id":"33333333-3333-4333-8333-333333333333","generation_id":"other"}' | ruby "$HOOK"
printf '%s' '{"event":"stop","generation_id":"missing"}' | ruby "$HOOK"
[ "$(usage_count "$events_a")" = 1 ] || fail "unmatched hook contaminated session A"
[ "$(usage_count "$events_b")" = 1 ] || fail "unmatched hook contaminated session B"
ok "ignores hooks without a matching active conversation"

printf '%s' '{"event":"stop","conversation_id":"11111111-1111-4111-8111-111111111111","generation_id":"gen-a","output_tokens":99}' | ruby "$HOOK"
[ "$(usage_count "$events_a")" = 1 ] || fail "duplicate generation was recorded"
ok "deduplicates parent generations within their run"

for _ in 1 2 3 4 5 6 7 8; do
  printf '%s' '{"event":"stop","conversation_id":"11111111-1111-4111-8111-111111111111","generation_id":"gen-race","input_tokens":10,"output_tokens":5}' | ruby "$HOOK" &
done
wait
[ "$(usage_count "$events_a")" = 2 ] || fail "concurrent duplicate hooks were recorded"
ok "deduplicates concurrent hook delivery under a file lock"

transcript="${TEST_ROOT}/parent.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"id":"msg-1","model":"claude-model","usage":{"input_tokens":3,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":4}}}' \
  '{"type":"assistant","message":{"id":"msg-1","model":"claude-model","usage":{"input_tokens":5,"cache_creation_input_tokens":11,"cache_read_input_tokens":22,"output_tokens":7}}}' \
  '{"type":"assistant","message":{"id":"msg-2","model":"claude-model","usage":{"input_tokens":2,"cache_creation":{"ephemeral_5m_input_tokens":13,"ephemeral_1h_input_tokens":17},"cache_read_input_tokens":19,"output_tokens":23}}}' \
  > "$transcript"
printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"${session_b}\",\"transcript_path\":\"${transcript}\"}" | ruby "$HOOK"
printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"${session_b}\",\"transcript_path\":\"${transcript}\"}" | ruby "$HOOK"
[ "$(usage_count "$events_b")" = 3 ] || fail "Claude transcript messages were not deduplicated"
[ "$(ruby -r json -e 'event=File.readlines(ARGV.fetch(0)).map { |line| JSON.parse(line) }.find { |row| row["generation_id"] == "msg-1" }; puts event.fetch("input")' "$events_b")" = "5" ] || fail "last cumulative message usage was not kept"
[ "$(json_value "$events_b" cache_w1)" = "17" ] || fail "Claude one-hour cache writes were not recorded"
ok "harvests Claude transcript usage once per final message id"

printf '%s\n' '{"type":"assistant","message":{"id":"msg-3","model":"claude-model","usage":{"input_tokens":41,"cache_creation_input_tokens":0,"cache_read_input_tokens":43,"output_tokens":47}}}' >> "$transcript"
printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"${session_b}\",\"transcript_path\":\"${transcript}\"}" | ruby "$HOOK"
[ "$(usage_count "$events_b")" = 4 ] || fail "incremental transcript usage was not recorded"
[ "$(json_value "$events_b" generation_id)" = "msg-3" ] || fail "transcript checkpoint skipped the appended message"
ok "advances a per-session transcript checkpoint"

agent_transcript="${TEST_ROOT}/agent-7.jsonl"
printf '%s\n' '{"type":"assistant","message":{"id":"agent-msg","model":"claude-model","usage":{"input_tokens":29,"cache_creation_input_tokens":0,"cache_read_input_tokens":31,"output_tokens":37}}}' > "$agent_transcript"
printf '%s' "{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"${session_b}\",\"agent_id\":\"agent-7\",\"agent_type\":\"review\",\"agent_transcript_path\":\"${agent_transcript}\"}" | ruby "$HOOK"
[ "$(usage_count "$events_b")" = 5 ] || fail "Claude subagent transcript usage was not recorded"
[ "$(json_value "$events_b" session)" = "$session_b" ] || fail "subagent replaced the parent session identity"
[ "$(json_value "$events_b" subagent_id)" = "agent-7" ] || fail "Claude agent id was not normalized"
[ "$(json_value "$events_b" input)" = "29" ] || fail "Claude subagent tokens were not harvested"
ok "harvests Claude subagent usage under the parent identity"

# Tamper with one registry entry to prove the hook verifies content as well as filename.
sed 's/^session=.*/session=another-session/' "${PR_GRAPH_STATE_ROOT}/active/${session_a}" > "${PR_GRAPH_STATE_ROOT}/active/${session_a}.tmp"
mv "${PR_GRAPH_STATE_ROOT}/active/${session_a}.tmp" "${PR_GRAPH_STATE_ROOT}/active/${session_a}"
printf '%s' '{"event":"stop","conversation_id":"11111111-1111-4111-8111-111111111111","generation_id":"tampered"}' | ruby "$HOOK"
[ "$(usage_count "$events_a")" = 2 ] || fail "tampered registry was trusted"
ok "fails closed on a mismatched registry identity"

"$CURRENT" clear "$session_a"
[ ! -e "${PR_GRAPH_STATE_ROOT}/active/${session_a}" ] || fail "session A state was not cleared"
[ -e "${PR_GRAPH_STATE_ROOT}/active/${session_b}" ] || fail "clearing session A removed session B"
ok "atomically clears only the named conversation"

"$CURRENT" clear "$session_b"
[ ! -e "${PR_GRAPH_STATE_ROOT}/active/${session_b}" ] || fail "session B state was not cleared"
[ ! -e "${PR_GRAPH_STATE_ROOT}/checkpoints/${session_b}" ] || fail "session B checkpoints were not cleared"
ok "clears transcript checkpoints with active run state"

echo "1..${tests}"
