# frozen_string_literal: true

module Giraffe
  module Schema
    # Whether a member that no property describes may be there. Only false has an effect: a member is allowed unless the schema says
    # otherwise. Properties asks about each such member as it reaches it, so what this rule is given is the member and the path to the
    # member, not the object that holds it.
    class AdditionalProperties
      def keyword = "additionalProperties"

      def errors(schema, _member, path)
        return [] unless schema["additionalProperties"] == false
        ["#{path} is not allowed"]
      end
    end
  end
end
