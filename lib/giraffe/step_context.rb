# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "model"

module Giraffe
  # What a step is handed: the attempt it is doing, the harness's services, and the helpers that read and write the
  # graph for that attempt. Nothing about the graph is kept here, and it is frozen so that nothing can be: a step run
  # again after a crash has to see what the crash left, and `put` checks exactly that.
  class StepContext
    attr_reader :run, :node, :attempt

    def initialize(run, services, node, attempt)
      @run, @services, @node, @attempt = run, services, node, attempt
      freeze
    end

    def git = @services.git
    def checks = @services.checks
    def github = @services.github
    def ac_audit_contract = @services.ac_audit_contract
    def spec_audit_contract = @services.spec_audit_contract

    def runtime = @run.state.fetch("runtime")
    def checkpoint(key, value) = @run.checkpoint(key, value)
    def worktree = File.join(@run.directory, "worktree")
    def base_sha = runtime.fetch("base_sha") { git.resolve_commit(@run.config["repo"], @run.config["base"]) }
    def clause_ids = state.dig("outcome_context", "clauses")
    def read_only_checks(commands = @run.config["checks"]) = git.read_only(worktree) { checks.run(worktree, commands) }

    def artifact_record(family)
      records = state.fetch("artifacts").select { |row| row["family"] == family && row["status"] == "current" }
      raise Error, "expected one current #{family}" unless records.one?
      records.first
    end

    def artifact(family) = evidence(artifact_record(family))

    def attempted_artifact(family)
      record = attempted_record(family)
      record && evidence(record)
    end

    # candidate: is the commit the evidence is about, perspective: whose view it is, and covered: the outcomes it covers.
    def put(family, content, **claim)
      existing = attempted_record(family)
      return replayed(existing, content, claim[:candidate]) if existing
      @run.coordinator.put_artifact(metadata(family, **claim), JSON.generate(content))
    end

    def finish(**options) = @run.coordinator.complete(@node, @attempt, **options)

    # The scope says where and how the model may work: cwd: (default the worktree), writable: (default false) and
    # unit: (default "main").
    def ask(role, inputs, **scope, &accept)
      scope = {cwd: worktree, writable: false, unit: "main"}.merge(scope)
      request = Model::Request.new(role: role, attempt: @attempt, inputs: {"ticket" => @run.state["ticket"]}.merge(inputs), **scope)
      @services.model.call(request, &accept)
    end

    # What a step has no edit or evidence for is a person's to settle. The step stays open; the answer reaches its next call.
    def ask_a_person(id, text)
      @run.update(status: "waiting_for_answers", questions: [{"id" => id, "text" => text, "role" => @node.downcase, "attempt_id" => @attempt}])
      raise Parked, "waiting for a person's answer"
    end

    private

    def state = @run.coordinator.snapshot
    def evidence(record) = @services.outcome_contract.read_artifact!(record, artifact_path: @run.path)
    def attempted_record(family) = state["artifacts"].find { |row| row["family"] == family && row["attempt_id"] == @attempt }

    def metadata(family, candidate: nil, perspective: "author", covered: [])
      {"family" => family, "node" => @node, "attempt_id" => @attempt, "producer" => "giraffe-harness",
       "input_sha" => candidate || base_sha, "candidate_sha" => candidate, "content_type" => "application/json",
       "wake_id" => nil, "perspective" => perspective, "covered_outcomes" => covered}
    end

    # Run again after a crash, a step finds what its attempt already put, and may put only the same.
    def replayed(existing, content, candidate)
      raise Error, "recovery would replace #{existing['family']} with different evidence" unless evidence(existing) == content && existing["candidate_sha"] == candidate
      existing
    end
  end
end
