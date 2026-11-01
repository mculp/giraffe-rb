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

class InterruptedBuildLog < PrGraph::EventLog
  def emit_many(path, **options)
    if options.fetch(:payloads).any? { |event| event.values_at("e", "node", "phase") == %w[node BUILD done] }
      raise PrGraph::ContractError, "fixture interruption before BUILD completion"
    end
    super
  end
end

class LegacyFixture
  attr_reader :coordinator, :worktree, :sha, :events, :build_attempt

  def initialize(root, interrupt_build: false)
    @root = root
    @worktree = File.join(root, "worktree")
    FileUtils.mkdir_p(worktree)
    git("init", "-q")
    git("config", "user.name", "PR Graph Test")
    git("config", "user.email", "pr-graph@example.test")
    git("-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "fixture")
    @sha = git("rev-parse", "HEAD").strip
    @events = File.join(root, "run.jsonl")
    @identity = {execution_path: events, run_id: SecureRandom.uuid, session: SecureRandom.uuid}
    @artifacts = events.sub(/\.jsonl\z/, ".artifacts.jsonl")
    PrGraph::EventLog.new.emit(events, **@identity.slice(:run_id, :session),
                              payload: {"e" => "run_start", "ticket" => "DEMO-768", "entry" => "ticket"})

    # Persist the v1 policy shape that completed BUILD before independent review.
    policy = PrGraph::Coordinator.new(**@identity).policy
    policy.fetch("nodes").fetch("BUILD")["outputs"] = [{"family" => "build_manifest", "candidate" => "head"}]
    policy.fetch("nodes").fetch("SELF-REVIEW").delete("retired")
    %w[PUBLISH DONE].each do |node|
      policy.fetch("nodes").fetch(node).fetch("inputs").find { |rule| rule["family"] == "self_review" }["pass_required"] = true
    end
    policy_path = File.join(root, "legacy-policy.json")
    File.write(policy_path, JSON.generate(policy))
    event_log = interrupt_build ? InterruptedBuildLog.new : PrGraph::EventLog.new
    @coordinator = PrGraph::Coordinator.new(**@identity, policy_path: policy_path, event_log: event_log)

    finish("TRIAGE", "triage_brief" => {
      "outcome_register" => {
        "why" => "Preserve review evidence when continuing a run.",
        "actors" => [{"id" => "actor:developer", "situation" => "Continuing a run."}],
        "positive_postconditions" => [{"id" => "outcome:review", "statement" => "The candidate is reviewed."}],
        "negative_face" => [{"id" => "constraint:immutable", "statement" => "Historical evidence remains immutable."}],
        "declared_gaps" => []
      }
    })
    finish("INVESTIGATE", "investigation_report" => {})
    finish("WORKTREE", "worktree_manifest" => {})
    finish("REPRODUCE", "repro_report" => {
      "status" => "not_applicable", "base_sha" => sha, "reason" => "Review continuation is not a reported defect."
    })
    finish("PLAN", "implementation_plan" => {"steps" => [{
      "id" => "step:review", "classification" => "AMEND", "intent" => "Review the candidate.",
      "outcome_ids" => %w[outcome:review constraint:immutable],
      "evidence" => [
        {"role" => "existing_mechanism", "kind" => "codebase", "ref" => "coordinator_runtime.rb", "claim" => "Review is a protected lane."},
        {"role" => "authorization", "kind" => "ticket", "ref" => "linear:DEMO-768", "claim" => "Continuing this run is authorized."}
      ]
    }]}, "test_plan" => {"coverage" => %w[outcome:review constraint:immutable].map do |id|
      {"outcome_id" => id, "status" => "planned", "planned_node" => "VERIFY", "strategy" => "Exercise resumed review."}
    end})
    @build_attempt = start("BUILD").fetch("attempt_id")
    put("BUILD", build_attempt, "build_manifest")
    if interrupt_build
      rejected("fixture interruption") { coordinator.complete("BUILD", build_attempt) }
    else
      coordinator.complete("BUILD", build_attempt)
    end
  end

  def git(*args)
    output, error, status = Open3.capture3("git", "-C", worktree, *args)
    raise error unless status.success?
    output
  end

  def start(node)
    coordinator.start(node, worktree: worktree)
  end

  def put(node, attempt, family, candidate: sha)
    perspective = {"self_review" => "independent_review", "verification" => "automated_check"}.fetch(family, "author")
    PrGraph::ArtifactLog.new.store(@artifacts, **@identity, metadata: {
      "family" => family, "node" => node, "attempt_id" => attempt,
      "producer" => "legacy-resume-test", "input_sha" => candidate, "candidate_sha" => candidate,
      "content_type" => "application/json", "wake_id" => nil, "perspective" => perspective,
      "covered_outcomes" => perspective == "author" ? [] : %w[outcome:review constraint:immutable]
    }, content: JSON.generate(block_given? ? yield : {}))
  end

  def finish(node, outputs)
    attempt = start(node).fetch("attempt_id")
    outputs.each { |family, content| put(node, attempt, family) { content } }
    coordinator.complete(node, attempt)
    attempt
  end

  def upgrade
    @coordinator = PrGraph::Coordinator.new(**@identity)
  end

  def verification
    candidate = coordinator.send(:current_candidate!, coordinator.send(:load_state))
    evidence = [{"ref" => "example.txt:1", "note" => "fixture evidence"}]
    {"ac_audit" => {
      "candidate_sha" => candidate, "inputs" => ["triage_brief"], "missed" => [],
      "clauses" => %w[outcome:review constraint:immutable].map do |id|
        {"clause_id" => id, "verdict" => "met", "evidence" => evidence}
      end
    }, "spec_audit" => {"candidate_sha" => candidate, "base_sha" => sha, "specs" => []}}
  end

  def resume
    cli = File.join(File.dirname(PrGraph::Coordinator.instance_method(:resume).source_location.first), "coordinate.rb")
    output, error, status = Open3.capture3({"PR_GRAPH_STATE_ROOT" => File.join(@root, "state")},
                                         RbConfig.ruby, cli, "resume-run", events, "--worktree", worktree, "--offline")
    raise error unless status.success?
    JSON.parse(output)
  end

  def snapshot
    Dir.glob(File.join(@root, "run*", "**", "*"))
       .concat(Dir.glob(File.join(@root, "run*")))
       .select { |path| File.file?(path) }.uniq.to_h { |path| [path, File.binread(path)] }
  end

  def assert_preserved(snapshot)
    snapshot.each do |path, content|
      actual = File.binread(path)
      assert(path.end_with?(".jsonl") ? actual.start_with?(content) : actual == content,
             "historical record changed: #{path}")
    end
  end
end

Dir.mktmpdir("legacy-review-resume") do |root|
  fixture = LegacyFixture.new(File.join(root, "unreviewed"))
  historical = fixture.snapshot
  fixture.upgrade
  assert(fixture.resume.fetch("runnable").include?("VERIFY"), "completed BUILD did not resume at VERIFY")
  fixture.finish("VERIFY", "verification" => fixture.verification)
  projection = fixture.resume
  assert(projection.fetch("runnable").include?("SELF-REVIEW"), "legacy BUILD has no runnable review recovery")
  assert(!projection.fetch("runnable").include?("PUBLISH"), "unreviewed candidate can publish")
  fixture.coordinator.check(worktree: fixture.worktree, offline: true)
  rejected("already closed") { fixture.put("BUILD", fixture.build_attempt, "self_review") }
  review = fixture.start("SELF-REVIEW")
  assert(review.fetch("authority") == "read", "recovery review received mutation authority")
  rejected("writer contention") { fixture.start("BUILD") }
  fixture.put("SELF-REVIEW", review.fetch("attempt_id"), "self_review")
  rejected("input artifact self_review is not green") { fixture.start("PUBLISH") }
  fixture.coordinator.complete("SELF-REVIEW", review.fetch("attempt_id"))
  assert(fixture.resume.fetch("runnable").include?("PUBLISH"), "reviewed candidate cannot publish")
  fixture.start("PUBLISH")
  fixture.assert_preserved(historical)
  TESTS << "persisted unreviewed BUILD resumes through a read-only review without rewriting history"

  fixture = LegacyFixture.new(File.join(root, "reviewed"))
  fixture.finish("VERIFY", "verification" => fixture.verification)
  fixture.finish("SELF-REVIEW", "self_review" => {})
  historical = fixture.snapshot
  fixture.upgrade
  assert(fixture.resume.fetch("runnable").include?("PUBLISH"), "completed same-candidate review was not preserved")
  rejected("already current") { fixture.start("SELF-REVIEW") }
  rejected("BUILD has no queued failures") { fixture.start("BUILD") }
  fixture.start("PUBLISH")
  fixture.assert_preserved(historical)
  TESTS << "completed same-candidate legacy review remains valid without another BUILD"

  fixture = LegacyFixture.new(File.join(root, "finding"), interrupt_build: true)
  historical = fixture.snapshot
  fixture.upgrade
  recovery = fixture.resume.dig("recovery", "partial_results")
  assert(recovery.one? && recovery.first["attempt_id"] == fixture.build_attempt, "interrupted BUILD completion was not recovered")
  assert(recovery.first["retry"] == {"command" => "complete", "findings" => 0}, "BUILD retry arguments changed")
  rejected("SELF-REVIEW is retired") { fixture.start("SELF-REVIEW") }
  fixture.git("-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "candidate drift")
  rejected("persisted BUILD completion fingerprint") { fixture.coordinator.complete("BUILD", fixture.build_attempt) }
  fixture.git("checkout", "-q", "--detach", fixture.sha)
  rejected("findings are valid only for a quality node") { fixture.coordinator.complete("BUILD", fixture.build_attempt, findings: 1) }
  fixture.coordinator.complete("BUILD", fixture.build_attempt)
  fixture.assert_preserved(historical)
  TESTS << "interrupted legacy BUILD completion replays its immutable result and rejects candidate or argument drift"
  fixture.finish("VERIFY", "verification" => fixture.verification)
  review = fixture.start("SELF-REVIEW").fetch("attempt_id")
  legacy_review = fixture.put("SELF-REVIEW", review, "self_review")
  File.write(File.join(fixture.worktree, "unauthorized.txt"), "reader edit")
  rejected("without BUILD authority") { fixture.coordinator.complete("SELF-REVIEW", review) }
  File.unlink(File.join(fixture.worktree, "unauthorized.txt"))
  fixture.coordinator.fail("SELF-REVIEW", review, reason: "Missing review proof", failure_id: "failure:review", revision: "review-1")
  rejected("input artifact self_review is not green") { fixture.start("PUBLISH") }
  build = fixture.start("BUILD")
  assert(build.fetch("authority") == "write", "review finding did not grant a normal BUILD lease")
  attempt = build.fetch("attempt_id")
  fixture.put("BUILD", attempt, "build_manifest")
  rejected("requires one current self_review output") { fixture.coordinator.complete("BUILD", attempt) }
  fixture.put("BUILD", attempt, "self_review")
  fixture.coordinator.complete("BUILD", attempt)
  rejected("SELF-REVIEW is retired") { fixture.start("SELF-REVIEW") }
  fixture.finish("VERIFY", "verification" => fixture.verification)
  assert(fixture.resume.fetch("runnable").include?("PUBLISH"), "same-SHA BUILD review conflicts with legacy review")
  artifacts = PrGraph::ArtifactLog.new.validate_file!(fixture.events.sub(/\.jsonl\z/, ".artifacts.jsonl"), execution_path: fixture.events)
  prior_review = artifacts.fetch("artifacts").find { |item| item["artifact_id"] == legacy_review["artifact_id"] }
  assert(prior_review["status"] == "invalidated", "legacy review remained authoritative after BUILD review")
  fixture.assert_preserved(historical)
  TESTS << "review findings retain the red-edge BUILD path and its mandatory review even at the same SHA"

  fixture = LegacyFixture.new(File.join(root, "partial-review"))
  fixture.finish("VERIFY", "verification" => fixture.verification)
  fixture.upgrade
  review = fixture.start("SELF-REVIEW").fetch("attempt_id")
  fixture.put("SELF-REVIEW", review, "self_review", candidate: "a" * 40)
  identity = PrGraph::EventLog.new.validate_file!(fixture.events).first
  PrGraph::EventLog.new.emit(fixture.events, run_id: identity.fetch("run_id"), session: identity.fetch("session"),
                            payload: {"e" => "outcome", "kind" => "self_review", "attempt_id" => review, "pass" => true, "n" => 0})
  rejected("missing current input artifact self_review") { fixture.start("PUBLISH") }
  state = fixture.coordinator.send(:load_state)
  rejected("missing current input artifact self_review") { fixture.coordinator.send(:verify_done_gates!, state, fixture.sha) }
  TESTS << "stale-candidate legacy review cannot satisfy PUBLISH or DONE even with a pass outcome"

  fixture.put("SELF-REVIEW", review, "self_review")
  rejected("input artifact self_review is not green") { fixture.start("PUBLISH") }
  state = fixture.coordinator.send(:load_state)
  rejected("input artifact self_review is not green") { fixture.coordinator.send(:verify_done_gates!, state, fixture.sha) }
  assert(!fixture.resume.fetch("runnable").include?("PUBLISH"), "open producer with a pass outcome can publish")
  TESTS << "open legacy review with a pass outcome cannot satisfy PUBLISH or DONE"
end

TESTS.each_with_index { |name, index| puts "ok #{index + 1}: #{name}" }
puts "#{TESTS.length} legacy review resume tests passed"
RUBY
