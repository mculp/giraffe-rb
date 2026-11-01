# frozen_string_literal: true

require "json"
require "open3"
require_relative "process_group"

module PrGraph
  # Runs the `temper` CLI, `temper` on PATH or the path in PR_GRAPH_TEMPER_BIN, and parses its JSON.
  class TemperCli
    class Error < StandardError; end
    # The CLI ran and refused; the message is its own reason.
    class Failed < Error; end

    TIMEOUT = 60
    CONTEXT_REF = %r{\A(?:[@+][a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*|\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z}

    def call(*args)
      bin = ENV.fetch("PR_GRAPH_TEMPER_BIN", "temper")
      unless bin.include?("/") ? File.executable?(bin) : ENV.fetch("PATH", "").split(":").any? { |dir| File.executable?(File.join(dir, bin)) }
        raise Error, "Temper is not installed"
      end

      Open3.popen3(bin, *args, "--format", "json", pgroup: true) do |stdin, stdout, stderr, wait|
        stdin.close
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        unless wait.join(TIMEOUT)
          ProcessGroup.terminate(wait.pid)
          out.join
          err.join
          raise Error, "Temper did not answer within #{TIMEOUT}s"
        end
        output, error = out.value, err.value
        raise Failed, failure(output, error, wait.value) unless wait.value.success?

        JSON.parse(output)
      end
    rescue JSON::ParserError => e
      raise Failed, e.message
    end

    private

    # The CLI prints {"code", "message"} on stdout for API errors, and plain text on stderr otherwise.
    def failure(out, err, status)
      message = begin
        JSON.parse(out)["message"]
      rescue JSON::ParserError, TypeError
        nil
      end
      message = err.lines.first.to_s.strip if message.to_s.empty?
      message.to_s.empty? ? "exit #{status.exitstatus}" : message
    end
  end
end
