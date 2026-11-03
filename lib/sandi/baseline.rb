# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "tally"

module Sandi
  # The committed file of what each rule allows today: a count per file that may fall and never rise.
  class Baseline
    def initialize(path) = @path = path

    # What one counter allows. A file the baseline does not list is allowed nothing.
    def tally(name) = Tally.from_h(recorded.dig(name, "counts") || {})

    def write(counters)
      File.write(@path, "#{JSON.pretty_generate(counters.to_h { |counter| [counter.name, section(counter)] })}\n")
    end

    private

    def recorded
      File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
    rescue JSON::ParserError => error
      raise Error, "#{@path} is not valid JSON: #{error.message}"
    end

    # The counter says how it counted, so a reader of the file knows what the numbers are.
    def section(counter) = {"counter" => counter.description, "counts" => counter.tally.to_h}
  end
end
