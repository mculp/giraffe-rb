# frozen_string_literal: true

require "digest"
require_relative "run"

module Giraffe
  # Public read model for a future HTTP/SSE frontend. The graph definition is separate from run
  # progress and from the append-only evidence; clients never need paths to private prompt files.
  class GraphView
    def initialize(run)
      @run = run
    end

    def snapshot
      view = @run.coordinator.read_view
      state, projection = view.values_at("state", "projection")
      graph = @run.store.event_log.contract.fetch("graph")
      policy = @run.coordinator.policy
      definition = {"nodes" => policy.fetch("nodes"), "dependencies" => graph.fetch("dependencies"), "legal_edges" => graph.fetch("legal_edges")}
      version = Digest::SHA256.hexdigest(JSON.generate(definition))
      nodes = policy.fetch("nodes").map do |name, rules|
        attempts = state["attempts"].values.select { |attempt| attempt["node"] == name }.sort_by { |attempt| attempt["start_seq"] }
        current = attempts.last
        status = if current && current["state"] == "open"
                   if %w[paused cancelled].include?(@run.state["status"])
                     @run.state["status"]
                   else
                     @run.state["questions"].any? { |q| q["attempt_id"] == current["attempt_id"] } ? "waiting_for_answers" : "active"
                   end
                 elsif projection["runnable"].include?(name)
                   "runnable"
                 elsif current
                   %w[failed mutation_violation].include?(state.dig("manifests", current["attempt_id"], "result", "state")) ? "failed" : "completed"
                 elsif rules["retired"]
                   "retired"
                 else
                   "blocked"
                 end
        {"id" => name, "status" => status, "dependencies" => graph.fetch("dependencies").fetch(name),
         "attempts" => attempts.map { |attempt| attempt.slice("attempt_id", "iteration", "state", "start_seq", "done_seq") },
         "blocked_reasons" => projection["blocked"][name] || [],
         "artifacts" => state["artifacts"].select { |artifact| artifact["node"] == name }.map do |artifact|
           artifact.slice("artifact_id", "family", "candidate_sha", "status", "perspective", "content_sha256", "covered_outcomes")
         end}
      end
      {"schema_version" => 1, "run_id" => @run.id, "revision" => @run.state["revision"], "cursor" => state["events"].length,
       "status" => @run.state["status"], "graph_version" => version, "definition" => definition,
       "candidate_sha" => projection["current_candidate"], "terminal" => projection["terminal"], "nodes" => nodes,
       "validation_error" => projection["validation_error"],
       "questions" => @run.state["questions"], "error" => @run.state["error"], "storage" => storage_status,
       "commands" => %w[answer resume cancel sync], "graph_editing" => false}
    end

    def events(after: 0)
      raise Error, "event cursor must be a nonnegative integer" unless after.is_a?(Integer) && after >= 0
      events = @run.coordinator.snapshot.fetch("events")
      raise Error, "event cursor is ahead of the run" if after > events.length
      {"schema_version" => 1, "run_id" => @run.id, "revision" => @run.state["revision"], "after" => after, "cursor" => events.length,
       "events" => events.drop(after)}
    end

    private

    def storage_status
      path = @run.path.sub(/\.jsonl\z/, ".sync.json")
      File.exist?(path) ? JSON.parse(File.read(path)) : {"mode" => @run.config["store"], "synced" => false}
    end
  end
end
