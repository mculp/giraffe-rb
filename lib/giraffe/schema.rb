# frozen_string_literal: true

require "json_schemer"
require_relative "errors"

module Giraffe
  # Checks the runner schemas, and each model output against its role's schema, with the json_schemer gem.
  module Schema
    module_function

    def check!(schema)
      problems = JSONSchemer.validate_schema(schema).to_a
      raise InvalidOutput, "invalid schema: #{messages(problems)}" unless problems.empty?
      schema
    end

    def validate!(schema, value)
      errors = JSONSchemer.schema(schema).validate(value).to_a
      raise InvalidOutput, refusal(errors) unless errors.empty?
      value
    end

    # Every role's schema is a oneOf of two shapes: the model asking questions, or answering. A model asked again
    # has to see what would make its output fit, and fewest errors would not say which shape it meant: an
    # incomplete output is closest to the one asking questions. So the errors are kept apart by the shape their
    # schema_pointer starts with, /oneOf/<n>. Any other error is listed as it comes.
    def refusal(errors)
      shapes = errors.group_by { |error| error["schema_pointer"][%r{\A/oneOf/\d+}] }
      return messages(errors) if shapes.key?(nil)
      "output must match exactly one of: #{shapes.values.map { |problems| messages(problems) }.join(' OR ')}"
    end

    # Eight at most, so a refusal stays short enough to store.
    def messages(errors) = errors.first(8).map { |error| error["error"] }.join("; ")
  end
end
