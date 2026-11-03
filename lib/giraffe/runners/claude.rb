# frozen_string_literal: true

require "json"
require "rubygems/version"
require_relative "../command"
require_relative "claude_argv"

module Giraffe
  module Runners
    class Claude
      MIN_VERSION = Gem::Version.new("2.1.312")
      # Where the answer comes back: ClaudeArgv sends the schema one level down under this name.
      ENVELOPE = ClaudeArgv::ENVELOPE
      def initialize(config, command: Command.new)
        @config, @command = config, command
        @checked = false
      end

      def call(task)
        check_version!(task.cwd) unless @checked
        read(task.step, capture(task))
      rescue JSON::ParserError
        raise InvalidOutput, "Claude returned malformed JSON"
      end

      private

      # Input travels over stdin, never in process arguments.
      def capture(task)
        @command.capture(ClaudeArgv.new(@config, task).to_a, cwd: task.cwd, env: environment, clean_env: true, input: task.prompt,
                         timeout: @config["call_timeout"])
      end

      # Only model authentication is inherited.
      def environment = ENV.slice(*Command::BASE_ENV, "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN").merge("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1")

      # What claude printed: its answer and what it cost, or why it is not an answer.
      def read(step, result)
        doc = JSON.parse(result["stdout"])
        usage = {"cost_usd" => doc.fetch("total_cost_usd", 0.0), "turns" => doc.fetch("num_turns", 0)}
        return {"output" => doc["structured_output"][ENVELOPE], "usage" => usage} if succeeded?(result, doc)
        raise failure(step, result, doc).tap { |error| error.usage = usage }
      end

      def succeeded?(result, doc)
        result["status"].zero? && doc["type"] == "result" && doc["subtype"] == "success" && !doc["is_error"] &&
          doc["structured_output"].is_a?(Hash) && doc["structured_output"].key?(ENVELOPE)
      end

      def failure(step, result, doc)
        reason = doc["result"] || doc["subtype"] || result["status"]
        Error.new("Claude #{step} did not return a successful structured result: #{Command.tail(reason.to_s)}")
      end

      def check_version!(cwd)
        version = @command.run!([@config["claude_bin"], "--version"], cwd: cwd, timeout: 15)[/\d+\.\d+\.\d+/]
        raise Error, "Claude Code #{MIN_VERSION} or newer is required" unless version && Gem::Version.new(version) >= MIN_VERSION
        @checked = true
      end
    end
  end
end
