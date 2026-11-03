# frozen_string_literal: true

require "json"
require "rubygems/version"
require_relative "../command"

module Giraffe
  module Runners
    class Claude
      MIN_VERSION = Gem::Version.new("2.1.312")
      # The API refuses a oneOf at the top of a tool's schema, and every role's schema is one. So the shape travels
      # one level down and comes back the same way; Model still validates what is inside.
      ENVELOPE = "output"
      def initialize(config, command: Command.new)
        @config, @command = config, command
        @checked = false
      end

      def call(task)
        check_version!(task.cwd) unless @checked
        # No shell, remote connector, subagent or publishing tools in any model call.
        tools = %w[Read Grep Glob]
        tools += %w[Edit Write] if task.writable
        allowed = %w[Read Grep Glob]
        allowed << "Edit(/**)" if task.writable
        argv = [@config["claude_bin"], "-p", "--output-format", "json", "--json-schema", JSON.generate(enveloped(task.schema)),
                "--setting-sources", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                "--permission-mode", "dontAsk", "--tools", tools.join(","), "--allowedTools", *allowed,
                "--disallowedTools", "Bash", "Agent", "Task", "WebFetch", "WebSearch", "mcp__*",
                "Edit(/**/.git/**)", "Edit(/.git)", "Edit(/**/.claude/**)", "Edit(/**/.cursor/**)",
                "Edit(/**/.env*)", "Edit(/**/AGENTS.md)", "Edit(/**/CLAUDE.md)",
                "--disable-slash-commands", "--no-session-persistence", "--max-turns", @config["max_turns"].to_s,
                "--max-budget-usd", task.budget_usd.to_s, "--model", (@config["models"] || {}).fetch(task.step, @config["model"])]
        # Input travels over stdin, never in process arguments. Only model authentication is inherited.
        env = ENV.slice(*Command::BASE_ENV, "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN")
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        result = @command.capture(argv, cwd: task.cwd, env: env, clean_env: true, input: task.prompt,
                                  timeout: @config["call_timeout"])
        doc = JSON.parse(result["stdout"])
        usage = {"cost_usd" => doc.fetch("total_cost_usd", 0.0), "turns" => doc.fetch("num_turns", 0)}
        unless result["status"].zero? && doc["type"] == "result" && doc["subtype"] == "success" && !doc["is_error"] && doc["structured_output"].is_a?(Hash) && doc["structured_output"].key?(ENVELOPE)
          error = Error.new("Claude #{task.step} did not return a successful structured result: #{Command.tail((doc['result'] || doc['subtype'] || result['status']).to_s)}")
          error.usage = usage
          raise error
        end
        {"output" => doc["structured_output"][ENVELOPE], "usage" => usage}
      rescue JSON::ParserError
        raise InvalidOutput, "Claude returned malformed JSON"
      end

      private

      def enveloped(schema) = {"type" => "object", "properties" => {ENVELOPE => schema}, "required" => [ENVELOPE], "additionalProperties" => false}

      def check_version!(cwd)
        version = @command.run!([@config["claude_bin"], "--version"], cwd: cwd, timeout: 15)[/\d+\.\d+\.\d+/]
        raise Error, "Claude Code #{MIN_VERSION} or newer is required" unless version && Gem::Version.new(version) >= MIN_VERSION
        @checked = true
      end
    end
  end
end
