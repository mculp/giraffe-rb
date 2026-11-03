# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "rbconfig"
require "tmpdir"
require_relative "../lib/giraffe/checks"

# The sandbox on its own. What its profile says is pinned byte for byte in sandbox_profile_test.rb, through Checks;
# these are the parts of what it offers that a Checks test cannot reach.
class SeatbeltTest < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir("giraffe-seatbelt-"))
    @old_env, @old_os = ENV.to_h, RbConfig::CONFIG["host_os"]
    RbConfig::CONFIG["host_os"] = "darwin24"
    @home, @checkout = File.join(@root, "home"), File.join(@root, "checkout")
    [@home, @checkout].each { |dir| FileUtils.mkdir_p(dir) }
    ENV["HOME"], ENV["TMPDIR"], ENV["PATH"] = @home, @root, "/usr/bin"
    @seatbelt = Giraffe::Sandbox::Seatbelt.new
  end

  def teardown
    ENV.replace(@old_env)
    RbConfig::CONFIG["host_os"] = @old_os
    FileUtils.remove_entry(@root)
  end

  def test_the_command_follows_sandbox_exec_and_its_profile
    wrapped = @seatbelt.wrap(%w[make test], cwd: @checkout)
    assert_equal %w[sandbox-exec -p], wrapped.first(2)
    assert_equal %w[make test], wrapped.last(2)
    assert_equal 5, wrapped.length
  end

  def test_the_network_is_shut_unless_asked_for
    shut = @seatbelt.wrap(%w[make], cwd: @checkout)
    assert_includes shut[2], "(deny network*)"
    assert_equal shut, @seatbelt.wrap(%w[make], cwd: @checkout, network: false)
    open = @seatbelt.wrap(%w[make], cwd: @checkout, network: true)
    refute_includes open[2], "(deny network*)"
    assert_includes open[2], %((deny file-read* (subpath "#{@home}")))
  end

  def test_each_command_gets_a_profile_from_the_machine_as_it_is_then
    first = @seatbelt.wrap(%w[make], cwd: @checkout)
    other = File.join(@root, "other")
    FileUtils.mkdir_p(other)
    ENV["HOME"] = other
    second = @seatbelt.wrap(%w[make], cwd: other)
    assert_includes first[2], %((subpath "#{@home}/.ssh"))
    assert_includes second[2], %((subpath "#{other}/.ssh"))
    refute_includes second[2], @home
  end

  def test_off_macos_it_refuses_instead_of_running_unsandboxed
    RbConfig::CONFIG["host_os"] = "linux-gnu"
    error = assert_raises(Giraffe::Error) { @seatbelt.wrap(%w[make], cwd: @checkout) }
    assert_equal "sandboxed checks currently require macOS; use an isolated test host and explicitly set sandbox_checks=false elsewhere", error.message
  end

  def test_a_profile_it_cannot_build_is_an_error_and_not_a_command_without_one
    assert_raises(Errno::ENOENT) { @seatbelt.wrap(%w[make], cwd: File.join(@root, "gone")) }
  end
end

# Checks is given a sandbox and asks it to wrap each command; it does not know which one it has.
class ChecksSandboxTest < Minitest::Test
  # Stands in for Giraffe::Command: remembers what it was asked to run, and says that it passed.
  class RecordingCommand
    attr_reader :requests
    def initialize = @requests = []

    def capture(argv, **options)
      @requests << [argv, options]
      {"status" => 0, "stdout" => "", "stderr" => ""}
    end
  end

  # Puts a word in front of the command, and remembers what it was asked.
  class FakeSandbox
    attr_reader :asked
    def initialize = @asked = []

    def wrap(argv, cwd:, network:)
      @asked << [argv, cwd, network]
      ["fenced", *argv]
    end
  end

  def setup
    @command, @sandbox = RecordingCommand.new, FakeSandbox.new
  end

  def checks(**config) = Giraffe::Checks.new({"sandbox_checks" => true, "checks" => [], "check_timeout" => 5}.merge(config.transform_keys(&:to_s)), command: @command, sandbox: @sandbox)

  def test_each_command_runs_as_the_sandbox_wrapped_it
    result = checks.run("/work", [%w[make test], %w[make lint]], network: true)
    assert_equal [[%w[make test], "/work", true], [%w[make lint], "/work", true]], @sandbox.asked
    assert_equal [%w[fenced make test], %w[fenced make lint]], @command.requests.map(&:first)
    assert_equal [%w[make test], %w[make lint]], result.map { |row| row["command"] }, "the record names the command as declared"
  end

  def test_the_network_is_not_asked_for_by_default
    checks.run("/work", [%w[make test]])
    assert_equal [[%w[make test], "/work", false]], @sandbox.asked
  end

  def test_the_sandbox_is_not_asked_when_the_checks_are_not_sandboxed
    checks(sandbox_checks: false).run("/work", [%w[make test]], network: true)
    assert_empty @sandbox.asked
    assert_equal [%w[make test]], @command.requests.map(&:first)
  end
end
