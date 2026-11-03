# frozen_string_literal: true

require_relative "errors"
require_relative "schema/type"
require_relative "schema/const"
require_relative "schema/enum"
require_relative "schema/one_of"
require_relative "schema/required"
require_relative "schema/properties"
require_relative "schema/additional_properties"
require_relative "schema/items"
require_relative "schema/bound"

module Giraffe
  # The deliberately small JSON Schema dialect used by the checked-in runner schemas.
  # Unknown keywords fail at load time; this is not a general draft-2020-12 implementation.
  #
  # Each keyword of the dialect is a rule, an object that knows its `keyword` and says in `errors(schema, value, path)` what is
  # wrong with a value that the schema asks it about: a list of messages, empty when the value is as the keyword asks. A rule that
  # holds schemas of its own also checks them, in `check!(schema)`.
  module Schema
    # How many problems a refusal names. A refusal is stored with the run, so it stays short.
    SHOWN = 8
    # A value of the wrong type is told so alone, so this rule is asked before any other.
    TYPE = Type.new
    # Asked by Properties about the members no property describes, and never about a value as a whole.
    ADDITIONAL_PROPERTIES = AdditionalProperties.new
    # What a value is held to, by what it is, in the order the errors are told: everything to const, enum and oneOf, and then each
    # to what its own kind asks. The order is not the schema's: the same schema tells the same errors however it lists its keywords.
    BY_KIND = {
      Object => [Const.new, Enum.new, OneOf.new],
      Hash => [Required.new, Properties.new(ADDITIONAL_PROPERTIES)],
      Array => [Bound.new("minItems", :length, :<, "has too few items"), Bound.new("maxItems", :length, :>, "has too many items"), Items.new],
      String => [Bound.new("minLength", :length, :<, "is too short")],
      Numeric => [Bound.new("minimum", :itself, :<, "is below minimum"), Bound.new("maximum", :itself, :>, "is above maximum")]
    }.freeze
    # Every rule by its keyword, which is how a schema is checked to use no other.
    RULES = [TYPE, ADDITIONAL_PROPERTIES, *BY_KIND.values.flatten].to_h { |rule| [rule.keyword, rule] }.freeze
    KEYWORDS = RULES.keys.freeze
    # The rules that hold schemas of their own and check them in `check!`, in the order those are checked.
    NESTING = RULES.values_at("properties", "items", "oneOf").freeze
    module_function

    def check!(schema)
      raise InvalidOutput, "schema must be an object" unless schema.is_a?(Hash)
      unknown = schema.keys - KEYWORDS
      raise InvalidOutput, "unsupported schema keyword: #{unknown.join(', ')}" unless unknown.empty?
      NESTING.each { |rule| rule.check!(schema) }
      schema
    end

    def validate!(schema, value, path = "$")
      errors = errors(schema, value, path)
      raise InvalidOutput, errors.first(SHOWN).join("; ") unless errors.empty?
      value
    end

    def errors(schema, value, path = "$")
      mismatch = TYPE.errors(schema, value, path)
      return mismatch unless mismatch.empty?
      rules_for(value).flat_map { |rule| rule.errors(schema, value, path) }
    end

    def rules_for(value) = BY_KIND.select { |kind, _| value.is_a?(kind) }.values.flatten
    private_class_method :rules_for
  end
end
