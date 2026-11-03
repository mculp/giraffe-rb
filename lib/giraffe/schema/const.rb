# frozen_string_literal: true

module Giraffe
  module Schema
    # The one value something must be. A schema that has the keyword asks it even of nil or false, which are values too.
    class Const
      def keyword = "const"

      def errors(schema, value, path)
        return [] unless schema.key?("const") && value != schema["const"]
        ["#{path} must equal #{schema['const'].inspect}"]
      end
    end
  end
end
