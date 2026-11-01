#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ruby -I "${SCRIPT_DIR}/../scripts" <<'RUBY'
require "ac_audit_contract"

TESTS = []

def rejected(message)
  yield
  raise "expected rejection containing #{message.inspect}"
rescue PrGraph::ContractError => e
  raise "expected #{message.inspect}, got #{e.message.inspect}" unless e.message.include?(message)
end

CANDIDATE = "c" * 40
CLAUSES = %w[outcome:named constraint:no-false-name].freeze
EVIDENCE = [{"ref" => "app/fix.rb:12", "note" => "names the cleared dimension"}].freeze

def met(id)
  {"clause_id" => id, "verdict" => "met", "evidence" => EVIDENCE}
end

def audit(**overrides)
  {"ac_audit" => {
    "candidate_sha" => CANDIDATE, "inputs" => %w[triage_brief investigation_report],
    "clauses" => CLAUSES.map { |id| met(id) }, "missed" => []
  }.merge(overrides)}
end

contract = PrGraph::AcAuditContract.new
check = ->(verification) { contract.validate!(verification, clause_ids: CLAUSES, candidate_sha: CANDIDATE) }

check.call(audit)
check.call(audit("clauses" => [met("outcome:named"),
                               {"clause_id" => "constraint:no-false-name", "verdict" => "unverifiable",
                                "reason" => "Needs a live ERP push."}]))
check.call(audit("missed" => [{"criterion" => "Clearing Class while Project stays mapped is named.",
                               "source" => "ticket comment 2", "verdict" => "met", "evidence" => EVIDENCE}]))
TESTS << "accepts met and unverifiable clauses and a missed criterion the candidate meets"

rejected("must record an ac_audit") { check.call({"failures" => 0}) }
rejected("must audit the current candidate") { check.call(audit("candidate_sha" => "d" * 40)) }
rejected("missing field(s): missed") { check.call({"ac_audit" => audit["ac_audit"].except("missed")}) }
TESTS << "rejects a missing or stale audit"

rejected("must not read implementation_plan, build_manifest") do
  check.call(audit("inputs" => %w[triage_brief implementation_plan build_manifest]))
end
rejected("inputs must include triage_brief") { check.call(audit("inputs" => ["investigation_report"])) }
TESTS << "the auditor reads the ticket, never the plan or the build"

rejected("no verdict for clause(s): constraint:no-false-name") { check.call(audit("clauses" => [met("outcome:named")])) }
rejected("unknown outcome clause(s): outcome:other") { check.call(audit("clauses" => CLAUSES.map { |id| met(id) } + [met("outcome:other")])) }
rejected("rules on outcome:named more than once") { check.call(audit("clauses" => CLAUSES.map { |id| met(id) } + [met("outcome:named")])) }
TESTS << "every outcome clause gets exactly one verdict"

rejected("clause 1 evidence must be a non-empty array") { check.call(audit("clauses" => [met("outcome:named").merge("evidence" => []), met("constraint:no-false-name")])) }
rejected("clause 2 reason must be non-empty text") do
  check.call(audit("clauses" => [met("outcome:named"), {"clause_id" => "constraint:no-false-name", "verdict" => "unverifiable", "reason" => " "}]))
end
rejected("verdict must be one of met, unmet, unverifiable") { check.call(audit("clauses" => [met("outcome:named").merge("verdict" => "partial"), met("constraint:no-false-name")])) }
TESTS << "a met verdict cites evidence and any other verdict gives a reason"

rejected("unmet criteria: constraint:no-false-name") do
  check.call(audit("clauses" => [met("outcome:named"), {"clause_id" => "constraint:no-false-name", "verdict" => "unmet", "reason" => "A mapped Project is named."}]))
end
rejected("unmet criteria: Clearing Class is named") do
  check.call(audit("missed" => [{"criterion" => "Clearing Class is named", "source" => "ticket body", "verdict" => "unmet",
                                 "reason" => "The gate never runs when Project stays mapped."}]))
end
rejected("missed criterion 1 verdict must be one of met, unmet") do
  check.call(audit("missed" => [{"criterion" => "x", "source" => "ticket", "verdict" => "unverifiable", "reason" => "y"}]))
end
TESTS << "an unmet clause or an unmet missed criterion blocks VERIFY"

TESTS.each_with_index { |name, index| puts "ok #{index + 1}: #{name}" }
puts "#{TESTS.length} ac audit tests passed"
RUBY
