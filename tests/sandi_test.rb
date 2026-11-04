# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/sandi/cli"

# bin/sandi against a tree in a temporary directory and a `rubocop` that reports what each test says, so that these
# tests need no gems. The ratchet is what keeps the design limits from slipping back, so what it lets through matters.
class SandiTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("sandi-")
    @tools = File.join(@root, ".tools")
    FileUtils.mkdir_p(@tools)
  end

  def teardown = FileUtils.remove_entry(@root)

  # What RuboCop will report: the cops that fired in each file it inspected, one name per offense. It only reports
  # files it read, so they exist.
  def rubocop_reports(offenses)
    offenses.each_key { |path| write(path, "") unless File.exist?(File.join(@root, path)) }
    files = offenses.map { |path, cops| {"path" => path, "offenses" => cops.map { |cop| {"cop_name" => "Metrics/#{cop}"} }} }
    report = JSON.generate("metadata" => {"rubocop_version" => "1.87.0"}, "files" => files)
    install("rubocop", "printf '%s' '#{report}'\nexit #{offenses.values.flatten.empty? ? 0 : 1}")
  end

  def install(name, script)
    File.write(File.join(@tools, name), "#!/bin/sh\n#{script}\n")
    File.chmod(0o755, File.join(@tools, name))
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    File.write(File.join(@root, path), body)
  end

  def script(path, body) = write(path, "#!/usr/bin/env ruby\n#{body}")

  # The exit status of `bin/sandi *argv` with only the fake tools on the PATH. Leaves what it said in @out and @err.
  def sandi(*argv)
    out, err = StringIO.new, StringIO.new
    status = with_path(@tools) { Sandi::CLI.new(argv, root: @root, out: out, err: err).call }
    @out, @err = out.string, err.string
    status
  end

  def with_path(directory)
    saved = ENV["PATH"]
    ENV["PATH"] = directory
    yield
  ensure
    ENV["PATH"] = saved
  end

  # A baseline taken from a tree that looks like this.
  def record(offenses)
    rubocop_reports(offenses)
    assert_equal 0, sandi("--update", "--allow-increase")
  end

  def baseline = File.read(File.join(@root, ".sandi-baseline.json"))

  def test_a_tree_no_worse_than_the_baseline_passes
    record("lib/a.rb" => %w[MethodLength MethodLength], "lib/b.rb" => [])
    assert_equal 0, sandi
    assert_includes @out, "offenses: 2 (MethodLength 2) in 1 of 2 files"
  end

  def test_a_count_that_rose_fails_and_is_named
    record("lib/a.rb" => %w[MethodLength])
    rubocop_reports("lib/a.rb" => %w[MethodLength MethodLength])
    assert_equal 1, sandi
    assert_includes @out, "worse: lib/a.rb MethodLength 1 -> 2"
  end

  def test_an_offense_in_a_file_the_baseline_does_not_list_fails
    record("lib/a.rb" => [], "lib/new.rb" => [])
    rubocop_reports("lib/a.rb" => [], "lib/new.rb" => %w[ClassLength])
    assert_equal 1, sandi
    assert_includes @out, "worse: lib/new.rb ClassLength 0 -> 1"
  end

  def test_a_count_that_fell_passes_and_names_the_file_that_improved
    record("lib/a.rb" => %w[MethodLength MethodLength], "lib/b.rb" => %w[ClassLength])
    rubocop_reports("lib/a.rb" => %w[MethodLength], "lib/b.rb" => %w[ClassLength])
    assert_equal 0, sandi
    assert_includes @out, "improved: lib/a.rb MethodLength 2 -> 1"
    refute_includes @out, "worse:"
  end

  def test_a_file_that_no_longer_offends_has_improved_and_may_not_offend_again
    record("lib/a.rb" => %w[MethodLength], "lib/b.rb" => %w[ClassLength])
    rubocop_reports("lib/a.rb" => [], "lib/b.rb" => %w[ClassLength])
    assert_equal 0, sandi("--update")
    assert_includes @out, "improved: lib/a.rb MethodLength 1 -> 0"
    rubocop_reports("lib/a.rb" => %w[MethodLength], "lib/b.rb" => %w[ClassLength])
    assert_equal 1, sandi
  end

  def test_an_entry_point_calling_methods_on_more_constants_than_recorded_fails
    script("bin/tool", "Config.load\nTickets.load\n")
    record("bin/tool" => [])
    script("bin/tool", "Config.load\nTickets.load\nRun.start\n")
    assert_equal 1, sandi
    assert_includes @out, "worse: bin/tool Constants 2 -> 3"
  end

  def test_an_entry_point_that_calls_methods_on_fewer_constants_has_improved
    script("bin/tool", "Config.load\nTickets.load\nRun.start\n")
    record("bin/tool" => [])
    script("bin/tool", "Config.load\nTickets.load\n")
    assert_equal 0, sandi
    assert_includes @out, "improved: bin/tool Constants 3 -> 2"
  end

  def test_a_new_entry_point_may_call_methods_on_one_constant_and_no_more
    script("bin/one", "Harness.new(ARGV).run\n")
    script("bin/two", "Config.load\nTickets.load\n")
    rubocop_reports("bin/one" => [], "bin/two" => [])
    assert_equal 1, sandi
    assert_includes @out, "worse: bin/two Constants 0 -> 2"
    refute_includes @out, "bin/one Constants"
  end

  def test_constants_count_once_by_full_path_and_only_when_called_on_outside_a_method
    script("bin/tool", <<~RUBY)
      OptionParser.new
      Giraffe::Config.load(JSON.parse(File.read(ARGV.first)))
      Giraffe::Config.save
      def helper = Harness.new
      Giraffe::Run.start(Giraffe::Config, ENV.fetch("HOME"))
      raise Failure, "unreachable"
    RUBY
    rubocop_reports("bin/tool" => [])
    sandi("--update", "--allow-increase")
    assert_includes @out, "entry points over 1 constant (rule 4): bin/tool 2"
  end

  def test_a_file_without_a_ruby_shebang_is_not_an_entry_point
    write("lib/a.rb", "Config.load\nTickets.load\n")
    write("bin/test", "#!/usr/bin/env bash\nConfig.load Tickets.load\n")
    rubocop_reports("lib/a.rb" => [], "bin/test" => [])
    assert_equal 0, sandi
    assert_includes @out, "entry points over 1 constant (rule 4): none"
  end

  def test_update_on_an_unchanged_tree_leaves_the_baseline_alone
    script("bin/tool", "Config.load\nTickets.load\n")
    record("bin/tool" => [], "lib/a.rb" => %w[MethodLength])
    before = baseline
    assert_equal 0, sandi("--update")
    assert_equal before, baseline
  end

  def test_the_baseline_does_not_depend_on_the_order_rubocop_found_the_files_in
    record("lib/a.rb" => %w[MethodLength], "lib/b.rb" => %w[MethodLength])
    first = baseline
    record("lib/b.rb" => %w[MethodLength], "lib/a.rb" => %w[MethodLength])
    assert_equal first, baseline
  end

  def test_update_tightens_the_baseline_so_what_was_allowed_before_is_not
    record("lib/a.rb" => %w[MethodLength MethodLength])
    rubocop_reports("lib/a.rb" => %w[MethodLength])
    assert_equal 0, sandi("--update")
    rubocop_reports("lib/a.rb" => %w[MethodLength MethodLength])
    assert_equal 1, sandi
  end

  def test_update_refuses_to_raise_a_count
    record("lib/a.rb" => %w[MethodLength])
    before = baseline
    rubocop_reports("lib/a.rb" => %w[MethodLength MethodLength])
    assert_equal 1, sandi("--update")
    assert_equal before, baseline
    assert_includes @out, "--allow-increase"
  end

  def test_allow_increase_accepts_the_rise
    record("lib/a.rb" => %w[MethodLength])
    rubocop_reports("lib/a.rb" => %w[MethodLength MethodLength])
    assert_equal 0, sandi("--update", "--allow-increase")
    assert_equal 0, sandi
  end

  def test_a_missing_rubocop_says_how_to_install_it
    assert_equal 2, sandi
    assert_includes @err, "gem install rubocop -v 1.87.0 --no-document"
  end

  def test_a_rubocop_that_fails_says_why
    install("rubocop", "echo 'rubocop: configuration is broken' >&2\nexit 2")
    assert_equal 2, sandi
    assert_includes @err, "rubocop: configuration is broken"
  end

  def test_a_baseline_that_is_not_json_is_reported_rather_than_crashed_on
    write(".sandi-baseline.json", "<<<<<<< HEAD\n")
    rubocop_reports("lib/a.rb" => [])
    assert_equal 2, sandi
    assert_includes @err, "not valid JSON"
  end

  def test_allow_increase_without_update_is_misuse
    assert_equal 2, sandi("--allow-increase")
    assert_includes @err, "usage: bin/sandi"
  end

  def test_a_misspelt_flag_is_misuse_and_not_a_quiet_check
    assert_equal 2, sandi("--updaet")
    assert_includes @err, "usage: bin/sandi"
  end
end
