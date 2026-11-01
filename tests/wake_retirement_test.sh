#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ruby -I "${SCRIPT_DIR}/../scripts" <<'RUBY'
require "tmpdir"
require "open3"
require "securerandom"
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

REGISTER = {"outcome_register" => {
  "why" => "Operators need stranded watches cleaned up.",
  "actors" => [{"id" => "actor:dev", "situation" => "Closing a node."}],
  "positive_postconditions" => [{"id" => "outcome:closed", "statement" => "A closed node leaves no live watch."}],
  "negative_face" => [{"id" => "constraint:no-stall", "statement" => "A stranded watch never blocks the run."}],
  "declared_gaps" => []
}}.freeze

# A run whose TRIAGE attempt is open with one registered wake.
class Run
  attr_reader :coordinator, :events, :attempt, :wake_id

  def initialize(root)
    worktree = File.join(root, "worktree")
    FileUtils.mkdir_p(worktree)
    Open3.capture3("git", "-C", worktree, "init", "-q")
    Open3.capture3("git", "-C", worktree, "-c", "user.name=t", "-c", "user.email=t@example.test", "-c", "core.hooksPath=/dev/null",
                   "commit", "--allow-empty", "-qm", "fixture")
    sha = Open3.capture3("git", "-C", worktree, "rev-parse", "HEAD").first.strip
    @events = File.join(root, "run.jsonl")
    @identity = {execution_path: @events, run_id: SecureRandom.uuid, session: SecureRandom.uuid}
    PrGraph::EventLog.new.emit(@events, **@identity.slice(:run_id, :session),
                              payload: {"e" => "run_start", "ticket" => "DEMO-887", "entry" => "ticket"})
    @coordinator = PrGraph::Coordinator.new(**@identity)
    @attempt = coordinator.start("TRIAGE", worktree: nil).fetch("attempt_id")
    @wake_id = coordinator.wake("TRIAGE", attempt, kind: "timer", state: "registered").fetch("wake_id")
    PrGraph::ArtifactLog.new.store(@events.sub(/\.jsonl\z/, ".artifacts.jsonl"), **@identity, metadata: {
      "family" => "triage_brief", "node" => "TRIAGE", "attempt_id" => attempt, "producer" => "wake-test",
      "input_sha" => sha, "candidate_sha" => sha, "content_type" => "application/json", "wake_id" => nil,
      "perspective" => "author", "covered_outcomes" => []
    }, content: JSON.generate(REGISTER))
  end

  def wake_states
    PrGraph::EventLog.new.validate_file!(events).select { |e| e["e"] == "wake" }.map { |e| e["state"] }
  end

  def emit(payload)
    PrGraph::EventLog.new.emit(events, **@identity.slice(:run_id, :session), payload: payload)
  end
end

Dir.mktmpdir do |root|
  run = Run.new(root)
  rejected("still has live wake(s) #{run.wake_id} (registered)") { run.coordinator.complete("TRIAGE", run.attempt) }
  assert(run.wake_states == ["registered"], "a refused completion must not write anything")
  run.coordinator.complete("TRIAGE", run.attempt, cancel_live_wakes: true)
  assert(run.wake_states == %w[registered armed cancelled], "a registered wake is armed then cancelled as the attempt closes")
end
TESTS << "an attempt cannot close with a live wake unless it cancels it in the same transition"

Dir.mktmpdir do |root|
  run = Run.new(root)
  run.coordinator.wake("TRIAGE", run.attempt, kind: "timer", state: "armed", wake_id: run.wake_id)
  run.coordinator.complete("TRIAGE", run.attempt, cancel_live_wakes: true)
  assert(run.wake_states == %w[registered armed cancelled], "an armed wake is cancelled directly")
end
TESTS << "an armed wake is cancelled without a second arm"

Dir.mktmpdir do |root|
  run = Run.new(root)
  run.coordinator.wake("TRIAGE", run.attempt, kind: "timer", state: "armed", wake_id: run.wake_id)
  run.coordinator.wake("TRIAGE", run.attempt, kind: "timer", state: "fired", wake_id: run.wake_id)
  run.coordinator.complete("TRIAGE", run.attempt)
  assert(run.wake_states == %w[registered armed fired], "a fired wake needs no cancellation")
end
TESTS << "an attempt whose wakes all finished closes normally"

Dir.mktmpdir do |root|
  run = Run.new(root)
  run.coordinator.complete("TRIAGE", run.attempt, cancel_live_wakes: true)
  # A run recorded before this rule: a closed attempt holding a wake that never armed.
  stranded = SecureRandom.uuid
  run.emit({"e" => "wake", "node" => "TRIAGE", "attempt_id" => run.attempt, "wake_id" => stranded,
            "kind" => "ci", "state" => "registered"})
  rejected("needs a reason") { run.coordinator.reap_wakes(reason: " ") }
  result = run.coordinator.reap_wakes(reason: "stranded by a pre-2.8 CI-WATCH attempt")
  assert(result.fetch("reaped") == [stranded], "reap-wakes must cancel exactly the stranded wake")
  assert(run.wake_states.last(2) == %w[armed cancelled], "the stranded wake is armed then cancelled")
  assert(run.coordinator.reap_wakes(reason: "again").fetch("reaped").empty?, "a second reap finds nothing")
end
TESTS << "reap-wakes cancels wakes stranded on closed attempts and leaves the rest alone"

Dir.mktmpdir do |root|
  run = Run.new(root)
  assert(run.coordinator.reap_wakes(reason: "sweep").fetch("reaped").empty?, "a wake on an open attempt is never reaped")
end
TESTS << "reap-wakes never touches an open attempt's wakes"

TESTS.each_with_index { |name, index| puts "ok #{index + 1}: #{name}" }
puts "#{TESTS.length} wake retirement tests passed"
RUBY
