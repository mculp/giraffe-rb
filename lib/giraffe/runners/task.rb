# frozen_string_literal: true

require_relative "tool_profile"

module Giraffe
  module Runners
    # What a runner is asked to do: the step it is for, what to say, the shape the answer must take, where it may
    # look, whether it may edit there, the most it may spend, and anything more it may use. Left unsaid, a runner
    # only reads, and uses nothing more.
    Task = Data.define(:step, :prompt, :schema, :cwd, :writable, :budget_usd, :profile) do
      def initialize(writable: false, profile: ToolProfile::NONE, **rest) = super
    end
  end
end
