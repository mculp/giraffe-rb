# frozen_string_literal: true

module Giraffe
  module Schema
    # What every element of an array must be, each told with its place.
    class Items
      def keyword = "items"

      def errors(schema, value, path)
        return [] unless schema["items"]
        value.each_with_index.flat_map { |inner, index| Schema.errors(schema["items"], inner, "#{path}[#{index}]") }
      end

      def check!(schema)
        Schema.check!(schema["items"]) if schema["items"]
      end
    end
  end
end
