# frozen_string_literal: true

require "digest"
require "json"
require_relative "run"
require_relative "node_view"

module Giraffe
  # Public read model for a future HTTP/SSE frontend. The graph definition is separate from run
  # progress and from the append-only evidence; clients never need paths to private prompt files.
  class GraphView
    def initialize(run)
      @run = run
    end

    def snapshot
      view = @run.coordinator.read_view
      definition = definition_of(@run.graph, @run.coordinator.policy)
      position(view, definition).merge(projected(view, definition)).merge(controls)
    end

    def events(after: 0)
      raise Error, "event cursor must be a nonnegative integer" unless after.is_a?(Integer) && after >= 0
      events = @run.coordinator.snapshot.fetch("events")
      raise Error, "event cursor is ahead of the run" if after > events.length
      stamp.merge("after" => after, "cursor" => events.length, "events" => events.drop(after))
    end

    private

    # Every answer says which run it describes, and at which revision of the run's metadata.
    def stamp = {"schema_version" => 1, "run_id" => @run.id, "revision" => @run.state["revision"]}

    def definition_of(graph, policy)
      {"nodes" => policy.fetch("nodes"), "dependencies" => graph.fetch("dependencies"), "legal_edges" => graph.fetch("legal_edges")}
    end

    # Where the run stands in its execution events, and the graph it follows. A client sees the graph change when its version does.
    def position(view, definition)
      stamp.merge("cursor" => view["state"]["events"].length, "status" => @run.state["status"],
                  "graph_version" => Digest::SHA256.hexdigest(JSON.generate(definition)), "definition" => definition)
    end

    # What the coordinator works out from the evidence: the candidate, whether the run is over, and where each node stands.
    def projected(view, definition)
      projection = view["projection"]
      {"candidate_sha" => projection["current_candidate"], "terminal" => projection["terminal"],
       "nodes" => nodes(view, definition), "validation_error" => projection["validation_error"]}
    end

    # What waits on a person, and what a person can do about it.
    def controls
      {"questions" => @run.state["questions"], "error" => @run.state["error"], "storage" => @run.store.sync_status,
       "commands" => %w[answer resume cancel sync], "graph_editing" => false}
    end

    def nodes(view, definition)
      progress = NodeView::Progress.new(run_status: @run.state["status"], questions: @run.state["questions"], state: view["state"], projection: view["projection"])
      definition["nodes"].map { |name, rules| NodeView.new(name, rules, definition["dependencies"].fetch(name), progress).to_h }
    end
  end
end
