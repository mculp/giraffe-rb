# frozen_string_literal: true

require_relative "callees"
require_relative "tally"

module Sandi
  # Sandi's fourth rule: an entry point builds one object. RuboCop has no cop for it, so it is counted as the distinct
  # constants a script calls methods on as it runs. Wiring up five classes shows as five.
  class EntryPoints
    LIMIT = 1
    SHEBANG = /\A#!.*\bruby\b/

    def initialize(paths, root:)
      @paths, @root = paths, root
    end

    def name = "rule 4"
    def description = "distinct constants a script calls methods on outside any def, read with Prism; limit #{LIMIT}"
    def tally = @tally ||= Tally.new(over_the_limit.to_h { |path, count| [[path, "Constants"], count] })
    def summary = "entry points over #{LIMIT} constant (rule 4): #{listing}"

    private

    # Only the entry points over the limit, as {path => constants}: within it there is nothing to ratchet.
    def over_the_limit = @over_the_limit ||= constants.select { |_path, count| count > LIMIT }

    def constants = executables.to_h { |path| [path, Callees.of(File.join(@root, path)).size] }
    def executables = @paths.select { |path| File.open(File.join(@root, path), &:gets).to_s.match?(SHEBANG) }

    def listing
      return "none" if over_the_limit.empty?
      over_the_limit.sort_by { |path, count| [-count, path] }.map { |path, count| "#{path} #{count}" }.join(", ")
    end
  end
end
