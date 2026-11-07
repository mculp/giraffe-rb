# frozen_string_literal: true

require_relative "batch"
require_relative "reviewed"

module Giraffe
  module Steps
    class Build
      # Reviews the candidate and has what blocks it fixed, round after round, until a candidate passes. A fix that is
      # written in the last round is never reviewed: running out of rounds leaves the writer open for inspection.
      class Rounds
        def initialize(context, plan)
          @context, @plan = context, plan
        end

        # The candidate that passed, with every review it took to get there.
        def call
          max_rounds.times do |round|
            return @reviewed if review(round).passes?
            fix(round)
          end
          raise Error, "BUILD reached its fix-round limit; the writer remains open for inspection"
        end

        private

        attr_reader :context

        def max_rounds = context.run.config["max_fix_rounds"]
        def git = context.git
        def worktree = context.worktree

        # A fix that changed nothing, or a resume past recorded fixes, leaves nothing new to check or review.
        def review(round)
          head = git.head(worktree)
          @reviewed = examine(head, round) unless head == @reviewed&.candidate
          @reviewed
        end

        def examine(head, round)
          checks = context.read_only_checks
          inputs = {"plan" => @plan, "diff" => git.diff(worktree, context.base_sha), "checks" => checks}
          Reviewed.new(head, checks, past + [context.ask("review", inputs, unit: "review-#{round}")])
        end

        def past = @reviewed ? @reviewed.reviews : []

        def fix(round)
          Batch.new(context, "fix-#{round}", {"findings" => @reviewed.blocking, "failed_checks" => @reviewed.failed_checks}).call
        end
      end
    end
  end
end
