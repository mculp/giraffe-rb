# frozen_string_literal: true

require_relative "errors"
require_relative "backends/temper"
require_relative "backends/sqlite"

module Giraffe
  # Where a run's records live. PrGraph::Store lists what it asks of a backend; each class here answers that,
  # and builds itself for the two callers that want one: `mirror` for a running run, `reader` for a restore.
  module Backends
    BY_NAME = {"temper" => Temper, "sqlite" => Sqlite}.freeze
    DEFAULT = "temper"

    def self.names
      BY_NAME.keys
    end

    # What a running run keeps its records in as it goes.
    def self.mirror(settings, run_id:, ticket:)
      named(settings).mirror(settings, run_id: run_id, ticket: ticket)
    end

    # What a restore reads a run back from.
    def self.reader(settings, run_id:, ticket:)
      named(settings).reader(settings, run_id: run_id, ticket: ticket)
    end

    # `settings` is a configuration, or the one a run kept when it started: that may predate `backend`, and
    # then names none.
    def self.named(settings)
      name = settings["backend"] || DEFAULT
      BY_NAME.fetch(name) { raise Error, "unknown backend #{name}" }
    end
    private_class_method :named
  end
end
