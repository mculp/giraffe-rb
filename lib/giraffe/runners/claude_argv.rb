# frozen_string_literal: true

require "json"

module Giraffe
  module Runners
    # The claude command line for one task. A call is given only the tools it needs, and edits only when its task says
    # it may.
    class ClaudeArgv
      # The API refuses a oneOf at the top of a tool's schema, and every role's schema is one. So the shape travels
      # one level down and comes back the same way; Model still validates what is inside.
      ENVELOPE = "output"
      # No shell, remote connector, subagent or publishing tools in any model call, unless its task's profile names
      # them. A profile can open shell commands by prefix and subagents, and nothing else on DENIED.
      READING = %w[Read Grep Glob].freeze
      WRITING = %w[Edit Write].freeze
      # Neither the engineer's settings nor any connector reaches a call.
      ISOLATION = ["--setting-sources", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--permission-mode", "dontAsk"].freeze
      # What no call may use, and the paths a writer may not edit.
      DENIED = ["--disallowedTools", "Bash", "Agent", "Task", "WebFetch", "WebSearch", "mcp__*",
                "Edit(/**/.git/**)", "Edit(/.git)", "Edit(/**/.claude/**)", "Edit(/**/.cursor/**)",
                "Edit(/**/.env*)", "Edit(/**/AGENTS.md)", "Edit(/**/CLAUDE.md)"].freeze
      # A call runs no slash command and leaves no session behind.
      STATELESS = ["--disable-slash-commands", "--no-session-persistence"].freeze

      def initialize(config, task)
        @config, @task = config, task
      end

      def to_a
        [@config["claude_bin"], "-p", "--output-format", "json", "--json-schema", JSON.generate(enveloped), *ISOLATION,
         "--tools", tools.join(","), "--allowedTools", *allowed, *denied, *STATELESS,
         "--max-turns", @config["max_turns"].to_s, "--max-budget-usd", @task.budget_usd.to_s, "--model", model, *effort]
      end

      private

      def enveloped = {"type" => "object", "properties" => {ENVELOPE => @task.schema}, "required" => [ENVELOPE], "additionalProperties" => false}
      def tools = (@task.writable ? READING + WRITING : READING) + opened
      def allowed = (@task.writable ? [*READING, "Edit(/**)"] : READING) + profile.bash_rules + (profile.subagents? ? ["Agent"] : [])
      # A deny outranks any allow, so what the profile opens leaves the deny list. Every other entry stays.
      def denied = DENIED - opened - (profile.subagents? ? ["Task"] : [])
      def opened = [*("Bash" if profile.shell?), *("Agent" if profile.subagents?)]
      def effort = profile.effort ? ["--effort", profile.effort] : []
      def profile = @task.profile
      def model = (@config["models"] || {}).fetch(@task.step, @config["model"])
    end
  end
end
