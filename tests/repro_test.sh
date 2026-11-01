#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ruby -I "${SCRIPT_DIR}/../scripts" <<'RUBY'
require "tmpdir"
require "coordinator_runtime"

TESTS = []

def assert(value, message)
  raise message unless value
end

def rejected(message)
  yield
  raise "expected rejection containing #{message.inspect}"
rescue PrGraph::ContractError => e
  raise "expected #{message.inspect}, got #{e.message.inspect}" unless e.message.include?(message)
end

SHA = "a" * 40
REFERENCES = File.expand_path("../references", File.dirname(PrGraph::Coordinator.instance_method(:start).source_location.first))
CLAUSES = %w[outcome:named constraint:no-false-name].freeze

def reproduced(**overrides)
  {
    "status" => "reproduced", "base_sha" => SHA,
    "steps" => ["Clear one category mapping on a mapped project.", "Push an invoice."],
    "expected" => "The failure names the cleared dimension.",
    "observed" => "The pre-push gate never fires; the ERP rejects the push with a generic message.",
    "code_path" => ["ERP rejection handler", "failure classifier"],
    "evidence" => [{"command" => "bin/rails runner repro.rb", "excerpt" => "generic message"}],
    "clause_ids" => ["outcome:named"], "rerun" => "bin/rails runner repro.rb"
  }.merge(overrides)
end

def plan(evidence_kind: "reproduction", planned_node: "VERIFY")
  implementation = {"steps" => [{
    "id" => "step:name", "classification" => "CONFORM", "intent" => "Name the dimension.",
    "outcome_ids" => CLAUSES,
    "evidence" => [{"role" => "observed_behavior", "kind" => evidence_kind, "ref" => "repro_report",
                    "claim" => "The repro reaches the ERP rejection path."}]
  }]}
  test_plan = {"coverage" => CLAUSES.map do |id|
    {"outcome_id" => id, "status" => "planned", "planned_node" => planned_node, "strategy" => "Re-run the repro."}
  end}
  [implementation, test_plan]
end

contract = PrGraph::ReproContract.new
validate = ->(report) { contract.validate_report!(report, clause_ids: CLAUSES, input_sha: SHA) }

validate.call(reproduced)
validate.call({"status" => "not_applicable", "base_sha" => SHA, "reason" => "Feature work, nothing to reproduce."})
validate.call(reproduced("status" => "not_reproduced", "reason" => "Steps pass on the base.").except("code_path", "clause_ids", "rerun"))
TESTS << "accepts reproduced, not_reproduced, and not_applicable reports"

rejected("base_sha must match the artifact input SHA") { validate.call(reproduced("base_sha" => "b" * 40)) }
rejected("unknown outcome clause outcome:other") { validate.call(reproduced("clause_ids" => ["outcome:other"])) }
rejected("missing field(s): code_path") { validate.call(reproduced.except("code_path")) }
rejected("missing field(s): reason") { validate.call(reproduced("status" => "not_reproduced").except("code_path", "clause_ids", "rerun")) }
rejected("status must be one of") { validate.call(reproduced("status" => "maybe")) }
rejected("repro evidence 1 command") { validate.call(reproduced("evidence" => [{"command" => " ", "excerpt" => "x"}])) }
TESTS << "rejects a report with a foreign base, unknown clause, or missing evidence"

contract.validate_plan!(reproduced, *plan)
contract.validate_plan!({"status" => "not_applicable"}, *plan(evidence_kind: "codebase", planned_node: "BUILD"))
rejected("must cite the repro_report") { contract.validate_plan!(reproduced, *plan(evidence_kind: "codebase")) }
rejected("must be planned for VERIFY") { contract.validate_plan!(reproduced, *plan(planned_node: "BUILD")) }
TESTS << "PLAN must cite the repro and plan its clauses for VERIFY when the bug reproduced"

CANDIDATE = "c" * 40
def regression(spec: "spec/regression_spec.rb", base: {}, candidate: {})
  {"regression" => {
    "spec" => spec,
    "base" => {"sha" => SHA, "result" => "fail", "excerpt" => "1 example, 1 failure"}.merge(base),
    "candidate" => {"sha" => CANDIDATE, "result" => "pass", "excerpt" => "1 example, 0 failures"}.merge(candidate)
  }}
end
prove = ->(verification, changed: ["spec/regression_spec.rb"], report: reproduced) do
  contract.validate_regression!(report, verification, candidate_sha: CANDIDATE, changed_paths: changed)
end
prove.call(regression)
prove.call({}, report: {"status" => "not_applicable"})
rejected("must record the regression spec run") { prove.call({}) }
rejected("must be added or changed by the candidate") { prove.call(regression, changed: ["app/fix.rb"]) }
rejected("regression spec must fail on the base") { prove.call(regression(base: {"result" => "pass"})) }
rejected("regression spec must pass on the candidate") { prove.call(regression(candidate: {"result" => "fail"})) }
rejected("regression base run must be on #{SHA}") { prove.call(regression(base: {"sha" => CANDIDATE})) }
rejected("regression candidate run must be on #{CANDIDATE}") { prove.call(regression(candidate: {"sha" => SHA})) }
TESTS << "a reproduced bug needs a committed spec that fails on the base and passes on the candidate"

class Fixture
  attr_reader :coordinator, :worktree, :sha

  def initialize(root, event_log: PrGraph::EventLog.new, policy_path: nil)
    @root = root
    @worktree = File.join(root, "worktree")
    FileUtils.mkdir_p(worktree)
    git("init", "-q")
    git("config", "user.name", "PR Graph Test")
    git("config", "user.email", "pr-graph@example.test")
    git("-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "fixture")
    @sha = git("rev-parse", "HEAD").strip
    @events = File.join(root, "run.jsonl")
    @identity = {execution_path: @events, run_id: SecureRandom.uuid, session: SecureRandom.uuid}
    @artifacts = @events.sub(/\.jsonl\z/, ".artifacts.jsonl")
    PrGraph::EventLog.new.emit(@events, **@identity.slice(:run_id, :session),
                              payload: {"e" => "run_start", "ticket" => "DEMO-3728", "entry" => "ticket"})
    @coordinator = PrGraph::Coordinator.new(**@identity, event_log: event_log, policy_path: policy_path)
    finish("TRIAGE", "triage_brief" => {"outcome_register" => {
      "why" => "Users need to know which mapping to fix.",
      "actors" => [{"id" => "actor:admin", "situation" => "Reading a failed push."}],
      "positive_postconditions" => [{"id" => "outcome:named", "statement" => "The failure names the missing dimension."}],
      "negative_face" => [{"id" => "constraint:no-false-name", "statement" => "A mapped dimension is never named."}],
      "declared_gaps" => []
    }})
    finish("INVESTIGATE", "investigation_report" => {})
    finish("WORKTREE", "worktree_manifest" => {})
  end

  def git(*args)
    output, error, status = Open3.capture3("git", "-C", worktree, *args)
    raise error unless status.success?
    output
  end

  def upgrade
    @coordinator = PrGraph::Coordinator.new(**@identity)
  end

  def start(node, worktree: @worktree)
    coordinator.start(node, worktree: worktree)
  end

  def put(node, attempt, family, content, input: sha, candidate: sha, perspective: "author", covered: [])
    PrGraph::ArtifactLog.new.store(@artifacts, **@identity, metadata: {
      "family" => family, "node" => node, "attempt_id" => attempt,
      "producer" => "repro-test", "input_sha" => input, "candidate_sha" => candidate,
      "content_type" => "application/json", "wake_id" => nil, "perspective" => perspective,
      "covered_outcomes" => covered
    }, content: JSON.generate(content))
  end

  # Reproduce, plan, and build a candidate that commits spec/regression_spec.rb; returns the open
  # VERIFY attempt and the candidate SHA.
  def build_reproduced_fix
    finish("REPRODUCE", "repro_report" => reproduced("base_sha" => sha))
    finish("PLAN", plan_outputs)
    build = start("BUILD").fetch("attempt_id")
    FileUtils.mkdir_p(File.join(worktree, "spec"))
    File.write(File.join(worktree, "spec/regression_spec.rb"), "# names the cleared dimension\n")
    git("add", "spec/regression_spec.rb")
    git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "regression spec and fix")
    head = git("rev-parse", "HEAD").strip
    put("BUILD", build, "build_manifest", {}, candidate: head, covered: ["outcome:named"])
    put("BUILD", build, "self_review", {}, input: head, candidate: head, perspective: "independent_review",
        covered: ["constraint:no-false-name"])
    coordinator.complete("BUILD", build)
    [start("VERIFY").fetch("attempt_id"), head]
  end

  def verify(attempt, head, content)
    put("VERIFY", attempt, "verification", content, input: head, candidate: head, perspective: "automated_check",
        covered: ["outcome:named"])
  end

  def audit(head, **overrides)
    evidence = [{"ref" => "app/fix.rb:12", "note" => "names the cleared dimension"}]
    {"ac_audit" => {
      "candidate_sha" => head, "inputs" => %w[triage_brief investigation_report], "missed" => [],
      "clauses" => CLAUSES.map { |id| {"clause_id" => id, "verdict" => "met", "evidence" => evidence} }
    }.merge(overrides), "spec_audit" => spec_audit(head)}
  end

  def spec_audit(head, **spec)
    {"candidate_sha" => head, "base_sha" => sha, "specs" => [{
      "ref" => "spec/regression_spec.rb:1", "behavior" => "a cleared dimension is named in the error",
      "classes" => [], "mutation" => {"change" => "drop the dimension from the error", "result" => "fail"}
    }.merge(spec)]}
  end

  def finish(node, outputs)
    attempt = start(node).fetch("attempt_id")
    outputs.each { |family, content| put(node, attempt, family, content) }
    coordinator.complete(node, attempt)
    attempt
  end

  def plan_outputs(**options)
    implementation, test_plan = plan(**options)
    {"implementation_plan" => implementation, "test_plan" => test_plan}
  end

  def runnable
    coordinator.send(:runnable_nodes, coordinator.send(:load_state)).first
  end
end

# A run recorded under the graph that predates REPRODUCE; `upgrade` reopens it under the current graph.
def legacy_fixture(root)
  execution = JSON.parse(File.read(File.join(REFERENCES, "execution-contract-v1.json")))
  graph = execution.fetch("graph")
  graph["nodes"].delete("REPRODUCE")
  graph["dependencies"].delete("REPRODUCE")
  graph["dependencies"]["PLAN"] = ["INVESTIGATE"]
  graph["legal_edges"].reject! { |edge| edge.include?("REPRODUCE") }
  execution_path = File.join(root, "legacy-execution.json")
  File.write(execution_path, JSON.generate(execution))
  policy = JSON.parse(File.read(File.join(REFERENCES, "coordinator-policy-v1.json")))
  policy["nodes"].delete("REPRODUCE")
  policy["nodes"]["PLAN"]["inputs"].reject! { |rule| rule["family"] == "repro_report" }
  policy_path = File.join(root, "legacy-policy.json")
  File.write(policy_path, JSON.generate(policy))

  Fixture.new(root, event_log: PrGraph::EventLog.new(contract_path: execution_path), policy_path: policy_path)
end

Dir.mktmpdir do |root|
  fixture = Fixture.new(root)
  assert(fixture.runnable.include?("REPRODUCE"), "REPRODUCE should be runnable after INVESTIGATE and WORKTREE")
  assert(!fixture.runnable.include?("PLAN"), "PLAN must wait for REPRODUCE")
  rejected("dependency REPRODUCE is incomplete") { fixture.start("PLAN") }
  rejected("REPRODUCE requires --worktree for mutation detection") { fixture.start("REPRODUCE", worktree: nil) }
  fixture.finish("REPRODUCE", "repro_report" => reproduced("base_sha" => fixture.sha))
  fixture.finish("PLAN", fixture.plan_outputs)
  assert(fixture.runnable.include?("BUILD"), "BUILD should follow a repro-backed PLAN")
end
TESTS << "a fresh run reproduces on the worktree before PLAN and then reaches BUILD"

Dir.mktmpdir do |root|
  fixture = Fixture.new(root)
  attempt = fixture.start("REPRODUCE").fetch("attempt_id")
  fixture.put("REPRODUCE", attempt, "repro_report", reproduced("base_sha" => fixture.sha))
  File.write(File.join(fixture.worktree, "repro_spec.rb"), "# left behind\n")
  rejected("REPRODUCE changed HEAD, index, or worktree without BUILD authority") { fixture.coordinator.complete("REPRODUCE", attempt) }
end
TESTS << "REPRODUCE cannot leave files in the worktree"

Dir.mktmpdir do |root|
  fixture = Fixture.new(root)
  fixture.finish("REPRODUCE", "repro_report" => reproduced("base_sha" => fixture.sha))
  attempt = fixture.start("PLAN").fetch("attempt_id")
  fixture.plan_outputs(evidence_kind: "codebase").each { |family, content| fixture.put("PLAN", attempt, family, content) }
  rejected("must cite the repro_report") { fixture.coordinator.complete("PLAN", attempt) }
end
TESTS << "the coordinator refuses a PLAN that ignores a reproduced bug"

Dir.mktmpdir do |root|
  fixture = Fixture.new(root)
  attempt, head = fixture.build_reproduced_fix
  fixture.verify(attempt, head, {"failures" => 0}.merge(fixture.audit(head)))
  rejected("must record the regression spec run") { fixture.coordinator.complete("VERIFY", attempt) }
end
Dir.mktmpdir do |root|
  fixture = Fixture.new(root)
  attempt, head = fixture.build_reproduced_fix
  fixture.verify(attempt, head, {"failures" => 0, "regression" => {
    "spec" => "spec/regression_spec.rb",
    "base" => {"sha" => fixture.sha, "result" => "fail", "excerpt" => "1 example, 1 failure"},
    "candidate" => {"sha" => head, "result" => "pass", "excerpt" => "1 example, 0 failures"}
  }}.merge(fixture.audit(head)))
  fixture.coordinator.complete("VERIFY", attempt)
  assert(fixture.runnable.include?("PUBLISH"), "a proven regression spec should unlock PUBLISH")
end
TESTS << "a green VERIFY needs the committed regression spec proven on base and candidate"

Dir.mktmpdir do |root|
  fixture = legacy_fixture(root)
  fixture.finish("PLAN", fixture.plan_outputs(evidence_kind: "codebase", planned_node: "BUILD"))
  fixture.upgrade
  assert(fixture.runnable.include?("BUILD"), "a legacy run that finished PLAN should resume into BUILD")
  assert(!fixture.runnable.include?("REPRODUCE"), "REPRODUCE must not re-open a legacy run")
  rejected("introduced after this run passed PLAN") { fixture.start("REPRODUCE") }
end
TESTS << "a run that finished PLAN before REPRODUCE existed resumes into BUILD"

Dir.mktmpdir do |root|
  fixture = legacy_fixture(root)
  attempt = fixture.start("PLAN").fetch("attempt_id")
  fixture.plan_outputs(evidence_kind: "codebase", planned_node: "BUILD").each { |family, content| fixture.put("PLAN", attempt, family, content) }
  fixture.upgrade
  fixture.coordinator.complete("PLAN", attempt)
  assert(fixture.runnable.include?("BUILD"), "a legacy PLAN interrupted mid-attempt should complete and reach BUILD")
end
TESTS << "a legacy PLAN attempt still open at upgrade completes without REPRODUCE"

def audited_verify(root, **overrides)
  fixture = Fixture.new(root)
  fixture.finish("REPRODUCE", "repro_report" => {"status" => "not_applicable", "base_sha" => fixture.sha,
                                                  "reason" => "Feature work, nothing to reproduce."})
  fixture.finish("PLAN", fixture.plan_outputs)
  build = fixture.start("BUILD").fetch("attempt_id")
  FileUtils.mkdir_p(File.join(fixture.worktree, "spec"))
  File.write(File.join(fixture.worktree, "spec/regression_spec.rb"), "# names the cleared dimension\n")
  fixture.git("add", "spec/regression_spec.rb")
  fixture.git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "fix")
  head = fixture.git("rev-parse", "HEAD").strip
  fixture.put("BUILD", build, "build_manifest", {}, candidate: head, covered: ["outcome:named"])
  fixture.put("BUILD", build, "self_review", {}, input: head, candidate: head, perspective: "independent_review",
              covered: ["constraint:no-false-name"])
  fixture.coordinator.complete("BUILD", build)
  attempt = fixture.start("VERIFY").fetch("attempt_id")
  content = {"failures" => 0}
  content.merge!(fixture.audit(head, **overrides.except(:unsaved))) unless overrides[:omit] || overrides[:unsaved]
  fixture.verify(attempt, head, content) unless overrides[:unsaved]
  [fixture, attempt]
end

Dir.mktmpdir do |root|
  fixture, attempt = audited_verify(root, omit: true)
  rejected("must record an ac_audit") { fixture.coordinator.complete("VERIFY", attempt) }
end
Dir.mktmpdir do |root|
  fixture, attempt = audited_verify(root, "candidate_sha" => SHA)
  rejected("must audit the current candidate") { fixture.coordinator.complete("VERIFY", attempt) }
end
Dir.mktmpdir do |root|
  unmet = {"clause_id" => "constraint:no-false-name", "verdict" => "unmet", "reason" => "A mapped Project is named."}
  fixture, attempt = audited_verify(root, "clauses" => [
    {"clause_id" => "outcome:named", "verdict" => "met", "evidence" => [{"ref" => "app/fix.rb:12", "note" => "named"}]}, unmet
  ])
  rejected("unmet criteria: constraint:no-false-name") { fixture.coordinator.complete("VERIFY", attempt) }
end
Dir.mktmpdir do |root|
  fixture, attempt = audited_verify(root)
  fixture.coordinator.complete("VERIFY", attempt)
  assert(fixture.runnable.include?("PUBLISH"), "an audited VERIFY should unlock PUBLISH")
end
TESTS << "a green VERIFY needs an ac_audit of the current candidate with nothing unmet"

def spec_audited_verify(root, spec_audit)
  fixture, attempt = audited_verify(root, unsaved: true)
  head = fixture.git("rev-parse", "HEAD").strip
  fixture.verify(attempt, head, {"failures" => 0}.merge(fixture.audit(head)).merge("spec_audit" => spec_audit.call(fixture, head)))
  [fixture, attempt]
end

Dir.mktmpdir do |root|
  fixture, attempt = spec_audited_verify(root, ->(f, head) { f.spec_audit(head, "classes" => ["restates_literal"]) })
  rejected("spec/regression_spec.rb:1 (restates_literal)") { fixture.coordinator.complete("VERIFY", attempt) }
end
Dir.mktmpdir do |root|
  fixture, attempt = spec_audited_verify(root, ->(f, head) { f.spec_audit(head).merge("specs" => []) })
  rejected("no entry for changed spec file(s): spec/regression_spec.rb") { fixture.coordinator.complete("VERIFY", attempt) }
end
Dir.mktmpdir do |root|
  fixture, attempt = spec_audited_verify(root, ->(f, head) { f.spec_audit(head).merge("base_sha" => head, "specs" => []) })
  rejected("must diff against the run's base") { fixture.coordinator.complete("VERIFY", attempt) }
end
TESTS << "the coordinator refuses a green VERIFY whose spec_audit flags a spec, skips a changed spec, or picks its own base"

def checked_put(fixture, attempt, head, content, replaces: nil, reason: nil)
  metadata = {
    "family" => "verification", "node" => "VERIFY", "attempt_id" => attempt, "producer" => "repro-test",
    "input_sha" => head, "candidate_sha" => head, "content_type" => "application/json", "wake_id" => nil,
    "perspective" => "automated_check", "covered_outcomes" => ["outcome:named"]
  }
  fixture.coordinator.put_artifact(metadata, JSON.generate(content), replaces: replaces, reason: reason)
end

def current_verifications(fixture, attempt)
  fixture.coordinator.send(:load_state).fetch("artifacts").select do |artifact|
    artifact["family"] == "verification" && artifact["attempt_id"] == attempt && artifact["status"] == "current"
  end
end

Dir.mktmpdir do |root|
  fixture, attempt = audited_verify(root, unsaved: true)
  head = fixture.git("rev-parse", "HEAD").strip
  bad = fixture.audit(head)
  bad["ac_audit"]["clauses"][0]["evidence"] = {"ref" => "app/fix.rb:12", "note" => "an object, not an array"}
  rejected("ac_audit clause 1 evidence must be an array") { checked_put(fixture, attempt, head, bad) }
  rejected("unknown class(es) nitpick") do
    checked_put(fixture, attempt, head, fixture.audit(head).merge("spec_audit" => fixture.spec_audit(head, "classes" => ["nitpick"])))
  end
  rejected("no entry for changed spec file(s): spec/regression_spec.rb") do
    checked_put(fixture, attempt, head, fixture.audit(head).merge("spec_audit" => fixture.spec_audit(head).merge("specs" => [])))
  end
  unmet = fixture.audit(head, "clauses" => [
    {"clause_id" => "outcome:named", "verdict" => "unmet", "reason" => "Still generic."},
    {"clause_id" => "constraint:no-false-name", "verdict" => "met", "evidence" => [{"ref" => "a.rb:1", "note" => "n"}]}
  ])
  red = checked_put(fixture, attempt, head, {"failures" => 1}.merge(unmet))
  rejected("already has current verification #{red.fetch('artifact_id')}") { checked_put(fixture, attempt, head, fixture.audit(head)) }
  replaced = checked_put(fixture, attempt, head, {"failures" => 0}.merge(fixture.audit(head)), replaces: red.fetch("artifact_id"),
                         reason: "audit rerun after the fix")
  assert(current_verifications(fixture, attempt).map { |artifact| artifact["artifact_id"] } == [replaced.fetch("artifact_id")],
         "replace must leave exactly the corrected artifact current")
  fixture.coordinator.complete("VERIFY", attempt)
end
TESTS << "a malformed audit is refused when saved, a red audit saves, and a correction replaces instead of duplicating"

Dir.mktmpdir do |root|
  fixture, attempt = audited_verify(root, unsaved: true)
  head = fixture.git("rev-parse", "HEAD").strip
  flagged = fixture.audit(head).merge("spec_audit" => fixture.spec_audit(head, "classes" => ["mocks_subject"]))
  checked_put(fixture, attempt, head, {"failures" => 1}.merge(flagged))
  fixture.coordinator.fail("VERIFY", attempt, reason: "spec mocks its subject", findings: 1,
                                              failure_id: "spec-audit:mocks_subject:spec/regression_spec.rb:1",
                                              revision: "verify-1")
  assert(fixture.runnable.include?("BUILD"), "a flagged spec_audit should route the run back to BUILD")
end
TESTS << "a flagged spec_audit saves on a red VERIFY and routes to BUILD"

Dir.mktmpdir do |root|
  fixture = Fixture.new(root)
  attempt, head = fixture.build_reproduced_fix
  proof = {"regression" => {
    "spec" => "spec/regression_spec.rb -e 'names the dimension'",
    "base" => {"sha" => fixture.sha, "result" => "fail", "excerpt" => "1 example, 1 failure"},
    "candidate" => {"sha" => head, "result" => "pass", "excerpt" => "1 example, 0 failures"}
  }}
  rejected("regression spec must be a file path, not a command or filter") do
    checked_put(fixture, attempt, head, {"failures" => 0}.merge(fixture.audit(head)).merge(proof))
  end
  proof["regression"]["spec"] = "spec/regression_spec.rb"
  proof["regression"]["candidate"]["result"] = "fail"
  checked_put(fixture, attempt, head, {"failures" => 1}.merge(fixture.audit(head)).merge(proof))
  assert(current_verifications(fixture, attempt).one?, "a red regression run saves at put time")
end
TESTS << "a regression spec given as a command is refused at save time, while a red run still saves"

Dir.mktmpdir do |root|
  fixture, attempt = audited_verify(root, unsaved: true)
  head = fixture.git("rev-parse", "HEAD").strip
  stale = fixture.verify(attempt, head, {"failures" => 0, "ac_audit" => []}).fetch("artifact_id")
  good = fixture.verify(attempt, head, {"failures" => 0}.merge(fixture.audit(head))).fetch("artifact_id")
  rejected("requires one current verification output") { fixture.coordinator.complete("VERIFY", attempt) }
  rejected("an artifact cannot supersede itself") { fixture.coordinator.supersede_duplicate("VERIFY", attempt, stale: good, replacement: good, reason: "x") }
  rejected("the replacement must be the newer artifact") { fixture.coordinator.supersede_duplicate("VERIFY", attempt, stale: good, replacement: stale, reason: "x") }
  rejected("needs a reason") { fixture.coordinator.supersede_duplicate("VERIFY", attempt, stale: stale, replacement: good, reason: " ") }
  fixture.coordinator.supersede_duplicate("VERIFY", attempt, stale: stale, replacement: good, reason: "array-form ac_audit")
  fixture.coordinator.complete("VERIFY", attempt)
  assert(fixture.runnable.include?("PUBLISH"), "a recovered VERIFY should unlock PUBLISH")
end
TESTS << "supersede recovers an attempt that already holds two current outputs, and only in the newer direction"

TESTS.each_with_index { |name, index| puts "ok #{index + 1}: #{name}" }
puts "#{TESTS.length} repro tests passed"
RUBY
