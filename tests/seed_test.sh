#!/usr/bin/env bash

set -euo pipefail

TEST_ROOT=$(cd "$(dirname "$0")/.." && pwd)

ruby -I"$TEST_ROOT/scripts" <<'RUBY'
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "seed_runtime"

RUN_ID = "11111111-1111-4111-8111-111111111111"
SHA = "a" * 40

def assert(value, message)
  raise "FAIL: #{message}" unless value
end

def assert_error(fragment)
  begin
    yield
  rescue PrGraph::SeedContract::SeedError => error
    assert(error.message.include?(fragment), "expected #{fragment.inspect}, got #{error.message.inspect}")
    return
  end
  raise "FAIL: expected error containing #{fragment.inspect}"
end

def plan(ruby_body: "seed.stable_key(\"record\")", scenarios: nil)
  {
    "schema_version" => 1,
    "run_id" => RUN_ID,
    "candidate_sha" => SHA,
    "target" => {"kind" => "review_app", "locator" => "pr:351"},
    "scenarios" => scenarios || [{"id" => "browser-1", "description" => "seed an invoice", "ruby" => ruby_body}]
  }
end

def result(plan, status: "succeeded", action: "created", changed: true, created: true)
  contract = PrGraph::SeedContract.new
  scenario = plan.fetch("scenarios").first
  mutation = {
    "kind" => "record",
    "identity" => "Invoice:7",
    "action" => action,
    "created" => created,
    "changed" => changed,
    "previous" => nil,
    "current" => {"id" => 7},
    "cleanup" => "delete Invoice:7"
  }
  cleanup_action = {
    "kind" => "record",
    "identity" => "Invoice:7",
    "instruction" => "delete Invoice:7",
    "status" => changed ? "pending" : "not_needed"
  }
  {
    "schema_version" => 1,
    "run_id" => plan.fetch("run_id"),
    "candidate_sha" => plan.fetch("candidate_sha"),
    "target" => plan.fetch("target"),
    "status" => status,
    "observed_at" => "2026-09-08T12:00:00.000000Z",
    "scenarios" => [{
      "id" => scenario.fetch("id"),
      "description" => scenario.fetch("description"),
      "idempotency_key" => contract.stable_key(plan.fetch("run_id"), scenario.fetch("id"), "scenario"),
      "status" => status == "failed" ? "failed" : "succeeded",
      "mutations" => [mutation]
    }],
    "cleanup" => {
      "required" => status == "succeeded" && changed,
      "status" => status == "failed" ? "restored" : changed ? "available" : "not_required",
      "actions" => [cleanup_action.merge("status" => status == "failed" ? "rolled_back" : cleanup_action["status"])],
      "residuals" => []
    },
    "error" => status == "failed" ? {"class" => "SeedFailure", "message" => "forced"} : nil
  }
end

contract = PrGraph::SeedContract.new
first = contract.stable_key(RUN_ID, "browser-1", "invoice")
assert(first == contract.stable_key(RUN_ID, "browser-1", "invoice"), "stable key changed")
assert(first != contract.stable_key(RUN_ID, "browser-2", "invoice"), "scenario identity did not affect stable key")
assert(first.start_with?("prg-"), "stable key lacks its namespace")
puts "ok 1 - derives stable idempotency keys from run, scenario, and label"

duplicate = plan(scenarios: [
  {"id" => "browser-1", "description" => "one", "ruby" => "seed.stable_key(\"one\")"},
  {"id" => "browser-1", "description" => "two", "ruby" => "seed.stable_key(\"two\")"}
])
assert_error("duplicate seed scenario") { contract.validate_plan!(duplicate) }
assert_error("scenario id is invalid") do
  contract.validate_plan!(plan(scenarios: [{"id" => "../bad", "description" => "bad", "ruby" => "puts 1"}]))
end
puts "ok 2 - rejects invalid and duplicate scenarios before rendering"

Dir.mktmpdir do |directory|
  seed_plan = plan
  script_path = File.join(directory, "runner.rb")
  manifest_path = File.join(directory, "manifest.json")
  calls = []
  remote = result(seed_plan)
  runtime = PrGraph::SeedRuntime.new(
    command_runner: lambda do |command, script|
      calls << [command, script]
      [PrGraph::SeedRuntime::RESULT_MARKER + JSON.generate(remote) + "\n", "", 0]
    end,
    clock: -> { Time.utc(2026, 9, 8, 12, 0, 0) }
  )
  prepared = runtime.prepare(plan: seed_plan, script_path: script_path, manifest_path: manifest_path)
  assert(prepared["status"] == "prepared", "active plan was not prepared")
  assert(Digest::SHA256.file(script_path).hexdigest == prepared["script_sha256"], "prepared hash is wrong")
  assert(calls.empty?, "prepare invoked the runner")

  assert_error("approval SHA is required") do
    runtime.execute(
      plan: seed_plan, script_path: script_path, manifest_path: manifest_path,
      approved_sha: nil, command: ["fake-runner"]
    )
  end
  assert(calls.empty?, "unapproved seed invoked the runner")
  assert_error("approval SHA does not match") do
    runtime.execute(
      plan: seed_plan, script_path: script_path, manifest_path: manifest_path,
      approved_sha: "0" * 64, command: ["fake-runner"]
    )
  end
  assert(calls.empty?, "mismatched approval invoked the runner")
  File.open("#{manifest_path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
    lock.flock(File::LOCK_EX)
    assert_error("another seed process") do
      runtime.execute(
        plan: seed_plan, script_path: script_path, manifest_path: manifest_path,
        approved_sha: prepared.fetch("script_sha256"), command: ["fake-runner"]
      )
    end
  end
  assert(calls.empty?, "concurrent seed ownership invoked the runner")
  puts "ok 3 - prepares an exact script and refuses unapproved mutation"

  complete = runtime.execute(
    plan: seed_plan, script_path: script_path, manifest_path: manifest_path,
    approved_sha: prepared.fetch("script_sha256"), command: ["bin/ops", "review-app", "runner", "--pr", "351"]
  )
  assert(calls.length == 1, "execute made more than one runner call")
  assert(calls.first.last == File.binread(script_path), "runner did not receive the approved bytes")
  assert(complete["status"] == "succeeded", "successful remote result was not persisted")
  assert(complete.dig("runner", "invocation_count") == 1, "runner invocation count is wrong")
  assert(complete.dig("cleanup", "required"), "successful mutation lost cleanup requirements")
  contract.validate_manifest!(JSON.parse(File.binread(manifest_path)), plan: seed_plan)
  puts "ok 4 - invokes one runner call and persists mutation and cleanup evidence"

  remote = result(seed_plan, action: "reused", changed: false, created: false)
  rerun = runtime.execute(
    plan: seed_plan, script_path: script_path, manifest_path: manifest_path,
    approved_sha: prepared.fetch("script_sha256"), command: ["fake-runner"]
  )
  mutation = rerun.dig("scenarios", 0, "mutations", 0)
  assert(calls.length == 2, "rerun did not use exactly one additional runner call")
  assert(mutation["created"] && mutation["changed"], "rerun erased the original cleanup baseline")
  assert(mutation["action"] == "created", "rerun replaced original creation identity")
  assert(rerun.dig("cleanup", "required"), "rerun erased the pending cleanup action")
  assert(rerun.dig("cleanup", "actions", 0, "status") == "pending", "rerun marked original cleanup unnecessary")
  puts "ok 5 - reuses stable records while retaining the original cleanup baseline"
end

Dir.mktmpdir do |directory|
  no_op = plan(ruby_body: nil)
  calls = 0
  runtime = PrGraph::SeedRuntime.new(command_runner: ->(*) { calls += 1 })
  prepared = runtime.prepare(
    plan: no_op,
    script_path: File.join(directory, "runner.rb"),
    manifest_path: File.join(directory, "manifest.json")
  )
  complete = runtime.execute(
    plan: no_op,
    script_path: File.join(directory, "runner.rb"),
    manifest_path: File.join(directory, "manifest.json"),
    approved_sha: nil,
    command: []
  )
  assert(prepared["status"] == "no_op" && complete["status"] == "no_op", "empty seed did not remain a no-op")
  assert(calls.zero?, "no-op seed invoked a runner")
  puts "ok 6 - skips approval and runner access when no scenario needs mutation"
end

Dir.mktmpdir do |directory|
  seed_plan = plan
  script_path = File.join(directory, "runner.rb")
  manifest_path = File.join(directory, "manifest.json")
  failed_remote = result(seed_plan, status: "failed")
  runtime = PrGraph::SeedRuntime.new(
    command_runner: ->(*) { [PrGraph::SeedRuntime::RESULT_MARKER + JSON.generate(failed_remote) + "\n", "app error", 1] }
  )
  prepared = runtime.prepare(plan: seed_plan, script_path: script_path, manifest_path: manifest_path)
  failed = runtime.execute(
    plan: seed_plan, script_path: script_path, manifest_path: manifest_path,
    approved_sha: prepared.fetch("script_sha256"), command: ["fake-runner"]
  )
  assert(failed["status"] == "failed", "remote failure was not fail-closed")
  assert(failed.dig("cleanup", "status") == "restored", "rollback evidence was lost")
  assert(failed.dig("runner", "exit_status") == 1, "failure exit was not retained")
  puts "ok 7 - retains rollback evidence and a failing status after app errors"
end

Dir.mktmpdir do |directory|
  seed_plan = plan
  script_path = File.join(directory, "runner.rb")
  manifest_path = File.join(directory, "manifest.json")
  runtime = PrGraph::SeedRuntime.new(command_runner: ->(*) { ["eks login required\n", "Forbidden", 1] })
  prepared = runtime.prepare(plan: seed_plan, script_path: script_path, manifest_path: manifest_path)
  uncertain = runtime.execute(
    plan: seed_plan, script_path: script_path, manifest_path: manifest_path,
    approved_sha: prepared.fetch("script_sha256"), command: ["fake-runner"]
  )
  assert(uncertain["status"] == "uncertain", "missing remote manifest did not fail closed")
  assert(uncertain.dig("cleanup", "status") == "unknown", "unknown remote state was not retained")
  assert(uncertain.dig("cleanup", "residuals").any?, "unknown remote state lacks a residual report")
  puts "ok 8 - persists an unknown cleanup report for EKS or runner failures"
end

Dir.mktmpdir do |directory|
  seed_plan = plan
  script_path = File.join(directory, "runner.rb")
  manifest_path = File.join(directory, "manifest.json")
  malformed = result(seed_plan).merge("run_id" => "22222222-2222-4222-8222-222222222222")
  runtime = PrGraph::SeedRuntime.new(
    command_runner: ->(*) { [PrGraph::SeedRuntime::RESULT_MARKER + JSON.generate(malformed) + "\n", "", 0] }
  )
  prepared = runtime.prepare(plan: seed_plan, script_path: script_path, manifest_path: manifest_path)
  uncertain = runtime.execute(
    plan: seed_plan, script_path: script_path, manifest_path: manifest_path,
    approved_sha: prepared.fetch("script_sha256"), command: ["fake-runner"]
  )
  assert(uncertain["status"] == "uncertain", "identity drift did not fail closed")
  assert(uncertain.dig("error", "message").include?("identity"), "contract failure was not persisted")
  assert(JSON.parse(File.binread(manifest_path))["status"] == "uncertain", "running state survived malformed output")
  puts "ok 9 - converts malformed or identity-drifted remote output into durable uncertainty"
end

Dir.mktmpdir do |directory|
  seed_plan = plan
  script_path = File.join(directory, "runner.rb")
  manifest_path = File.join(directory, "manifest.json")
  remote = result(seed_plan)
  runtime = PrGraph::SeedRuntime.new(
    command_runner: ->(*) { [PrGraph::SeedRuntime::RESULT_MARKER + JSON.generate(remote) + "\n", "scale-down failed", 1] }
  )
  prepared = runtime.prepare(plan: seed_plan, script_path: script_path, manifest_path: manifest_path)
  uncertain = runtime.execute(
    plan: seed_plan, script_path: script_path, manifest_path: manifest_path,
    approved_sha: prepared.fetch("script_sha256"), command: ["fake-runner"]
  )
  assert(uncertain["status"] == "uncertain", "contradictory success and exit status was trusted")
  assert(uncertain.dig("scenarios", 0, "mutations").length == 1, "known remote mutation evidence was discarded")
  assert(uncertain.dig("cleanup", "actions", 0, "status") == "unknown", "cleanup was not marked unknown")
  puts "ok 10 - retains known mutations when a contradictory runner exit makes cleanup uncertain"
end

Dir.mktmpdir do |directory|
  seed_plan = plan
  plan_path = File.join(directory, "plan.json")
  script_path = File.join(directory, "runner.rb")
  manifest_path = File.join(directory, "manifest.json")
  fake_runner = File.join(directory, "fake-runner.rb")
  call_log = File.join(directory, "calls.log")
  File.write(plan_path, JSON.generate(seed_plan))
  remote = result(seed_plan, status: "failed")
  File.write(fake_runner, <<~RUBY)
    File.open(#{call_log.dump}, "a") { |file| file.puts(ARGV.length) }
    puts #{(PrGraph::SeedRuntime::RESULT_MARKER + JSON.generate(remote)).dump}
    exit 1
  RUBY
  runtime = PrGraph::SeedRuntime.new
  prepared = runtime.prepare(plan: seed_plan, script_path: script_path, manifest_path: manifest_path)
  cli = File.join($LOAD_PATH.first, "seed.rb")
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby, cli, "execute",
    "--plan", plan_path, "--script", script_path, "--manifest", manifest_path,
    "--approved-sha", prepared.fetch("script_sha256"), "--",
    RbConfig.ruby, fake_runner
  )
  assert(!status.success?, "seed CLI returned zero for a reported mutation failure")
  assert(File.readlines(call_log).length == 1, "seed CLI made more than one runner call")
  assert(JSON.parse(stdout)["status"] == "failed", "seed CLI did not return the failure manifest: #{stderr}")
  puts "ok 11 - returns nonzero from the CLI after exactly one failing runner call"
end

Dir.mktmpdir do |directory|
  failing_plan = plan(ruby_body: <<~'BODY')
    seed.ensure_record(
      label: "invoice",
      find: ->(key) { FakeRecord.find_by_key(key) },
      create: ->(key) { FakeRecord.create(key) }
    )
    seed.enable_flag(label: "demo-flag", name: :demo)
    raise "forced"
  BODY
  runtime = PrGraph::SeedRuntime.new
  script = runtime.render(failing_plan)
  prelude = <<~'RUBY'
    module FakeStore
      class << self
        attr_accessor :records, :flags
      end
      self.records = {}
      self.flags = {}
    end
    module ActiveRecord
      class Base
        def self.transaction
          snapshot = FakeStore.records.dup
          yield
        rescue StandardError
          FakeStore.records = snapshot
          raise
        end
      end
    end
    class FakeRecord
      attr_reader :id, :key
      def self.find_by_key(key)
        FakeStore.records[key]
      end
      def self.create(key)
        record = new(key)
        FakeStore.records[key] = record
        record
      end
      def initialize(key)
        @key = key
        @id = 7
      end
      def persisted?
        true
      end
      def attributes
        {"id" => id, "key" => key}
      end
    end
    module Flipper
      def self.enabled?(name, _actor = nil)
        FakeStore.flags.fetch(name, false)
      end
      def self.enable(name, _actor = nil)
        FakeStore.flags[name] = true
      end
      def self.disable(name, _actor = nil)
        FakeStore.flags[name] = false
      end
    end
    eval(ARGV.fetch(0), TOPLEVEL_BINDING, "approved-seed.rb")
  RUBY
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", prelude, script)
  assert(!status.success?, "rendered runner hid scenario failure")
  line = stdout.lines.find { |candidate| candidate.start_with?(PrGraph::SeedRuntime::RESULT_MARKER) }
  assert(line, "rendered runner omitted its failure manifest: #{stderr}")
  remote = JSON.parse(line.delete_prefix(PrGraph::SeedRuntime::RESULT_MARKER))
  actions = remote.dig("cleanup", "actions")
  assert(remote["status"] == "failed", "rendered runner reported failure as success")
  assert(actions.any? { |action| action["kind"] == "record" && action["status"] == "rolled_back" }, "DB rollback missing")
  assert(actions.any? { |action| action["kind"] == "flag" && action["status"] == "restored" }, "flag restoration missing")
  assert(remote.dig("cleanup", "residuals").empty?, "successful restoration left residuals")
  puts "ok 12 - rolls back database work and restores nontransactional changes on failure"
end

Dir.mktmpdir do |directory|
  failing_plan = plan(ruby_body: <<~'BODY')
    seed.nontransactional(
      label: "external",
      kind: "remote_setting",
      identity: "setting:7",
      previous: "old",
      cleanup: "restore setting:7 to old",
      apply: -> { "new" },
      restore: -> { raise "restore denied" }
    )
    raise "forced"
  BODY
  runtime = PrGraph::SeedRuntime.new
  script = runtime.render(failing_plan)
  prelude = <<~'RUBY'
    module ActiveRecord
      class Base
        def self.transaction
          yield
        end
      end
    end
    eval(ARGV.fetch(0), TOPLEVEL_BINDING, "approved-seed.rb")
  RUBY
  stdout, _stderr, status = Open3.capture3(RbConfig.ruby, "-e", prelude, script)
  assert(!status.success?, "restore failure returned success")
  line = stdout.lines.find { |candidate| candidate.start_with?(PrGraph::SeedRuntime::RESULT_MARKER) }
  remote = JSON.parse(line.delete_prefix(PrGraph::SeedRuntime::RESULT_MARKER))
  assert(remote.dig("cleanup", "status") == "incomplete", "restore failure was not marked incomplete")
  assert(remote.dig("cleanup", "residuals").first.include?("restore denied"), "restore failure lacks a residual")
  puts "ok 13 - preserves residual cleanup evidence when restoration fails"
end
RUBY
