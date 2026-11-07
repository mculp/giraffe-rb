# frozen_string_literal: true

require_relative "../../errors"

module Giraffe
  module Steps
    class Publish
      # A publish that stopped after GitHub had the pull request must not make another. The one it recorded is read back
      # from GitHub, and it has to be what was published: still open, still a draft, and still on the candidate that
      # was verified. Anything else is an error, which pauses the run.
      class Recovery
        def initialize(github:, repo:)
          @github, @repo = github, repo
        end

        # The number of the recorded pull request, once GitHub agrees that it is unchanged.
        def confirm!(saved, candidate)
          number = saved.fetch("pull_request").fetch("number")
          live = @github.reconcile_pr(repo: @repo, pr_number: number)
          raise Error, "published PR changed during recovery" unless unchanged?(live, saved, candidate)
          number
        end

        private

        def unchanged?(live, saved, candidate)
          live.dig("pull_request", "head_sha") == candidate && live.dig("pull_request", "is_draft") &&
            live.dig("pull_request", "state") == "open" && live.dig("pull_request", "id") == saved.dig("pull_request", "id")
        end
      end
    end
  end
end
