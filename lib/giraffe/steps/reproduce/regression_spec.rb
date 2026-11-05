# frozen_string_literal: true

require_relative "../../errors"
require_relative "../../safe_path"

module Giraffe
  module Steps
    class Reproduce
      # The path a model names for the spec that BUILD must leave behind. The candidate has to commit that file and VERIFY
      # runs it on both sides of the fix, so it must be a plain path to a file git will carry: not a command or a filter,
      # not a directory and not ignored. A model wrote it, so each way it can be wrong is that output's fault, and
      # resuming asks again.
      class RegressionSpec
        def initialize(path, git:, worktree:)
          @path, @git, @worktree = path, git, worktree
        end

        # From the cheapest to the dearest: the name alone, then the tree on disk (SafePath refuses a path that leaves
        # it), then git.
        def check!
          raise InvalidOutput, "regression_spec must be a file path, not a command or filter: #{@path}" if @path.match?(%r{[\s:]|/\z})
          raise InvalidOutput, "regression_spec must be a file path, not a directory: #{@path}" if File.directory?(SafePath.new(@worktree).target(@path))
          raise InvalidOutput, "regression_spec is gitignored, so no commit can carry it: #{@path}" if @git.ignored?(@worktree, @path)
        end
      end
    end
  end
end
