# frozen_string_literal: true

require_relative "../errors"

module Giraffe
  module Runners
    # What a call may use beyond reading and editing: shell commands that start with one of a few named prefixes,
    # subagents on a named model, and an effort level. Giraffe's own steps use none of it. A caller that runs a
    # writer which must run the project's checks itself, such as a builder landing straight on main, opts in.
    class ToolProfile < Data.define(:bash, :subagents, :effort)
      # A prefix names a program and its leading arguments. Anything that could join, redirect or substitute
      # another command is refused, so a prefix cannot widen into a shell.
      UNSAFE = /[;&|<>`$(){}\\\n\r*?\[\]!'"]/
      MODEL = /\A[a-z0-9][a-z0-9.\-\[\]]*\z/
      EFFORTS = %w[low medium high xhigh max].freeze

      def initialize(bash: [], subagents: nil, effort: nil)
        bash.each { |prefix| validate_prefix!(prefix) }
        raise Error, "subagents must name a model" unless subagents.nil? || subagents.to_s.match?(MODEL)
        raise Error, "effort must be one of #{EFFORTS.join(', ')}" unless effort.nil? || EFFORTS.include?(effort)
        super(bash: bash.dup.freeze, subagents: subagents, effort: effort)
      end

      # From a configuration hash with string keys, as JSON gives it.
      def self.from(hash)
        new(bash: hash.fetch("bash", []), subagents: hash["subagents"], effort: hash["effort"])
      end

      def shell? = bash.any?
      def subagents? = !subagents.nil?

      # Claude Code matches "Bash(prefix:*)" against each command in a compound line, so "git status && curl x"
      # is refused unless both parts match.
      def bash_rules = bash.map { |prefix| "Bash(#{prefix}:*)" }

      private

      def validate_prefix!(prefix)
        raise Error, "a bash prefix must be a nonempty string" unless prefix.is_a?(String) && !prefix.strip.empty?
        raise Error, "a bash prefix may not hold shell syntax: #{prefix}" if prefix.match?(UNSAFE)
      end

      NONE = new
    end
  end
end
