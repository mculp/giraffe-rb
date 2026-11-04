# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../lib/giraffe/harness"

# What Model asks of a runner: these go through Model and a real runner, so they hold whatever the runner's own interface is.
class ModelRunnerTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  REVIEW = {"questions" => [], "summary" => "Looks fine", "findings" => []}.freeze
  DONE = {"questions" => [], "summary" => "Done"}.freeze

  # A checkout that never moves, so a call is judged only by what it was asked and what came back.
  class StillGit
    def head(_cwd) = "0123abc"
    def fingerprint(_cwd) = {"head" => "0123abc"}
    def unchanged!(_cwd, _before) = nil
  end

  class FakeCommand
    attr_reader :requests
    def initialize(output) = (@output, @requests = output, [])
    def run!(*, **) = "2.1.312 (Claude Code)"
    def capture(argv, **options)
      @requests << [argv, options]
      {"status" => 0, "stdout" => JSON.generate("type" => "result", "subtype" => "success", "is_error" => false, "total_cost_usd" => 0.5, "num_turns" => 3,
                                                "structured_output" => {"output" => @output}), "stderr" => ""}
    end
  end

  def setup = @tmp = Dir.mktmpdir("giraffe-model-runner-test-")
  def teardown = FileUtils.remove_entry(@tmp)

  def start(**overrides)
    Giraffe::Run.start(Giraffe::Config.new(Giraffe::Config::DEFAULTS.merge(
      "store" => "local", "repo" => @tmp, "runs_dir" => File.join(@tmp, "runs"), "context" => "+test/runs", "github_repo" => "example/app",
      "checks" => [[RbConfig.ruby, "-e", "1"]], "spec_command" => [RbConfig.ruby, "{spec}"], "runner" => "scripted").merge(overrides.transform_keys(&:to_s))),
                       {"id" => "DEMO-1", "title" => "Show a greeting", "description" => "Say hello."})
  end

  def asked(role, unit: "main", writable: false, inputs: {"files" => ["app.rb"]})
    Giraffe::Model::Request.new(role: role, attempt: "attempt-1", unit: unit, inputs: inputs, cwd: @tmp, writable: writable)
  end

  def role_schema(role) = JSON.parse(File.read(File.join(ROOT, "schemas", "#{role}.json")))
  def prompt_for(role, inputs) = File.read(File.join(ROOT, "prompts", "#{role}.md")) + "\n\n" + JSON.generate("preferences_and_skills" => [], "inputs" => inputs, "human_answers" => {})

  def test_a_request_becomes_what_a_runner_is_asked_in_these_fields_and_this_order
    request = asked("review", writable: false).for_runner("the prompt", 1.5).to_h
    assert_equal({step: "review", prompt: "the prompt", schema: role_schema("review"), cwd: @tmp, writable: false, budget_usd: 1.5}, request)
    assert_equal %i[step prompt schema cwd writable budget_usd], request.keys
    assert_equal true, asked("build", writable: true).for_runner("p", 2).to_h[:writable]
  end

  def test_a_runner_is_asked_for_the_roles_prompt_schema_and_directory
    runner = Giraffe::Runners::Scripted.new({"review" => [REVIEW]})
    Giraffe::Model.new(start, runner, git: StillGit.new).call(asked("review"))
    assert_equal [{step: "review", prompt: prompt_for("review", {"files" => ["app.rb"]}), schema: role_schema("review"), cwd: @tmp, writable: false, budget_usd: 3.0}], runner.calls
  end

  def test_a_writer_is_asked_to_write
    runner = Giraffe::Runners::Scripted.new({"build" => [DONE]})
    Giraffe::Model.new(start, runner, git: StillGit.new).call(asked("build", writable: true))
    assert_equal [true], runner.calls.map { |call| call[:writable] }
  end

  def test_a_runner_is_limited_to_the_smaller_of_the_call_budget_and_what_the_run_has_left
    runner = Giraffe::Runners::Scripted.new({"review" => [{"output" => REVIEW, "cost_usd" => 2.75}, REVIEW]})
    model = Giraffe::Model.new(start(call_budget_usd: 3.0, run_budget_usd: 4.0), runner, git: StillGit.new)
    model.call(asked("review", unit: "first"))
    model.call(asked("review", unit: "second"))
    assert_equal [3.0, 1.25], runner.calls.map { |call| call[:budget_usd] }
  end

  def test_claude_is_asked_in_the_roles_schema_and_limit_with_the_prompt_on_stdin
    command = FakeCommand.new(DONE)
    run = start(call_budget_usd: 1.5)
    output = Giraffe::Model.new(run, Giraffe::Runners::Claude.new(run.config, command: command), git: StillGit.new).call(asked("build", writable: true))
    assert_equal DONE, output
    argv, options = command.requests.last
    assert_equal "claude", argv.first
    assert_equal({"type" => "object", "properties" => {"output" => role_schema("build")}, "required" => ["output"], "additionalProperties" => false}, JSON.parse(argv[argv.index("--json-schema") + 1]))
    assert_equal "Read,Grep,Glob,Edit,Write", argv[argv.index("--tools") + 1]
    assert_equal "1.5", argv[argv.index("--max-budget-usd") + 1]
    assert_equal "sonnet", argv[argv.index("--model") + 1]
    assert_equal({cwd: @tmp, input: prompt_for("build", {"files" => ["app.rb"]}), timeout: 900}, options.slice(:cwd, :input, :timeout))
  end

  def test_claude_is_asked_to_only_read_when_the_request_is_not_writable
    command = FakeCommand.new(REVIEW)
    run = start
    Giraffe::Model.new(run, Giraffe::Runners::Claude.new(run.config, command: command), git: StillGit.new).call(asked("review"))
    argv = command.requests.last.first
    assert_equal "Read,Grep,Glob", argv[argv.index("--tools") + 1]
    refute_includes argv, "Edit(/**)"
  end

  def test_the_model_a_role_runs_on_is_the_one_the_config_names_for_it
    command = FakeCommand.new(REVIEW)
    run = start(models: {"review" => "opus"})
    Giraffe::Model.new(run, Giraffe::Runners::Claude.new(run.config, command: command), git: StillGit.new).call(asked("review"))
    argv = command.requests.last.first
    assert_equal "opus", argv[argv.index("--model") + 1]
  end
end
