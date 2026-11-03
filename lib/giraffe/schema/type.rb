# frozen_string_literal: true

require_relative "../errors"

module Giraffe
  module Schema
    # What a value must be, by the name a schema gives it. A value of the wrong type is told so alone: whatever else the schema
    # says of it was written for the type it was meant to have.
    class Type
      # Only these are in the dialect, each matched with ===: a class takes its instances, and boolean is true or false, which are
      # instances of two classes. A schema that asks for another type is refused when it is asked, not when it is loaded.
      TYPES = {
        "object" => Hash, "array" => Array, "string" => String, "integer" => Integer,
        "boolean" => ->(value) { value == true || value == false }
      }.freeze

      def keyword = "type"

      def errors(schema, value, path)
        types = Array(schema["type"])
        return [] unless types.any? && types.none? { |type| matches?(type, value) }
        ["#{path} must be #{types.join(' or ')}"]
      end

      private

      def matches?(type, value)
        TYPES.fetch(type) { raise InvalidOutput, "unsupported schema type: #{type}" } === value
      end
    end
  end
end
