# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/giraffe/runners/scripted"

class ScriptedRunnerTest < Minitest::Test
  # The runner works in a directory of its own inside another, so that a write which escapes lands somewhere the test cleans up.
  def setup
    @parent = Dir.mktmpdir("giraffe-scripted-test-")
    @tmp = File.join(@parent, "work")
    Dir.mkdir(@tmp)
  end

  def teardown = FileUtils.remove_entry(@parent)

  # Hands a runner a request the way Model does, filling in what a test does not care about.
  def ask(runner, **request) = runner.call(**{step: "build", prompt: "p", schema: {}, cwd: @tmp, writable: false, budget_usd: 1.0}.merge(request))
  def script(*entries) = Giraffe::Runners::Scripted.new({"build" => entries})

  def test_each_call_is_kept_as_a_hash_of_what_was_asked
    runner = script({"summary" => "a"}, {"summary" => "b"})
    ask(runner, prompt: "first", schema: {"type" => "object"})
    ask(runner, prompt: "second", writable: true, budget_usd: 0.5)
    assert_equal [{step: "build", prompt: "first", schema: {"type" => "object"}, cwd: @tmp, writable: false, budget_usd: 1.0},
                  {step: "build", prompt: "second", schema: {}, cwd: @tmp, writable: true, budget_usd: 0.5}], runner.calls
  end

  def test_a_call_is_kept_even_when_it_is_refused
    runner = script(Giraffe::Error.new("interrupted"))
    assert_raises(Giraffe::Error) { ask(runner) }
    assert_raises(Giraffe::Error) { ask(runner, step: "triage") }
    assert_raises(Giraffe::Error) { ask(runner) }
    assert_equal %w[build triage build], runner.calls.map { |call| call[:step] }
  end

  def test_an_entry_that_can_be_called_is_given_the_call_and_answers_for_it
    seen = nil
    runner = script(->(request) { seen = request; {"summary" => "made"} })
    result = ask(runner, prompt: "look at this")
    assert_equal runner.calls.first, seen
    assert_equal "look at this", seen[:prompt]
    assert_equal({"output" => {"summary" => "made"}, "usage" => {"cost_usd" => 0.0, "turns" => 1}}, result)
  end

  def test_what_an_entry_says_about_output_and_cost_is_what_the_runner_answers
    runner = script({"summary" => "plain"}, {"output" => {"summary" => "wrapped"}, "cost_usd" => 0.42})
    assert_equal({"output" => {"summary" => "plain"}, "usage" => {"cost_usd" => 0.0, "turns" => 1}}, ask(runner))
    assert_equal({"output" => {"summary" => "wrapped"}, "usage" => {"cost_usd" => 0.42, "turns" => 1}}, ask(runner))
  end

  def test_a_step_without_a_script_is_refused_by_name
    assert_equal "no scripted step triage", assert_raises(Giraffe::Error) { ask(script, step: "triage") }.message
  end

  def test_a_script_that_has_run_out_is_refused_by_name
    runner = script({"summary" => "only"})
    ask(runner)
    assert_equal "script exhausted for build", assert_raises(Giraffe::Error) { ask(runner) }.message
  end

  def test_an_exception_in_the_script_is_raised_and_the_next_call_gets_the_next_entry
    runner = script(Giraffe::Error.new("interrupted"), {"summary" => "again"})
    assert_equal "interrupted", assert_raises(Giraffe::Error) { ask(runner) }.message
    assert_equal({"summary" => "again"}, ask(runner)["output"])
  end

  def test_positions_start_where_they_are_given_and_are_reported_as_they_advance
    seen = []
    runner = Giraffe::Runners::Scripted.new({"build" => [{"summary" => "skipped"}, {"summary" => "second"}, {"summary" => "third"}]},
                                            positions: {"build" => 1}, on_advance: ->(positions) { seen << positions })
    assert_equal "second", ask(runner)["output"]["summary"]
    assert_equal "third", ask(runner)["output"]["summary"]
    assert_equal [{"build" => 2}, {"build" => 3}], seen
  end

  def test_a_script_can_be_read_from_a_file
    path = File.join(@tmp, "script.json")
    File.write(path, JSON.generate("build" => [{"summary" => "from the file"}]))
    assert_equal "from the file", ask(Giraffe::Runners::Scripted.new(path))["output"]["summary"]
  end

  def test_a_writer_gets_the_files_its_entry_names_inside_its_directory
    runner = script({"output" => {"summary" => "wrote"}, "writes" => {"app.rb" => "puts 1\n", "lib/deep/nested.rb" => "x = 1\n"}})
    ask(runner, writable: true)
    assert_equal "puts 1\n", File.read(File.join(@tmp, "app.rb"))
    assert_equal "x = 1\n", File.read(File.join(@tmp, "lib/deep/nested.rb"))
  end

  def test_a_reader_is_not_allowed_fixture_writes
    runner = script({"output" => {"summary" => "wrote"}, "writes" => {"app.rb" => "puts 1\n"}})
    assert_equal "fixture writes are allowed only for BUILD", assert_raises(Giraffe::Error) { ask(runner, writable: false) }.message
    refute File.exist?(File.join(@tmp, "app.rb"))
  end

  def test_a_fixture_write_cannot_leave_its_directory
    ["../outside.txt", File.join(@parent, "absolute.txt"), "lib/../../outside.txt", ".git/config", "lib/.git/hooks/pre-commit"].each do |relative|
      runner = script({"output" => {"summary" => "wrote"}, "writes" => {relative => "x"}})
      error = assert_raises(Giraffe::Error, relative) { ask(runner, writable: true) }
      assert_equal "fixture write escapes its directory", error.message, relative
    end
    assert_equal %w[work], Dir.children(@parent)
  end

  def test_a_fixture_write_cannot_follow_a_link_out_of_its_directory
    elsewhere = File.join(@parent, "elsewhere")
    Dir.mkdir(elsewhere)
    File.symlink(elsewhere, File.join(@tmp, "link"))
    runner = script({"output" => {"summary" => "wrote"}, "writes" => {"link/planted.txt" => "x"}})
    assert_equal "fixture write follows an escaping symlink", assert_raises(Giraffe::Error) { ask(runner, writable: true) }.message
    assert_empty Dir.children(elsewhere)
  end
end
