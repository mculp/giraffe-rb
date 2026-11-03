# frozen_string_literal: true

require_relative "errors"
require_relative "tickets/file"
require_relative "tickets/https"
require_relative "tickets/linear"
require_relative "tickets/validated"

module Giraffe
  # Where a run's ticket comes from. A source answers `fetch` with the ticket's fields, and Validated holds any
  # source to the same rules.
  module Tickets
    def self.load(identifier: nil, file: nil) = Validated.new(source(identifier, file)).fetch

    def self.source(identifier, file)
      return Tickets::File.new(file) if file
      raise Error, "a ticket identifier or --ticket-file is required" if identifier.to_s.empty?
      Linear.new(identifier, http: Https.new, env: ENV)
    end
    private_class_method :source
  end
end
