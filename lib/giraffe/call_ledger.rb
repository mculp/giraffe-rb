# frozen_string_literal: true

module Giraffe
  # What each model call cost and came to, kept in the run's state so it outlives the process that made the call.
  class CallLedger
    def initialize(run) = @run = run

    def output(key) = entries.dig(key, "output")
    def refusal(key) = entries.dig(key, "refused")
    def spent = entries.values.sum { |entry| entry.fetch("charge", 0.0) }

    # Neither carries a charge of its own: the call that produced them was billed under its reservation.
    def keep(key, role, output) = write(key, "role" => role, "charge" => 0.0, "output" => output)
    def refuse(key, role, reason) = write(key, "role" => role, "charge" => 0.0, "refused" => reason)

    def reserve(reservation, role, limit) = write(reservation, "role" => role, "charge" => limit, "state" => "started")
    def bill(reservation, role, state, usage) = write(reservation, "role" => role, "charge" => usage.fetch("cost_usd"), "state" => state, "usage" => usage)

    private

    def entries = @run.state.fetch("runtime").fetch("calls", {})
    def write(key, entry) = @run.checkpoint_entry("calls", key, entry)
  end
end
