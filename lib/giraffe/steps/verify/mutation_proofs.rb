# frozen_string_literal: true

require_relative "../../safe_path"

module Giraffe
  module Steps
    module Verify
      # Proves the mutations of a spec audit: each spec is run, at the line it cites, with its mutation applied. What a
      # spec cites is the model's to get right, so a spec the candidate did not change or a line it does not have is
      # refused as InvalidOutput, and the model is asked again.
      class MutationProofs
        def initialize(runner:, worktree:, paths:, spec_command:)
          @runner, @worktree, @paths, @spec_command = runner, worktree, paths, spec_command
        end

        # The runner's result for each spec, in order. A spec is checked just before its own mutation runs.
        def call(specs)
          specs.map do |spec|
            require_changed_spec_line!(spec.fetch("ref"))
            @runner.prove(spec.fetch("patch"), @spec_command.for(spec["ref"]))
          end
        end

        private

        def require_changed_spec_line!(ref)
          path, line = ref.split(":", 2)
          return if @paths.include?(path) && line.to_s.match?(/\A[1-9][0-9]*\z/) && line.to_i <= File.readlines(SafePath.new(@worktree).file(path)).length
          raise InvalidOutput, "spec audit must cite a real changed spec and line: #{ref}"
        end
      end
    end
  end
end
