# frozen_string_literal: true

module Giraffe
  module Steps
    module Verify
      # The command that runs one spec, made from the repository's spec_command with {spec} and {line} filled in.
      class SpecCommand
        def initialize(arguments) = @arguments = arguments

        # A ref names a spec file and, after a colon, a line of it. Without a line the whole file runs.
        def for(ref)
          path, line = ref.split(":", 2)
          arguments = line ? @arguments : whole_file_arguments
          arguments.map { |arg| arg.gsub("{spec}", path).gsub("{line}", line.to_s) }
        end

        private

        # "path:" is not a location a framework can load, and an argument carrying only the line means nothing.
        def whole_file_arguments
          arguments = @arguments.map { |arg| arg.gsub("{spec}:{line}", "{spec}") }
          arguments.reject { |arg| arg.include?("{line}") && !arg.include?("{spec}") }
        end
      end
    end
  end
end
