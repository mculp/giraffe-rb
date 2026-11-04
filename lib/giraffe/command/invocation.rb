# frozen_string_literal: true

require_relative "../errors"

module Giraffe
  class Command
    # What one run of a command needs, so that what carries it out is handed one thing instead of seven.
    Invocation = Data.define(:argv, :cwd, :env, :timeout, :input, :clean_env, :limit) do
      def initialize(argv:, **rest)
        raise Error, "command must be a nonempty argument array" unless argv.is_a?(Array) && argv.any? && argv.all? { |part| part.is_a?(String) }
        super
      end

      # The program and its first argument: enough for an error to say which command it means, without the rest
      # of a long argument list.
      def label = argv.first(2).join(" ")

      # For Open3.popen3. A group of its own, so that ProcessGroup can end the child and whatever it starts.
      def popen3_args = [env, *argv, {chdir: cwd, pgroup: true, unsetenv_others: clean_env}]
    end
  end
end
