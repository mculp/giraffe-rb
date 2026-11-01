# frozen_string_literal: true

require "json"
require "rubygems/version"
require_relative "../command"

module Giraffe
  module Runners
    class Claude
      MIN_VERSION = Gem::Version.new("2.1.312")
      def initialize(config, command: Command.new)
        @config, @command = config, command
        @checked = false
      end

      def call(step:, prompt:, schema:, cwd:, writable: false, budget_usd:, **)
        check_version!(cwd) unless @checked
        # No shell, remote connector, subagent or publishing tools in any model call.
        tools = %w[Read Grep Glob]
        tools += %w[Edit Write] if writable
        allowed = %w[Read Grep Glob]
        allowed << "Edit(/**)" if writable
        argv = [@config["claude_bin"], "-p", "--output-format", "json", "--json-schema", JSON.generate(schema),
                "--setting-sources", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                "--permission-mode", "dontAsk", "--tools", tools.join(","), "--allowedTools", *allowed,
                "--disallowedTools", "Bash", "Agent", "Task", "WebFetch", "WebSearch", "mcp__*",
                "Edit(/**/.git/**)", "Edit(/.git)", "Edit(/**/.claude/**)", "Edit(/**/.cursor/**)",
                "Edit(/**/.env*)", "Edit(/**/AGENTS.md)", "Edit(/**/CLAUDE.md)",
                "--disable-slash-commands", "--no-session-persistence", "--max-turns", @config["max_turns"].to_s,
                "--max-budget-usd", budget_usd.to_s, "--model", (@config["models"] || {}).fetch(step, @config["model"])]
        # Input travels over stdin, never in process arguments. Only model authentication is inherited.
        env = ENV.slice(*Command::BASE_ENV, "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN")
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        result = @command.capture(argv, cwd: cwd, env: env, clean_env: true, input: prompt,
                                  timeout: @config["call_timeout"])
        doc = JSON.parse(result["stdout"])
        usage = {"cost_usd" => doc.fetch("total_cost_usd", 0.0), "turns" => doc.fetch("num_turns", 0)}
        unless result["status"].zero? && doc["type"] == "result" && doc["subtype"] == "success" && !doc["is_error"] && doc.key?("structured_output")
          error = Error.new("Claude #{step} did not return a successful structured result (#{doc['subtype'] || result['status']})")
          error.usage = usage
          raise error
        end
        {"output" => doc["structured_output"], "usage" => usage}
      rescue JSON::ParserError
        raise InvalidOutput, "Claude returned malformed JSON"
      end

      private

      def check_version!(cwd)
        version = @command.run!([@config["claude_bin"], "--version"], cwd: cwd, timeout: 15)[/\d+\.\d+\.\d+/]
        raise Error, "Claude Code #{MIN_VERSION} or newer is required" unless version && Gem::Version.new(version) >= MIN_VERSION
        @checked = true
      end
    end
  end
end
