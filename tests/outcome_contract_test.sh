#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTCOMES="${SCRIPT_DIR}/../scripts/outcomes.rb"
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

write_fixture() {
  printf '%s' "$2" > "$TEST_ROOT/$1"
}

assert_rejected() {
  local expected="$1"
  shift

  if output=$("$@" 2>&1); then
    fail "$expected"
  fi
  printf '%s' "$output" | grep -Fq "$expected" || fail "expected '$expected', got: $output"
}

valid_triage='{"ticket":"DEMO-771","outcome_register":{"why":"Developers need plans that preserve intent while technical choices remain negotiable.","actors":[{"id":"actor:developer","situation":"A developer preparing a change from incomplete product guidance."}],"positive_postconditions":[{"id":"outcome:explicit-intent","statement":"The developer can identify what must become true before work begins."}],"negative_face":[{"id":"constraint:no-invented-support","statement":"Unavailable evidence must never be presented as established support."}],"declared_gaps":[{"id":"gap:human-approval","reason":"Final human approval remains deliberately outside this workflow."}]}}'
valid_plan='{"steps":[{"id":"step:ground-plan","classification":"AMEND","intent":"Validate the planning artifacts before authorizing build work.","outcome_ids":["outcome:explicit-intent","constraint:no-invented-support"],"evidence":[{"role":"existing_mechanism","kind":"codebase","ref":"skills/pr-graph/SKILL.md:210","claim":"Planning currently records prose without a structured outcome contract."},{"role":"authorization","kind":"ticket","ref":"linear:DEMO-771#ac:2","claim":"The ticket requires grounded AMEND and EXTEND steps."}]}]}'
valid_tests='{"coverage":[{"outcome_id":"outcome:explicit-intent","status":"planned","planned_node":"VERIFY","strategy":"An automated check rejects a plan whose intended result is absent."},{"outcome_id":"constraint:no-invented-support","status":"uncovered","reason":"Proving the truth of every external reference is outside local validation."}]}'

write_fixture triage.json "$valid_triage"
write_fixture plan.json "$valid_plan"
write_fixture tests.json "$valid_tests"

projection=$("$OUTCOMES" plan "$TEST_ROOT/triage.json" "$TEST_ROOT/plan.json" "$TEST_ROOT/tests.json")
printf '%s' "$projection" | ruby -r json -e '
  value = JSON.parse($stdin.read)
  abort unless value.fetch("planned_outcome_ids") == ["outcome:explicit-intent"]
  abort unless value.fetch("uncovered_outcome_ids") == ["constraint:no-invented-support"]
' || fail "valid plan projection was wrong"
ok "accepts a complete mechanism-free register and reports planned versus uncovered clauses"

write_fixture no-actors.json '{"outcome_register":{"why":"The desired result must be explicit.","actors":[],"positive_postconditions":[{"id":"outcome:one","statement":"The desired result becomes explicit."}],"negative_face":[{"id":"constraint:one","statement":"Missing intent must never authorize work."}],"declared_gaps":[]}}'
assert_rejected "outcome_register.actors must not be empty" "$OUTCOMES" register "$TEST_ROOT/no-actors.json"
ok "rejects an outcome register without a situated actor"

write_fixture no-negative.json '{"outcome_register":{"why":"The desired result must be explicit.","actors":[{"id":"actor:one","situation":"A developer preparing a change."}],"positive_postconditions":[{"id":"outcome:one","statement":"The desired result becomes explicit."}],"declared_gaps":[]}}'
assert_rejected "outcome_register is missing field(s): negative_face" "$OUTCOMES" register "$TEST_ROOT/no-negative.json"
ok "rejects an outcome register without a negative face"

write_fixture empty-register.json '{"outcome_register":{}}'
assert_rejected "outcome_register is missing field(s)" "$OUTCOMES" register "$TEST_ROOT/empty-register.json"
ok "rejects an empty register before it can authorize BUILD"

write_fixture mechanism.json '{"outcome_register":{"why":"A developer needs UserPolicy.rb to decide the result.","actors":[{"id":"actor:one","situation":"A developer preparing a change."}],"positive_postconditions":[{"id":"outcome:one","statement":"The desired result becomes explicit."}],"negative_face":[{"id":"constraint:one","statement":"Missing intent must never authorize work."}],"declared_gaps":[]}}'
assert_rejected "names an implementation mechanism" "$OUTCOMES" register "$TEST_ROOT/mechanism.json"
ok "rejects implementation mechanisms inside the outcome register"

write_fixture uncited-amend.json '{"steps":[{"id":"step:one","classification":"AMEND","intent":"Change the current behavior.","outcome_ids":["outcome:explicit-intent"],"evidence":[{"role":"existing_mechanism","kind":"codebase","ref":"source:1","claim":"Existing behavior was found."}]}]}'
assert_rejected "AMEND is missing actual evidence role(s): authorization" "$OUTCOMES" plan "$TEST_ROOT/triage.json" "$TEST_ROOT/uncited-amend.json" "$TEST_ROOT/tests.json"
ok "rejects an AMEND step without authorization evidence"

write_fixture gap-plan.json '{"steps":[{"id":"step:one","classification":"CONFORM","intent":"Follow the expected product result.","outcome_ids":["outcome:explicit-intent"],"evidence":[{"role":"gap","kind":"gap","reason":"No matching precedent was available.","searched":["codebase","prior art"]}]}]}'
"$OUTCOMES" plan "$TEST_ROOT/triage.json" "$TEST_ROOT/gap-plan.json" "$TEST_ROOT/tests.json" >/dev/null
ok "preserves unavailable evidence as a bounded gap instead of inventing support"

write_fixture missing-coverage.json '{"coverage":[{"outcome_id":"outcome:explicit-intent","status":"planned","planned_node":"VERIFY","strategy":"An automated check rejects missing intent."}]}'
assert_rejected "leaves outcome clause(s) undeclared: constraint:no-invented-support" "$OUTCOMES" plan "$TEST_ROOT/triage.json" "$TEST_ROOT/plan.json" "$TEST_ROOT/missing-coverage.json"
ok "requires every positive and negative clause to be planned or explicitly uncovered"

write_fixture witness.json '{"coverage":[{"outcome_id":"outcome:explicit-intent","status":"planned","planned_node":"VERIFY","strategy":"An automated check rejects missing intent.","witness":"spec/result.json"},{"outcome_id":"constraint:no-invented-support","status":"uncovered","reason":"No proof is planned."}]}'
assert_rejected "contains concrete witness field(s): witness" "$OUTCOMES" plan "$TEST_ROOT/triage.json" "$TEST_ROOT/plan.json" "$TEST_ROOT/witness.json"
ok "keeps concrete witness identities out of PLAN"

write_fixture invented-outcome.json '{"steps":[{"id":"step:one","classification":"CONFORM","intent":"Follow the expected result.","outcome_ids":["outcome:not-declared"],"evidence":[{"role":"gap","kind":"gap","reason":"No matching precedent was available.","searched":["codebase"]}]}]}'
assert_rejected "references unknown outcome clause outcome:not-declared" "$OUTCOMES" plan "$TEST_ROOT/triage.json" "$TEST_ROOT/invented-outcome.json" "$TEST_ROOT/tests.json"
ok "rejects plan steps that invent undeclared outcome clauses"

echo "1..${tests}"
