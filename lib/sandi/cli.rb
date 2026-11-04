# frozen_string_literal: true

require_relative "baseline"
require_relative "entry_points"
require_relative "errors"
require_relative "offenses"
require_relative "ratchet"
require_relative "rubocop"

module Sandi
  ROOT = File.expand_path("../..", __dir__)

  # bin/sandi: reads the flags, builds what the counting needs, and answers with an exit status: 0 when no count rose,
  # 1 when one did, 2 when it could not count or was misused.
  class CLI
    USAGE = "usage: bin/sandi [--update [--allow-increase]]"
    FLAGS = %w[--update --allow-increase].freeze
    BASELINE = ".sandi-baseline.json"

    def initialize(argv, root: ROOT, out: $stdout, err: $stderr)
      @argv, @root, @out, @err = argv, root, out, err
    end

    def call
      return help if @argv.intersect?(%w[-h --help])
      return complain(USAGE) unless usable?
      update? ? ratchet.update(allow_increase: allow_increase?) : ratchet.check
    rescue Error => error
      complain(error.message)
    end

    private

    def usable? = (@argv - FLAGS).empty? && (update? || !allow_increase?)
    def update? = @argv.include?("--update")
    def allow_increase? = @argv.include?("--allow-increase")

    def ratchet
      offenses = Offenses.new(Rubocop.new(@root).report)
      counters = [offenses, EntryPoints.new(offenses.paths, root: @root)]
      Ratchet.new(counters, Baseline.new(File.join(@root, BASELINE)), @out)
    end

    def help
      @out.puts(USAGE)
      0
    end

    def complain(message)
      @err.puts(message)
      2
    end
  end
end
