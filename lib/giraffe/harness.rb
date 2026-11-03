# frozen_string_literal: true

require_relative "run"
require_relative "git"
require_relative "checks"
require_relative "model"
require_relative "mutation_runner"
require_relative "screen_checks"
require_relative "runners"
require_relative "services"
require_relative "step_context"
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
      @services = Services.new(git: @git, checks: @checks, github: @github, model: @model)
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
          @context = StepContext.new(@run, @services, node, @attempt)
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
    def checkpoint(key, value) = @run.checkpoint(key, value)
    def worktree = File.join(@run.directory, "worktree")

    # What the mixins call. The step that is running has its context answer them.
    def ac_audit_contract = @context.ac_audit_contract
    def spec_audit_contract = @context.spec_audit_contract
    def runtime = @context.runtime
    def base_sha = @context.base_sha
    def clause_ids = @context.clause_ids
    def artifact(family) = @context.artifact(family)
    def artifact_record(family) = @context.artifact_record(family)
    def attempted_artifact(family) = @context.attempted_artifact(family)
    def ask_a_person(id, text) = @context.ask_a_person(id, text)
    def read_only_checks(...) = @context.read_only_checks(...)
    def put(...) = @context.put(...)
    def finish(...) = @context.finish(...)
    def ask(...) = @context.ask(...)

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
