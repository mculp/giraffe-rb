# frozen_string_literal: true

module Giraffe
  module Schema
    # The shapes a value may have, of which it has to fit exactly one. What each shape still lacks is what a refusal says. A model
    # asked again has to see what would make its output fit, and fewest errors would not say which shape it meant: an incomplete
    # output is closest to the one asking questions.
    class OneOf
      def keyword = "oneOf"

      def errors(schema, value, path)
        return [] unless schema["oneOf"]
        outcomes = schema["oneOf"].map { |branch| Schema.errors(branch, value, path) }
        return [] if outcomes.one?(&:empty?)
        ["#{path} must match exactly one of: #{outcomes.map { |problems| lacking(problems) }.join(' OR ')}"]
      end

      private

      def lacking(problems) = problems.empty? ? "matched" : problems.first(Schema::SHOWN).join(", ")
    end
  end
end
