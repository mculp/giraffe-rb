# frozen_string_literal: true

module Giraffe
  module Schema
    # The values something may be. An empty list lets none through.
    class Enum
      def keyword = "enum"

      def errors(schema, value, path)
        return [] unless schema["enum"] && !schema["enum"].include?(value)
        ["#{path} is outside its enum"]
      end
    end
  end
end
