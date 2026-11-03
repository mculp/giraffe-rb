# frozen_string_literal: true

module Giraffe
  module Schema
    # How big a value may be, the keyword's own value being the limit. The measure names the method that says how big a value is, its
    # length or, for a number, itself. The limit is broken when the measure stands to it as `compare` says, and the complaint says what
    # that means.
    Bound = Data.define(:keyword, :measure, :compare, :complaint) do
      def errors(schema, value, path)
        limit = schema[keyword]
        return [] unless limit && value.public_send(measure).public_send(compare, limit)
        ["#{path} #{complaint}"]
      end
    end
  end
end
