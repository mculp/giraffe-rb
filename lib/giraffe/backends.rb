# frozen_string_literal: true

require_relative "errors"
require_relative "backends/temper"

module Giraffe
  # Where a run's records live. PrGraph::Store lists what it asks of a backend; each class here answers it.
  module Backends
    BY_NAME = {"temper" => Temper}.freeze
    DEFAULT = "temper"

    def self.names
      BY_NAME.keys
    end

    # A backend for one run. `settings` is a configuration, or the one a run kept when it started: that
    # may predate `backend`, and then names none. `options` are the backend's own, such as Temper's retries.
    def self.build(settings, run_id:, ticket:, **options)
      name = settings["backend"] || DEFAULT
      backend = BY_NAME.fetch(name) { raise Error, "unknown backend #{name}" }
      backend.from(settings, run_id: run_id, ticket: ticket, **options)
    end
  end
end
