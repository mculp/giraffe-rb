# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/giraffe/steps"

class SpecCommandTest < Minitest::Test
  def spec_command(*arguments) = Giraffe::Steps::Verify::SpecCommand.new(arguments)

  def test_spec_command_for_a_line_and_for_a_whole_file
    {
      ["rspec", "{spec}:{line}"] => [["rspec", "a_spec.rb:3"], ["rspec", "a_spec.rb"]],
      ["run", "{spec}", "--line={line}"] => [["run", "a_spec.rb", "--line=3"], ["run", "a_spec.rb"]],
      ["run", "{spec}", "{line}"] => [["run", "a_spec.rb", "3"], ["run", "a_spec.rb"]],
      ["sh", "-c", "run {spec} # line {line}"] => [["sh", "-c", "run a_spec.rb # line 3"], ["sh", "-c", "run a_spec.rb # line "]]
    }.each do |arguments, (at_line, whole_file)|
      command = spec_command(*arguments)
      assert_equal at_line, command.for("a_spec.rb:3")
      assert_equal whole_file, command.for("a_spec.rb")
    end
  end

  # The arguments are the run's configuration, shared by every spec it runs, so a whole-file command must not edit them.
  def test_a_whole_file_leaves_the_arguments_for_the_next_spec_as_they_were
    arguments = ["run", "{spec}:{line}", "--line={line}"].freeze
    command = Giraffe::Steps::Verify::SpecCommand.new(arguments)
    assert_equal ["run", "a_spec.rb"], command.for("a_spec.rb")
    assert_equal ["run", "a_spec.rb:3", "--line=3"], command.for("a_spec.rb:3")
  end
end
