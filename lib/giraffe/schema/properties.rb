# frozen_string_literal: true

module Giraffe
  module Schema
    # What each member of an object must be, by the property that describes it. A member that no property describes is left to
    # additionalProperties. Both speak in one pass over the members, so that their errors come in the order the object has its members in.
    class Properties
      def initialize(additional) = @additional = additional

      def keyword = "properties"

      def errors(schema, value, path)
        described = schema.fetch("properties", {})
        value.flat_map do |key, inner|
          member = "#{path}.#{key}"
          described[key] ? Schema.errors(described[key], inner, member) : @additional.errors(schema, inner, member)
        end
      end

      def check!(schema)
        schema.fetch("properties", {}).each_value { |child| Schema.check!(child) }
      end
    end
  end
end
