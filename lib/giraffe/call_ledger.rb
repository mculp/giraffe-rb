# frozen_string_literal: true

require "securerandom"
require_relative "errors"
require_relative "../../scripts/content_scan"

module Giraffe
  # What each model call cost and came to, kept in the run's state so it outlives the process that made the call.
  class CallLedger
    def initialize(run) = @run = run

    def entries = @run.state.fetch("runtime").fetch("calls", {})
    def output(key) = entries.dig(key, "output")
    def refusal(key) = entries.dig(key, "refused")
    def spent = entries.values.sum { |entry| entry.fetch("charge", 0.0) }

    # What a call came to. Neither carries a charge: the call itself was charged under its reservation.
    def keep(key, request, output) = write(key, outcome(request).merge("output" => output))
    def refuse(key, request, reason) = write(key, outcome(request).merge("refused" => PrGraph::ContentScan.redact(reason)))

    # Only the attempt in progress can ask again, and an output is as long as a model made it, so those of
    # earlier attempts leave the state. Whatever carries a charge stays.
    def retire_outcomes(attempt)
      current = entries.select { |_key, entry| entry.key?("charge") || entry["attempt"] == attempt }
      @run.checkpoint("calls", current) unless current.size == entries.size
    end

    # Returns the reservation, an entry of its own so that asking again keeps any earlier unknown charge.
    def reserve(key, role, limit)
      "#{key}:#{SecureRandom.uuid}".tap do |reservation|
        write(reservation, "role" => role, "charge" => limit, "state" => "started")
      end
    end

    def finished(reservation, usage)
      raise InvalidOutput, "runner returned an invalid cost" unless billable?(usage)
      bill(reservation, "finished", usage)
    end

    # A failed call that reported no usable cost keeps its reservation.
    def failed(reservation, usage)
      bill(reservation, "failed", usage) if billable?(usage)
    end

    private

    def outcome(request) = {"role" => request.role, "attempt" => request.attempt}

    def billable?(usage)
      cost = usage && usage["cost_usd"]
      cost.is_a?(Numeric) && cost.finite? && cost >= 0
    end

    def bill(reservation, state, usage)
      write(reservation, entries.fetch(reservation).merge("charge" => usage.fetch("cost_usd"), "state" => state, "usage" => usage))
    end

    def write(key, entry) = @run.checkpoint_entry("calls", key, entry)
  end
end
