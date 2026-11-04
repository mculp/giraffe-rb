# frozen_string_literal: true

module Sandi
  # What the counts did since the baseline. A count that rose fails the ratchet; one that fell is progress.
  class Verdict
    def initialize(changes) = @changes = changes

    def failed? = worse.any?
    def worse = @changes.select(&:worse?)
    def improved = @changes.select(&:improved?)

    def lines = improved.map { |change| "improved: #{change}" } + worse.map { |change| "worse: #{change}" }

    def closing
      failed? ? "FAILED: a count rose above the baseline, which only shrinks" : "ok: no count rose above the baseline"
    end
  end
end
