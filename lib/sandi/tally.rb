# frozen_string_literal: true

module Sandi
  # How many of each kind a file has, offenses or constants called on, as {["lib/a.rb", "MethodLength"] => 2}. A file
  # with none is absent.
  class Tally
    Change = Data.define(:file, :name, :was, :now) do
      def worse? = now > was
      def improved? = now < was
      def to_s = "#{file} #{name} #{was} -> #{now}"
    end

    # The baseline file nests by file so that a diff of it reads well: {"lib/a.rb" => {"MethodLength" => 2}}.
    def self.from_h(nested)
      new(nested.flat_map { |file, names| names.map { |name, count| [[file, name], count] } }.to_h)
    end

    def initialize(counts = {}) = @counts = counts

    def keys = @counts.keys
    def count(key) = @counts.fetch(key, 0)
    def total = @counts.values.sum
    def file_count = keys.map(&:first).uniq.size

    def by_name
      @counts.each_with_object(Hash.new(0)) { |((_file, name), count), sums| sums[name] += count }.sort.to_h
    end

    # Every place the count differs from the earlier one, in file order.
    def changes_from(earlier)
      (keys | earlier.keys).sort.filter_map do |key|
        Change.new(*key, earlier.count(key), count(key)) unless count(key) == earlier.count(key)
      end
    end

    def to_h
      @counts.sort.each_with_object({}) { |((file, name), count), nested| (nested[file] ||= {})[name] = count }
    end
  end
end
