# frozen_string_literal: true

require "open3"
require_relative "../../../scripts/process_group"
require_relative "../errors"
require_relative "pipes"

module Giraffe
  class Command
    # One run of an invocation, from starting the child to the last of its output. An object of its own because a
    # run keeps a child, its pipes and a clock in view at once, more than the few lines of a method can hold.
    class Execution
      # How long to wait on one thread before looking at the clock and the cancellation again.
      POLL = 0.025

      def initialize(invocation, cancelled)
        @invocation, @cancelled = invocation, cancelled
      end

      # The clock starts before the child does, so a slow start counts against its time.
      def call
        started = now
        Open3.popen3(*@invocation.popen3_args) do |stdin, stdout, stderr, waiter|
          supervise(waiter, Pipes.new(stdin, stdout, stderr, @invocation), started)
        end
      end

      private

      # However the wait ends, so do the child, whatever it started, and the threads at its pipes.
      def supervise(waiter, pipes, started)
        await(waiter, pipes, started)
        outcome(waiter, pipes)
      ensure
        PrGraph::ProcessGroup.terminate(waiter.pid)
        pipes.close
      end

      def await(waiter, pipes, started)
        loop { break if settled?(waiter, pipes, started) }
      end

      # Whether the child and every thread at its pipes are done, after a moment's wait on the first that is not.
      def settled?(waiter, pipes, started)
        end_early!(pipes, started)
        pending = [waiter, *pipes.threads].find(&:alive?)
        pending&.join(POLL)
        pending.nil?
      end

      # What ends a wait by raising: the caller's cancellation, the child's time running out, or a pipe that failed.
      def end_early!(pipes, started)
        raise Cancelled, "run cancelled" if @cancelled.call
        raise CommandLimit, "#{@invocation.label} timed out after #{@invocation.timeout}s" if now - started > @invocation.timeout
        pipes.check!
      end

      def outcome(waiter, pipes)
        stdout, stderr = pipes.output
        {"status" => exit_code(waiter), "stdout" => text(stdout), "stderr" => text(stderr)}
      end

      def exit_code(waiter) = waiter.value.exitstatus || 128 + waiter.value.termsig.to_i
      def text(bytes) = bytes.force_encoding("UTF-8").scrub
      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
