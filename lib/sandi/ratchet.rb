# frozen_string_literal: true

require_relative "verdict"

module Sandi
  # The counts held against a baseline that only shrinks. Says where things stand, then lets the baseline follow or not.
  class Ratchet
    def initialize(counters, baseline, out)
      @counters, @baseline, @out = counters, baseline, out
    end

    # 0 when no count rose above the baseline, 1 when one did.
    def check
      verdict = compare
      @out.puts(verdict.closing)
      verdict.failed? ? 1 : 0
    end

    # Writes what is counted now as the baseline, unless that would raise a count and nobody said it may.
    def update(allow_increase:)
      verdict = compare
      return refuse if verdict.failed? && !allow_increase
      @baseline.write(@counters)
      @out.puts("baseline written")
      0
    end

    private

    def compare
      @out.puts(@counters.map(&:summary))
      Verdict.new(changes).tap { |verdict| @out.puts(verdict.lines) }
    end

    def changes = @counters.flat_map { |counter| counter.tally.changes_from(@baseline.tally(counter.name)) }

    def refuse
      @out.puts("not written: that would raise the baseline. Fix what is marked worse, or add --allow-increase.")
      1
    end
  end
end
