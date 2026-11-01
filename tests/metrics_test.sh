#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS="${SCRIPT_DIR}/../scripts/metrics.rb"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

tests=0

ok() {
  tests=$((tests + 1))
  echo "ok ${tests} - $1"
}

fail() {
  echo "not ok $((tests + 1)) - $1" >&2
  exit 1
}

run_id="11111111-1111-4111-8111-111111111111"
session="22222222-2222-4222-8222-222222222222"
build_a="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
build_b="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
ci_attempt="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
wake_id="dddddddd-dddd-4ddd-8ddd-dddddddddddd"
sha="1111111111111111111111111111111111111111"
events="${TEST_ROOT}/metrics.jsonl"

printf '%s\n' \
  "{\"v\":1,\"run_id\":\"${run_id}\",\"seq\":1,\"ts\":\"2026-09-08T10:00:00Z\",\"session\":\"${session}\",\"e\":\"run_start\",\"ticket\":\"DEMO-759\",\"entry\":\"ticket\"}" \
  "{\"v\":1,\"run_id\":\"${run_id}\",\"seq\":2,\"ts\":\"2026-09-08T10:00:00Z\",\"session\":\"${session}\",\"e\":\"node\",\"node\":\"BUILD\",\"phase\":\"start\",\"attempt_id\":\"${build_a}\",\"iteration\":1}" \
  "{\"v\":1,\"run_id\":\"${run_id}\",\"seq\":3,\"ts\":\"2026-09-08T10:10:00Z\",\"session\":\"${session}\",\"e\":\"node\",\"node\":\"BUILD\",\"phase\":\"done\",\"attempt_id\":\"${build_a}\",\"iteration\":1}" \
  "{\"v\":1,\"run_id\":\"${run_id}\",\"seq\":4,\"ts\":\"2026-09-08T11:00:00Z\",\"session\":\"${session}\",\"e\":\"node\",\"node\":\"BUILD\",\"phase\":\"start\",\"attempt_id\":\"${build_b}\",\"iteration\":2}" \
  "{\"v\":1,\"run_id\":\"${run_id}\",\"seq\":5,\"ts\":\"2026-09-08T11:05:00Z\",\"session\":\"${session}\",\"e\":\"node\",\"node\":\"BUILD\",\"phase\":\"done\",\"attempt_id\":\"${build_b}\",\"iteration\":2}" \
  "{\"v\":1,\"run_id\":\"${run_id}\",\"seq\":6,\"ts\":\"2026-09-08T11:10:00Z\",\"session\":\"${session}\",\"e\":\"node\",\"node\":\"CI-WATCH\",\"phase\":\"start\",\"attempt_id\":\"${ci_attempt}\",\"iteration\":1}" \
  "{\"v\":1,\"run_id\":\"${run_id}\",\"seq\":7,\"ts\":\"2026-09-08T11:10:00Z\",\"session\":\"${session}\",\"e\":\"wake\",\"node\":\"CI-WATCH\",\"attempt_id\":\"${ci_attempt}\",\"wake_id\":\"${wake_id}\",\"kind\":\"ci\",\"state\":\"registered\"}" \
  "{\"v\":1,\"run_id\":\"${run_id}\",\"seq\":8,\"ts\":\"2026-09-08T11:11:00Z\",\"session\":\"${session}\",\"e\":\"wake\",\"node\":\"CI-WATCH\",\"attempt_id\":\"${ci_attempt}\",\"wake_id\":\"${wake_id}\",\"kind\":\"ci\",\"state\":\"armed\"}" \
  "{\"v\":1,\"run_id\":\"${run_id}\",\"seq\":9,\"ts\":\"2026-09-08T11:21:00Z\",\"session\":\"${session}\",\"e\":\"wake\",\"node\":\"CI-WATCH\",\"attempt_id\":\"${ci_attempt}\",\"wake_id\":\"${wake_id}\",\"kind\":\"ci\",\"state\":\"fired\"}" \
  "{\"v\":1,\"run_id\":\"${run_id}\",\"seq\":10,\"ts\":\"2026-09-08T11:22:00Z\",\"session\":\"${session}\",\"e\":\"node\",\"node\":\"CI-WATCH\",\"phase\":\"done\",\"attempt_id\":\"${ci_attempt}\",\"iteration\":1}" \
  "{\"v\":1,\"run_id\":\"${run_id}\",\"seq\":11,\"ts\":\"2026-09-08T11:22:00Z\",\"session\":\"${session}\",\"e\":\"publish\",\"pr\":63067,\"candidate_sha\":\"${sha}\"}" \
  "{\"v\":1,\"run_id\":\"${run_id}\",\"seq\":12,\"ts\":\"2026-09-08T11:22:00Z\",\"session\":\"${session}\",\"e\":\"done\",\"candidate_sha\":\"${sha}\"}" \
  > "$events"

report=$(ruby "$METRICS" "$events")
printf '%s' "$report" | grep -q "Run wall: 1h22m" || fail "run wall is wrong"
printf '%s' "$report" | grep -q "Attempt time: 17m00s active + 10m00s wait = 27m00s elapsed" || fail "active/wait totals are wrong"
printf '%s' "$report" | grep -E -q 'BUILD +2 +2 +15m00s +0s +15m00s +closed' || fail "BUILD attempts were measured by summed intervals"
printf '%s' "$report" | grep -E -q 'CI-WATCH +1 +1 +2m00s +10m00s +12m00s +closed' || fail "CI wait was not separated"
ok "reports run wall separately from summed active and wait intervals"

json=$(ruby "$METRICS" "$events" --json)
printf '%s' "$json" | ruby -r json -e '
  data = JSON.parse($stdin.read)
  build = data.fetch("nodes").find { |row| row.fetch("node") == "BUILD" }
  ci = data.fetch("nodes").find { |row| row.fetch("node") == "CI-WATCH" }
  abort unless build.fetch("active") == 900 && build.fetch("wait") == 0
  abort unless ci.fetch("active") == 120 && ci.fetch("wait") == 600
'
ok "exposes active and wait seconds in JSON output"

malformed="${TEST_ROOT}/malformed.jsonl"
cp "$events" "$malformed"
printf '%s\n' '{not json}' >> "$malformed"
if output=$(ruby "$METRICS" "$malformed" 2>&1); then
  fail "malformed stream was accepted"
fi
printf '%s' "$output" | grep -q "malformed JSON" || fail "malformed stream error was hidden"
ok "fails closed instead of silently skipping malformed JSON"

legacy="${TEST_ROOT}/legacy.jsonl"
printf '%s\n' '{"e":"node","node":"BUILD","phase":"start"}' > "$legacy"
if output=$(ruby "$METRICS" "$legacy" 2>&1); then
  fail "legacy stream was accepted"
fi
printf '%s' "$output" | grep -q "unsupported legacy event" || fail "legacy stream error was hidden"
ok "rejects unsupported legacy metrics input explicitly"

echo "1..${tests}"
