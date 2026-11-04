# frozen_string_literal: true

require_relative "runners/claude"
require_relative "runners/scripted"

module Giraffe
  # Every runner answers call(**request) with an output and its usage; a run's configuration says which one makes
  # its calls. This takes the run, not just its config: the scripted runner keeps its place in the run, and Claude
  # shares the harness's command, which stops when the run is cancelled.
  module Runners
    def self.for(run, command:)
      return Claude.new(run.config, command: command) unless run.config["runner"] == "scripted"
      scripted(run)
    end

    def self.scripted(run)
      positions = run.state.fetch("runtime").fetch("script_positions", {})
      Scripted.new(run.config["script"], positions: positions, on_advance: ->(kept) { run.checkpoint("script_positions", kept) })
    end
    private_class_method :scripted
  end
end
