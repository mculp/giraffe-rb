# frozen_string_literal: true

module Giraffe
  module Runners
    # What a runner is asked to do: the step it is for, what to say, the shape the answer must take, where it may
    # look, whether it may edit there, and the most it may spend. Left unsaid, a runner only reads.
    Task = Data.define(:step, :prompt, :schema, :cwd, :writable, :budget_usd) do
      def initialize(writable: false, **rest) = super
    end
  end
end
