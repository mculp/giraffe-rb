# frozen_string_literal: true

module Giraffe
  module Schema
    # The keys an object must have, told in the order the schema lists them. A key is there when the object has it, whatever its value.
    class Required
      def keyword = "required"

      def errors(schema, value, path)
        missing = []
        schema.fetch("required", []).each { |key| missing << "#{path}.#{key} is required" unless value.key?(key) }
        missing
      end
    end
  end
end
