# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/giraffe/runners/claude"
require_relative "../lib/giraffe/runners/task"

# A profile opens exactly what it names, for a caller that asks for it, and nothing else on the deny list.
class ToolProfileTest < Minitest::Test
  Profile = Giraffe::Runners::ToolProfile
  REPLY = JSON.generate({"type" => "result", "subtype" => "success", "is_error" => false,
                          "structured_output" => {"output" => {}}, "total_cost_usd" => 0.1, "num_turns" => 1})
  class FakeCommand
    attr_reader :requests
    def initialize
      @requests = []
    end
    def run!(*, **) = "2.1.318 (Claude Code)"
    def capture(argv, **options)
      @requests << [argv, options]
      {"status" => 0, "stdout" => REPLY, "stderr" => ""}
    end
  end

  def config = {"claude_bin" => "claude", "max_turns" => 10, "call_timeout" => 60, "model" => "opus"}
  def builder = Profile.new(bash: ["node tools/check.mjs", "git status", "git diff"], subagents: "sonnet", effort: "medium")
  def task(profile = Profile::NONE, writable: true) = Giraffe::Runners::Task.new(step: "build", prompt: "p", schema: {}, cwd: Dir.pwd, writable: writable, budget_usd: 2, profile: profile)
  def argv(profile = Profile::NONE, **) = Giraffe::Runners::ClaudeArgv.new(config, task(profile, **)).to_a
  def list_after(flag, line) = line[(line.index(flag) + 1)..].take_while { |part| !part.start_with?("--") }
  def denied(line) = list_after("--disallowedTools", line)

  def test_no_profile_leaves_the_command_line_as_it_was
    assert_equal argv, Giraffe::Runners::ClaudeArgv.new(config, Giraffe::Runners::Task.new(step: "build", prompt: "p", schema: {}, cwd: Dir.pwd, writable: true, budget_usd: 2)).to_a
    assert_includes denied(argv), "Bash"
    refute_includes argv, "--effort"
  end

  def test_a_builder_runs_only_the_named_commands
    line = argv(builder)
    assert_equal "Read,Grep,Glob,Edit,Write,Bash,Agent", line[line.index("--tools") + 1]
    allowed = list_after("--allowedTools", line)
    assert_equal ["Bash(node tools/check.mjs:*)", "Bash(git status:*)", "Bash(git diff:*)"], allowed.grep(/\ABash/)
    refute_includes allowed, "Bash"
    assert_equal "dontAsk", line[line.index("--permission-mode") + 1]
  end

  def test_opening_the_shell_and_subagents_keeps_every_other_deny
    assert_equal Giraffe::Runners::ClaudeArgv::DENIED[1..] - %w[Bash Agent Task], denied(argv(builder))
    assert_includes denied(argv(builder)), "WebFetch"
    assert_includes denied(argv(builder)), "Edit(/**/.git/**)"
    assert_includes denied(argv(Profile.new(bash: ["git status"]))), "Agent"
  end

  def test_effort_travels_as_its_own_flag
    line = argv(builder)
    assert_equal "medium", line[line.index("--effort") + 1]
  end

  def test_commands_run_without_the_model_credential_and_subagents_on_the_named_model
    command = FakeCommand.new
    ENV["CLAUDE_CODE_OAUTH_TOKEN"] = "token"
    Giraffe::Runners::Claude.new(config, command: command).call(task(builder))
    env = command.requests.last.last[:env]
    assert_equal "1", env["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"]
    assert_equal "sonnet", env["CLAUDE_CODE_SUBAGENT_MODEL"]
    Giraffe::Runners::Claude.new(config, command: command).call(task)
    refute command.requests.last.last[:env].key?("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB")
  ensure
    ENV.delete("CLAUDE_CODE_OAUTH_TOKEN")
  end

  def test_a_prefix_cannot_widen_into_a_shell
    ["git status; curl x", "git status && rm -rf /", "node $(cat x)", "cat `x`", "echo > f", "git *", "", "  ", "a\nb", "sh -c 'x'"].each do |prefix|
      assert_raises(Giraffe::Error, prefix.inspect) { Profile.new(bash: [prefix]) }
    end
    assert_raises(Giraffe::Error) { Profile.new(bash: [nil]) }
  end

  def test_only_known_efforts_and_plain_model_names
    assert_raises(Giraffe::Error) { Profile.new(effort: "extreme") }
    assert_raises(Giraffe::Error) { Profile.new(subagents: "sonnet --dangerously-skip-permissions") }
    assert_equal "claude-sonnet-5-5", Profile.new(subagents: "claude-sonnet-5-5").subagents
  end

  def test_a_profile_reads_from_json
    profile = Profile.from(JSON.parse('{"bash":["node tools/check.mjs"],"subagents":"sonnet","effort":"medium"}'))
    assert_equal ["Bash(node tools/check.mjs:*)"], profile.bash_rules
    assert_equal Profile::NONE, Profile.from({})
  end
end
