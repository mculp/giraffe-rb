# frozen_string_literal: true

require "digest"
require "json"
require_relative "../shapes"

module Giraffe
  module Backends
    # Pins a run's kinds to the contracts of the release that started it: each logical kind maps to a name that
    # carries the digest of its schema. Every backend that records the pin builds it here.
    module KindMap
      MISMATCH = "run uses different contracts; resume it with its pinned Giraffe release"

      def self.current(shapes = PrGraph::Shapes.build)
        shapes.to_h { |kind, schema| [kind, "#{kind}-#{Digest::SHA256.hexdigest(JSON.generate(schema))[0, 16]}"] }
      end
    end
  end
end
