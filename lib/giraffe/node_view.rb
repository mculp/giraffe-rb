# frozen_string_literal: true

module Giraffe
  # One node's part of a run's graph view: where the node stands, and the attempts and artifacts that put it there.
  class NodeView
    # What a run has done by the time it is viewed: its own status and open questions, and what its coordinator
    # recorded in `state` and worked out in `projection`. Every node of one view reads the same progress.
    Progress = Data.define(:run_status, :questions, :state, :projection)

    ATTEMPT_FIELDS = %w[attempt_id iteration state start_seq done_seq].freeze
    ARTIFACT_FIELDS = %w[artifact_id family candidate_sha status perspective content_sha256 covered_outcomes].freeze

    def initialize(name, rules, dependencies, progress)
      @name, @rules, @dependencies, @progress = name, rules, dependencies, progress
    end

    def to_h
      {"id" => @name, "status" => status, "dependencies" => @dependencies, "attempts" => attempts.map { |attempt| attempt.slice(*ATTEMPT_FIELDS) },
       "blocked_reasons" => blocked_reasons, "artifacts" => artifacts}
    end

    private

    # The newest attempt decides: an open one is under way, and a closed one is done unless the projection lets the node
    # run again. With no attempt the node is runnable, retired or blocked.
    def status
      current = attempts.last
      return open_status(current) if current && current["state"] == "open"
      return "runnable" if @progress.projection["runnable"].include?(@name)
      return closed_status(current) if current
      @rules["retired"] ? "retired" : "blocked"
    end

    # A paused or cancelled run shows through its open attempt; otherwise only a question asked of the attempt makes it wait.
    def open_status(current)
      return @progress.run_status if %w[paused cancelled].include?(@progress.run_status)
      @progress.questions.any? { |question| question["attempt_id"] == current["attempt_id"] } ? "waiting_for_answers" : "active"
    end

    # The coordinator records a failed attempt as "failed", or as "mutation_violation" when the worktree also changed
    # without authority. Either leaves the node failed; any other result leaves it completed.
    def closed_status(current)
      result = @progress.state.dig("manifests", current["attempt_id"], "result", "state")
      %w[failed mutation_violation].include?(result) ? "failed" : "completed"
    end

    def attempts
      @attempts ||= @progress.state["attempts"].values.select { |attempt| attempt["node"] == @name }.sort_by { |attempt| attempt["start_seq"] }
    end

    def artifacts
      @progress.state["artifacts"].select { |artifact| artifact["node"] == @name }.map { |artifact| artifact.slice(*ARTIFACT_FIELDS) }
    end

    def blocked_reasons = @progress.projection["blocked"][@name] || []
  end
end
