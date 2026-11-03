# frozen_string_literal: true

require "open3"
require_relative "../../scripts/process_group"
require_relative "errors"
require_relative "command/invocation"
require_relative "command/pipes"

module Giraffe
  # Argument arrays only; shell commands for project checks are explicit, sandboxed inputs.
  class Command
    LIMIT = 2_000_000
    # The environment any child may inherit; a caller adds what its own child needs.
    BASE_ENV = %w[PATH HOME TMPDIR LANG LC_ALL USER].freeze
    # What project code may inherit: never a controller, model, GitHub, Linear or Temper credential.
    PROJECT_ENV = [*BASE_ENV, "SHELL", "GEM_HOME", "GEM_PATH", "BUNDLE_PATH"].freeze
    TAIL_CHARS = 1_000

    # The end of some output, for a reason that has to stay short. Its line breaks stay: joining lines could
    # make a secret pattern out of text that redaction had no reason to touch.
    def self.tail(output)
      text = output.strip
      text[-TAIL_CHARS..] || text
    end

    def initialize(cancelled: -> { false })
      @cancelled = cancelled
    end

    def capture(argv, cwd:, env: {}, timeout: 600, input: nil, clean_env: false, limit: LIMIT)
      invocation = Invocation.new(argv: argv, cwd: cwd, env: env, timeout: timeout, input: input, clean_env: clean_env, limit: limit)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output = error = status = nil
      Open3.popen3(*invocation.popen3_args) do |stdin, stdout, stderr, waiter|
        pipes = Pipes.new(stdin, stdout, stderr, invocation)
        begin
          loop do
            raise Cancelled, "run cancelled" if @cancelled.call
            raise CommandLimit, "#{invocation.label} timed out after #{invocation.timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > invocation.timeout
            pipes.check!
            pending = [waiter, *pipes.threads].find(&:alive?)
            break unless pending
            pending.join(0.025)
          end
          output, error = pipes.output
          status = waiter.value.exitstatus || 128 + waiter.value.termsig.to_i
        ensure
          PrGraph::ProcessGroup.terminate(waiter.pid)
          pipes.close
        end
      end
      {"status" => status, "stdout" => output.force_encoding("UTF-8").scrub, "stderr" => error.force_encoding("UTF-8").scrub}
    end

    def run!(argv, **options)
      result = capture(argv, **options)
      raise Error, "#{argv.first} failed (#{result['status']}): #{self.class.tail(result['stderr'])}" unless result["status"].zero?
      result.fetch("stdout")
    end
  end
end
