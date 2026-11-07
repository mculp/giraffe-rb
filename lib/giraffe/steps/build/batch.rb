# frozen_string_literal: true

require_relative "../../protected_paths"

module Giraffe
  module Steps
    class Build
      # One commit of the writer's work: a unit of the plan, a fix for a review, or the fix VERIFY asked for. The commit
      # carries a trailer naming the batch, so that a commit a crash left behind, before it could be checkpointed, is
      # taken up rather than written twice.
      class Batch
        def initialize(context, unit, assignment)
          @context, @unit, @assignment = context, unit, assignment
        end

        def call
          return if recorded?
          found = left_by_a_crash
          found.any? ? adopt(found) : write
        end

        private

        attr_reader :context

        def git = context.git
        def worktree = context.worktree
        def key = "build:#{context.attempt}:#{@unit}"
        def trailer = "Giraffe-Unit: #{key}"
        def recorded? = context.runtime.fetch("build_commits", {}).key?(key)
        def record(sha) = context.run.checkpoint_entry("build_commits", key, sha)

        # Past the base, because the trailer is the only trace a crash leaves of a batch it did not checkpoint.
        def left_by_a_crash
          range = "#{context.base_sha}..HEAD"
          git.call(worktree, "log", "--format=%H", "--fixed-strings", "--grep=#{trailer}", range).lines.map(&:strip)
        end

        def adopt(commits)
          raise Error, "ambiguous recovered BUILD commit" unless commits.one?
          record(commits.first)
        end

        def write
          git.clean!(worktree)
          ask_the_writer
          autocorrect
          record(commit)
        end

        def ask_the_writer
          inputs = @assignment.merge("test_plan" => context.artifact("test_plan"), "reproduction" => context.runtime["reproduction"])
          context.ask("build", inputs, writable: true, unit: @unit)
        end

        # Autocorrect belongs to BUILD; VERIFY runs it read-only and refuses any resulting mutation. What the writer
        # changed is checked before it runs, and what it changed after.
        def autocorrect
          guard_changed_paths!
          context.checks.run(worktree, context.run.config["lint"])
          guard_changed_paths!
        end

        def commit
          title = context.run.state.dig("ticket", "title")
          git.commit(worktree, "#{title}\n\n#{trailer}") || git.head(worktree)
        end

        def guard_changed_paths!
          protected_paths = ProtectedPaths.new(hooks_prefix: git.hooks_prefix(worktree))
          forbidden = protected_paths.among(git.changed_paths(worktree))
          raise Error, "BUILD changed protected files: #{forbidden.join(', ')}" if forbidden.any?
        end
      end
    end
  end
end
