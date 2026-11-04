# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../lib/giraffe/command"

# How a run of a command ends, and what it leaves behind: the parts of Command that no caller's test reaches, since
# they all run it through a fake or only ever see it succeed. Every command is a Ruby one-liner, so none of them
# needs a tool the host might lack.
class CommandTest < Minitest::Test
  # How long the descendant below sleeps before it would leave its mark.
  DESCENDANT_DELAY = 1.5

  def setup
    @tmp = Dir.mktmpdir("giraffe-command-test-")
    @command = Giraffe::Command.new
  end

  def teardown
    ENV.delete("GIRAFFE_COMMAND_TEST")
    FileUtils.remove_entry(@tmp)
  end

  def ruby(script, *arguments) = [RbConfig.ruby, "-e", script, *arguments]
  def mark = File.join(@tmp, "survived")
  def ready = File.join(@tmp, "ready")

  # Starts a descendant that writes `mark` once DESCENDANT_DELAY has gone, says so by writing `ready`, and goes on
  # as `afterwards` says. The descendant's streams go nowhere, so only its process group can stop it, never the end
  # of a pipe.
  def leaving_a_descendant(afterwards)
    descendant = "sleep #{DESCENDANT_DELAY}; File.write(ARGV[0], 'survived')"
    ruby(<<~RUBY, mark, ready)
      spawn(RbConfig.ruby, "-e", #{descendant.inspect}, ARGV[0], in: File::NULL, out: File::NULL, err: File::NULL)
      File.write(ARGV[1], "")
      #{afterwards}
    RUBY
  end

  # Whether the descendant got to write, once it had every chance to.
  def descendant_wrote?
    assert File.exist?(ready), "the command was stopped before it started its descendant"
    wait = File.mtime(ready) + DESCENDANT_DELAY + 0.5 - Time.now
    sleep wait if wait.positive?
    File.exist?(mark)
  end

  def test_cancelling_stops_a_run_and_everything_it_started
    command = Giraffe::Command.new(cancelled: -> { File.exist?(ready) })
    error = assert_raises(Giraffe::Cancelled) { command.capture(leaving_a_descendant("sleep 30"), cwd: @tmp, timeout: 30) }
    assert_equal "run cancelled", error.message
    refute descendant_wrote?, "a descendant outlived the run that was cancelled"
  end

  def test_a_run_past_its_time_ends_everything_it_started
    error = assert_raises(Giraffe::CommandLimit) { @command.capture(leaving_a_descendant("sleep 30"), cwd: @tmp, timeout: 1) }
    assert_equal "#{RbConfig.ruby} -e timed out after 1s", error.message
    refute descendant_wrote?, "a descendant outlived the run that timed out"
  end

  def test_a_run_that_finishes_ends_what_it_left_running
    assert_equal 0, @command.capture(leaving_a_descendant("exit 0"), cwd: @tmp)["status"]
    refute descendant_wrote?, "a descendant outlived the run that started it"
  end

  def test_a_child_can_answer_while_it_is_still_being_told
    echo = ruby('$stdout.sync = true; while (chunk = $stdin.read(65_536)); $stdout.write(chunk); end')
    input = ("a".."z").to_a.join * 40_000
    result = @command.capture(echo, cwd: @tmp, input: input, timeout: 20)
    assert_equal 0, result["status"]
    assert_equal input, result["stdout"]
  end

  def test_a_child_that_never_reads_its_input_does_not_fail_the_run
    result = @command.capture(ruby("exit 0"), cwd: @tmp, input: "x" * 1_000_000)
    assert_equal 0, result["status"]
  end

  def test_a_child_killed_by_a_signal_exits_with_128_plus_it
    assert_equal 137, @command.capture(ruby('Process.kill("KILL", $$)'), cwd: @tmp)["status"]
  end

  def test_output_that_is_not_utf8_comes_back_scrubbed
    result = @command.capture(ruby(%q($stdout.write("\xFFok".b); $stderr.write("e\xC3".b))), cwd: @tmp)
    assert_equal ["�ok", "e�"], [result["stdout"], result["stderr"]]
  end

  def test_stderr_is_held_to_the_output_limit_as_well_and_a_limit_is_not_passed_by_staying_on_it
    assert_equal "x" * 10, @command.capture(ruby('print "x" * 10'), cwd: @tmp, limit: 10)["stdout"]
    error = assert_raises(Giraffe::CommandLimit) { @command.capture(ruby('$stderr.print "x" * 11'), cwd: @tmp, limit: 10) }
    assert_equal "#{RbConfig.ruby} -e output exceeds 10 bytes", error.message
  end

  def test_the_child_runs_where_it_is_told_with_env_added_to_what_it_inherits_unless_it_starts_clean
    ENV["GIRAFFE_COMMAND_TEST"] = "inherited"
    show = ruby('print [Dir.pwd, ENV["GIRAFFE_COMMAND_TEST"], ENV["ADDED"]].inspect')
    inheriting = @command.capture(show, cwd: @tmp, env: {"ADDED" => "yes"})
    clean = @command.capture(show, cwd: @tmp, env: {"ADDED" => "yes"}, clean_env: true)
    assert_equal [File.realpath(@tmp), "inherited", "yes"].inspect, inheriting["stdout"]
    assert_equal [File.realpath(@tmp), nil, "yes"].inspect, clean["stdout"]
  end

  def test_a_command_that_is_not_a_nonempty_array_of_strings_is_refused_before_anything_starts
    [[], "echo hi", ["echo", 1], ["echo", nil], nil].each do |argv|
      error = assert_raises(Giraffe::Error, argv.inspect) { @command.capture(argv, cwd: @tmp) }
      assert_equal "command must be a nonempty argument array", error.message
    end
  end
end
