# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/giraffe/runners/claude"
require_relative "../lib/giraffe/runners/task"

class RunnerTest < Minitest::Test
  class FakeCommand
    attr_reader :requests, :versions
    def initialize(document, status: 0, version: "2.1.312 (Claude Code)")
      @document, @status, @version, @requests, @versions = document, status, version, [], []
    end
    def run!(argv, **options)
      @versions << [argv, options]
      @version
    end
    def capture(argv, **options)
      @requests << [argv, options]
      {"status" => @status, "stdout" => @document.is_a?(String) ? @document : JSON.generate(@document), "stderr" => ""}
    end
  end

  # What the test schema becomes on the way to the API: its shape one level down, in this key order.
  ENVELOPED_SCHEMA = '{"type":"object","properties":{"output":{"type":"object","required":["answer"],"properties":{"answer":{"type":"string"}},"additionalProperties":false}},"required":["output"],"additionalProperties":false}'
  # The whole command line of a call that may only read, and of one that may write. Nothing else gets through.
  READER_ARGV = ["claude", "-p", "--output-format", "json", "--json-schema", ENVELOPED_SCHEMA,
                 "--setting-sources", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                 "--permission-mode", "dontAsk", "--tools", "Read,Grep,Glob", "--allowedTools", "Read", "Grep", "Glob",
                 "--disallowedTools", "Bash", "Agent", "Task", "WebFetch", "WebSearch", "mcp__*",
                 "Edit(/**/.git/**)", "Edit(/.git)", "Edit(/**/.claude/**)", "Edit(/**/.cursor/**)",
                 "Edit(/**/.env*)", "Edit(/**/AGENTS.md)", "Edit(/**/CLAUDE.md)",
                 "--disable-slash-commands", "--no-session-persistence", "--max-turns", "10",
                 "--max-budget-usd", "1.5", "--model", "sonnet"].freeze
  WRITER_ARGV = ["claude", "-p", "--output-format", "json", "--json-schema", ENVELOPED_SCHEMA,
                 "--setting-sources", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                 "--permission-mode", "dontAsk", "--tools", "Read,Grep,Glob,Edit,Write", "--allowedTools", "Read", "Grep", "Glob", "Edit(/**)",
                 "--disallowedTools", "Bash", "Agent", "Task", "WebFetch", "WebSearch", "mcp__*",
                 "Edit(/**/.git/**)", "Edit(/.git)", "Edit(/**/.claude/**)", "Edit(/**/.cursor/**)",
                 "Edit(/**/.env*)", "Edit(/**/AGENTS.md)", "Edit(/**/CLAUDE.md)",
                 "--disable-slash-commands", "--no-session-persistence", "--max-turns", "10",
                 "--max-budget-usd", "1.5", "--model", "sonnet"].freeze
  # A parent environment holding both what a call may inherit and what it may not.
  PARENT_ENV = {"PATH" => "/usr/bin", "HOME" => "/home/giraffe", "TMPDIR" => "/tmp/giraffe", "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8",
                "USER" => "giraffe", "ANTHROPIC_API_KEY" => "model-key", "CLAUDE_CODE_OAUTH_TOKEN" => "model-token",
                "GH_TOKEN" => "never", "LINEAR_API_KEY" => "never", "SHELL" => "/bin/zsh", "GEM_HOME" => "/gems"}.freeze

  def schema = {"type" => "object", "required" => ["answer"], "properties" => {"answer" => {"type" => "string"}}, "additionalProperties" => false}
  def config = {"claude_bin" => "claude", "max_turns" => 10, "call_timeout" => 60, "model" => "sonnet"}
  # Hands a runner a request the way Model does.
  def ask(runner, **request) = runner.call(Giraffe::Runners::Task.new(**request))
  def call(document, writable: false, status: 0, settings: config, step: "review", budget: 1.5)
    @command = FakeCommand.new(document, status: status)
    ask(Giraffe::Runners::Claude.new(settings, command: @command), step: step, prompt: "private prompt", schema: schema, cwd: Dir.pwd, writable: writable, budget_usd: budget)
  end
  # A call with nothing in it that matters, for the tests about everything around a call.
  def plain(runner) = ask(runner, step: "review", prompt: "p", schema: schema, cwd: "/work", writable: false, budget_usd: 1)
  def success = {"type" => "result", "subtype" => "success", "is_error" => false, "structured_output" => {"output" => {"answer" => "ok"}}, "total_cost_usd" => 0.12, "num_turns" => 2}
  def argv_after(**options) = (call(success, **options); @command.requests.last.first)
  def value_after(flag, **options) = (argv = argv_after(**options); argv[argv.index(flag) + 1])

  def with_env(variables)
    saved = ENV.to_h
    ENV.replace(variables)
    yield
  ensure
    ENV.replace(saved)
  end

  def test_cli_flags_remove_unneeded_capabilities_and_keep_prompt_on_stdin
    result = call(success)
    assert_equal({"answer" => "ok"}, result["output"])
    argv, options = @command.requests.last
    tools = argv[argv.index("--tools") + 1].split(",")
    assert_empty tools & %w[Bash Edit Write Agent Task WebFetch WebSearch]
    assert_equal "dontAsk", argv[argv.index("--permission-mode") + 1]
    assert_equal "", argv[argv.index("--setting-sources") + 1]
    assert_includes argv, "--strict-mcp-config"
    assert_includes argv, "--disable-slash-commands"
    assert_includes argv, "--json-schema"
    assert_equal "1.5", argv[argv.index("--max-budget-usd") + 1]
    refute_includes argv, "private prompt"
    assert_equal "private prompt", options[:input]
    assert options[:clean_env]
    refute options[:env].key?("GH_TOKEN")
    refute options[:env].key?("LINEAR_API_KEY")
  end

  def test_writer_has_scoped_edits_but_no_shell_tool
    call(success, writable: true)
    argv = @command.requests.last.first
    assert_empty argv[argv.index("--tools") + 1].split(",") & %w[Bash Agent Task WebFetch WebSearch]
    assert_includes argv, "Edit(/**)"
    assert_includes argv, "Edit(/.git)"
  end

  def test_a_reader_gets_exactly_this_command_line
    assert_equal READER_ARGV, argv_after
  end

  def test_a_writer_gets_exactly_this_command_line
    assert_equal WRITER_ARGV, argv_after(writable: true)
  end

  def test_the_command_line_depends_on_the_config_and_the_task_alone
    reader = Giraffe::Runners::Task.new(step: "review", prompt: "p", schema: schema, cwd: "/work", writable: false, budget_usd: 1.5)
    assert_equal READER_ARGV, Giraffe::Runners::ClaudeArgv.new(config, reader).to_a
    assert_equal WRITER_ARGV, Giraffe::Runners::ClaudeArgv.new(config, reader.with(writable: true)).to_a
  end

  def test_a_task_that_does_not_say_it_may_write_may_not
    assert_equal false, Giraffe::Runners::Task.new(step: "review", prompt: "p", schema: schema, cwd: "/work", budget_usd: 1).writable
  end

  def test_a_call_that_does_not_say_it_may_write_only_reads
    command = FakeCommand.new(success)
    ask(Giraffe::Runners::Claude.new(config, command: command), step: "review", prompt: "p", schema: schema, cwd: Dir.pwd, budget_usd: 1)
    argv = command.requests.last.first
    assert_equal "Read,Grep,Glob", argv[argv.index("--tools") + 1]
    refute_includes argv, "Edit(/**)"
  end

  def test_a_step_runs_on_the_model_the_config_names_for_it_and_otherwise_on_the_default
    named = config.merge("models" => {"review" => "opus"})
    assert_equal "opus", value_after("--model", settings: named, step: "review")
    assert_equal "sonnet", value_after("--model", settings: named, step: "audit")
    assert_equal "sonnet", value_after("--model", settings: config.merge("models" => {}), step: "review")
  end

  def test_the_budget_travels_as_its_own_text
    {1 => "1", 1.5 => "1.5", 3.0 => "3.0", 0.0505 => "0.0505", 0.1 + 0.2 => "0.30000000000000004"}.each do |budget, text|
      assert_equal text, value_after("--max-budget-usd", budget: budget)
    end
  end

  def test_the_binary_and_the_turn_limit_come_from_the_config
    settings = config.merge("claude_bin" => "/opt/claude/bin/claude", "max_turns" => 7)
    assert_equal "/opt/claude/bin/claude", argv_after(settings: settings).first
    assert_equal "7", value_after("--max-turns", settings: settings)
  end

  def test_the_child_runs_in_the_calls_directory_on_stdin_with_only_model_authentication
    with_env(PARENT_ENV) { call(success) }
    inherited = {"PATH" => "/usr/bin", "HOME" => "/home/giraffe", "TMPDIR" => "/tmp/giraffe", "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8",
                 "USER" => "giraffe", "ANTHROPIC_API_KEY" => "model-key", "CLAUDE_CODE_OAUTH_TOKEN" => "model-token",
                 "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1"}
    assert_equal({cwd: Dir.pwd, env: inherited, clean_env: true, input: "private prompt", timeout: 60}, @command.requests.last.last)
  end

  def test_what_the_parent_does_not_have_is_not_invented
    with_env("PATH" => "/usr/bin") { call(success) }
    assert_equal({"PATH" => "/usr/bin", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1"}, @command.requests.last.last[:env])
  end

  def test_the_version_is_asked_of_the_binary_once_from_the_calls_directory
    command = FakeCommand.new(success)
    runner = Giraffe::Runners::Claude.new(config.merge("claude_bin" => "/opt/claude/bin/claude"), command: command)
    2.times { plain(runner) }
    assert_equal [[["/opt/claude/bin/claude", "--version"], {cwd: "/work", timeout: 15}]], command.versions
    assert_equal ["/work", "/work"], command.requests.map { |_argv, options| options[:cwd] }
  end

  def test_a_version_below_the_minimum_or_unreadable_stops_the_call_and_is_asked_again
    ["2.1.311 (Claude Code)", "no version here"].each do |version|
      command = FakeCommand.new(success, version: version)
      runner = Giraffe::Runners::Claude.new(config, command: command)
      2.times do
        error = assert_raises(Giraffe::Error) { plain(runner) }
        assert_equal "Claude Code 2.1.312 or newer is required", error.message
      end
      assert_equal 2, command.versions.length, "a refusal is not remembered"
      assert_empty command.requests, "no call is paid for under a version that is too old"
    end
  end

  def test_the_minimum_version_and_newer_ones_are_accepted
    ["2.1.312", "2.1.313 (Claude Code)", "2.2.0", "10.0.0"].each do |version|
      command = FakeCommand.new(success, version: version)
      plain(Giraffe::Runners::Claude.new(config, command: command))
      assert_equal 1, command.requests.length, version
    end
  end

  def test_success_is_the_unwrapped_output_and_what_it_cost_and_nothing_else
    assert_equal({"output" => {"answer" => "ok"}, "usage" => {"cost_usd" => 0.12, "turns" => 2}}, call(success))
  end

  def test_success_without_structured_output_is_failure_even_at_exit_zero
    error = assert_raises(Giraffe::Error) { call(success.reject { |key, _| key == "structured_output" }) }
    assert_in_delta 0.12, error.usage["cost_usd"]
  end

  def test_structured_output_returns_with_its_usage_for_the_caller_to_judge
    result = call(success.merge("structured_output" => {"output" => {"answer" => 42}}))
    assert_equal({"answer" => 42}, result["output"])
    assert_in_delta 0.12, result["usage"]["cost_usd"]
  end

  def test_every_role_schema_is_sent_with_a_top_level_the_api_accepts
    Dir[File.expand_path("../schemas/*.json", __dir__)].each do |path|
      role_schema = JSON.parse(File.read(path))
      command = FakeCommand.new(success)
      ask(Giraffe::Runners::Claude.new(config, command: command), step: "review", prompt: "p", schema: role_schema, cwd: Dir.pwd, budget_usd: 1)
      argv = command.requests.last.first
      sent = JSON.parse(argv[argv.index("--json-schema") + 1])
      assert_equal "object", sent["type"], path
      assert_empty sent.keys & %w[oneOf anyOf allOf], path
      assert_equal role_schema, sent.dig("properties", "output"), path
    end
  end

  def test_plan_schema_offers_only_the_evidence_roles_the_contract_accepts
    root = File.expand_path("..", __dir__)
    contract = JSON.parse(File.read(File.join(root, "references/outcome-contract-v1.json"))).fetch("implementation_plan")
    plan = JSON.parse(File.read(File.join(root, "schemas/plan.json"))).fetch("oneOf").last
    evidence = plan.dig("properties", "implementation_plan", "properties", "steps", "items", "properties", "evidence", "items", "oneOf")
    assert_equal contract.fetch("roles") - ["gap"], evidence.first.dig("properties", "role", "enum")
  end

  def test_a_failed_call_says_why_in_claudes_own_words
    error = assert_raises(Giraffe::Error) { call(success.merge("is_error" => true, "result" => "You've hit your 5-hour limit")) }
    assert_includes error.message, "5-hour limit"
  end

  def test_a_failure_names_the_step_and_what_the_call_reported_spending
    error = assert_raises(Giraffe::Error) { call(success.merge("is_error" => true, "result" => "usage limit reached"), step: "audit") }
    assert_equal "Claude audit did not return a successful structured result: usage limit reached", error.message
    assert_equal({"cost_usd" => 0.12, "turns" => 2}, error.usage)
  end

  def test_a_failure_that_reported_nothing_spent_nothing
    error = assert_raises(Giraffe::Error) { call({"type" => "result", "subtype" => "error_during_execution"}) }
    assert_equal({"cost_usd" => 0.0, "turns" => 0}, error.usage)
  end

  def test_the_reason_falls_back_from_the_result_to_the_subtype_to_the_exit_status
    assert_match(/: error_max_turns\z/, assert_raises(Giraffe::Error) { call(success.merge("subtype" => "error_max_turns")) }.message)
    assert_match(/: success\z/, assert_raises(Giraffe::Error) { call(success, status: 1) }.message, "a nonzero exit fails a document that looks fine")
    assert_match(/: 7\z/, assert_raises(Giraffe::Error) { call({"type" => "result"}, status: 7) }.message)
  end

  def test_the_reason_is_stripped_and_cut_to_its_last_thousand_characters
    long = assert_raises(Giraffe::Error) { call(success.merge("is_error" => true, "result" => "#{'x' * 1_200}END")) }
    assert_equal "#{'x' * 997}END", long.message.delete_prefix("Claude review did not return a successful structured result: ")
    padded = assert_raises(Giraffe::Error) { call(success.merge("is_error" => true, "result" => "  padded\n")) }
    assert_match(/: padded\z/, padded.message)
  end

  def test_output_that_does_not_carry_the_envelope_is_a_failure
    [{"answer" => "ok"}, "text", nil].each do |structured|
      error = assert_raises(Giraffe::Error) { call(success.merge("structured_output" => structured)) }
      assert_match(/did not return a successful structured result/, error.message)
    end
  end

  def test_malformed_json_and_error_result_are_refused
    assert_raises(Giraffe::InvalidOutput) { call("not json") }
    assert_raises(Giraffe::Error) { call(success.merge("subtype" => "error_max_turns")) }
  end

  def test_malformed_json_says_so
    ["not json", ""].each do |stdout|
      assert_equal "Claude returned malformed JSON", assert_raises(Giraffe::InvalidOutput) { call(stdout) }.message
    end
  end
end
