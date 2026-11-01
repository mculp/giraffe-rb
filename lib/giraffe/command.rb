# frozen_string_literal: true

require "open3"
require "time"
require_relative "errors"

module Giraffe
  # Argument arrays only; shell commands for project checks are explicit, sandboxed inputs.
  class Command
    LIMIT = 2_000_000
    def initialize(cancelled: -> { false })
      @cancelled = cancelled
    end

    def capture(argv, cwd:, env: {}, timeout: 600, input: nil, clean_env: false)
      raise Error, "command must be a nonempty argument array" unless argv.is_a?(Array) && argv.any? && argv.all? { |part| part.is_a?(String) }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output = error = status = nil
      Open3.popen3(env, *argv, chdir: cwd, pgroup: true, unsetenv_others: clean_env) do |stdin, stdout, stderr, waiter|
        readers = [stdout, stderr].map do |stream|
          Thread.new do
            Thread.current.report_on_exception = false
            data = +""
            while (chunk = stream.read(16_384))
              data << chunk
              if data.bytesize > LIMIT
                raise Error, "command output exceeds #{LIMIT} bytes"
              end
            end
            data
          end
        end
        writer = Thread.new do
          Thread.current.report_on_exception = false
          begin
            stdin.write(input) if input
          rescue Errno::EPIPE
            nil
          ensure
            stdin.close unless stdin.closed?
          end
        end
        begin
          loop do
            raise Cancelled, "run cancelled" if @cancelled.call
            raise Error, "command timed out after #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > timeout
            readers.each { |thread| thread.value unless thread.alive? }
            break if !waiter.alive? && readers.none?(&:alive?) && !writer.alive?
            sleep 0.025
          end
          writer.value
          output, error = readers.map(&:value)
          status = waiter.value.exitstatus || 128 + waiter.value.termsig.to_i
        ensure
          stop(waiter.pid)
          stdin.close unless stdin.closed?
          writer.join(1)
          readers.each { |thread| thread.join(1) }
        end
      end
      {"argv" => argv, "status" => status, "stdout" => output.force_encoding("UTF-8").scrub,
       "stderr" => error.force_encoding("UTF-8").scrub}
    end

    def run!(argv, **options)
      result = capture(argv, **options)
      raise Error, "#{argv.first} failed (#{result['status']}): #{result['stderr'].lines.first.to_s.strip}" unless result["status"].zero?
      result.fetch("stdout")
    end

    private

    def stop(pid)
      Process.kill("TERM", -pid)
      sleep 0.05
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end
  end
end
