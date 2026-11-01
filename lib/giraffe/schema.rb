# frozen_string_literal: true

require_relative "errors"

module Giraffe
  # The deliberately small JSON Schema dialect used by the checked-in runner schemas.
  # Unknown keywords fail at load time; this is not a general draft-2020-12 implementation.
  module Schema
    KEYWORDS = %w[type properties required additionalProperties items minItems maxItems minLength maxLength enum const minimum maximum oneOf anyOf pattern description title $schema].freeze
    module_function

    def check!(schema)
      raise InvalidOutput, "schema must be an object" unless schema.is_a?(Hash)
      unknown = schema.keys - KEYWORDS
      raise InvalidOutput, "unsupported schema keyword: #{unknown.join(', ')}" unless unknown.empty?
      schema.fetch("properties", {}).each_value { |child| check!(child) }
      check!(schema["items"]) if schema["items"]
      %w[oneOf anyOf].each { |key| schema.fetch(key, []).each { |child| check!(child) } }
      schema
    end

    def validate!(schema, value, path = "$")
      errors = errors(schema, value, path)
      raise InvalidOutput, errors.first(8).join("; ") unless errors.empty?
      value
    end

    def errors(schema, value, path = "$")
      types = Array(schema["type"])
      return ["#{path} must be #{types.join(' or ')}"] if types.any? && types.none? { |type| type?(type, value) }
      found = []
      found << "#{path} must equal #{schema['const'].inspect}" if schema.key?("const") && value != schema["const"]
      found << "#{path} is outside its enum" if schema["enum"] && !schema["enum"].include?(value)
      %w[oneOf anyOf].each do |key|
        next unless schema[key]
        matches = schema[key].count { |branch| errors(branch, value, path).empty? }
        found << "#{path} must match #{key}" unless key == "oneOf" ? matches == 1 : matches.positive?
      end
      if value.is_a?(Hash)
        schema.fetch("required", []).each { |key| found << "#{path}.#{key} is required" unless value.key?(key) }
        properties = schema.fetch("properties", {})
        value.each do |key, inner|
          if properties[key]
            found.concat(errors(properties[key], inner, "#{path}.#{key}"))
          elsif schema["additionalProperties"] == false
            found << "#{path}.#{key} is not allowed"
          end
        end
      elsif value.is_a?(Array)
        found << "#{path} has too few items" if schema["minItems"] && value.length < schema["minItems"]
        found << "#{path} has too many items" if schema["maxItems"] && value.length > schema["maxItems"]
        value.each_with_index { |inner, index| found.concat(errors(schema["items"], inner, "#{path}[#{index}]")) } if schema["items"]
      elsif value.is_a?(String)
        found << "#{path} is too short" if schema["minLength"] && value.length < schema["minLength"]
        found << "#{path} is too long" if schema["maxLength"] && value.length > schema["maxLength"]
        found << "#{path} does not match its pattern" if schema["pattern"] && !Regexp.new(schema["pattern"]).match?(value)
      elsif value.is_a?(Numeric)
        found << "#{path} is below minimum" if schema["minimum"] && value < schema["minimum"]
        found << "#{path} is above maximum" if schema["maximum"] && value > schema["maximum"]
      end
      found
    end

    def type?(type, value)
      case type
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric) && value.finite?
      when "boolean" then value == true || value == false
      when "null" then value.nil?
      else raise InvalidOutput, "unsupported schema type: #{type}"
      end
    end
  end
end
