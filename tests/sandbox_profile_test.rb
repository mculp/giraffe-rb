# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "rbconfig"
require "tmpdir"
require_relative "../lib/giraffe/checks"

# Pins, byte for byte, the command line a sandboxed check runs under. That text is all that keeps a candidate's own code
# off the network, out of the home directory's credentials and away from the keychain, so a change to it that no test
# notices is a hole nobody sees. It is reached through Checks with a command runner that only records, so nothing here
# starts sandbox-exec or needs macOS; harness_test.rb runs the real thing.
class SandboxProfileTest < Minitest::Test
  # Stands in for Giraffe::Command: remembers what it was asked to run, and says that it passed.
  class RecordingCommand
    attr_reader :requests
    def initialize = @requests = []

    def capture(argv, **options)
      @requests << [argv, options]
      {"status" => 0, "stdout" => "", "stderr" => ""}
    end
  end

  CREDENTIALS = %w[.ssh .aws .config/gh .claude .git-credentials .netrc .npmrc .docker .gnupg .zsh_history .bash_history .config/temper .local/share/temper].freeze
  NOT_MACOS = "sandboxed checks currently require macOS; use an isolated test host and explicitly set sandbox_checks=false elsewhere"

  # A home directory, a temporary directory and a checkout, with HOME and TMPDIR pointing at the first two and a PATH
  # that holds nothing of the home directory. Pretending to be macOS is all it takes to build a command line.
  def setup
    @root = File.realpath(Dir.mktmpdir("giraffe-sandbox-profile-"))
    @old_env, @old_os = ENV.to_h, RbConfig::CONFIG["host_os"]
    RbConfig::CONFIG["host_os"] = "darwin24"
    @home, @tmp, @checkout = %w[home tmp checkout].map { |name| File.join(@root, name) }
    [@home, @tmp, @checkout].each { |dir| FileUtils.mkdir_p(dir) }
    ENV["HOME"], ENV["TMPDIR"], ENV["PATH"] = @home, @tmp, "/usr/bin"
    @command = RecordingCommand.new
  end

  def teardown
    ENV.replace(@old_env)
    RbConfig::CONFIG["host_os"] = @old_os
    FileUtils.remove_entry(@root)
  end

  def checks(**config) = Giraffe::Checks.new({"sandbox_checks" => true, "checks" => [%w[true]], "check_timeout" => 30}.merge(config.transform_keys(&:to_s)), command: @command)
  def execute(*commands, cwd: @checkout, network: false, **config) = checks(**config).run(cwd, commands, network: network)
  def ran = @command.requests.map(&:first)

  def subpaths(paths) = paths.map { |path| %((subpath "#{path}")) }.join(" ")

  # No network, and writes only in the checkout and the temporary directories. The rules against credentials and the
  # keychain come last, because a later rule beats an earlier one.
  def closed_profile(home: @home, checkout: @checkout, tmp: @tmp)
    <<~PROFILE.chomp
      (version 1)
      (allow default)
      (deny network*)
      (deny file-write*)
      (allow file-write* (subpath "#{checkout}") (subpath "#{tmp}") (subpath "/private/tmp") (subpath "/dev"))
      (deny file-read* #{subpaths(CREDENTIALS.map { |path| "#{home}/#{path}" })})
      (deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd.xpc") (global-name "com.apple.secd"))
    PROFILE
  end

  # The network, and in return none of the home directory but what `readable` lists.
  def open_profile(readable, home: @home, checkout: @checkout, tmp: @tmp)
    <<~PROFILE.chomp
      (version 1)
      (allow default)
      (deny file-read* (subpath "#{home}"))
      (allow file-read-metadata)
      (allow file-read* #{subpaths(readable)})
      (deny file-write*)
      (allow file-write* (subpath "#{checkout}") (subpath "#{tmp}") (subpath "/private/tmp") (subpath "/dev"))
      (deny file-read* #{subpaths(CREDENTIALS.map { |path| "#{home}/#{path}" })})
      (deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd.xpc") (global-name "com.apple.secd"))
    PROFILE
  end

  def beside_the_checkout(home: @home, checkout: @checkout) = [checkout, "#{home}/.gitconfig", "#{home}/.config/git"]

  def test_an_ordinary_check_runs_under_a_profile_that_denies_the_network
    execute(%w[make test])
    assert_equal [["sandbox-exec", "-p", closed_profile, "make", "test"]], ran
  end

  def test_a_check_with_the_network_reads_nothing_of_the_home_directory_but_what_it_needs
    execute(%w[make test], network: true)
    assert_equal [["sandbox-exec", "-p", open_profile(beside_the_checkout), "make", "test"]], ran
  end

  def test_the_tools_on_path_in_the_home_directory_are_readable_with_the_libraries_beside_them
    %W[#{@home}/tool/bin #{@home}/tool/lib #{@home}/other/bin #{@root}/home-sibling/bin #{@root}/outside/bin].each { |dir| FileUtils.mkdir_p(dir) }
    File.write("#{@home}/notadir", "")
    File.symlink("#{@home}/tool/bin", "#{@home}/linked")
    File.symlink("#{@root}/outside/bin", "#{@home}/sneaky")
    ENV["PATH"] = [
      "#{@home}/tool/bin",          # a tool in the home directory, with a lib beside it
      "#{@home}/other/bin",         # another, with none
      "#{@home}/linked",            # a link to the first: named for where it really is
      "#{@home}/sneaky",            # a link out of the home directory: nothing of the home directory
      "#{@root}/home-sibling/bin",  # begins with the home directory's name without being in it
      "#{@root}/outside/bin", "/usr/bin",
      "#{@home}/missing/bin", "#{@home}/notadir", "", @home,
      "#{@home}/tool/bin"           # listed twice
    ].join(":")
    execute(%w[make test], network: true)
    tools = %w[tool/bin other/bin tool/bin tool/bin].map { |dir| "#{@home}/#{dir}" }
    libraries = tools.flat_map { |dir| [File.join(File.dirname(dir), "lib"), File.join(File.dirname(dir), "libexec")] }
    # Nothing deduplicates them: this test is here to notice any change in the text, and so it says so.
    assert_equal [["sandbox-exec", "-p", open_profile([*beside_the_checkout, *tools, *libraries]), "make", "test"]], ran
  end

  def test_with_no_path_there_are_no_tools
    ENV.delete("PATH")
    execute(%w[make test], network: true)
    assert_equal [["sandbox-exec", "-p", open_profile(beside_the_checkout), "make", "test"]], ran
  end

  def test_the_network_is_decided_for_each_run_and_applies_to_every_command_in_it
    checks.run(@checkout, [%w[a], %w[b]], network: true)
    checks.run(@checkout, [%w[c], %w[d]])
    open, closed = open_profile(beside_the_checkout), closed_profile
    assert_equal [["sandbox-exec", "-p", open, "a"], ["sandbox-exec", "-p", open, "b"], ["sandbox-exec", "-p", closed, "c"], ["sandbox-exec", "-p", closed, "d"]], ran
  end

  def test_the_command_is_appended_untouched
    argv = ["sh", "-c", "echo 'a b' \"c\"\n", "", "-p", "(allow network*)"]
    execute(argv)
    assert_equal ["sandbox-exec", "-p", closed_profile, *argv], ran.first
  end

  def test_the_home_directory_the_checkout_and_the_temporary_directory_are_named_as_they_really_are
    FileUtils.mkdir_p("#{@home}/tool/bin")
    %w[home-link checkout-link tmp-link].zip([@home, @checkout, @tmp]).each { |link, target| File.symlink(target, "#{@root}/#{link}") }
    ENV["HOME"], ENV["TMPDIR"], ENV["PATH"] = "#{@root}/home-link", "#{@root}/tmp-link", "#{@root}/home-link/tool/bin"
    execute(%w[make test], cwd: "#{@root}/checkout-link", network: true)
    readable = [*beside_the_checkout, "#{@home}/tool/bin", "#{@home}/tool/lib", "#{@home}/tool/libexec"]
    assert_equal [["sandbox-exec", "-p", open_profile(readable), "make", "test"]], ran
    assert_equal "#{@root}/checkout-link", @command.requests.first[1][:cwd], "it still runs where it was told to"
  end

  # The odd name carries a quote, a backslash, an interpolation and a newline: all of what would end a rule early.
  def test_a_path_is_quoted_the_way_inspect_quotes_it
    odd = File.join(@root, "a \"b\" \\c \#{d} \#$e\nf")
    FileUtils.mkdir_p(odd)
    quoted = <<~'NAME'.chomp
      a \"b\" \\c \#{d} \#$e\nf
    NAME
    execute(%w[make test], cwd: odd)
    assert_equal [["sandbox-exec", "-p", closed_profile(checkout: "#{@root}/#{quoted}"), "make", "test"]], ran
  end

  def test_the_profile_is_built_again_from_the_environment_of_each_run
    sandboxed = checks
    sandboxed.run(@checkout, [%w[make]], network: true)
    other = File.join(@root, "other")
    %w[home tmp checkout home/tool/bin].each { |dir| FileUtils.mkdir_p(File.join(other, dir)) }
    ENV["HOME"], ENV["TMPDIR"], ENV["PATH"] = File.join(other, "home"), File.join(other, "tmp"), File.join(other, "home/tool/bin")
    sandboxed.run(File.join(other, "checkout"), [%w[make]], network: true)
    home, tools = File.join(other, "home"), File.join(other, "home/tool/bin")
    readable = [File.join(other, "checkout"), "#{home}/.gitconfig", "#{home}/.config/git", tools, File.join(home, "tool/lib"), File.join(home, "tool/libexec")]
    second = open_profile(readable, home: home, checkout: File.join(other, "checkout"), tmp: File.join(other, "tmp"))
    assert_equal [open_profile(beside_the_checkout), second], ran.map { |argv| argv[2] }
  end

  def test_a_check_is_not_wrapped_when_the_sandbox_is_off_even_on_a_host_without_one
    RbConfig::CONFIG["host_os"] = "linux-gnu"
    execute(%w[make test], %w[make lint], sandbox_checks: false)
    assert_equal [%w[make test], %w[make lint]], ran
  end

  def test_off_macos_a_sandboxed_check_is_refused_before_anything_runs
    RbConfig::CONFIG["host_os"] = "linux-gnu"
    error = assert_raises(Giraffe::Error) { execute(%w[make test], %w[make lint]) }
    assert_equal NOT_MACOS, error.message
    assert_empty @command.requests
  end

  def test_with_nothing_to_run_there_is_nothing_to_refuse
    RbConfig::CONFIG["host_os"] = "linux-gnu"
    assert_empty execute
  end

  def test_a_profile_that_cannot_be_built_never_lets_the_check_run_bare
    assert_raises(Errno::ENOENT) { execute(%w[make test], cwd: File.join(@root, "gone")) }
    ENV["HOME"] = File.join(@root, "no-home")
    assert_raises(Errno::ENOENT) { execute(%w[make test]) }
    assert_empty @command.requests
  end

  def test_the_result_names_the_command_as_declared_not_as_wrapped
    assert_equal [{"command" => %w[make test], "exit_code" => 0, "excerpt" => ""}], execute(%w[make test])
  end

  def test_the_wrapped_command_runs_where_and_how_the_bare_one_would
    checks(check_timeout: 7).run(@checkout, [%w[make]])
    options = @command.requests.first.last
    assert_equal [@checkout, true, 7, "1"], [options[:cwd], options[:clean_env], options[:timeout], options[:env]["CI"]]
  end

  def test_without_commands_given_it_runs_the_configured_checks
    checks(checks: [%w[make test], %w[make lint]]).run(@checkout)
    assert_equal [%w[make test], %w[make lint]], ran.map { |argv| argv.drop(3) }
  end
end
