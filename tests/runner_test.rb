# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rbconfig"
require_relative "../lib/giraffe/runners/claude"

class RunnerTest < Minitest::Test
  class FakeCommand
    attr_reader :requests
    def initialize(document, status: 0)
      @document, @status, @requests = document, status, []
    end
    def run!(*, **) = "2.1.312 (Claude Code)"
    def capture(argv, **options)
      @requests << [argv, options]
      {"status" => @status, "stdout" => @document.is_a?(String) ? @document : JSON.generate(@document), "stderr" => ""}
    end
  end

  def schema = {"type" => "object", "required" => ["answer"], "properties" => {"answer" => {"type" => "string"}}, "additionalProperties" => false}
  def config = {"claude_bin" => "claude", "max_turns" => 10, "call_timeout" => 60, "model" => "sonnet"}
  def call(document, writable: false)
    @command = FakeCommand.new(document)
    Giraffe::Runners::Claude.new(config, command: @command).call(step: "review", prompt: "private prompt", schema: schema,
      cwd: Dir.pwd, writable: writable, budget_usd: 1.5)
  end
  def success = {"type" => "result", "subtype" => "success", "is_error" => false, "structured_output" => {"answer" => "ok"}, "total_cost_usd" => 0.12, "num_turns" => 2}

  def test_cli_flags_remove_unneeded_capabilities_and_keep_prompt_on_stdin
    result = call(success)
    assert_equal({"answer" => "ok"}, result["output"])
    argv, options = @command.requests.last
    assert_equal "Read,Grep,Glob", argv[argv.index("--tools") + 1]
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
    assert_equal "Read,Grep,Glob,Edit,Write", argv[argv.index("--tools") + 1]
    assert_includes argv, "Edit(/**)"
    assert_includes argv, "Edit(/.git)"
    refute_includes argv[argv.index("--tools") + 1], "Bash"
  end

  def test_success_without_structured_output_is_failure_even_at_exit_zero
    error = assert_raises(Giraffe::Error) { call(success.reject { |key, _| key == "structured_output" }) }
    assert_in_delta 0.12, error.usage["cost_usd"]
  end

  def test_invalid_structured_output_keeps_known_usage
    invalid = success.merge("structured_output" => {"answer" => 42})
    error = assert_raises(Giraffe::InvalidOutput) { call(invalid) }
    assert_in_delta 0.12, error.usage["cost_usd"]
  end

  def test_malformed_json_and_error_result_are_refused
    assert_raises(Giraffe::InvalidOutput) { call("not json") }
    assert_raises(Giraffe::Error) { call(success.merge("subtype" => "error_max_turns")) }
  end

  def test_schema_cannot_silently_ignore_unknown_keywords
    assert_raises(Giraffe::InvalidOutput) { Giraffe::Schema.check!(schema.merge("unevaluatedProperties" => false)) }
    assert_raises(Giraffe::InvalidOutput) { Giraffe::Schema.validate!(schema, {"answer" => "ok", "unexpected" => true}) }
  end
end
