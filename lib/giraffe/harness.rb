# frozen_string_literal: true

require "json"
require_relative "run"
require_relative "git"
require_relative "checks"
require_relative "model"
require_relative "mutation_runner"
require_relative "screen_checks"
require_relative "runners"
require_relative "steps/preparation"
require_relative "steps/build"
require_relative "steps/verify"
require_relative "steps/publish"

module Giraffe
  # First vertical slice: the existing graph owns transitions through PUBLISH. Later gates remain
  # visibly incomplete. No model chooses a node, runs a check, commits or publishes.
  class Harness
    include Steps::Preparation
    include Steps::Build
    include Steps::Verify
    include Steps::Publish
    ORDER = %w[TRIAGE WORKTREE INVESTIGATE REPRODUCE PLAN BUILD VERIFY PUBLISH].freeze

    def initialize(run, runner: nil, checks: nil, github: nil)
      @run = run
      command = Command.new(cancelled: -> { run.cancel_requested? })
      @git = Git.new(command: command)
      @checks = checks || Checks.new(run.config, command: command)
      @github = github || PrGraph::GitHubPrCi.new
      @model = Model.new(run, runner || Runners.for(run, command: command), git: @git)
    end

    def run
      @run.lock do
        raise Cancelled, "run cancelled" if cancelled?
        return @run.state if @run.state["status"] == "draft_pr"
        return @run.state if @run.state["questions"].any?
        @run.update(status: "running", error: nil)
        loop do
          raise Cancelled, "run cancelled" if cancelled?
          projection = replayed_projection
          if state["published"]
            @run.update(status: "draft_pr")
            break
          end
          open = projection["open_attempts"].find { |attempt| ORDER.include?(attempt["node"]) }
          node = open ? open["node"] : ORDER.find { |name| projection["runnable"].include?(name) }
          raise Error, "no supported runnable step; inspect coordinator status" unless node
          attempt = open || @run.coordinator.start(node, worktree: protected?(node) ? worktree : nil)
          @attempt = attempt.fetch("attempt_id")
          @node = node
          @model.begin_attempt(@attempt)
          send("step_#{node.downcase}")
          # Also moves the revision on, so this boundary's checkpoint is the one hydrate and restore pick.
          checkpoint("last_step", node)
          @run.sync
        end
      rescue Parked
        # The step remains open; an answer creates a fresh model call with that answer as input.
      rescue Cancelled => error
        @run.update(status: "cancelled", error: error.message)
      rescue StandardError => error
        @run.update(status: "paused", error: PrGraph::ContentScan.redact(error.message))
        @run.sync
        raise
      end
      @run.sync
      @run.state
    end

    private

    def protected?(node) = @run.coordinator.policy.dig("nodes", node, "mutation_guard")
    def cancelled? = @run.state["status"] == "cancelled" || @run.cancel_requested?
    def state = @run.coordinator.snapshot
    def runtime = @run.state.fetch("runtime")
    def checkpoint(key, value) = @run.checkpoint(key, value)
    def worktree = File.join(@run.directory, "worktree")
    def base_sha = runtime.fetch("base_sha") { @git.resolve_commit(@run.config["repo"], @run.config["base"]) }
    def clause_ids = state.dig("outcome_context", "clauses")
    def outcome_contract = @outcome_contract ||= PrGraph::OutcomeContract.new
    def ac_audit_contract = @ac_audit_contract ||= PrGraph::AcAuditContract.new
    def spec_audit_contract = @spec_audit_contract ||= PrGraph::SpecAuditContract.new
    def read_only_checks(commands = @run.config["checks"]) = @git.read_only(worktree) { @checks.run(worktree, commands) }

    def artifact_record(family)
      records = state.fetch("artifacts").select { |row| row["family"] == family && row["status"] == "current" }
      raise Error, "expected one current #{family}" unless records.one?
      records.first
    end

    def evidence(record) = outcome_contract.read_artifact!(record, artifact_path: @run.path)
    def artifact(family) = evidence(artifact_record(family))
    def attempted_record(family) = state["artifacts"].find { |row| row["family"] == family && row["attempt_id"] == @attempt }

    def attempted_artifact(family)
      record = attempted_record(family)
      record && evidence(record)
    end

    def put(family, content, candidate: nil, perspective: "author", covered: [])
      existing = attempted_record(family)
      if existing
        raise Error, "recovery would replace #{family} with different evidence" unless evidence(existing) == content && existing["candidate_sha"] == candidate
        return existing
      end
      @run.coordinator.put_artifact({
          "family" => family, "node" => @node, "attempt_id" => @attempt, "producer" => "giraffe-harness",
          "input_sha" => candidate || base_sha, "candidate_sha" => candidate, "content_type" => "application/json",
          "wake_id" => nil, "perspective" => perspective, "covered_outcomes" => covered}, JSON.generate(content))
    end

    def finish(**options) = @run.coordinator.complete(@node, @attempt, **options)

    def ask(role, inputs, cwd: worktree, writable: false, unit: "main", &accept)
      request = Model::Request.new(role: role, attempt: @attempt, unit: unit, cwd: cwd, writable: writable,
                                   inputs: {"ticket" => @run.state["ticket"]}.merge(inputs))
      @model.call(request, &accept)
    end

    # What a step has no edit or evidence for is a person's to settle. The step stays open; the answer reaches its next call.
    def ask_a_person(id, text)
      @run.update(status: "waiting_for_answers", questions: [{"id" => id, "text" => text, "role" => @node.downcase, "attempt_id" => @attempt}])
      raise Parked, "waiting for a person's answer"
    end

    # The graph after finishing any result a crash left half recorded.
    def replayed_projection
      projection = @run.coordinator.check(offline: true)
      partial = projection.dig("recovery", "partial_results")
      return projection if partial.empty?
      partial.each do |result|
        arguments = result.fetch("retry")
        @run.coordinator.public_send(arguments.fetch("command"), result.fetch("node"), result.fetch("attempt_id"), **arguments.except("command").transform_keys(&:to_sym))
      end
      @run.coordinator.check(offline: true)
    end
  end
end
