# frozen_string_literal: true

module Giraffe
  module Steps
    class Build
      # A candidate commit, the checks that ran on it, and every review so far. The last review is of this commit; the
      # earlier ones are of the candidates that fixes have since replaced.
      Reviewed = Data.define(:candidate, :checks, :reviews) do
        def blocking = reviews.last.fetch("findings").select { |finding| finding["severity"] == "blocking" }
        def failed_checks = checks.reject { |check| check["exit_code"].zero? }
        def passes? = blocking.empty? && failed_checks.empty?

        # What is saved when the candidate passes, so that recovery can reuse the whole history of reviews.
        def self_review = {"candidate_sha" => candidate, "reviews" => reviews}
      end
    end
  end
end
