# frozen_string_literal: true

module Giraffe
  module Steps
    class Build
      # What BUILD does when VERIFY sent a candidate back and the fix batch left it as it was. The same candidate can
      # only come back red, so what BUILD has no edit for is a person's to settle, unless one has answered since that
      # red, whether this question or one BUILD asked for itself.
      class StillRed
        def initialize(context, feedback)
          @context, @feedback = context, feedback
        end

        def call
          context.ask_a_person("verification-#{context.attempt}", question) if unchanged?
        end

        private

        attr_reader :context

        def candidate = @feedback.fetch("candidate_sha")
        def unchanged? = context.git.head(context.worktree) == candidate && context.run.state["answers"].size == @feedback["answers_seen"]

        def question
          "VERIFY stays red and BUILD found no edit to make: #{@feedback.fetch('reason')}. #{open_clauses} #{screenshots}" \
            "Please answer with evidence, such as what a command printed on #{candidate}, or with what should change."
        end

        def open_clauses
          rows = @feedback.dig("ac_audit", "clauses").to_a.reject { |row| row["verdict"] == "met" }
          rows.map { |row| "#{row['clause_id']}: #{row['reason']}" }.join(" ")
        end

        def screenshots
          paths = @feedback["screenshots"].to_a.map { |shot| shot["path"] }
          "Its screenshots are #{paths.join(', ')}. " if paths.any?
        end
      end
    end
  end
end
