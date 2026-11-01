#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ruby -I "${SCRIPT_DIR}/../scripts" <<'RUBY'
require "outcome_coverage"

tests = 0

def assert(value, message)
  raise message unless value
end

def rejected(message)
  yield
  raise "expected rejection containing #{message.inspect}"
rescue PrGraph::OutcomeCoverage::CoverageError => e
  raise "expected #{message.inspect}, got #{e.message.inspect}" unless e.message.include?(message)
end

def artifact(id, node, attempt, outcomes, perspective)
  {
    "artifact_id" => id,
    "node" => node,
    "attempt_id" => attempt,
    "covered_outcomes" => outcomes,
    "perspective" => perspective,
    "status" => "current"
  }
end

def add_attempt(contract, attempts, manifests, artifacts, clauses, prior, node, attempt_id, output, polarity, state)
  attempts[attempt_id] = {"node" => node, "state" => "closed"}
  impact = contract.build_impact!(
    node: node,
    attempt_id: attempt_id,
    outputs: [output],
    clauses: clauses,
    prior: prior,
    polarity: polarity
  )
  manifests[attempt_id] = {
    "result" => {
      "node" => node,
      "state" => state,
      "outcome_impact" => impact,
      "outcome_disposition" => nil
    }
  }
  artifacts << output
end

def projection(contract, clauses, attempts, manifests, artifacts, planned_uncovered = [])
  contract.project!(
    clauses: clauses,
    attempts: attempts,
    manifests: manifests,
    artifacts: artifacts,
    planned_uncovered: planned_uncovered
  )
end

contract = PrGraph::OutcomeCoverage.new
clauses = ["outcome:ship", "constraint:no-regression"]
attempts = {}
manifests = {}
artifacts = []
current = projection(contract, clauses, attempts, manifests, artifacts)

build_attempt = "11111111-1111-4111-8111-111111111111"
build = artifact(
  "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "BUILD",
  build_attempt,
  ["outcome:ship"],
  "author"
)
add_attempt(contract, attempts, manifests, artifacts, clauses, current, "BUILD", build_attempt, build, "advanced", "completed")
current = projection(contract, clauses, attempts, manifests, artifacts)
assert(current.dig("clauses", "outcome:ship", "state") == "covered", "BUILD evidence did not advance coverage")
assert(current.dig("clauses", "outcome:ship", "supports", 0, "perspective") == "author", "evidence perspective was lost")
tests += 1
puts "ok #{tests} - BUILD advances a declared outcome with attributed evidence"

verify_attempt = "22222222-2222-4222-8222-222222222222"
verify = artifact(
  "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  "VERIFY",
  verify_attempt,
  ["outcome:ship"],
  "automated_check"
)
add_attempt(contract, attempts, manifests, artifacts, clauses, current, "VERIFY", verify_attempt, verify, "contradicted", "failed")
current = projection(contract, clauses, attempts, manifests, artifacts)
assert(current.dig("clauses", "outcome:ship", "state") == "conflicting", "conflict was hidden")
assert(current.fetch("conflicts") == ["outcome:ship"], "conflict list was wrong")
tests += 1
puts "ok #{tests} - VERIFY contradiction is surfaced instead of replacing support"

build["status"] = "superseded"
verify["status"] = "invalidated"
current = projection(contract, clauses, attempts, manifests, artifacts)
assert(current.dig("clauses", "outcome:ship", "state") == "uncovered", "stale evidence still covered the outcome")
assert(current.fetch("history").length == 2, "historical impacts were discarded")
tests += 1
puts "ok #{tests} - invalidation removes current proof while preserving impact history"

browser_attempt = "33333333-3333-4333-8333-333333333333"
browser = artifact(
  "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
  "REVIEW-APP",
  browser_attempt,
  ["constraint:no-regression"],
  "user_observation"
)
add_attempt(contract, attempts, manifests, artifacts, clauses, current, "REVIEW-APP", browser_attempt, browser, "advanced", "completed")
current = projection(contract, clauses, attempts, manifests, artifacts, ["outcome:ship"])
final = contract.finalize!(
  {
    "clauses" => [
      {"outcome_id" => "outcome:ship", "status" => "deliberately_excluded", "reason" => "PLAN bounded this proof outside the run."},
      {"outcome_id" => "constraint:no-regression", "status" => "covered"}
    ]
  },
  clauses: clauses,
  projection: current,
  planned_uncovered: ["outcome:ship"]
)
assert(final.dig("clauses", 1, "evidence", 0, "perspective") == "user_observation", "browser perspective was not retained")
tests += 1
puts "ok #{tests} - terminal disposition permits only a PLAN-declared exclusion"

rejected("leaves outcome clause(s) undeclared") do
  contract.finalize!(
    {"clauses" => [{"outcome_id" => "constraint:no-regression", "status" => "covered"}]},
    clauses: clauses,
    projection: current,
    planned_uncovered: ["outcome:ship"]
  )
end
rejected("was not deliberately excluded by PLAN") do
  contract.finalize!(
    {
      "clauses" => [
        {"outcome_id" => "outcome:ship", "status" => "deliberately_excluded", "reason" => "No proof."},
        {"outcome_id" => "constraint:no-regression", "status" => "covered"}
      ]
    },
    clauses: clauses,
    projection: current,
    planned_uncovered: []
  )
end
tests += 1
puts "ok #{tests} - DONE refuses silent gaps and undeclared exclusions"

unknown_attempt = "44444444-4444-4444-8444-444444444444"
unknown = artifact(
  "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
  "CI-WATCH",
  unknown_attempt,
  ["outcome:not-registered"],
  "external_service"
)
rejected("names undeclared outcome clause outcome:not-registered") do
  contract.build_impact!(
    node: "CI-WATCH",
    attempt_id: unknown_attempt,
    outputs: [unknown],
    clauses: clauses,
    prior: current,
    polarity: "advanced"
  )
end
tests += 1
puts "ok #{tests} - completion rejects evidence for an undeclared clause"

plan_attempt = "55555555-5555-4555-8555-555555555555"
plan = artifact(
  "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
  "PLAN",
  plan_attempt,
  ["outcome:ship"],
  "author"
)
rejected("PLAN must not introduce concrete outcome evidence") do
  contract.build_impact!(
    node: "PLAN",
    attempt_id: plan_attempt,
    outputs: [plan],
    clauses: clauses,
    prior: current,
    polarity: "advanced"
  )
end
tests += 1
puts "ok #{tests} - PLAN cannot fabricate a concrete outcome witness"

puts "1..#{tests}"
RUBY
