# frozen_string_literal: true

require "json"
require_relative "../errors"

module Giraffe
  module Tickets
    # Holds any source to the rules a run needs of its ticket, so a file and Linear are judged alike: text where
    # text is needed, a name to go by, and small enough to hand to a model. Both sources parse JSON, so a document
    # that is not JSON is reported here too.
    class Validated
      TEXT_FIELDS = %w[id title description].freeze
      MAX_BYTES = 131_072

      def initialize(source) = @source = source

      def fetch
        check(@source.fetch)
      rescue JSON::ParserError => e
        raise Error, "invalid ticket JSON: #{e.message}"
      end

      private

      def check(ticket)
        require_text!(ticket)
        require_names!(ticket)
        require_size!(ticket)
        ticket
      end

      def require_text!(ticket)
        TEXT_FIELDS.each { |key| raise Error, "ticket #{key} must be text" unless ticket[key].is_a?(String) }
      end

      def require_names!(ticket)
        raise Error, "ticket id and title cannot be empty" if ticket.values_at("id", "title").any?(&:empty?)
      end

      def require_size!(ticket)
        raise Error, "ticket exceeds 128 KB" if JSON.generate(ticket).bytesize > MAX_BYTES
      end
    end
  end
end
