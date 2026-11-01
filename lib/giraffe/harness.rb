# frozen_string_literal: true

require "json"
require "digest"
require_relative "run"
require_relative "git"
require_relative "checks"
require_relative "model"
require_relative "runners/claude"
require_relative "runners/scripted"
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

    def initialize(run, runner: nil, git: nil, checks: nil, github: nil)
      @run = run
      @command = Command.new(cancelled: -> { File.exist?(File.join(run.directory, "cancel.request")) })
      @git = git || Git.new(command: @command)
      @checks = checks || Checks.new(run.config, command: @command)
      @github = github || PrGraph::GitHubPrCi.new
      runner ||= if run.config["runner"] == "scripted"
                   Runners::Scripted.new(run.config["script"], positions: runtime.fetch("script_positions", {}),
                                        on_advance: ->(positions) { checkpoint("script_positions", positions) })
                 else
                   Runners::Claude.new(run.config, command: @command)
                 end
      @model = Model.new(run, runner, git: @git)
    end

    def run
      @run.lock do
        raise Cancelled, "run cancelled" if cancelled?
        return @run.state if @run.state["status"] == "draft_pr"
        return @run.state if @run.state["questions"].any?
        @run.update(status: "running", error: nil)
        loop do
          raise Cancelled, "run cancelled" if cancelled?
          projection = @run.coordinator.check(offline: true)
          replay_results(projection)
          projection = @run.coordinator.check(offline: true)
          if completed?("PUBLISH")
            @run.update(status: "draft_pr")
            break
          end
          open = projection["open_attempts"].find { |attempt| ORDER.include?(attempt["node"]) }
          node = open ? open["node"] : ORDER.find { |name| projection["runnable"].include?(name) }
          raise Error, "no supported runnable step; inspect coordinator status" unless node
          # Dry run is a persisted planning stop. Resuming it never enters WORKTREE or BUILD.
          if @run.config["dry_run"] && node == "WORKTREE"
            @run.update(status: "dry_run")
            break
          end
          if protected?(node) && !(open && node == "BUILD") && projection["current_candidate"] && @git.head(worktree) != projection["current_candidate"]
            raise Error, "worktree HEAD differs from the graph's current candidate"
          end
          attempt = open || @run.coordinator.start(node, worktree: protected?(node) ? worktree : nil)
          @attempt = attempt.fetch("attempt_id")
          @node = node
          send("step_#{node.downcase}")
          checkpoint("last_step", node)
          @run.sync
        end
      rescue Parked
        # The step remains open; an answer creates a fresh model call with that answer as input.
        @run.state
      rescue Cancelled => error
        @run.update(status: "cancelled", error: error.message)
      rescue StandardError => error
        @run.update(status: "paused", error: error.message)
        @run.sync
        raise
      end
      @run.sync
      @run.state
    end

    private

    def protected?(node) = @run.coordinator.policy.dig("nodes", node, "mutation_guard")
    def cancelled? = @run.state["status"] == "cancelled" || File.exist?(File.join(@run.directory, "cancel.request"))
    def state = @run.coordinator.snapshot
    def runtime = @run.state.fetch("runtime")
    def checkpoint(key, value) = @run.update(runtime: runtime.merge(key => value))
    def completed?(node) = state["attempts"].values.any? { |attempt| attempt["node"] == node && attempt["state"] == "closed" && state.dig("manifests", attempt["attempt_id"], "result", "state") == "completed" }
    def worktree = File.join(@run.directory, "worktree")
    def base_sha = runtime.fetch("base_sha") { @git.call(@run.config["repo"], "rev-parse", "--verify", "#{@run.config['base']}^{commit}") }
    def clause_ids = PrGraph::OutcomeContract.new.validate_register!(artifact("triage_brief")).fetch("clause_ids")

    def artifact_record(family)
      records = state.fetch("artifacts").select { |row| row["family"] == family && row["status"] == "current" }
      raise Error, "expected one current #{family}" unless records.one?
      records.first
    end

    def artifact(family)
      record = artifact_record(family)
      JSON.parse(File.read(File.join(@run.directory, record.fetch("content_ref"))))
    end

    def attempted_artifact(family)
      record = state["artifacts"].find { |row| row["family"] == family && row["attempt_id"] == @attempt }
      record && JSON.parse(File.read(File.join(@run.directory, record.fetch("content_ref"))))
    end

    def put(family, content, candidate: nil, input: nil, perspective: "author", covered: [])
      existing = state["artifacts"].find { |row| row["family"] == family && row["attempt_id"] == @attempt }
      if existing
        stored = JSON.parse(File.read(File.join(@run.directory, existing.fetch("content_ref"))))
        raise Error, "recovery would replace #{family} with different evidence" unless stored == content && existing["candidate_sha"] == candidate
        return existing
      end
      @run.coordinator.put_artifact({
          "family" => family, "node" => @node, "attempt_id" => @attempt, "producer" => "giraffe-harness",
          "input_sha" => input || candidate || base_sha, "candidate_sha" => candidate, "content_type" => "application/json",
          "wake_id" => nil, "perspective" => perspective, "covered_outcomes" => covered}, JSON.generate(content))
    end

    def finish(**options) = @run.coordinator.complete(@node, @attempt, **options)

    def ask(role, inputs, cwd: worktree, writable: false, unit: "main")
      @model.call(role, attempt: @attempt, inputs: inputs, cwd: cwd, writable: writable, unit: unit)
    end

    def replay_results(projection)
      projection.dig("recovery", "partial_results").each do |result|
        arguments = result.fetch("retry")
        command = arguments.fetch("command")
        options = arguments.reject { |key, _| key == "command" }.transform_keys(&:to_sym)
        @run.coordinator.public_send(command, result.fetch("node"), result.fetch("attempt_id"), **options)
      end
    end
  end
end
